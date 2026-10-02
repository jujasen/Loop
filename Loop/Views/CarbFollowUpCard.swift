//
//  CarbFollowUpCard.swift
//  Loop
//
//  The later-carb settings on a favorite food's edit screen.
//

import SwiftUI
import LoopKit
import LoopKitUI

/// Turns a favorite food's later carbs on or off and sets their amount, timing and absorption.
///
/// Saved as soon as it changes, apart from the food's own Save button: the rule lives beside the
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

    /// True while the rule is the meal estimate's suggestion, untouched.
    private var isSuggested: Bool {
        guard let assessment, !assessment.userChanged, let suggestion = assessment.suggestion else { return false }
        return suggestion == rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: isOn) {
                Text("Later Carbs", comment: "Toggle turning on a favorite food's later carbs")
            }

            if isSuggested {
                LaterCarbSuggestionLabel(reason: assessment?.reason)
            }

            if let rule {
                CardSectionDivider()
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
            // The first assessment can land while the screen is open.
            rule = UserDefaults.standard.carbFollowUpRules[food.id]
            assessment = UserDefaults.standard.carbFollowUpAssessments[food.id]
        }
    }

    private var explanation: String {
        guard let rule else {
            return String(localized: "For food whose fat and protein raise glucose hours later, such as porridge and milk. Loop adds a small, slow carb entry by itself once the dip after the meal is over.", comment: "Explanation under the later carbs toggle when it is off")
        }
        return String(
            format: String(localized: "Every time %1$@ is logged — here on the phone, from the caregiver app or the watch — Loop adds %2$@ g with %3$@ absorption %4$@ later, once glucose is at least 6 mmol/L and no longer falling. If it has not turned up 3 hours after the meal, the later carbs are skipped.", comment: "Explanation under the later carbs settings (1: food name)(2: grams)(3: absorption time)(4: delay)"),
            food.name,
            NumberFormatter.localizedString(from: NSNumber(value: rule.carbGrams), number: .decimal),
            LaterCarbFormat.duration(rule.absorptionTime),
            LaterCarbFormat.duration(rule.delay)
        )
    }

    private var isOn: Binding<Bool> {
        Binding(
            get: { rule != nil },
            set: { save($0 ? (rule ?? assessment?.suggestion ?? .standard) : nil) }
        )
    }

    private func save(_ newRule: CarbFollowUpRule?) {
        withAnimation {
            rule = newRule
        }

        // A hand-made change outlives later assessments of the same food.
        var assessments = UserDefaults.standard.carbFollowUpAssessments
        var changed = assessments[food.id] ?? FavoriteCarbFollowUpAssessment(contentKey: FavoriteCarbFollowUpAssessment.contentKey(for: food))
        changed.userChanged = newRule != changed.suggestion
        changed.contentKey = FavoriteCarbFollowUpAssessment.contentKey(for: food)
        assessments[food.id] = changed
        UserDefaults.standard.carbFollowUpAssessments = assessments
        assessment = changed

        var rules = UserDefaults.standard.carbFollowUpRules
        rules[food.id] = newRule
        UserDefaults.standard.carbFollowUpRules = rules
    }
}
