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
        UserDefaults.standard.aiDoseAdviceSettings.isEnabled && OpenAIChat.shared != nil
    }

    var body: some View {
        NavigationView {
            List {
                todaySection
                if status.longTermText != nil || status.longTerm != nil || aiEnabled {
                    longTermSection
                }
                if let longTerm = status.longTerm {
                    daypartsSection(longTerm)
                    if !longTerm.advice.isEmpty {
                        adviceSection(longTerm.advice)
                    }
                }
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
                manager.updateIfDue(force: true)
            }
            .onAppear {
                if refreshOnAppear {
                    manager.updateIfDue(force: true)
                }
            }
        }
    }

    // MARK: Today

    @ViewBuilder
    private var todaySection: some View {
        Section {
            if let text = status.todayText, Calendar.current.isDateInToday(text.createdAt) {
                InsightTextView(text: text)
            } else if aiEnabled {
                Text("The AI writes about today from 06:00, and again when a meal is over or after a low.", comment: "Shown before the AI has written about today")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            if let today = status.today, Calendar.current.isDateInToday(today.computedAt) {
                if let period = today.period {
                    PeriodRow(period: period, hoursAboveTen: today.hoursAboveTen)
                }
                if let deviation = today.forecastDeviationMmol {
                    Label {
                        Text(deviationText(deviation))
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: deviation > 0 ? "arrow.up.right" : deviation < 0 ? "arrow.down.right" : "equal")
                            .foregroundColor(abs(deviation) >= 1 ? .orange : .secondary)
                    }
                }
                ForEach(today.meals, id: \.date) { meal in
                    MealRow(meal: meal)
                }
            } else if status.today == nil {
                Text("No numbers yet. They are read from Nightscout.", comment: "Shown when the glucose insight has no data yet")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Today", comment: "Header of today's section in the glucose insight")
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

    // MARK: The weeks behind

    @ViewBuilder
    private var longTermSection: some View {
        Section {
            if let text = status.longTermText {
                InsightTextView(text: text)
            } else if aiEnabled {
                Text("The AI writes about the weeks behind each night after 04:00.", comment: "Shown before the AI has written about the weeks behind")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            if let longTerm = status.longTerm {
                if let week = longTerm.last7Days {
                    LabeledValue(label: String(localized: "Last 7 days", comment: "Glucose insight: last seven days"), value: periodSummary(week))
                }
                if let earlier = longTerm.earlierDays {
                    LabeledValue(label: String(format: NSLocalizedString("Days 8–%d", comment: "Glucose insight: the days before the last seven (1: days kept)"), longTerm.days), value: periodSummary(earlier))
                }
                if let weekday = longTerm.weekdayDaytime, let weekend = longTerm.weekendDaytime {
                    LabeledValue(
                        label: String(localized: "09–15 weekday / weekend", comment: "Glucose insight: daytime on weekdays against weekends"),
                        value: "\(weekday.timeInRangePercent) % / \(weekend.timeInRangePercent) %"
                    )
                }
            }
        } header: {
            Text("The Weeks Behind", comment: "Header of the long-term section in the glucose insight")
        }
    }

    private func daypartsSection(_ longTerm: GlucoseInsightLongTerm) -> some View {
        Section {
            ForEach(longTerm.dayparts, id: \.name) { part in
                DaypartRow(part: part)
            }
        } header: {
            Text("Parts of the Day", comment: "Header of the parts of the day in the glucose insight")
        } footer: {
            Text("Loop 2 h: how far glucose ended above (+) or below (−) Loop's forecast two hours on. Meals: only those without extra carbs, corrections or treated lows.", comment: "Footer explaining the parts of the day in the glucose insight")
        }
    }

    private func adviceSection(_ advice: [GlucoseInsightAdvice]) -> some View {
        Section {
            let accepted = advice.filter(\.accepted)
            LabeledValue(
                label: String(localized: "Shown / used", comment: "Glucose insight: AI doses shown and used"),
                value: "\(advice.count) / \(accepted.count)"
            )
            let finished = accepted.compactMap(\.lowestWithin4hMmol)
            if !finished.isEmpty {
                LabeledValue(
                    label: String(localized: "Low after a used AI dose", comment: "Glucose insight: lows within four hours of a used AI dose"),
                    value: "\(finished.filter { $0 < 3.9 }.count) / \(finished.count)"
                )
            }
            ForEach(advice.suffix(5).reversed(), id: \.date) { record in
                AdviceRow(record: record)
            }
        } header: {
            Text("AI Doses", comment: "Header of the AI dose outcomes in the glucose insight")
        }
    }

    // MARK: Updating

    private var updateSection: some View {
        Section {
            Button {
                manager.updateIfDue(force: true)
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
                if aiEnabled {
                    let usage = UserDefaults.standard.openAIUsage(on: Date())
                    Text(String(format: NSLocalizedString("AI today: %1$@ calls, about $%2$@ (about %3$@ kr).", comment: "Glucose insight: OpenAI use today (1: calls)(2: dollars)(3: kroner)"),
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

private struct InsightTextView: View {
    let text: GlucoseInsightText

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text.summary)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(text.doseHints, id: \.self) { hint in
                Label {
                    Text(hint).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lightbulb").foregroundColor(.purple)
                }
            }
            ForEach(text.points, id: \.self) { point in
                Text(verbatim: "• \(point)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(text.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
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
