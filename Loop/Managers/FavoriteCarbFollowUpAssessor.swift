//
//  FavoriteCarbFollowUpAssessor.swift
//  Loop
//
//  Asks the meal estimate, once per favorite food, how much fat and protein it holds.
//

import Foundation
import LoopKit
import os.log

/// Finds the fat and protein in each favorite food, from which a meal's later carbs are worked out.
///
/// Every favorite is looked at once, and again after it is edited — here or in the caregiver app.
/// The estimate only supplies the fat and protein; whether that adds up to later carbs is decided
/// by `CarbFollowUpPlanner` for the whole meal, so porridge and the milk after it count together.
@MainActor
final class FavoriteCarbFollowUpAssessor {
    static let shared = FavoriteCarbFollowUpAssessor()

    private let log = OSLog(category: "FavoriteCarbFollowUpAssessor")
    private var isRunning = false
    private var runAgain = false
    private var pending: Task<Void, Never>?
    private var isObserving = false

    private init() {}

    /// Starts listening for edited favorites and assesses what has not been assessed. Called once
    /// at launch, and safe to call again.
    func start() {
        guard MealCarbEstimator.shared != nil else { return }
        Self.retireSuggestedRules()
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

    /// Runs after a short delay. A run under way is never interrupted — the favorites sync after
    /// every loop, which used to cut it off mid-food — it just goes round once more afterwards.
    func runSoon(delay: TimeInterval = 5) {
        if isRunning {
            runAgain = true
            return
        }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Its own task, so cancelling the wait never cancels a request already out.
            Task { @MainActor [weak self] in await self?.run() }
        }
    }

    /// The favorites whose fat and protein are missing or describe an older version of the food, and
    /// those assessed before the estimate was asked whether they rise late.
    static func foodsNeedingAssessment(_ foods: [StoredFavoriteFood], assessments: [String: FavoriteCarbFollowUpAssessment]) -> [StoredFavoriteFood] {
        foods.filter { food in
            guard let assessment = assessments[food.id], assessment.nutrition?.delayedRise != nil else { return true }
            return assessment.contentKey != FavoriteCarbFollowUpAssessment.contentKey(for: food)
        }
    }

    /// Keeps a new assessment's fat and protein, and whatever was set by hand.
    static func apply(_ nutrition: MealNutrition?, contentKey: String, to foodID: String, defaults: UserDefaults = .standard) {
        var assessments = defaults.carbFollowUpAssessments
        var assessment = assessments[foodID] ?? FavoriteCarbFollowUpAssessment(contentKey: contentKey)
        assessment.contentKey = contentKey
        assessment.nutrition = nutrition ?? .zero
        assessments[foodID] = assessment
        defaults.carbFollowUpAssessments = assessments
        NotificationCenter.default.post(name: .carbFollowUpRulesDidChange, object: nil)
    }

    /// The first build of later carbs turned the estimate's own guess into a fixed amount on each
    /// favorite. Those amounts were too unsteady to keep, so the ones nobody touched are removed;
    /// the amount is worked out for each meal instead.
    static func retireSuggestedRules(defaults: UserDefaults = .standard) {
        var rules = defaults.carbFollowUpRules
        var assessments = defaults.carbFollowUpAssessments
        var changed = false
        for (id, assessment) in assessments where assessment.suggestion != nil {
            if !assessment.userChanged, rules[id] == assessment.suggestion {
                rules[id] = nil
            }
            assessments[id]?.suggestion = nil
            assessments[id]?.reason = nil
            changed = true
        }
        guard changed else { return }
        defaults.carbFollowUpAssessments = assessments
        defaults.carbFollowUpRules = rules
    }

    private func run() async {
        guard !isRunning, let estimator = MealCarbEstimator.shared else { return }
        isRunning = true
        defer {
            isRunning = false
            if runAgain {
                runAgain = false
                runSoon()
            }
        }

        let defaults = UserDefaults.standard
        let foods = Self.foodsNeedingAssessment(defaults.favoriteFoods, assessments: defaults.carbFollowUpAssessments)
        guard !foods.isEmpty else { return }
        log.default("Estimating fat and protein for %d favorite foods", foods.count)

        for food in foods {
            do {
                let nutrition = try await estimator.estimateNutrition(of: food)
                // The food may have been edited or deleted while the estimate was out.
                guard let current = defaults.favoriteFoods.first(where: { $0.id == food.id }),
                      FavoriteCarbFollowUpAssessment.contentKey(for: current) == FavoriteCarbFollowUpAssessment.contentKey(for: food) else { continue }
                Self.apply(nutrition, contentKey: FavoriteCarbFollowUpAssessment.contentKey(for: food), to: food.id, defaults: defaults)
            } catch {
                // Offline or rate limited: the rest waits for the next launch or edit.
                log.error("Could not estimate fat and protein for %{public}@: %{public}@", food.name, String(describing: error))
                return
            }
        }
    }
}
