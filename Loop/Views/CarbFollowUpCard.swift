//
//  CarbFollowUpCard.swift
//  Loop
//
//  The later-carb settings on a favorite food's edit screen.
//

import SwiftUI
import LoopKit
import LoopKitUI

/// What a favorite food adds to a meal's later carbs: the fat and protein the meal estimate found
/// in it, and — set by hand — a fixed amount that replaces the calculation.
///
/// Saved as soon as it changes, apart from the food's own Save button: it lives beside the
/// favorite rather than in it (see `UserDefaults.carbFollowUpRules`).
struct CarbFollowUpCard: View {
    let food: StoredFavoriteFood

    @State private var rule: CarbFollowUpRule?
    @State private var assessment: FavoriteCarbFollowUpAssessment?

    init(food: StoredFavoriteFood) {
        self.food = food
        self._rule = State(initialValue: UserDefaults.standard.carbFollowUpRules[food.id])
        self._assessment = State(initialValue: UserDefaults.standard.carbFollowUpAssessments[food.id])
    }

    /// The fat and protein, when they describe the food as it is now.
    private var nutrition: MealNutrition? {
        guard let assessment, assessment.contentKey == FavoriteCarbFollowUpAssessment.contentKey(for: food) else { return nil }
        return assessment.nutrition
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Later Carbs", comment: "Title of the later carbs card on a favorite food")
                .font(.headline)

            nutritionRow

            CardSectionDivider()

            Toggle(isOn: isFixed) {
                Text("Fixed Amount", comment: "Toggle giving a favorite food a fixed amount of later carbs")
            }

            if let rule {
                LaterCarbSteppers(rule: Binding(get: { rule }, set: { save($0) }))
            }

            Text(explanation)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .padding(.horizontal)
        .background(CardBackground())
        .padding(.horizontal)
        .onReceive(NotificationCenter.default.publisher(for: .carbFollowUpRulesDidChange).receive(on: RunLoop.main)) { _ in
            // The assessment can land while the screen is open.
            rule = UserDefaults.standard.carbFollowUpRules[food.id]
            assessment = UserDefaults.standard.carbFollowUpAssessments[food.id]
        }
    }

    @ViewBuilder
    private var nutritionRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Fat and Protein", comment: "Row with a favorite food's fat and protein")
                Spacer()
                if let nutrition {
                    Text(String(format: NSLocalizedString("%1$@ g · %2$@ g", comment: "A favorite food's fat and protein (1: grams of fat)(2: grams of protein)"), whole(nutrition.fatGrams), whole(nutrition.proteinGrams)))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                } else {
                    Text("Being estimated…", comment: "Shown while the fat and protein of a favorite food are not known yet")
                        .foregroundColor(.secondary)
                }
            }

            if let nutrition {
                LaterCarbSuggestionLabel(reason: CarbFollowUpPlanner.explanation(for: nutrition))
                    .padding(.top, 2)
            }
        }
    }

    private var explanation: String {
        guard let rule else {
            return String(localized: "Later carbs are worked out for each meal from the fat and protein of everything eaten within an hour, so porridge and the milk after it count together. Below one fat-protein unit there are none.", comment: "Explanation on a favorite food without a fixed amount of later carbs")
        }
        return String(
            format: String(localized: "Every time %1$@ is logged — here on the phone, from the caregiver app or the watch — Loop adds %2$@ g with %3$@ absorption %4$@ later, once glucose is at least 6 mmol/L and no longer falling. If it has not turned up 3 hours after the meal, the later carbs are skipped.", comment: "Explanation under the later carbs settings (1: food name)(2: grams)(3: absorption time)(4: delay)"),
            food.name,
            NumberFormatter.localizedString(from: NSNumber(value: rule.carbGrams), number: .decimal),
            LaterCarbFormat.duration(rule.absorptionTime),
            LaterCarbFormat.duration(rule.delay)
        )
    }

    private var isFixed: Binding<Bool> {
        Binding(
            get: { rule != nil },
            set: { save($0 ? (rule ?? nutrition.flatMap(CarbFollowUpPlanner.rule(for:)) ?? .standard) : nil) }
        )
    }

    private func whole(_ value: Double) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value.rounded()), number: .decimal)
    }

    private func save(_ newRule: CarbFollowUpRule?) {
        withAnimation {
            rule = newRule
        }

        var assessments = UserDefaults.standard.carbFollowUpAssessments
        if var changed = assessments[food.id] {
            changed.userChanged = true
            assessments[food.id] = changed
            UserDefaults.standard.carbFollowUpAssessments = assessments
            assessment = changed
        }

        var rules = UserDefaults.standard.carbFollowUpRules
        rules[food.id] = newRule
        UserDefaults.standard.carbFollowUpRules = rules
    }
}
