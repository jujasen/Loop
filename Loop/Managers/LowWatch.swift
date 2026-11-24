//
//  LowWatch.swift
//  Loop
//
//  The low watch («Lavvakt»). When Loop forecasts a low within 20 minutes, or glucose is already
//  under 4.4 and falling, it suggests a few grams of fast carbs, around the clock. It never gives
//  or enters anything itself: a person gives the carbs and enters them.
//
//  The rules come from 42 days of Walter's Nightscout history (14 October–24 November 2026),
//  26 lows under 3.9 for at least ten minutes, five of them under 3.0:
//
//  - Loop's forecast under 3.9 within 20 minutes, with glucose under 6 and not rising, warned
//    before 23 of the 26, a median of 15 minutes ahead. A straight line through the last quarter
//    of an hour caught fewer (21) and was no quieter.
//  - With the safety net (under 4.4 and falling) and 20 minutes between two suggestions, it
//    suggested 2.5 times a day; 0.8 a day were followed by neither a low nor carbs within 45
//    minutes.
//  - Nothing in the 20 minutes after carbs were entered: they are being treated already.
//
//  The grams: one gram raised glucose about 0.7 mmol/L over 45 minutes (median of the lows
//  treated with carbs alone). Enough to lift Loop's lowest forecast within an hour to 5.5, from
//  2 to 6 g. Over the 42 days that was 4 g in the middle, what Julia most often gave.
//
//  Glucose is in mmol/L throughout.
//

import Foundation

struct LowWatchSettings: Codable, Equatable {
    var isOn = false
    /// The notification on this phone makes a sound by day. At night it is silent unless this
    /// is on: a parent's LoopFollow is what wakes someone then.
    var soundAtNight = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case isOn, soundAtNight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isOn = try container.decodeIfPresent(Bool.self, forKey: .isOn) ?? false
        soundAtNight = try container.decodeIfPresent(Bool.self, forKey: .soundAtNight) ?? false
    }
}

struct LowWatchAction: Codable, Equatable, Identifiable {
    enum Trigger: String, Codable {
        /// Loop forecasts a low within 20 minutes.
        case forecast
        /// Already under 4.4 and falling.
        case low
    }

    enum State: String, Codable {
        /// Waiting for carbs.
        case open
        /// Carbs were entered after it.
        case eaten
        case declined
        /// Glucose came up by itself, or it was left too long.
        case lapsed
    }

    var id = UUID().uuidString
    var trigger: Trigger
    var date: Date
    var glucose: Double
    var change15: Double?
    /// Loop's lowest forecast within 20 minutes.
    var lowestForecast: Double?
    /// What the grams were worked out from: Loop's lowest forecast within an hour, or glucose
    /// when that is lower.
    var nadir: Double
    var grams: Double
    var iob: Double?
    var state: State
    var closedAt: Date?
    var eatenGrams: Double?
}

struct LowWatchState: Codable, Equatable {
    var actions: [LowWatchAction] = []

    var open: LowWatchAction? {
        actions.last { $0.state == .open }
    }
}

enum LowWatch {
    struct Carbs: Equatable {
        /// When they are eaten.
        var date: Date
        var grams: Double
        /// When they were entered.
        var entered: Date
    }

    struct Input: Equatable {
        /// Oldest first, at least the last half hour.
        var glucose: [EveningWatch.Reading]
        var carbs: [Carbs]
        var iob: Double?
        /// Loop's lowest forecast within 20 minutes and within an hour; nil without a forecast.
        var lowest20: Double?
        var lowest60: Double?
    }

    enum Rule {
        static let freshGlucose: TimeInterval = 6 * 60
        static let jump = 1.5
        /// Loop forecasts under this within `forecastWithin`, with glucose under `forecastFrom`.
        static let forecastBelow = 3.9
        static let forecastWithin: TimeInterval = 20 * 60
        static let forecastFrom = 6.0
        /// Not when glucose rose more than this over the last five minutes.
        static let rising5 = 0.1
        /// The safety net: under this and lower than a quarter of an hour ago.
        static let lowFrom = 4.4
        /// Carbs entered within this are being treated already.
        static let quietAfterCarbs: TimeInterval = 20 * 60
        /// Carbs dated this far ahead still count as eaten now.
        static let carbsAhead: TimeInterval = 10 * 60
        static let minimumCarbs = 1.0
        static let between: TimeInterval = 20 * 60
        /// The grams lift the lowest forecast to `target`, `mmolPerGram` each, from 2 to 6.
        static let target = 5.5
        static let mmolPerGram = 0.7
        static let grams = 2.0 ... 6.0
        /// An open suggestion lapses at or over this when not falling, or after `lifetime`.
        static let lapseFrom = 5.0
        static let lifetime: TimeInterval = 30 * 60
        /// Night, for the sound on this phone.
        static let nightFrom = 21 * 60
        static let nightUntil = 7 * 60
    }

