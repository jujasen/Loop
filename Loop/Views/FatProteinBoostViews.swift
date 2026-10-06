//
//  FatProteinBoostViews.swift
//  Loop
//
//  The screens of the fat and protein boost: the row on the carb entry screen and the sheet behind
//  it, the card on a favorite food, and the settings with what the boost has learned.
//

import SwiftUI
import HealthKit
import LoopKit
import LoopKitUI

enum FatProteinFormat {
    static func grams(_ grams: Double) -> String {
        "\(NumberFormatter.localizedString(from: NSNumber(value: grams.rounded()), number: .decimal)) g"
    }

    static func units(_ units: Double) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: (units * 10).rounded() / 10), number: .decimal)
    }

    static func factor(_ factor: Double) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: (factor * 100).rounded() / 100), number: .decimal)
    }
}

/// The carb entry screen's row: what the boost will do for this meal, tapped to change it.
struct FatProteinBoostRow: View {
    var boost: FatProteinBoostPreview?
    var isDeclined: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text("Fat and Protein", comment: "Label for the fat and protein row on the carb entry screen")
                    .foregroundColor(.primary)

                Spacer()

                if isDeclined {
                    Text("Off", comment: "Fat and protein row value when the boost was turned off for this meal")
                        .foregroundColor(.secondary)
                } else if let boost, let strength = boost.strength, let duration = boost.duration {
                    HStack(spacing: 4) {
                        Text(verbatim: "🧈")
                            .font(.caption)
                        Text(String(format: NSLocalizedString("%1$@ for %2$@", comment: "Short summary of the fat and protein boost (1: insulin needs in percent)(2: duration)"), FatProteinBoostPlanner.percent(strength), FatProteinBoostPlanner.hours(duration)))
                    }
                    .font(.subheadline)
                    .foregroundColor(Color.carbTintColor)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(Capsule().fill(Color.carbTintColor.opacity(0.15)))
                } else if let boost, boost.source != .none || boost.mealTotal.fatProteinUnits > 0 {
                    Text(String(format: NSLocalizedString("%@ units, none", comment: "Fat and protein row value for a meal below the limit (1: fat-protein units)"), FatProteinFormat.units(boost.units)))
                        .foregroundColor(.secondary)
                } else {
                    Text("Not known", comment: "Fat and protein row value when nothing is known about the meal's fat and protein")
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

/// Two steppers for the fat and protein of an amount of food.
struct FatProteinSteppers: View {
    @Binding var nutrition: MealNutrition

    var body: some View {
        VStack(spacing: 10) {
            Stepper(value: $nutrition.fatGrams, in: 0...80, step: 1) {
                row(String(localized: "Fat", comment: "Label for grams of fat"), value: FatProteinFormat.grams(nutrition.fatGrams))
            }
            Stepper(value: $nutrition.proteinGrams, in: 0...80, step: 1) {
                row(String(localized: "Protein", comment: "Label for grams of protein"), value: FatProteinFormat.grams(nutrition.proteinGrams))
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

/// Edits one meal's fat and protein, or turns the boost off for it.
struct FatProteinBoostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference

    let boost: FatProteinBoostPreview?
    let carbs: Double
    let onDone: (MealNutrition?, Bool) -> Void

    @State private var isOn: Bool
    @State private var isEditing: Bool
    @State private var nutrition: MealNutrition

    private let settings = UserDefaults.standard.fatProteinBoostSettings

    init(boost: FatProteinBoostPreview?, isDeclined: Bool, carbs: Double, onDone: @escaping (MealNutrition?, Bool) -> Void) {
        self.boost = boost
        self.carbs = carbs
        self.onDone = onDone
        self._isOn = State(initialValue: !isDeclined)
        self._isEditing = State(initialValue: boost?.source == .meal)
        self._nutrition = State(initialValue: boost?.entry ?? MealNutrition(fatGrams: 0, proteinGrams: 0, carbGrams: carbs))
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Toggle(isOn: $isOn) {
                        Text("Boost This Meal", comment: "Toggle turning the fat and protein boost on or off for one meal")
                    }
                } footer: {
                    Text(conditionsText)
                }

                if isOn {
                    Section {
                        Text(liveExplanation)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        Toggle(isOn: $isEditing) {
                            Text("Set Fat and Protein by Hand", comment: "Toggle for typing in the fat and protein of the food being logged")
                        }
                        if isEditing {
                            FatProteinSteppers(nutrition: $nutrition)
                        }
                    } header: {
                        Text("This Food", comment: "Header above the fat and protein of the food being logged")
                    } footer: {
                        Text(sourceText)
                    }
                }
            }
            .insetGroupedListStyle()
            .navigationTitle(Text("Fat and Protein", comment: "Title of the fat and protein sheet"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", comment: "Cancel button")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Done button")) {
                        onDone(isEditing ? MealNutrition(fatGrams: nutrition.fatGrams, proteinGrams: nutrition.proteinGrams, carbGrams: carbs) : nil, !isOn)
                        dismiss()
                    }
                }
            }
        }
    }

