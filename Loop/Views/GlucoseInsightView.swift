//
//  GlucoseInsightView.swift
//  Loop
//
//  The insight tab: what today and the weeks behind show, as the AI dose advice reads it.
//

import LoopKitUI
import SwiftUI

struct GlucoseInsightView: View {
    @ObservedObject var manager: GlucoseInsightManager
    /// Off only for looking at made-up numbers.
    var refreshOnAppear = true
    @Environment(\.dismiss) private var dismiss

    private var status: GlucoseInsightStatus { manager.status }
    private var aiEnabled: Bool {
        UserDefaults.standard.aiDoseAdviceSettings.isEnabled && AIChat.shared != nil
    }

    @State private var showsDetails = false
    /// The suggestion waiting for a yes before it is turned on.
    @State private var confirming: GlucoseInsightSuggestion?
    @State private var working: GlucoseInsightSuggestion?
    @State private var failures: [GlucoseInsightSuggestion: String] = [:]

    private var todayText: GlucoseInsightText? {
        status.todayText.flatMap { Calendar.current.isDateInToday($0.createdAt) ? $0 : nil }
    }

    private var today: GlucoseInsightToday? {
        status.today.flatMap { Calendar.current.isDateInToday($0.computedAt) ? $0 : nil }
    }

    var body: some View {
        NavigationView {
            List {
                nowSection
                todaySection
                weekSection
                // Checked against the settings now: what has been done already is not suggested again.
                let suggestions = manager.suggestionsNow().filter { $0.state != .changed || manager.activation(for: $0) != nil }
                if !suggestions.isEmpty {
                    suggestionsSection(suggestions)
                }
                detailsSection
                updateSection
            }
            .insetGroupedListStyle()
            .navigationTitle(Text("Insight", comment: "Title of the glucose insight screen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", comment: "Button closing the glucose insight screen")) {
                        dismiss()
                    }
                }
            }
            .refreshable {
                await manager.refresh()
            }
            .onAppear {
                if refreshOnAppear {
                    manager.updateIfDue(force: true)
                }
            }
        }
    }

    // MARK: Now

    @ViewBuilder
    private var nowSection: some View {
        Section {
            if let text = todayText, let now = text.now {
                VStack(alignment: .leading, spacing: 10) {
                    Text(now)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let action = text.action {
                        Label {
                            Text(action).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "hand.point.right.fill").foregroundColor(.orange)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    Text(text.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } else if aiEnabled {
                Text("The AI looks at the situation every half hour from 06:00.", comment: "Shown before the AI has written about the situation now")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Now", comment: "Header of the situation now in the glucose insight")
        }
    }

    // MARK: Today

    @ViewBuilder
    private var todaySection: some View {
        Section {
            if let text = todayText {
                Text(text.summary)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                InsightList(title: String(localized: "Why", comment: "Glucose insight: heading of the causes of how today is going"), lines: text.causes ?? [], symbol: "magnifyingglass", color: .orange)
                InsightList(title: String(localized: "Do This", comment: "Glucose insight: heading of what to do for more time in range"), lines: text.fixes ?? [], symbol: "target", color: .green)
            }
            if let today, let period = today.period {
                PeriodRow(period: period, hoursAboveTen: today.hoursAboveTen)
            } else if todayText == nil {
                Text("No numbers yet. They are read from Nightscout.", comment: "Shown when the glucose insight has no data yet")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Today", comment: "Header of today's section in the glucose insight")
        }
    }

    // MARK: This week

    @ViewBuilder
    private var weekSection: some View {
        Section {
            if let text = status.longTermText {
                Text(text.summary)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if let trend = text.trend, !trend.isEmpty {
                    Label {
                        Text(trend).font(.footnote).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "chart.line.uptrend.xyaxis").foregroundColor(.purple)
                    }
                }
                InsightList(title: String(localized: "For More Time in Range", comment: "Glucose insight: heading of the week's concrete measures"), lines: text.fixes ?? [], symbol: "target", color: .green)
            } else if aiEnabled {
                Text("The AI looks at the week each night after 04:00.", comment: "Shown before the AI has written about the week")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            if let week = status.longTerm?.last7Days {
                LabeledValue(label: String(localized: "Last 7 days", comment: "Glucose insight: last seven days"), value: periodSummary(week))
            }
            if let days = status.longTerm?.recentDays, days.count >= 3 {
                RecentDaysRow(days: days)
            }
            if let weeks = status.longTerm?.weeks, weeks.count >= 2 {
                LabeledValue(
                    label: String(localized: "Last 4 weeks", comment: "Glucose insight: time in range week by week"),
                    value: weeks.map { "\($0.period.timeInRangePercent)" }.joined(separator: " → ") + " %"
                )
            }
        } header: {
            Text("This Week", comment: "Header of the week section in the glucose insight")
        }
    }

    // MARK: Suggested settings

    private func suggestionsSection(_ suggestions: [GlucoseInsightSuggestion]) -> some View {
        Section {
            ForEach(suggestions, id: \.self) { suggestion in
                SuggestionRow(
                    suggestion: suggestion,
                    isDone: suggestion.state == .done,
                    activation: manager.activation(for: suggestion),
                    canActivate: manager.preview(suggestion) != nil,
                    isWorking: working == suggestion,
                    failure: failures[suggestion],
                    activate: { confirming = suggestion },
                    undo: { activation in run(suggestion) { try await manager.undo(activation) } }
                )
            }
        } header: {
            Text("Suggested Settings", comment: "Header of the suggested therapy settings changes in the glucose insight")
        } footer: {
            Text("Only patterns seen on at least three days. Talk it over with the diabetes team before changing anything.", comment: "Footer of the suggested therapy settings changes in the glucose insight")
        }
        .alert(
            Text("Activate Suggestion?", comment: "Title of the confirmation before an insight suggestion changes a setting"),
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            presenting: confirming
        ) { suggestion in
            Button(String(localized: "Activate", comment: "Button turning on an insight suggestion")) {
                run(suggestion) { try await manager.activate(suggestion) }
            }
            Button(String(localized: "Cancel", comment: "Button cancelling turning on an insight suggestion"), role: .cancel) {}
        } message: { suggestion in
            Text(confirmationText(suggestion))
        }
    }

    private func run(_ suggestion: GlucoseInsightSuggestion, _ action: @escaping () async throws -> Void) {
        working = suggestion
        failures[suggestion] = nil
        Task {
            do {
                try await action()
            } catch {
                failures[suggestion] = error.localizedDescription
            }
            working = nil
        }
    }

    private func confirmationText(_ suggestion: GlucoseInsightSuggestion) -> String {
        let changes = manager.preview(suggestion) ?? []
        let lines = changes.map { change in
            "\(clock(change.start))–\(clock(change.end)):  \(SuggestionRow.value(change.from, suggestion.setting)) → \(SuggestionRow.value(change.to, suggestion.setting)) \(SuggestionRow.unit(suggestion.setting))"
        }
        let intro = String(format: NSLocalizedString("%@ in Loop's settings changes like this:", comment: "Glucose insight: the confirmation before turning on a suggestion, followed by the changes (1: setting name)"), SuggestionRow.title(suggestion.setting))
        let outro = String(localized: "Loop uses it from the next loop. You can undo it here as long as no one has changed the setting since.", comment: "Glucose insight: after the changes in the confirmation before turning on a suggestion")
        return ([intro, ""] + lines + ["", outro]).joined(separator: "\n")
    }

    // MARK: Details

    private var detailsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsDetails) {
                if let text = todayText {
                    hints(text.doseHints)
                }
                if let today, let deviation = today.forecastDeviationMmol {
                    Label {
                        Text(deviationText(deviation)).font(.subheadline)
                    } icon: {
                        Image(systemName: deviation > 0 ? "arrow.up.right" : deviation < 0 ? "arrow.down.right" : "equal")
                            .foregroundColor(abs(deviation) >= 1 ? .orange : .secondary)
                    }
                }
                if let today {
                    ForEach(today.meals, id: \.date) { meal in
                        MealRow(meal: meal)
                    }
                }
                if let text = status.longTermText {
                    ForEach(text.points, id: \.self) { point in
                        Text(verbatim: "• \(point)")
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    hints(text.doseHints)
                }
                if let longTerm = status.longTerm {
                    ForEach(longTerm.dayparts, id: \.name) { part in
                        DaypartRow(part: part)
                    }
                    if !longTerm.advice.isEmpty {
                        let accepted = longTerm.advice.filter(\.accepted)
                        LabeledValue(
                            label: String(localized: "AI doses shown / used", comment: "Glucose insight: AI doses shown and used"),
                            value: "\(longTerm.advice.count) / \(accepted.count)"
                        )
                        ForEach(longTerm.advice.suffix(5).reversed(), id: \.date) { record in
                            AdviceRow(record: record)
                        }
                    }
                }
            } label: {
                Text("Show Details", comment: "Disclosure for the details behind the glucose insight")
            }
        }
    }

    private func hints(_ hints: [String]) -> some View {
        ForEach(hints, id: \.self) { hint in
            Label {
                Text(hint).font(.footnote).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lightbulb").foregroundColor(.purple)
            }
        }
    }

    private func deviationText(_ deviation: Double) -> String {
        if deviation >= 1 || deviation <= -1 {
            let value = mmol(abs(deviation))
            return deviation > 0
                ? String(format: NSLocalizedString("Loop is forecasting %@ mmol/L lower than usual today: more insulin is needed than usual.", comment: "Glucose insight: today's forecast deviation, more insulin needed (1: signed mmol/L)"), value)
                : String(format: NSLocalizedString("Loop is forecasting %@ mmol/L higher than usual today: less insulin is needed than usual.", comment: "Glucose insight: today's forecast deviation, less insulin needed (1: signed mmol/L)"), value)
        }
        return String(format: NSLocalizedString("Loop's forecast is about as usual today (%@ mmol/L).", comment: "Glucose insight: today's forecast deviation is small (1: signed mmol/L)"), signed(deviation))
    }

    // MARK: Updating

    private var updateSection: some View {
        Section {
            Button {
                manager.updateIfDue(force: true, manual: true)
            } label: {
                HStack {
                    Text("Update Now", comment: "Button updating the glucose insight")
                    Spacer()
                    if manager.isUpdating {
                        ProgressView()
                    }
                }
            }
            .disabled(manager.isUpdating)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let updated = status.dataUpdatedAt {
                    Text(String(format: NSLocalizedString("Numbers from Nightscout %@.", comment: "Glucose insight: when the numbers were read (1: time)"), updated.formatted(date: .omitted, time: .shortened)))
                }
                if let error = status.lastError {
                    Text(error).foregroundColor(.red)
                }
                switch manager.sharing {
                case let .shared(date):
                    Text(String(format: NSLocalizedString("Shared with LoopFollow %@.", comment: "Glucose insight: when it was last put in Nightscout for LoopFollow (1: time)"), date.formatted(date: .omitted, time: .shortened)))
                case let .failed(error, date):
                    Text(String(format: NSLocalizedString("Couldn't share with LoopFollow %1$@: %2$@", comment: "Glucose insight: putting it in Nightscout for LoopFollow failed (1: time)(2: error)"), date.formatted(date: .omitted, time: .shortened), error))
                        .foregroundColor(.red)
                case nil:
                    EmptyView()
                }
                if aiEnabled {
                    let usage = UserDefaults.standard.aiUsage(on: Date())
                    Text(String(format: NSLocalizedString("AI today: %1$@ calls, about $%2$@ (about %3$@ kr).", comment: "Glucose insight: AI use today (1: calls)(2: dollars)(3: kroner)"),
                                "\(usage.byTier.values.reduce(0) { $0 + $1.calls })",
                                usage.dollars.formatted(.number.precision(.fractionLength(2))),
                                (usage.dollars * 10.5).formatted(.number.precision(.fractionLength(0)))))
                } else {
                    Text("Turn on AI Dose Advice in settings to have the AI write what the numbers mean.", comment: "Glucose insight: AI is off")
                }
            }
        }
    }

    private func periodSummary(_ period: GlucoseInsightPeriod) -> String {
        String(format: NSLocalizedString("%1$d %% in range · %2$@ mean · %3$d lows", comment: "Glucose insight: a period's summary (1: percent in range)(2: mean mmol/L)(3: low episodes)"),
               period.timeInRangePercent, mmol(period.meanMmol), period.lowEpisodes)
    }
}

// MARK: - Rows

private func mmol(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
}

private func signed(_ value: Double) -> String {
    (value > 0 ? "+" : value < 0 ? "−" : "") + mmol(abs(value))
}

private func clock(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    return String(format: "%02d:%02d", minutes / 60, minutes % 60)
}

private struct SuggestionRow: View {
    let suggestion: GlucoseInsightSuggestion
    /// The setting already has the proposed value (changed by hand, or from LoopFollow).
    var isDone = false
    let activation: GlucoseInsightActivation?
    let canActivate: Bool
    let isWorking: Bool
    let failure: String?
    let activate: () -> Void
    let undo: (GlucoseInsightActivation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "\(Self.title(suggestion.setting)) \(String(format: "%02d", suggestion.startHour))–\(String(format: "%02d", suggestion.endHour))")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(verbatim: "\(Self.value(suggestion.current, suggestion.setting)) → \(Self.value(suggestion.proposed, suggestion.setting)) \(Self.unit(suggestion.setting))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(suggestion.givesMoreInsulin ? .orange : .blue)
            }
            Text(suggestion.reason)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            controls
            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var controls: some View {
        if isWorking {
            HStack(spacing: 8) {
                ProgressView()
                Text("Saving…", comment: "Glucose insight: a suggestion is being turned on or undone").font(.footnote).foregroundColor(.secondary)
            }
        } else if let activation {
            HStack {
                Label {
                    Text(String(format: NSLocalizedString("Active since %@", comment: "Glucose insight: a suggestion that was turned on (1: date and time)"),
                                activation.date.formatted(.dateTime.weekday(.abbreviated).hour().minute())))
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                }
                .font(.footnote)
                Spacer()
                Button(String(localized: "Undo", comment: "Button undoing a turned-on insight suggestion")) {
                    undo(activation)
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
            }
        } else if isDone {
            Label {
                Text(String(format: NSLocalizedString("Already done: it is %@ now", comment: "Glucose insight: a suggestion whose setting already has the proposed value (1: value with unit)"),
                            "\(Self.value(suggestion.proposed, suggestion.setting)) \(Self.unit(suggestion.setting))"))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            }
            .font(.footnote)
        } else if canActivate {
            Button(action: activate) {
                Label {
                    Text("Activate", comment: "Button turning on an insight suggestion")
                } icon: {
                    Image(systemName: "wand.and.stars").foregroundColor(.purple)
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.purple)
        } else {
            Text("The setting is no longer what the suggestion was made from.", comment: "Glucose insight: a suggestion that can't be turned on because the setting has changed")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    static func title(_ setting: GlucoseInsightSuggestion.Setting) -> String {
        switch setting {
        case .carbRatio: return String(localized: "Carb ratio", comment: "Glucose insight suggestion: carb ratio")
        case .insulinSensitivity: return String(localized: "Insulin sensitivity", comment: "Glucose insight suggestion: insulin sensitivity")
        case .basalRate: return String(localized: "Basal rate", comment: "Glucose insight suggestion: basal rate")
        }
    }

    static func unit(_ setting: GlucoseInsightSuggestion.Setting) -> String {
        switch setting {
        case .carbRatio: return "g/E"
        case .insulinSensitivity: return "mmol/L/E"
        case .basalRate: return "E/t"
        }
    }

    static func value(_ number: Double, _ setting: GlucoseInsightSuggestion.Setting) -> String {
        // Sensitivity kept in mg/dL reads as 2.775 mmol/L; it is shown as the insight shows it.
        number.formatted(.number.precision(.fractionLength(setting == .insulinSensitivity ? 0...1 : 0...2)))
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

private struct PeriodRow: View {
    let period: GlucoseInsightPeriod
    let hoursAboveTen: Double

    var body: some View {
        HStack {
            stat("\(period.timeInRangePercent) %", String(localized: "in range", comment: "Glucose insight: time in range label"))
            stat(mmol(period.meanMmol), String(localized: "mean", comment: "Glucose insight: mean glucose label"))
            stat("\(period.lowEpisodes)", String(localized: "lows", comment: "Glucose insight: low episodes label"))
            stat(hoursAboveTen.formatted(.number.precision(.fractionLength(1))) + " t", String(localized: "over 10", comment: "Glucose insight: hours above 10 mmol/L label"))
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline)
            Text(label).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MealRow: View {
    let meal: GlucoseInsightMeal

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(meal.date.formatted(date: .omitted, time: .shortened)).font(.subheadline.monospacedDigit())
                Text(meal.foods.isEmpty ? "🍽" : meal.foods.joined(separator: " + ")).font(.subheadline).lineLimit(1)
                Spacer()
                Text(verbatim: "\(Int(meal.carbsGrams)) g · \(meal.bolusUnits.formatted(.number.precision(.fractionLength(0...2)))) E")
                    .font(.subheadline).foregroundColor(.secondary)
            }
            Text(curve)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var curve: String {
        var parts: [String] = []
        if let start = meal.startMmol { parts.append(mmol(start)) }
        if let peak = meal.peakMmol { parts.append("↑ " + mmol(peak)) }
        if let after = meal.after3hMmol { parts.append("3 t " + mmol(after)) }
        if let lowest = meal.lowestWithin4hMmol, lowest < 3.9 { parts.append("⚠︎ " + mmol(lowest)) }
        var text = parts.joined(separator: " → ")
        let flags = meal.flags.filter { $0 != .unfinished }
        if !flags.isEmpty {
            text += " · " + flags.map(Self.flagText).joined(separator: ", ")
        }
        if meal.flags.contains(.unfinished) {
            text += " · " + String(localized: "still going", comment: "Glucose insight: a meal less than four hours ago")
        }
        return text
    }

    static func flagText(_ flag: GlucoseInsightMeal.Flag) -> String {
        switch flag {
        case .extraCarbs: return String(localized: "extra carbs", comment: "Glucose insight meal flag")
        case .correction: return String(localized: "correction", comment: "Glucose insight meal flag")
        case .treatedLow: return String(localized: "treated low", comment: "Glucose insight meal flag")
        case .startedLow: return String(localized: "started low", comment: "Glucose insight meal flag")
        case .unfinished: return String(localized: "still going", comment: "Glucose insight: a meal less than four hours ago")
        }
    }
}

private struct DaypartRow: View {
    let part: GlucoseInsightDaypart

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(part.name.capitalized).font(.subheadline.weight(.semibold))
                Spacer()
                if let week = part.last7Days, let month = part.last30Days {
                    Text(String(format: NSLocalizedString("%1$d %% · 30 d %2$d %%", comment: "Glucose insight: time in range last 7 and 30 days (1: 7 days)(2: 30 days)"), week.timeInRangePercent, month.timeInRangePercent))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            details
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

extension DaypartRow {
    /// One line of text that wraps as a sentence, with the worrying numbers in colour.
    private var details: Text {
        var parts: [Text] = []
        if let error = part.loopForecastError2hMmol {
            parts.append(Text(verbatim: "Loop\u{00A0}2\u{00A0}t\u{00A0}\(signed(error))").foregroundColor(abs(error) >= 1.5 ? .orange : .secondary))
        }
        if part.cleanMeals > 0 {
            parts.append(Text(String(format: NSLocalizedString("%d meals", comment: "Glucose insight: clean meals in a part of the day"), part.cleanMeals)).foregroundColor(.secondary))
            if let low = part.lowAfterMealPercent {
                parts.append(Text(String(format: NSLocalizedString("low after %d %%", comment: "Glucose insight: share of meals followed by a low"), low)).foregroundColor(low >= 20 ? .red : .secondary))
            }
            if let high = part.highAt3hPercent {
                parts.append(Text(String(format: NSLocalizedString(">10 at 3 h %d %%", comment: "Glucose insight: share of meals above 10 three hours on"), high)).foregroundColor(high >= 40 ? .orange : .secondary))
            }
        }
        guard let first = parts.first else { return Text(verbatim: "") }
        return parts.dropFirst().reduce(first) { $0 + Text(verbatim: "  ·  ").foregroundColor(.secondary) + $1 }
    }
}

private struct AdviceRow: View {
    let record: GlucoseInsightAdvice

    var body: some View {
        HStack {
            Text(record.date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                .font(.footnote.monospacedDigit())
            Spacer()
            Text(verbatim: "AI \(record.suggestedUnits.formatted(.number.precision(.fractionLength(0...2)))) / Loop \((record.loopUnits ?? 0).formatted(.number.precision(.fractionLength(0...2)))) E")
                .font(.footnote)
                .foregroundColor(record.accepted ? .purple : .secondary)
            if let after = record.after3hMmol {
                Text(verbatim: "→ \(mmol(after))")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            if let lowest = record.lowestWithin4hMmol, lowest < 3.9 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red).font(.footnote)
            }
        }
    }
}

/// A short headed list: the causes of today, or what to do.
private struct InsightList: View {
    let title: String
    let lines: [String]
    let symbol: String
    let color: Color

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                ForEach(lines, id: \.self) { line in
                    Label {
                        Text(line).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: symbol).foregroundColor(color)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// Time in range day by day, the last two weeks: one bar a day, newest on the right.
private struct RecentDaysRow: View {
    let days: [GlucoseInsightDay]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Last 14 days", comment: "Glucose insight: time in range day by day")
                Spacer()
                if let first = days.first, let last = days.last {
                    Text(verbatim: "\(first.timeInRangePercent) → \(last.timeInRangePercent) %")
                        .foregroundColor(.secondary)
                }
            }
            .font(.subheadline)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days, id: \.date) { day in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Self.color(day))
                        .frame(height: max(4, CGFloat(day.timeInRangePercent) * 0.4))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(Text(verbatim: "\(day.date.formatted(.dateTime.weekday(.abbreviated).day())): \(day.timeInRangePercent) %"))
                }
            }
            .frame(height: 40, alignment: .bottom)
        }
    }

    static func color(_ day: GlucoseInsightDay) -> Color {
        if day.lowEpisodes > 0 && day.timeInRangePercent < 70 { return .red.opacity(0.7) }
        if day.timeInRangePercent >= 70 { return .green.opacity(0.7) }
        if day.timeInRangePercent >= 50 { return .orange.opacity(0.7) }
        return .red.opacity(0.7)
    }
}
