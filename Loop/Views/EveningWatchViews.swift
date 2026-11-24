//
//  EveningWatchViews.swift
//  Loop
//
//  The high watch's card on the home screen, its settings and its log.
//

import LoopKitUI
import SwiftUI

/// An open suggestion with its buttons, or a line on what the watch is doing tonight.
struct EveningWatchCard: View {
    let card: EveningWatchCardContent
    var onReview: (EveningWatchAction) -> Void
    var onDecline: (EveningWatchAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let action = card.open {
                Text(EveningWatchText.suggestionTitle(action))
                    .font(.headline)
                Text(EveningWatchText.reason(action))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button {
                        onReview(action)
                    } label: {
                        Text("Review", comment: "Button opening the bolus screen with the meal watch suggestion")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.insulinTintColor)

                    Button(role: .destructive) {
                        onDecline(action)
                    } label: {
                        Text("Decline", comment: "Button declining the meal watch suggestion")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Text("Stays until answered here or in LoopFollow, or until glucose comes down.", comment: "Evening watch card: how long a suggestion stays")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: EveningWatchText.symbol)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(watching)
                            .font(.subheadline)
                        ForEach(card.tonight) { action in
                            Text(verbatim: "\(EveningWatchText.time(action.date)) · \(EveningWatchText.state(action))")
                                .font(.caption)
                                .foregroundColor(action.state == .failed ? .orange : .secondary)
                        }
                        if let stop = card.stop {
                            Text(String(format: NSLocalizedString("Automatic turned off after %@", comment: "Evening watch log (1: lowest glucose)"), EveningWatchText.glucose(stop.lowest)))
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private var watching: String {
        if card.allDay {
            return NSLocalizedString("High watch suggests around the clock", comment: "High watch card outside the evening window when it watches around the clock")
        }
        let until = EveningWatchText.time(card.windowEnd)
        if card.givesItself {
            return String(format: NSLocalizedString("High watch doses until %@", comment: "High watch card in automatic mode (1: time)"), until)
        }
        return String(format: NSLocalizedString("High watch suggests until %@", comment: "High watch card in suggestion mode (1: time)"), until)
    }
}

struct EveningWatchSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = EveningWatchManager.shared
    @State private var settings = EveningWatchManager.shared.settings
    @State private var confirmsAutomatic = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker(selection: modeBinding) {
                        Text("Off", comment: "Evening watch mode").tag(EveningWatchSettings.Mode.off)
                        Text("Suggest", comment: "Evening watch mode").tag(EveningWatchSettings.Mode.suggest)
                        Text("Automatic", comment: "Evening watch mode").tag(EveningWatchSettings.Mode.automatic)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    if let stop = manager.state.stop, settings.mode != .automatic {
                        Text(EveningWatchText.stopped(stop, actions: manager.state.actions))
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                } footer: {
                    Text(modeFooter)
                }

                Section {
                    Toggle(isOn: $settings.allDay) {
                        Text("Around the Clock", comment: "High watch: watch all day and night, not only in the evening")
                    }
                    if !settings.allDay || settings.mode == .automatic {
                        timeRow(settings.allDay ? String(localized: "Gives Itself From", comment: "High watch around the clock: start of the hours when automatic mode gives the dose") : String(localized: "From", comment: "Evening watch: start of the window"), minutes: $settings.start)
                        timeRow(String(localized: "To", comment: "Evening watch: end of the window"), minutes: $settings.end)
                    }
                    timeRow(String(localized: "Late From", comment: "Evening watch: when the late limits start"), minutes: $settings.lateFrom)
                } header: {
                    Text("When", comment: "Evening watch settings header")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if settings.allDay {
                            Text("By day and at night it only suggests, also when Automatic is on. Food and doses come close together by day: over six weeks in autumn 2026, one in seven suggestions by day or at night was followed by glucose under 4.5 within three hours, against one in fifty in the evening. Look at what has been eaten and given before you give it.", comment: "High watch settings footer when it watches around the clock")
                        }
                        Text("From the late time until 06:00 both limits are 1 mmol/L higher and the dose is 60 %: glucose falls by itself more often after 23:00.", comment: "Evening watch settings footer under the times")
                    }
                }

                Section {
                    Stepper(value: $settings.risingFrom, in: EveningWatchSettings.risingRange, step: 0.5) {
                        valueRow(String(localized: "Rising From", comment: "Evening watch: the rising limit"), glucose(settings.risingFrom))
                    }
                    Stepper(value: $settings.highFrom, in: EveningWatchSettings.highRange, step: 0.5) {
                        valueRow(String(localized: "High From", comment: "Evening watch: the high limit"), glucose(settings.highFrom))
                    }
                } header: {
                    Text("Glucose", comment: "Evening watch settings header")
                } footer: {
                    Text("Rising: at or over the limit, up at least 0.3 over 15 minutes and 0.8 over half an hour. High: every reading for half an hour near the limit, and not falling.", comment: "Evening watch settings footer under the limits")
                }

                Section {
                    Stepper(value: $settings.startUnits, in: EveningWatchSettings.startUnitsRange, step: 0.05) {
                        valueRow(String(localized: "Dose at 12 mmol/L", comment: "Evening watch: the starting dose"), units(settings.startUnits))
                    }
                    if let learned = manager.state.learnedUnits {
                        HStack {
                            valueRow(String(localized: "Learned", comment: "Evening watch: the learned dose"), units(learned))
                            Button(String(localized: "Reset", comment: "Evening watch: forget the learned dose")) {
                                manager.forgetLearnedDose()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Stepper(value: $settings.maximumIOB, in: EveningWatchSettings.maximumIOBRange, step: 0.1) {
                        valueRow(String(localized: "Insulin on Board Under", comment: "Evening watch: maximum insulin on board"), units(settings.maximumIOB))
                    }
                    Stepper(value: $settings.maximumPerEvening, in: EveningWatchSettings.maximumPerEveningRange, step: 0.05) {
                        valueRow(settings.allDay ? String(localized: "At Most per 6 Hours", comment: "High watch around the clock: units in any six hours") : String(localized: "At Most per Evening", comment: "Evening watch: units per evening"), units(settings.maximumPerEvening))
                    }
                    Stepper(value: $settings.dosesPerEvening, in: EveningWatchSettings.dosesPerEveningRange) {
                        valueRow(settings.allDay ? String(localized: "Doses per 6 Hours", comment: "High watch around the clock: doses in any six hours") : String(localized: "Doses per Evening", comment: "Evening watch: doses per evening"), "\(settings.dosesPerEvening)")
                    }
                    Stepper(value: $settings.minutesBetween, in: EveningWatchSettings.minutesBetweenRange, step: 15) {
                        valueRow(String(localized: "At Least Between", comment: "Evening watch: minutes between doses"), String(format: NSLocalizedString("%d min", comment: "Minutes (1: number)"), settings.minutesBetween))
                    }
                } header: {
                    Text("Dose", comment: "Evening watch settings header")
                } footer: {
                    Text("Under 10 mmol/L 65 % of the dose, under 12 80 %, never over 0.8 U or the maximum bolus. After each dose given it learns from the next three hours: smaller after a low, larger when glucose was still over 12 two hours on.", comment: "High watch settings footer under the dose")
                }

                Section {
                    Text("Nothing when: glucose was under 6 in the last hour, carbs within 90 minutes (30 under 15 g, or entered ahead), a dose by hand within 30 minutes, Loop forecasts under 3.9, an override with less insulin is on, readings are missing or jump. Automatic also needs closed loop on and the pump free. A reading under 4 within four hours of an automatic dose turns automatic off. A fast rise from 10 (0.8 in 15 minutes) waits only 20 minutes after small carbs or a dose by hand.", comment: "Evening watch's fixed safety rules")
                        .font(.footnote)
                } header: {
                    Text("Always", comment: "Evening watch settings header above the fixed rules")
                }

                Section {
                    NavigationLink {
                        EveningWatchLogView(state: manager.state)
                    } label: {
                        Text("What It Has Done", comment: "Evening watch: link to the log")
                    }
                }
            }
            .insetGroupedListStyle()
            .navigationTitle(Text(verbatim: EveningWatchText.symbol + " " + EveningWatchText.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Done button")) { dismiss() }
                }
            }
            .onChange(of: settings) { newValue in
                manager.update(newValue)
            }
            .alert(Text("Give insulin automatically?", comment: "Evening watch: confirm automatic mode"), isPresented: $confirmsAutomatic) {
                Button(String(localized: "Turn On", comment: "Evening watch: confirm automatic mode")) {
                    settings.mode = .automatic
                }
                Button(String(localized: "Cancel", comment: "Cancel button"), role: .cancel) {}
            } message: {
                Text(String(format: NSLocalizedString("From %3$@ to %4$@ the high watch then gives up to %1$@ by itself, %2$@ at a time, without asking. Outside those hours it never gives anything itself. Keep the low alerts on.", comment: "High watch: what automatic mode means (1: units per evening)(2: largest dose)(3: start of the window)(4: end of the window)"), units(settings.maximumPerEvening), units(EveningWatch.Rule.maximumUnits), clock(settings.start), clock(settings.end)))
            }
        }
    }

    private var modeBinding: Binding<EveningWatchSettings.Mode> {
        Binding(
            get: { settings.mode },
            set: { mode in
                if mode == .automatic, settings.mode != .automatic {
                    confirmsAutomatic = true
                } else {
                    settings.mode = mode
                }
            }
        )
    }

    private var modeFooter: String {
        switch settings.mode {
        case .off:
            return NSLocalizedString("When glucose keeps rising or stays high and nothing has been given or eaten for a while, the high watch suggests a correction or gives it. It goes by glucose itself, not by Loop's forecast.", comment: "High watch settings: explanation when off")
        case .suggest:
            return NSLocalizedString("Suggests a correction here and in LoopFollow. The suggestion stays until it is given or declined, or until glucose comes down.", comment: "Evening watch settings: explanation of suggestion mode")
        case .automatic:
            return settings.allDay
                ? NSLocalizedString("Gives the correction itself in the hours below, and suggests it the rest of the day. Every dose shows here, in LoopFollow and in Nightscout.", comment: "High watch settings: explanation of automatic mode around the clock")
                : NSLocalizedString("Gives the correction itself and keeps watching until the window ends. Every dose shows here, in LoopFollow and in Nightscout.", comment: "Evening watch settings: explanation of automatic mode")
        }
    }

    private func timeRow(_ title: String, minutes: Binding<Int>) -> some View {
        DatePicker(title, selection: Binding(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: { minutes.wrappedValue = EveningWatch.minutes($0) }
        ), displayedComponents: .hourAndMinute)
    }

    /// Minutes after midnight as a time of day.
    private func clock(_ minutes: Int) -> String {
        EveningWatchText.time(Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date())
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }

    private func glucose(_ mmol: Double) -> String {
        EveningWatchText.glucose(mmol) + " mmol/L"
    }

    private func units(_ value: Double) -> String {
        String(format: NSLocalizedString("%@ U", comment: "Units of insulin (1: number)"), EveningWatchText.units(value))
    }
}

/// Doses and suggestions, then what each look found, newest first.
struct EveningWatchLogView: View {
    let state: EveningWatchState

    var body: some View {
        List {
            if !state.actions.isEmpty {
                Section {
                    ForEach(state.actions.reversed()) { action in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(action.date, style: .date) + Text(verbatim: " ") + Text(action.date, style: .time)
                                Spacer()
                                Text(EveningWatchText.state(action)).foregroundColor(.secondary)
                            }
                            Text(verbatim: (action.kind == .automatic ? "⚙︎ " : "") + EveningWatchText.reason(action))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if let outcome = action.outcome, let lowest = outcome.lowest {
                                Text(String(format: NSLocalizedString("2 h: %1$@ · lowest %2$@ · dose %3$@ → %4$@ U", comment: "Evening watch: what followed a dose (1: glucose after 2 h)(2: lowest within 3 h)(3: dose before)(4: dose after)"),
                                            outcome.after2h.map(EveningWatchText.glucose) ?? "–", EveningWatchText.glucose(lowest), EveningWatchText.units(outcome.unitsBefore), EveningWatchText.units(outcome.unitsAfter)))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Doses and Suggestions", comment: "Evening watch log header")
                }
            }
            Section {
                ForEach(Array(state.decisions.reversed().prefix(200).enumerated()), id: \.offset) { _, decision in
                    HStack {
                        Text(EveningWatchText.time(decision.date)).monospacedDigit()
                        Text(decision.glucose.map(EveningWatchText.glucose) ?? "–").monospacedDigit().foregroundColor(.secondary)
                        Text(EveningWatchText.decision(decision))
                    }
                    .font(.footnote)
                }
            } header: {
                Text("Each Reading", comment: "Evening watch log header")
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(Text("What It Has Done", comment: "Evening watch: link to the log"))
    }
}