    /// The calculation for the whole meal as it stands with the values on screen: the earlier
    /// parts of the meal, plus this food as typed in or as found.
    private var liveExplanation: String {
        let others = (boost?.mealTotal ?? .zero) + MealNutrition(fatGrams: -(boost?.entry?.fatGrams ?? 0), proteinGrams: -(boost?.entry?.proteinGrams ?? 0), carbGrams: 0)
        let own = isEditing ? nutrition : (boost?.entry ?? .zero)
        let total = others + own
        let calibration = UserDefaults.standard.fatProteinBoostCalibration
        return FatProteinBoostPlanner.explanation(
            for: MealNutrition(fatGrams: max(0, total.fatGrams), proteinGrams: max(0, total.proteinGrams), carbGrams: total.carbGrams),
            settings: settings,
            factor: calibration.factor
        )
    }

    private var conditionsText: String {
        let start = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: settings.startGlucoseMgdl)
        let stop = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: settings.stopGlucoseMgdl)
        let earliest = boost.map { FatProteinBoostPlanner.time($0.earliestStart) } ?? FatProteinBoostPlanner.hours(settings.delay)
        return String(
            format: NSLocalizedString("Loop raises insulin needs from %1$@ at the earliest, once glucose is at least %2$@ and not falling, and ends it below %3$@. If glucose has not turned up 3 hours later, nothing happens. Meals within an hour of each other count together.", comment: "Explanation on the fat and protein sheet (1: earliest start time)(2: start glucose)(3: stop glucose)"),
            earliest, displayGlucosePreference.format(start), displayGlucosePreference.format(stop)
        )
    }

    private var sourceText: String {
        if isEditing {
            return String(localized: "From the meal estimate, or typed in for this meal.", comment: "Where the fat and protein of the food being logged came from: this meal")
        }
        switch boost?.source ?? .none {
        case .meal:
            return String(localized: "From the meal estimate, or typed in for this meal.", comment: "Where the fat and protein of the food being logged came from: this meal")
        case .favorite:
            return String(localized: "From the favorite food. Change it on the favorite to change it every time.", comment: "Where the fat and protein of the food being logged came from: a favorite food")
        case .none:
            return String(localized: "Nothing is known about this food's fat and protein. Describe the meal to the AI estimate, pick a favorite food, or set it by hand.", comment: "Footer when nothing is known about the fat and protein of the food being logged")
        }
    }
}

/// A favorite food's fat and protein: found by the meal estimate, or typed in by hand.
///
/// Saved as soon as it changes, apart from the food's own Save button: it lives beside the
/// favorite rather than in it (see `UserDefaults.favoriteNutritionAssessments`), so the favorites
/// shared with the caregiver app are unchanged by it.
struct FavoriteNutritionCard: View {
    let food: StoredFavoriteFood

    @State private var assessment: FavoriteNutritionAssessment?

    init(food: StoredFavoriteFood) {
        self.food = food
        self._assessment = State(initialValue: UserDefaults.standard.favoriteNutritionAssessments[food.id])
    }

    private var carbs: Double {
        food.defaultPortion.carbsQuantity.doubleValue(for: .gram())
    }

    private var nutrition: MealNutrition? {
        assessment?.nutrition.map { $0.scaled(toCarbs: carbs) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fat and Protein", comment: "Title of the fat and protein card on a favorite food")
                .font(.headline)

            if let nutrition {
                FatProteinSteppers(nutrition: Binding(get: { nutrition }, set: save))
                Text(String(format: NSLocalizedString("%1$@ fat-protein units in %2$@ of carbs. %3$@", comment: "Under a favorite food's fat and protein (1: units)(2: grams of carbs)(3: where the values came from)"), FatProteinFormat.units(nutrition.fatProteinUnits), FatProteinFormat.grams(carbs), assessment?.isUserSet == true ? String(localized: "Set by hand.", comment: "A favorite's fat and protein were typed in") : String(localized: "Estimated by AI.", comment: "A favorite's fat and protein came from the meal estimate")))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Text("Being estimated…", comment: "Shown while the fat and protein of a favorite food are not known yet")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(String(localized: "Set by Hand", comment: "Button typing in a favorite food's fat and protein")) {
                        save(MealNutrition(fatGrams: 0, proteinGrams: 0, carbGrams: carbs))
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal)
        .background(CardBackground())
        .padding(.horizontal)
        .onReceive(NotificationCenter.default.publisher(for: .fatProteinBoostInputsDidChange).receive(on: RunLoop.main)) { _ in
            // The estimate can land while the screen is open.
            assessment = UserDefaults.standard.favoriteNutritionAssessments[food.id]
        }
    }

    private func save(_ nutrition: MealNutrition) {
        FavoriteNutritionAssessor.apply(nutrition, isUserSet: true, to: food)
        assessment = UserDefaults.standard.favoriteNutritionAssessments[food.id]
    }
}

/// The boost's settings, what it is doing now, and what it has learned.
struct FatProteinBoostSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference

    let manager: FatProteinBoostManager?

    @State private var settings = UserDefaults.standard.fatProteinBoostSettings
    @State private var calibration = UserDefaults.standard.fatProteinBoostCalibration
    @State private var planned: [FatProteinBoostPlan] = []
    @State private var active: FatProteinBoostRecord?
    @State private var showResetConfirmation = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Toggle(isOn: $settings.isEnabled) {
                        Text("Fat and Protein Boost", comment: "Toggle turning the fat and protein boost on or off")
                    }
                } footer: {
                    Text("After a meal with a lot of fat and protein — porridge with butter, milk, pizza — glucose rises hours later, when the meal's carbs are long gone. Loop then raises insulin needs for a few hours, as an override named 🧈 Fat and Protein, but only once glucose has actually turned up. If it ends lower than it should, or stays high, the next boost is adjusted.", comment: "Explanation of the fat and protein boost")
                }

