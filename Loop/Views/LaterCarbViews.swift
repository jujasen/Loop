//
//  LaterCarbViews.swift
//  Loop
//
//  The pieces of the later-carb screens: the row on the carb entry screen, the sheet that edits
//  a meal's later carbs, and the sheet that explains why waiting later carbs are still waiting.
//

import SwiftUI
import HealthKit
import LoopKit
import LoopKitUI
import LoopUI

enum LaterCarbFormat {
    static func duration(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .short
        return formatter.string(from: interval) ?? ""
    }

    static func grams(_ grams: Double) -> String {
        "\(NumberFormatter.localizedString(from: NSNumber(value: grams), number: .decimal)) g"
    }

    static func time(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }

    /// "6 g in 1 hr, 30 min" — what a row says about a meal's later carbs.
    static func summary(_ rule: CarbFollowUpRule) -> String {
        String(format: NSLocalizedString("%1$@ in %2$@", comment: "Short summary of later carbs (1: grams)(2: time after the meal)"), grams(rule.carbGrams), duration(rule.delay))
    }
}

/// "Suggested by AI", with the estimate's reason underneath.
struct LaterCarbSuggestionLabel: View {
    var reason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text("Suggested by AI", comment: "Label on later carbs that the meal estimate suggested")
            } icon: {
                Image(systemName: "sparkles")
            }
            .font(.caption.weight(.medium))
            .foregroundColor(.purple)

            if let reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Amount, timing and absorption of later carbs, as three steppers.
struct LaterCarbSteppers: View {
    @Binding var rule: CarbFollowUpRule

    var body: some View {
        VStack(spacing: 10) {
            Stepper(value: $rule.carbGrams, in: CarbFollowUpRule.carbRange, step: 1) {
                row(String(localized: "Carbs", comment: "Label for the later carbs' amount"), value: LaterCarbFormat.grams(rule.carbGrams))
            }
            Stepper(value: $rule.delay, in: CarbFollowUpRule.delayRange, step: .minutes(15)) {
                row(String(localized: "After the meal", comment: "Label for how long after the meal the later carbs are added"), value: LaterCarbFormat.duration(rule.delay))
            }
            Stepper(value: $rule.absorptionTime, in: CarbFollowUpRule.absorptionRange, step: .minutes(30)) {
                row(String(localized: "Absorption Time", comment: "Label for the later carbs' absorption time"), value: LaterCarbFormat.duration(rule.absorptionTime))
            }
        }
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }
}

/// The carb entry screen's row: what happens later for this meal, tapped to change it.
struct LaterCarbRow: View {
    var plan: MealCarbFollowUp?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text("Later Carbs", comment: "Label for the later carbs row on the carb entry screen")
                    .foregroundColor(.primary)

                Spacer()

                if let rule = plan?.rule {
                    HStack(spacing: 4) {
                        Image(systemName: plan?.source == .ai ? "sparkles" : "clock")
                            .font(.caption)
                        Text(LaterCarbFormat.summary(rule))
                    }
                    .font(.subheadline)
                    .foregroundColor(Color.carbTintColor)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Capsule().fill(Color.carbTintColor.opacity(0.15)))
                } else {
                    Text(plan == nil ? String(localized: "None", comment: "Later carbs row value when the meal has none") : String(localized: "Off", comment: "Later carbs row value when they were turned down for this meal"))
                        .foregroundColor(.secondary)
                }

                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Color(.tertiaryLabel))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// Edits one meal's later carbs: use the suggestion as it is, change it, turn it down, or add
/// later carbs to a meal that has none.
struct LaterCarbEditorView: View {
    @Environment(\.dismiss) private var dismiss

    /// What the favorite food or the meal estimate suggested, if anything.
    let suggestion: MealCarbFollowUp?
    let mealStart: Date
    let onDone: (MealCarbFollowUp?) -> Void

    @State private var rule: CarbFollowUpRule

