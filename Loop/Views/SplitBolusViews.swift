//
//  SplitBolusViews.swift
//  Loop
//
//  The screens of the split bolus: the switch and suggestion on the carb entry screen, the card
//  offering a rest that is due, and the settings with what the split has learned.
//

import SwiftUI
import HealthKit
import LoopKit
import LoopKitUI

/// The carb entry screen's switch, and with it on, the split and its two steppers.
struct SplitBolusSection: View {
    @ObservedObject var viewModel: CarbEntryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $viewModel.isSplitBolusOn) {
                HStack(spacing: 6) {
                    Text(verbatim: "✂️")
                    Text("Split Bolus", comment: "Toggle on the carb entry screen splitting the bolus in two")
                }
            }

            if viewModel.isSplitBolusOn {
                if let split = viewModel.splitBolus {
                    details(split)
                } else {
                    Text("Enter the carbs to see the split.", comment: "Split bolus hint without carbs")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func details(_ split: SplitBolusSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            partRow(
                title: String(localized: "Now", comment: "The part of a split bolus given with the meal"),
                carbs: split.nowCarbs, units: split.nowUnits, time: nil
            )
            partRow(
                title: String(localized: "Rest", comment: "The part of a split bolus given later"),
                carbs: split.laterCarbs, units: split.laterUnits, time: split.due
            )
        }
        .font(.subheadline)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.carbTintColor.opacity(0.12)))

        Stepper(value: shareBinding(split), in: SplitBolusSettings.nowShareRange, step: SplitBolusSettings.nowShareStep) {
            valueRow(String(localized: "Share Now", comment: "Stepper: share of the carbs dosed for with the meal"), SplitBolusPlanner.percent(split.nowShare))
        }
        Stepper(value: delayBinding(split), in: SplitBolusSettings.delayRange, step: SplitBolusSettings.delayStep) {
            valueRow(String(localized: "Rest After", comment: "Stepper: time from the meal to the rest"), FatProteinBoostPlanner.hours(split.delay))
        }

        Text(explanation(split))
            .font(.footnote)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func partRow(title: String, carbs: Double, units: Double?, time: Date?) -> some View {
        HStack {
            Text(title)
            if let time {
                Text(String(format: NSLocalizedString("at %@", comment: "When the rest of a split bolus is due (1: time)"), FatProteinBoostPlanner.time(time)))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(SplitBolusPlanner.grams(carbs))
                .foregroundColor(Color.carbTintColor)
                .monospacedDigit()
            if let units {
                Text(String(format: NSLocalizedString("≈ %@", comment: "Rough insulin for a part of a split bolus (1: insulin)"), SplitBolusPlanner.units(units)))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func shareBinding(_ split: SplitBolusSuggestion) -> Binding<Double> {
        Binding(get: { viewModel.splitChosenShare ?? split.nowShare }, set: { viewModel.splitChosenShare = $0 })
    }

    private func delayBinding(_ split: SplitBolusSuggestion) -> Binding<TimeInterval> {
        Binding(get: { viewModel.splitChosenDelay ?? split.delay }, set: { viewModel.splitChosenDelay = $0 })
    }

    private func explanation(_ split: SplitBolusSuggestion) -> String {
        var lines: [String] = []
        switch split.delaySource {
        case .learned:
            lines.append(String(localized: "Time learned from earlier splits.", comment: "Where the split bolus's time came from"))
        case .history:
            lines.append(String(localized: "Time from earlier servings in Nightscout: the rest half an hour before the usual rise.", comment: "Where the split bolus's time came from"))
        case .standard:
            lines.append(String(localized: "Fat in the meal gives a late rise, so the rest comes 2 hours after.", comment: "Where the split bolus's time came from"))
        case .chosen:
            break
        }
        if let basis = split.basis {
            lines.append(SplitBolusPlanner.basisText(basis) + ".")
        }
        if split.extra > 0 {
            lines.append(String(format: NSLocalizedString("The rest has %@ extra, learned from evenings that stayed high.", comment: "Learned extra on the rest of a split bolus (1: percent)"), SplitBolusPlanner.percent(split.extra)))
        }
        lines.append(String(localized: "Loop doses only for the part now. When the rest is due you get a notification; with glucose below 5 or falling it waits half an hour, once.", comment: "How the split bolus works, under the switch"))
        return lines.joined(separator: " ")
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
}

/// A rest not logged yet, on the home screen and at the top of a new carb entry, or the rest
/// being logged now. Either way it can be called off from here.
struct SplitRestCard: View {
    let plan: SplitBolusPlan
    /// `nil` once the rest is filled in.
    var onUse: (() -> Void)?
    var onCancel: (() -> Void)?

    @State private var showCancelConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: NSLocalizedString("✂️ Rest of the bolus for %@", comment: "Card title for the rest of a split bolus (1: name of the meal)"), plan.mealDescription))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let onUse {
                    Button(action: onUse) {
                        Text("Log the Rest", comment: "Button filling the carb entry in with the rest of a split bolus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.carbTintColor)
                }
                if onCancel != nil {
                    Button(role: .destructive, action: { showCancelConfirmation = true }) {
                        Text("Call Off", comment: "Button calling off the rest of a split bolus")
                            .frame(maxWidth: onUse == nil ? .infinity : nil)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            Text("Call off the rest?", comment: "Title of the confirmation for calling off the rest of a split bolus"),
            isPresented: $showCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Call Off", comment: "Button calling off the rest of a split bolus"), role: .destructive) {
                onCancel?()
            }
        } message: {
            Text("No reminder comes, and Loop doses for nothing more of this meal.", comment: "Message of the confirmation for calling off the rest of a split bolus")
        }
    }

    private var detail: String {
        var text = String(format: NSLocalizedString("Planned for %1$@: %2$@", comment: "When and how much the rest of a split bolus is (1: time)(2: carbs)"), FatProteinBoostPlanner.time(plan.due), SplitBolusPlanner.grams(plan.laterCarbs))
        if let units = plan.laterUnits {
            text += String(format: NSLocalizedString(", about %@", comment: "Appended: rough insulin for the rest of a split bolus (1: insulin)"), SplitBolusPlanner.units(units))
        }
        text += ". "
        text += onUse == nil
            ? String(localized: "Loop works out the bolus from glucose now.", comment: "Under the rest of a split bolus being logged")
            : String(localized: "Check glucose before you log it.", comment: "Under a rest of a split bolus that is due")
        return text
    }
}

/// The split's start values, what it has learned, and splits still waiting for their rest.
struct SplitBolusSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference

    let manager: SplitBolusManager?

    @State private var settings = UserDefaults.standard.splitBolusSettings
    @State private var calibration = UserDefaults.standard.splitBolusCalibration
    @State private var open: [SplitBolusPlan] = []
    @State private var showResetConfirmation = false

    var body: some View {
        NavigationView {
            List {
                if !open.isEmpty {
                    Section {
                        ForEach(open) { plan in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(format: NSLocalizedString("%1$@: %2$@ at %3$@", comment: "A split waiting for its rest (1: meal)(2: carbs)(3: time)"), plan.mealDescription, SplitBolusPlanner.grams(plan.laterCarbs), FatProteinBoostPlanner.time(plan.due)))
                                Text(stateText(plan.state))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .swipeActions {
                                Button(String(localized: "Call Off", comment: "Button calling off the rest of a split bolus"), role: .destructive) {
                                    manager?.cancel(planID: plan.id)
                                    reload()
                                }
                            }
                        }
                    } header: {
                        Text("Waiting", comment: "Header above splits waiting for their rest")
                    } footer: {
                        Text("Swipe to call a rest off.", comment: "Footer under splits waiting for their rest")
                    }
                }

                Section {
                    Stepper(value: $settings.nowShare, in: SplitBolusSettings.nowShareRange, step: SplitBolusSettings.nowShareStep) {
                        valueRow(String(localized: "Share Now", comment: "Stepper: share of the carbs dosed for with the meal"), SplitBolusPlanner.percent(settings.nowShare))
                    }
                    Stepper(value: $settings.delay, in: SplitBolusSettings.delayRange, step: SplitBolusSettings.delayStep) {
                        valueRow(String(localized: "Rest After", comment: "Stepper: time from the meal to the rest"), FatProteinBoostPlanner.hours(settings.delay))
                    }
                } header: {
                    Text("Start Values", comment: "Header above the split bolus's start values")
                } footer: {
                    Text("Used until something is learned. Without anything learned, the time comes from earlier servings of the same food in Nightscout when there are at least 5 of them.", comment: "Footer under the split bolus's start values")
                }

                learnedSection
            }
            .insetGroupedListStyle()
            .navigationTitle(Text("Split Bolus", comment: "Title of the split bolus settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Done button")) { dismiss() }
                }
            }
            .onChange(of: settings) { newValue in
                UserDefaults.standard.splitBolusSettings = newValue
            }
            .onAppear(perform: reload)
            .onReceive(NotificationCenter.default.publisher(for: .splitBolusDidChange).receive(on: RunLoop.main)) { _ in reload() }
            .confirmationDialog(Text("Forget what was learned?", comment: "Title of the confirmation for resetting the split bolus's learning"), isPresented: $showResetConfirmation, titleVisibility: .visible) {
                Button(String(localized: "Start Over", comment: "Button resetting the split bolus's learning"), role: .destructive) {
                    UserDefaults.standard.splitBolusCalibration = SplitBolusCalibration()
                    reload()
                }
            }
        }
    }

    private var learnedSection: some View {
        Section {
            valueRow(String(localized: "Share Now", comment: "Stepper: share of the carbs dosed for with the meal"), calibration.nowShare.map(SplitBolusPlanner.percent) ?? String(localized: "Start value", comment: "Split bolus value not learned yet"))
            valueRow(String(localized: "Rest After", comment: "Stepper: time from the meal to the rest"), calibration.delay.map(FatProteinBoostPlanner.hours) ?? String(localized: "Start value", comment: "Split bolus value not learned yet"))
            valueRow(String(localized: "Extra on the Rest", comment: "Learned extra on the rest of a split bolus"), "+" + SplitBolusPlanner.percent(calibration.extra))
            ForEach(Array(calibration.outcomes.enumerated()), id: \.offset) { _, outcome in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(outcome.mealName)
                        Spacer()
                        Text(DateFormatter.localizedString(from: outcome.mealDate, dateStyle: .short, timeStyle: .short))
                            .foregroundColor(.secondary)
                    }
                    Text(outcomeText(outcome))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !calibration.outcomes.isEmpty || calibration.nowShare != nil || calibration.delay != nil || calibration.extra != 0 {
                Button(String(localized: "Start Over", comment: "Button resetting the split bolus's learning"), role: .destructive) {
                    showResetConfirmation = true
                }
            }
        } header: {
            Text("Learned", comment: "Header above what the split bolus has learned")
        } footer: {
            Text("Six hours after each split Loop looks back. Below 4 mmol/L before the rest: 5 % less now next time. Below 4 after the rest: less extra, or the rest 15 minutes later. Over 10 for more than an hour from 2 to 6 hours after: 10 % extra on the rest. Already 2 mmol/L up when the rest was logged (from the low point, or from the start after a dip): the rest 15 minutes earlier. Share now stays between 40 and 80 %, the rest at least 1½ hours after the meal, the extra at most 50 %.", comment: "Footer explaining how the split bolus learns")
        }
    }

    private func outcomeText(_ outcome: SplitBolusOutcome) -> String {
        var parts = [String(format: NSLocalizedString("lowest before the rest %@", comment: "Split outcome part (1: glucose)"), glucose(outcome.lowestBeforeRestMgdl))]
        if let after = outcome.lowestAfterRestMgdl {
            parts.append(String(format: NSLocalizedString("after %@", comment: "Split outcome part: lowest after the rest (1: glucose)"), glucose(after)))
        } else if !outcome.restWasGiven {
            parts.append(String(localized: "no rest", comment: "Split outcome part: the rest was not logged"))
        }
        parts.append(String(format: NSLocalizedString("%@ over 10", comment: "Split outcome part: time above 10 mmol/L (1: duration)"), FatProteinBoostPlanner.hours(outcome.minutesHigh * 60)))
        if outcome.changed {
            parts.append(String(format: NSLocalizedString("now %1$@ → %2$@, rest %3$@ → %4$@, extra %5$@ → %6$@", comment: "Split outcome: what changed (1,2: share now)(3,4: time of rest)(5,6: extra)"),
                                SplitBolusPlanner.percent(outcome.nowShareBefore), SplitBolusPlanner.percent(outcome.nowShareAfter),
                                FatProteinBoostPlanner.hours(outcome.delayBefore), FatProteinBoostPlanner.hours(outcome.delayAfter),
                                SplitBolusPlanner.percent(outcome.extraBefore), SplitBolusPlanner.percent(outcome.extraAfter)))
        } else {
            parts.append(String(localized: "no change", comment: "Split outcome part: nothing learned"))
        }
        return parts.joined(separator: " · ")
    }

    private func stateText(_ state: SplitBolusPlan.State) -> String {
        switch state {
        case .waiting: return String(localized: "Not due yet", comment: "State of a split waiting for its rest")
        case .notified: return String(localized: "Due: notification sent", comment: "State of a split whose rest is due")
        case .postponed: return String(localized: "Waiting half an hour: glucose was low or falling", comment: "State of a split whose rest waits")
        default: return ""
        }
    }

    private func glucose(_ mgdl: Double) -> String {
        displayGlucosePreference.format(HKQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl))
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
        settings = UserDefaults.standard.splitBolusSettings
        calibration = UserDefaults.standard.splitBolusCalibration
        open = manager?.openPlans ?? []
    }
}