                if settings.isEnabled {
                    nowSection
                    startSection
                    strengthSection
                    learnedSection
                }
            }
            .insetGroupedListStyle()
            .navigationTitle(Text("Fat and Protein", comment: "Title of the fat and protein settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Done button")) { dismiss() }
                }
            }
            .onChange(of: settings) { newValue in
                UserDefaults.standard.fatProteinBoostSettings = newValue
            }
            .onAppear(perform: reload)
            .onReceive(NotificationCenter.default.publisher(for: .fatProteinBoostDidChange).receive(on: RunLoop.main)) { _ in reload() }
            .confirmationDialog(Text("Forget what was learned?", comment: "Title of the confirmation for resetting the fat and protein boost's learning"), isPresented: $showResetConfirmation, titleVisibility: .visible) {
                Button(String(localized: "Start Over", comment: "Button resetting the fat and protein boost's learning"), role: .destructive) {
                    UserDefaults.standard.fatProteinBoostCalibration = FatProteinBoostCalibration()
                    reload()
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var nowSection: some View {
        if active != nil || !planned.isEmpty {
            Section {
                if let active {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: NSLocalizedString("Running: %1$@ until %2$@", comment: "The fat and protein boost running now (1: insulin needs in percent)(2: end time)"), FatProteinBoostPlanner.percent(active.strength), active.plannedEnd.map(FatProteinBoostPlanner.time) ?? "–"))
                        Text(active.mealName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Button(String(localized: "End Now", comment: "Button ending the running fat and protein boost"), role: .destructive) {
                        manager?.endActive()
                        reload()
                    }
                }
                ForEach(planned, id: \.triggerID) { plan in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: NSLocalizedString("Waiting: %1$@ from %2$@", comment: "A fat and protein boost waiting for glucose to turn up (1: insulin needs in percent)(2: earliest start)"), FatProteinBoostPlanner.percent(plan.strength), FatProteinBoostPlanner.time(plan.earliestStart)))
                        Text(plan.explanation)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Now", comment: "Header above the running and waiting fat and protein boosts")
            }
        }
    }

    private var startSection: some View {
        Section {
            Stepper(value: $settings.delay, in: FatProteinBoostSettings.delayRange, step: .minutes(15)) {
                valueRow(String(localized: "Earliest After the Meal", comment: "Setting: how long after the meal the boost may start"), FatProteinBoostPlanner.hours(settings.delay))
            }
            Stepper(value: $settings.startGlucoseMgdl, in: FatProteinBoostSettings.startGlucoseRange, step: glucoseStep) {
                valueRow(String(localized: "Starts at", comment: "Setting: glucose the boost starts at"), glucose(settings.startGlucoseMgdl))
            }
            Stepper(value: $settings.stopGlucoseMgdl, in: FatProteinBoostSettings.stopGlucoseRange, step: glucoseStep) {
                valueRow(String(localized: "Ends Below", comment: "Setting: glucose the boost ends below"), glucose(settings.stopGlucoseMgdl))
            }
            Stepper(value: $settings.minimumUnits, in: FatProteinBoostSettings.minimumUnitsRange, step: 0.25) {
                valueRow(String(localized: "Smallest Meal", comment: "Setting: fewest fat-protein units that get a boost"), String(format: NSLocalizedString("%@ units", comment: "Fat-protein units (1: number)"), FatProteinFormat.units(settings.minimumUnits)))
            }
        } header: {
            Text("When", comment: "Header above the fat and protein boost's start settings")
        } footer: {
            Text("A fat-protein unit is 100 kcal from fat and protein: about 11 g fat, or 25 g protein. Carbs that treated a low (logged below 5 mmol/L) are not counted.", comment: "Footer explaining fat-protein units")
        }
    }

    private var strengthSection: some View {
        Section {
            Stepper(value: $settings.strengthPerUnit, in: FatProteinBoostSettings.strengthPerUnitRange, step: 0.05) {
                valueRow(String(localized: "Per Unit", comment: "Setting: extra insulin needs per fat-protein unit"), "+" + FatProteinBoostPlanner.percent(settings.strengthPerUnit).replacingOccurrences(of: " %", with: "") + " %")
            }
            Stepper(value: $settings.maximumStrength, in: FatProteinBoostSettings.maximumStrengthRange, step: 0.05) {
                valueRow(String(localized: "At Most", comment: "Setting: highest insulin needs the boost sets"), FatProteinBoostPlanner.percent(settings.maximumStrength))
            }
        } header: {
            Text("How Much", comment: "Header above the fat and protein boost's strength settings")
        } footer: {
            Text(strengthExample)
        }
    }

    private var learnedSection: some View {
        Section {
            valueRow(String(localized: "Learned Factor", comment: "The factor the fat and protein boost has learned"), "× " + FatProteinFormat.factor(calibration.factor))
            ForEach(Array(calibration.outcomes.enumerated()), id: \.offset) { _, outcome in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(verdictText(outcome.verdict))
                        Spacer()
                        Text(DateFormatter.localizedString(from: outcome.start, dateStyle: .short, timeStyle: .short))
                            .foregroundColor(.secondary)
                    }
                    Text(String(format: NSLocalizedString("%1$@ · %2$@ · highest %3$@, lowest %4$@ · × %5$@ → × %6$@", comment: "One fat and protein boost's outcome (1: meal)(2: insulin needs in percent)(3: highest glucose)(4: lowest glucose)(5: factor before)(6: factor after)"), outcome.mealName, FatProteinBoostPlanner.percent(outcome.strength), glucose(outcome.peakMgdl), glucose(outcome.lowestMgdl), FatProteinFormat.factor(outcome.factorBefore), FatProteinFormat.factor(outcome.factorAfter)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !calibration.outcomes.isEmpty || calibration.factor != 1 {
                Button(String(localized: "Start Over", comment: "Button resetting the fat and protein boost's learning"), role: .destructive) {
                    showResetConfirmation = true
                }
            }
        } header: {
            Text("Learned", comment: "Header above what the fat and protein boost has learned")
        } footer: {
            Text("Two hours after each boost Loop looks back: below 4 mmol/L makes the next one 20 % weaker, below 4.5 10 % weaker; still at 13 or more an hour into it makes the next one 15 % stronger, 11 or more 8 % stronger. The factor stays between × 0.5 and × 2, and the boost never goes past At Most.", comment: "Footer explaining how the fat and protein boost learns")
        }
    }

    // MARK: Helpers

    private var glucoseStep: Double {
        displayGlucosePreference.unit == .millimolesPerLiter ? 9.009 : 5
    }

    private func glucose(_ mgdl: Double) -> String {
        displayGlucosePreference.format(HKQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl))
    }

    private var strengthExample: String {
        let examples = [1.0, 2.0, 3.0].map { units in
            String(format: NSLocalizedString("%1$@ units → %2$@", comment: "One example of the fat and protein boost's strength (1: units)(2: insulin needs in percent)"), FatProteinFormat.units(units), FatProteinBoostPlanner.percent(FatProteinBoostPlanner.strength(units: units, settings: settings, factor: calibration.factor)))
        }
        return String(format: NSLocalizedString("With what has been learned: %@. Porridge with butter and a glass of milk is often 2–3 units.", comment: "Examples under the fat and protein boost's strength settings (1: the examples)"), examples.joined(separator: ", "))
    }

    private func verdictText(_ verdict: FatProteinBoostOutcome.Verdict) -> String {
        switch verdict {
        case .low: return String(localized: "Went low", comment: "Outcome of a fat and protein boost: glucose went below 4")
        case .lowish: return String(localized: "A little low", comment: "Outcome of a fat and protein boost: glucose went below 4.5")
        case .high: return String(localized: "Stayed high", comment: "Outcome of a fat and protein boost: glucose stayed at 13 or more")
        case .highish: return String(localized: "A little high", comment: "Outcome of a fat and protein boost: glucose stayed at 11 or more")
        case .good: return String(localized: "Good", comment: "Outcome of a fat and protein boost: neither low nor high")
        }
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }

    private func reload() {
        calibration = UserDefaults.standard.fatProteinBoostCalibration
        planned = manager?.planned ?? []
        active = manager?.active
    }
}