    enum Effect: Equatable {
        case none
        case suggest(LowWatchAction)
    }

    // MARK: - One look

    static func tick(_ state: LowWatchState, input: Input, settings: LowWatchSettings, now: Date) -> (state: LowWatchState, effect: Effect) {
        var state = state
        state.actions.removeAll { now.timeIntervalSince($0.date) > 7 * 24 * 3600 }
        settle(&state, input: input, now: now)
        guard settings.isOn else {
            close(&state, as: .lapsed, now: now)
            return (state, .none)
        }
        guard state.open == nil, let action = decide(state, input: input, now: now) else { return (state, .none) }
        state.actions.append(action)
        return (state, .suggest(action))
    }

    /// A suggestion, or nil when nothing calls for one.
    static func decide(_ state: LowWatchState, input: Input, now: Date) -> LowWatchAction? {
        guard let latest = input.glucose.last, now.timeIntervalSince(latest.date) <= Rule.freshGlucose,
              let before5 = EveningWatch.reading(near: latest.date.addingTimeInterval(-5 * 60), in: input.glucose),
              let change15 = EveningWatch.change(input.glucose, minutes: 15)
        else { return nil }
        let glucose = latest.mmol
        let change5 = glucose - before5.mmol
        if abs(change5) > Rule.jump { return nil }

        let forecast = glucose < Rule.forecastFrom && (input.lowest20.map { $0 < Rule.forecastBelow } ?? false) && change5 <= Rule.rising5
        let low = glucose < Rule.lowFrom && change15 < 0
        guard forecast || low else { return nil }

        if carbsBeingTreated(input.carbs, now: now) { return nil }
        if let last = state.actions.last, now.timeIntervalSince(last.date) < Rule.between { return nil }

        let nadir = min(input.lowest60 ?? glucose, glucose)
        return LowWatchAction(
            trigger: forecast ? .forecast : .low,
            date: now,
            glucose: glucose,
            change15: change15,
            lowestForecast: input.lowest20,
            nadir: nadir,
            grams: grams(nadir: nadir),
            iob: input.iob,
            state: .open
        )
    }

    /// Enough to lift `nadir` to the target, from 2 to 6 g, whole grams.
    static func grams(nadir: Double) -> Double {
        let grams = ((Rule.target - nadir) / Rule.mmolPerGram).rounded()
        return min(max(grams, Rule.grams.lowerBound), Rule.grams.upperBound)
    }

    static func carbsBeingTreated(_ carbs: [Carbs], now: Date) -> Bool {
        carbs.contains { entry in
            entry.grams >= Rule.minimumCarbs
                && entry.entered <= now && now.timeIntervalSince(entry.entered) < Rule.quietAfterCarbs
                && entry.date <= now.addingTimeInterval(Rule.carbsAhead)
        }
    }

    /// Carbs entered after the suggestion answer it; glucose back up, or the time, lapses it.
    private static func settle(_ state: inout LowWatchState, input: Input, now: Date) {
        guard let index = state.actions.lastIndex(where: { $0.state == .open }) else { return }
        let action = state.actions[index]
        let eaten = input.carbs.filter { $0.grams >= Rule.minimumCarbs && $0.entered >= action.date.addingTimeInterval(-60) && $0.entered <= now }
        if let first = eaten.min(by: { $0.entered < $1.entered }) {
            state.actions[index].state = .eaten
            state.actions[index].eatenGrams = eaten.filter { $0.entered.timeIntervalSince(first.entered) < 5 * 60 }.reduce(0) { $0 + $1.grams }
            state.actions[index].closedAt = first.entered
            return
        }
        let comingUp = input.glucose.last.map { $0.mmol >= Rule.lapseFrom && (EveningWatch.change(input.glucose, minutes: 15) ?? -1) >= 0 } ?? false
        if comingUp || now.timeIntervalSince(action.date) >= Rule.lifetime {
            state.actions[index].state = .lapsed
            state.actions[index].closedAt = now
        }
    }

    private static func close(_ state: inout LowWatchState, as closed: LowWatchAction.State, now: Date) {
        for index in state.actions.indices where state.actions[index].state == .open {
            state.actions[index].state = closed
            state.actions[index].closedAt = now
        }
    }

    static func isNight(_ date: Date, calendar: Calendar = .current) -> Bool {
        EveningWatch.contains(EveningWatch.minutes(date, calendar: calendar), from: Rule.nightFrom, to: Rule.nightUntil)
    }
}
