//
//  FavoriteCarbFollowUpAssessor.swift
//  Loop
//
//  Asks the meal estimate, once per favorite food, whether it causes a late rise.
//

import Foundation
import LoopKit
import os.log

/// Gives favorite foods later carbs where the meal estimate expects a late rise.
///
/// Every favorite is looked at once, and again after it is edited — here or in the caregiver app.
/// A suggestion becomes the food's rule straight away, so the later carbs follow the food without
/// anyone having to accept them; the favorite's screen says it came from the estimate and turns it
/// off. A rule set or turned off by hand is never overwritten.
@MainActor
final class FavoriteCarbFollowUpAssessor {
    static let shared = FavoriteCarbFollowUpAssessor()

    private let log = OSLog(category: "FavoriteCarbFollowUpAssessor")
    private var isRunning = false
    private var pending: Task<Void, Never>?
    private var isObserving = false

    private init() {}

    /// Starts listening for edited favorites and assesses what has not been assessed. Called once
    /// at launch, and safe to call again.
    func start() {
        guard MealCarbEstimator.shared != nil else { return }
        if !isObserving {
            isObserving = true
            for name in [Notification.Name.favoriteFoodsEditedLocally, .favoriteFoodsChangedBySync] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                    Task { @MainActor in self?.runSoon() }
                }
            }
        }
        runSoon(delay: 20)
    }

    func runSoon(delay: TimeInterval = 5) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    /// The favorites whose assessment is missing or describes an older version of the food.
    static func foodsNeedingAssessment(_ foods: [StoredFavoriteFood], assessments: [String: FavoriteCarbFollowUpAssessment], rules: [String: CarbFollowUpRule]) -> [StoredFavoriteFood] {
        foods.filter { food in
            if let assessment = assessments[food.id] {
                return assessment.contentKey != FavoriteCarbFollowUpAssessment.contentKey(for: food) && !assessment.userChanged
            }
            // A food that already has a rule set by hand keeps it.
            return rules[food.id] == nil
        }
    }

    /// Applies an assessment: the suggestion becomes the rule, unless the rule was set by hand.
    static func apply(_ assessment: FavoriteCarbFollowUpAssessment, to foodID: String, defaults: UserDefaults = .standard) {
        let previous = defaults.carbFollowUpAssessments[foodID]
        var assessments = defaults.carbFollowUpAssessments
        assessments[foodID] = assessment
        defaults.carbFollowUpAssessments = assessments

        var rules = defaults.carbFollowUpRules
        let ruleIsTheOldSuggestion = rules[foodID] == nil || rules[foodID] == previous?.suggestion
        guard ruleIsTheOldSuggestion, rules[foodID] != assessment.suggestion else { return }
        rules[foodID] = assessment.suggestion
        defaults.carbFollowUpRules = rules
    }

    private func run() async {
        guard !isRunning, let estimator = MealCarbEstimator.shared else { return }
        isRunning = true
        defer { isRunning = false }

        let defaults = UserDefaults.standard
        let foods = Self.foodsNeedingAssessment(defaults.favoriteFoods, assessments: defaults.carbFollowUpAssessments, rules: defaults.carbFollowUpRules)
        guard !foods.isEmpty else { return }
        log.default("Assessing later carbs for %d favorite foods", foods.count)

        for food in foods {
            guard !Task.isCancelled else { return }
            do {
                let (rule, reason) = try await estimator.assessLaterCarbs(for: food)
                // The food may have been edited or deleted while the estimate was out.
                guard let current = defaults.favoriteFoods.first(where: { $0.id == food.id }),
                      FavoriteCarbFollowUpAssessment.contentKey(for: current) == FavoriteCarbFollowUpAssessment.contentKey(for: food) else { continue }
                Self.apply(FavoriteCarbFollowUpAssessment(contentKey: FavoriteCarbFollowUpAssessment.contentKey(for: food), suggestion: rule, reason: reason), to: food.id, defaults: defaults)
            } catch {
                // Offline or rate limited: the rest waits for the next launch or edit.
                log.error("Could not assess later carbs for %{public}@: %{public}@", food.name, String(describing: error))
                return
            }
        }
    }
}