    init(plan: MealCarbFollowUp?, suggestion: MealCarbFollowUp?, mealStart: Date, onDone: @escaping (MealCarbFollowUp?) -> Void) {
        self.suggestion = suggestion
        self.mealStart = mealStart
        self.onDone = onDone
        self._rule = State(initialValue: plan?.rule ?? suggestion?.rule ?? .standard)
    }

    private var hasSomethingToTurnDown: Bool {
        suggestion?.rule != nil
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    if let suggestion, suggestion.rule != nil, suggestion.source == .ai {
                        LaterCarbSuggestionLabel(reason: suggestion.reason)
                            .padding(12)
                            .background(CardBackground())
                    }

                    LaterCarbSteppers(rule: $rule)
                        .padding(12)
                        .background(CardBackground())

                    Text(String(format: NSLocalizedString("Added at %1$@ at the earliest, once glucose is at least 6 mmol/L and no longer falling. Skipped if that has not happened by %2$@.", comment: "Conditions under the later carbs editor (1: earliest time)(2: latest time)"), LaterCarbFormat.time(mealStart.addingTimeInterval(rule.delay)), LaterCarbFormat.time(CarbFollowUpPlanner.expiryDate(start: mealStart, rule: rule))))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)

                    Button(action: use) {
                        Text(hasSomethingToTurnDown ? String(localized: "Use", comment: "Button using the later carbs as shown") : String(localized: "Add Later Carbs", comment: "Button adding later carbs to a meal without any"))
                    }
                    .buttonStyle(ActionButtonStyle())
                    .padding(.top, 4)

                    if hasSomethingToTurnDown {
                        Button(role: .destructive, action: turnDown) {
                            Text("Not This Time", comment: "Button turning down later carbs for this meal")
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitle(String(localized: "Later Carbs", comment: "Title of the later carbs editor"), displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(String(localized: "Cancel", comment: "Button closing the later carbs editor without changes")) { dismiss() }
                }
            }
        }
    }

    private func use() {
        // Unchanged amounts keep the suggestion's source and reason.
        if let suggestion, suggestion.rule == rule {
            onDone(suggestion)
        } else {
            onDone(MealCarbFollowUp(rule: rule, source: .manual))
        }
        dismiss()
    }

    private func turnDown() {
        onDone(MealCarbFollowUp(rule: nil, source: suggestion?.source ?? .manual, reason: suggestion?.reason))
        dismiss()
    }
}

