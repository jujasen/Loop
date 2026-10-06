//
//  FavoriteNutritionAssessor.swift
//  Loop
//
//  Asks the meal estimate, once per favorite food, how much fat and protein it holds.
//

import Foundation
import LoopKit
import os.log

/// Finds the fat and protein in each favorite food, from which a meal's fat and protein boost is
/// worked out.
///
/// Every favorite is looked at once, and again after it is edited — here or in the caregiver app.
/// Whether that adds up to a boost is decided by `FatProteinBoostPlanner` for the whole meal, so
/// porridge and the milk after it count together.
@MainActor
final class FavoriteNutritionAssessor {
    static let shared = FavoriteNutritionAssessor()

    private let log = OSLog(category: "FavoriteNutritionAssessor")
    private var isRunning = false
    private var runAgain = false
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

    /// Runs after a short delay. A run under way is never interrupted — the favorites sync after
    /// every loop, which would otherwise cut it off mid-food — it just goes round once more afterwards.
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

    /// The favorites whose fat and protein are missing or describe an older version of the food.
    /// Values typed in by hand are kept whatever happens to the food.
    static func foodsNeedingAssessment(_ foods: [StoredFavoriteFood], assessments: [String: FavoriteNutritionAssessment]) -> [StoredFavoriteFood] {
        foods.filter { food in
            guard let assessment = assessments[food.id], assessment.nutrition != nil else { return true }
            if assessment.isUserSet == true { return false }
            return assessment.contentKey != FavoriteNutritionAssessment.contentKey(for: food)
        }
    }

    /// Keeps a food's fat and protein: from the estimate, or typed in by hand.
    static func apply(_ nutrition: MealNutrition?, isUserSet: Bool = false, to food: StoredFavoriteFood, defaults: UserDefaults = .standard) {
        var assessments = defaults.favoriteNutritionAssessments
        assessments[food.id] = FavoriteNutritionAssessment(
            contentKey: FavoriteNutritionAssessment.contentKey(for: food),
            nutrition: nutrition ?? .zero,
            isUserSet: isUserSet ? true : nil
        )
        defaults.favoriteNutritionAssessments = assessments
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
        let foods = Self.foodsNeedingAssessment(defaults.favoriteFoods, assessments: defaults.favoriteNutritionAssessments)
        guard !foods.isEmpty else { return }
        log.default("Estimating fat and protein for %d favorite foods", foods.count)

        for food in foods {
            do {
                let nutrition = try await estimator.estimateNutrition(of: food)
                // The food may have been edited or deleted, or its values typed in, while the
                // estimate was out.
                guard let current = defaults.favoriteFoods.first(where: { $0.id == food.id }),
                      FavoriteNutritionAssessment.contentKey(for: current) == FavoriteNutritionAssessment.contentKey(for: food),
                      defaults.favoriteNutritionAssessments[food.id]?.isUserSet != true else { continue }
                Self.apply(nutrition, to: food, defaults: defaults)
            } catch {
                // Offline or rate limited: the rest waits for the next launch or edit.
                log.error("Could not estimate fat and protein for %{public}@: %{public}@", food.name, String(describing: error))
                return
            }
        }
    }
}