/// Why waiting later carbs are still waiting, with a way to change, cancel or add them now.
struct LaterCarbDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let followUp: PlannedCarbFollowUp
    let conditions: CarbFollowUpConditions
    let glucoseUnit: HKUnit
    let onEdit: () -> Void
    let onCancel: () -> Void
    let onAddNow: () -> Void

    @State private var confirmCancel = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    if followUp.source == .ai {
                        LaterCarbSuggestionLabel(reason: followUp.reason)
                            .padding(12)
                            .background(CardBackground())
                    }

                    VStack(spacing: 10) {
                        detailRow(String(localized: "Meal", comment: "Row naming the meal later carbs belong to"), value: "\(followUp.emoji) \(followUp.mealDescription) \(LaterCarbFormat.time(followUp.mealStart))".trimmingCharacters(in: .whitespaces))
                        CardSectionDivider()
                        detailRow(String(localized: "Earliest", comment: "Row with the earliest time later carbs are added"), value: LaterCarbFormat.time(followUp.dueDate), emphasized: true)
                        CardSectionDivider()
                        detailRow(String(localized: "Latest", comment: "Row with the time after which later carbs are skipped"), value: LaterCarbFormat.time(followUp.expiryDate))
                        CardSectionDivider()
                        detailRow(String(localized: "Absorption Time", comment: "Row with the later carbs' absorption time"), value: LaterCarbFormat.duration(followUp.rule.absorptionTime))
                    }
                    .padding(12)
                    .background(CardBackground())

                    VStack(spacing: 10) {
                        conditionRow(met: conditions.isHighEnough, title: String(localized: "Glucose at least 6", comment: "Condition for adding later carbs: glucose high enough"), value: glucoseText)
                        CardSectionDivider()
                        conditionRow(met: conditions.isNotFalling, title: String(localized: "Not falling", comment: "Condition for adding later carbs: glucose not falling"), value: changeText)
                    }
                    .padding(12)
                    .background(CardBackground())

                    Text(statusText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)

                    HStack(spacing: 12) {
                        Button(action: { dismiss(); onEdit() }) {
                            Text("Edit", comment: "Button editing waiting later carbs")
                        }
                        .buttonStyle(ActionButtonStyle(.secondary))

                        Button(action: { dismiss(); onAddNow() }) {
                            Text("Add Now", comment: "Button adding waiting later carbs straight away")
                        }
                        .buttonStyle(ActionButtonStyle(.secondary))
                    }

                    Button(role: .destructive, action: { confirmCancel = true }) {
                        Text("Cancel Later Carbs", comment: "Button cancelling waiting later carbs")
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 4)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitle(String(format: NSLocalizedString("Later Carbs · %@", comment: "Title of the waiting later carbs sheet (1: grams)"), LaterCarbFormat.grams(followUp.rule.carbGrams)), displayMode: .inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(String(localized: "Done", comment: "Button closing the waiting later carbs sheet")) { dismiss() }
                }
            }
            .alert(String(localized: "Cancel Later Carbs?", comment: "Title of the alert confirming that waiting later carbs are cancelled"), isPresented: $confirmCancel) {
                Button(String(localized: "Cancel Later Carbs", comment: "Button cancelling waiting later carbs"), role: .destructive) {
                    dismiss()
                    onCancel()
                }
                Button(String(localized: "Keep", comment: "Button keeping waiting later carbs"), role: .cancel) {}
            } message: {
                Text(String(format: NSLocalizedString("The %1$@ after %2$@ will not be added this time. A favorite food keeps its later carbs for next time.", comment: "Message of the alert confirming that waiting later carbs are cancelled (1: grams)(2: name of the meal)"), LaterCarbFormat.grams(followUp.rule.carbGrams), followUp.mealDescription))
            }
        }
    }

    private var glucoseText: String {
        guard let glucose = conditions.latestGlucose else {
            return String(localized: "No recent glucose", comment: "Shown instead of glucose when there is no recent reading")
        }
        return String(format: NSLocalizedString("now %@", comment: "Current glucose next to a later carbs condition (1: glucose)"), formatted(glucose))
    }

    private var changeText: String {
        guard let change = conditions.recentChange else { return "–" }
        let value = change.doubleValue(for: glucoseUnit)
        let sign = value > 0 ? "+" : ""
        return String(format: NSLocalizedString("%@ last 15 min", comment: "Glucose change next to the not-falling condition (1: signed change)"), sign + formatted(change))
    }

    private var statusText: String {
        if Date() < followUp.dueDate {
            return String(format: NSLocalizedString("Checked from %@, before every loop.", comment: "Status of later carbs that are not due yet (1: earliest time)"), LaterCarbFormat.time(followUp.dueDate))
        }
        return NSLocalizedString("Waiting for glucose to turn. Checked before every loop.", comment: "Status of due later carbs waiting for the conditions")
    }

    private func formatted(_ quantity: HKQuantity) -> String {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = glucoseUnit == .milligramsPerDeciliter ? 0 : 1
        formatter.minimumFractionDigits = formatter.maximumFractionDigits
        return formatter.string(from: NSNumber(value: quantity.doubleValue(for: glucoseUnit))) ?? ""
    }

    private func detailRow(_ title: String, value: String, emphasized: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(emphasized ? .primary : .secondary)
                .fontWeight(emphasized ? .medium : .regular)
        }
    }

    private func conditionRow(met: Bool, title: String, value: String) -> some View {
        HStack {
            Image(systemName: met ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(met ? .green : Color(.systemGray3))
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }
}
