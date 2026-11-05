//
//  EveningWatch.swift
//  Loop
//
//  The evening watch («Kveldsvakt»). In the evening, when glucose keeps rising or stays high and
//  nothing has been given or eaten for a while, it suggests a correction — or, in automatic mode,
//  gives it — and then keeps watching for the rest of the window.
//
//  It looks at glucose itself and not at Loop's forecast for the dose. On Walter's evenings Loop
//  expects the insulin on board to bring glucose down much further than it does, gives nothing
//  and holds basal at zero, and he stays over 10 for hours. What helped was a small correction
//  by hand: 0.35–0.5 U around 20, 22 and midnight on 30 October 2026, none followed by a low.
//
//  The rules come from 45 evenings of Nightscout history (September–October 2026). With nothing
//  given, glucose before 23:00 that had risen at least 0.8 over half an hour went under 7 in
//  5 % of cases within three hours; after 23:00 it fell by itself much more often (16–22 %), so
//  the limits are 1 mmol/L higher then and the dose smaller. Just over the limit the dose is
//  smaller too: from 9–10 glucose went under 7 by itself in a third of cases.
//
//  The dose learns from what happened in the three hours after each one that was given: smaller
//  after a low, larger when glucose was still high two hours on. A low under 4 within four hours
//  of an automatic dose turns automatic mode off (it goes back to suggesting) until it is turned
//  on again by hand.
//
//  Glucose is in mmol/L throughout.
//

import Foundation

struct EveningWatchSettings: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case off
        /// Suggests on the phone and in LoopFollow; a person gives it.
        case suggest
        /// Gives the dose itself.
        case automatic
    }

    var mode: Mode = .off
    /// Minutes after midnight. The window may run past midnight.
    var start = 19 * 60
    var end = 60
    /// Rising: glucose at or above this and up over 15 and 30 minutes.
    var risingFrom = 9.0
    /// High: every reading for half an hour near this, and not falling.
    var highFrom = 11.0
    /// From this time until 06:00 both limits are `Rule.lateRaise` higher and the dose smaller.
    var lateFrom = 23 * 60
    /// The dose at 12 mmol/L before anything is learned.
    var startUnits = 0.5
    /// Nothing with this much insulin on board or more.
    var maximumIOB = 1.6
    /// All doses in one evening together.
    var maximumPerEvening = 1.2
    var dosesPerEvening = 3
    /// Between two suggestions or doses.
    var minutesBetween = 75

    static let risingRange = 8.0 ... 13.0
    static let highRange = 9.0 ... 16.0
    static let startUnitsRange = 0.1 ... 0.8
    static let maximumIOBRange = 0.3 ... 2.0
    static let maximumPerEveningRange = 0.1 ... 2.0
    static let dosesPerEveningRange = 1 ... 4
    static let minutesBetweenRange = 60 ... 180

    init() {}

    /// Within the ranges, whatever was stored or sent.
    var clamped: EveningWatchSettings {
        var settings = self
        settings.start = Self.clamp(start, 0 ... 1439)
        settings.end = Self.clamp(end, 0 ... 1439)
        settings.lateFrom = Self.clamp(lateFrom, 0 ... 1439)
        settings.risingFrom = Self.clamp(risingFrom, Self.risingRange)
        settings.highFrom = Self.clamp(highFrom, Self.highRange)
        settings.startUnits = Self.clamp(startUnits, Self.startUnitsRange)
        settings.maximumIOB = Self.clamp(maximumIOB, Self.maximumIOBRange)
        settings.maximumPerEvening = Self.clamp(maximumPerEvening, Self.maximumPerEveningRange)
        settings.dosesPerEvening = Self.clamp(dosesPerEvening, Self.dosesPerEveningRange)
        settings.minutesBetween = Self.clamp(minutesBetween, Self.minutesBetweenRange)
        return settings
    }

    private static func clamp<T: Comparable>(_ value: T, _ range: ClosedRange<T>) -> T {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // Missing keys keep their defaults, so settings stored by an older build still load.
    private enum CodingKeys: String, CodingKey {
        case mode, start, end, risingFrom, highFrom, lateFrom, startUnits, maximumIOB, maximumPerEvening, dosesPerEvening, minutesBetween
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EveningWatchSettings()
        mode = (try? container.decodeIfPresent(Mode.self, forKey: .mode)) ?? defaults.mode
        start = try container.decodeIfPresent(Int.self, forKey: .start) ?? defaults.start
        end = try container.decodeIfPresent(Int.self, forKey: .end) ?? defaults.end
        risingFrom = try container.decodeIfPresent(Double.self, forKey: .risingFrom) ?? defaults.risingFrom
        highFrom = try container.decodeIfPresent(Double.self, forKey: .highFrom) ?? defaults.highFrom
        lateFrom = try container.decodeIfPresent(Int.self, forKey: .lateFrom) ?? defaults.lateFrom
        startUnits = try container.decodeIfPresent(Double.self, forKey: .startUnits) ?? defaults.startUnits
        maximumIOB = try container.decodeIfPresent(Double.self, forKey: .maximumIOB) ?? defaults.maximumIOB
        maximumPerEvening = try container.decodeIfPresent(Double.self, forKey: .maximumPerEvening) ?? defaults.maximumPerEvening
        dosesPerEvening = try container.decodeIfPresent(Int.self, forKey: .dosesPerEvening) ?? defaults.dosesPerEvening
        minutesBetween = try container.decodeIfPresent(Int.self, forKey: .minutesBetween) ?? defaults.minutesBetween
    }
}

/// A suggestion or an automatic dose.
struct EveningWatchAction: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case suggestion
        case automatic
    }

    enum Trigger: String, Codable {
        case rising
        case high
    }

    enum State: String, Codable {
        /// A suggestion waiting for an answer.
        case open
        /// An automatic dose sent to the pump.
        case delivering
        case given
        case declined
        /// Glucose came down, fell or went low before the suggestion was answered.
        case lapsed
        /// The pump did not take the automatic dose.
        case failed
    }

    struct Outcome: Codable, Equatable {
        /// Nil when too few readings were seen to judge it.
        var lowest: Double?
        var after2h: Double?
        var unitsBefore: Double
        var unitsAfter: Double
    }

    var id = UUID().uuidString
    var kind: Kind
    var trigger: Trigger
    var date: Date
    var glucose: Double
    var change15: Double?
    var change30: Double?
    var iob: Double?
    var units: Double
    /// What the learned dose was scaled by.
    var scale: Double
    var state: State
    var closedAt: Date?
    var givenUnits: Double?
    var outcome: Outcome?

    /// Whether it takes one of the evening's doses: a lapsed or failed one does not.
    var counts: Bool { state != .lapsed && state != .failed }
}

/// What one look found, for the log.
struct EveningWatchDecision: Codable, Equatable {
    enum Kind: String, Codable {
        case noFreshGlucose, missingReadings, jump, belowLimit, notRising, falling, recentLow, recentCarbs, recentBolus
        case recentAction, enoughTonight, noInsulinOnBoard, highIOB, forecastLow, reducedInsulin, cannotDose, tooSmall
        case suggested, dosed, open, lapsed, stopped
    }

    /// The reading looked at.
    var date: Date
    var glucose: Double?
    var kind: Kind
    /// When a wait ends.
    var until: Date?
    /// Units for a suggestion or dose, the change for `falling`, insulin on board for `highIOB`,
    /// the forecast for `forecastLow`, the lowest reading for `stopped`.
    var value: Double?
}

struct EveningWatchState: Codable, Equatable {
    /// The dose at 12 mmol/L before the late scaling, once something has been learned.
    var learnedUnits: Double?
    var actions: [EveningWatchAction] = []
    var decisions: [EveningWatchDecision] = []
    /// Automatic mode turned itself off after a low.
    var stop: Stop?

    struct Stop: Codable, Equatable {
        var date: Date
        var lowest: Double
        var actionID: String
    }

    var open: EveningWatchAction? {
        actions.last { $0.state == .open }
    }
}

enum EveningWatch {
    struct Reading: Codable, Equatable {
        var date: Date
        var mmol: Double
    }

    struct Dose: Codable, Equatable {
        var date: Date
        var units: Double
    }

    struct Carbs: Codable, Equatable {
        var date: Date
        var grams: Double
    }

    struct Input: Equatable {
        /// Oldest first, at least the last four and a half hours.
        var glucose: [Reading]
        /// Boluses given by hand, remotely or by the evening watch; not Loop's automatic ones.
        var manualBoluses: [Dose]
        /// Including entries dated ahead.
        var carbs: [Carbs]
        var iob: Double?
        /// The lowest Loop forecasts within three hours.
        var lowestForecast: Double?
        var maximumBolus: Double?
        /// Closed loop on, pump not suspended and no bolus running.
        var canDose: Bool
        /// An override that lowers insulin needs (activity) is on.
        var reducedInsulin: Bool
    }

    /// The fixed rules.
    enum Rule {
        static let freshGlucose: TimeInterval = 6 * 60
        static let rise15 = 0.3
        static let rise30 = 0.8
        /// A high counts when every reading for `highFor` is at most this under the limit.
        static let highMargin = 1.0
        static let highFor: TimeInterval = 30 * 60
        static let highFalling15 = -0.2
        /// A jump this size between two readings looks like the sensor, not glucose.
        static let jump = 1.5
        /// Nothing when a reading under this was seen within `lowLookback`.
        static let lowFloor = 6.0
        static let lowLookback: TimeInterval = 90 * 60
        /// A meal has this long to show what it does; one entered ahead counts from this before.
        static let carbGap: TimeInterval = 90 * 60
        /// Less than this — the evening milk or a yoghurt, given with its own bolus — has only
        /// `smallCarbGap`. With 90 minutes, milk at 19:15 held the watch back until after Julia had
        /// already given the first correction by hand on every evening from 28 October to 4 November.
        static let smallCarbs = 15.0
        static let smallCarbGap: TimeInterval = 45 * 60
        static let carbAhead: TimeInterval = 60 * 60
        static let minimumCarbs = 3.0
        /// A dose given by hand has this long.
        static let bolusGap: TimeInterval = 45 * 60
        static let minimumBolus = 0.1
        /// Loop expects a low.
        static let forecastFloor = 3.9
        /// Late, both limits are this much higher and the dose is scaled by `lateScale`.
        static let lateRaise = 1.0
        static let lateScale = 0.6
        static let lateUntil = 6 * 60
        /// The dose by glucose: this share under 10, `middleScale` under 12, all from 12.
        static let lowScale = 0.5
        static let middleScale = 0.7
        static let maximumUnits = 0.8
        static let minimumUnits = 0.1
        static let learnedRange = 0.25 ... 0.8
        /// An open suggestion lapses this far under the rising limit, when glucose falls this fast
        /// over 15 minutes, after a reading under `lowFloor`, or after `lifetime`.
        static let lapseMargin = 1.0
        static let lapseFalling15 = -0.5
        static let lifetime: TimeInterval = 3 * 3600
        /// A dose is judged on the three hours after it.
        static let outcomeAfter: TimeInterval = 3 * 3600
        /// A reading under this within `stopWithin` of an automatic dose turns automatic mode off.
        static let stopBelow = 4.0
        static let stopWithin: TimeInterval = 4 * 3600
        /// A dose still marked as delivering after this is settled from the pump's record.
        static let deliveringFor: TimeInterval = 10 * 60
    }

    enum Effect: Equatable {
        case none
        case suggest(EveningWatchAction)
        case dose(EveningWatchAction)
        /// Automatic mode must turn off.
        case stop
    }

    // MARK: - One look

    /// Settles earlier actions, learns from them, then decides on the latest reading.
    static func tick(_ state: EveningWatchState, input: Input, settings: EveningWatchSettings, now: Date, calendar: Calendar = .current) -> (state: EveningWatchState, effect: Effect) {
        var state = state
        prune(&state, now: now)
        settle(&state, input: input, now: now)
        learn(&state, input: input, settings: settings, now: now)

        if settings.mode == .automatic, let stop = lowAfterAutomatic(state, input: input, now: now) {
            state.stop = stop
            record(&state, EveningWatchDecision(date: input.glucose.last?.date ?? now, glucose: input.glucose.last?.mmol, kind: .stopped, value: stop.lowest))
            return (state, .stop)
        }

        guard settings.mode != .off, isInWindow(now, settings: settings, calendar: calendar) || state.open != nil else {
            lapseOpen(&state, now: now)
            return (state, .none)
        }

        guard let latest = input.glucose.last, now.timeIntervalSince(latest.date) <= Rule.freshGlucose else {
            record(&state, EveningWatchDecision(date: input.glucose.last?.date ?? now, kind: .noFreshGlucose))
            return (state, .none)
        }

        if let index = state.actions.lastIndex(where: { $0.state == .open }) {
            if settings.mode != .suggest || shouldLapse(state.actions[index], input: input, settings: settings, now: now, calendar: calendar) {
                state.actions[index].state = .lapsed
                state.actions[index].closedAt = now
                record(&state, EveningWatchDecision(date: latest.date, glucose: latest.mmol, kind: .lapsed))
            } else {
                record(&state, EveningWatchDecision(date: latest.date, glucose: latest.mmol, kind: .open, value: state.actions[index].units))
                return (state, .none)
            }
        }

        guard isInWindow(now, settings: settings, calendar: calendar) else { return (state, .none) }

        let decision = decide(state, input: input, settings: settings, now: now, calendar: calendar)
        record(&state, decision.decision)
        guard let action = decision.action else { return (state, .none) }
        state.actions.append(action)
        return (state, action.kind == .automatic ? .dose(action) : .suggest(action))
    }

    /// Whether this reading calls for a suggestion or a dose, and if not, why not.
    static func decide(_ state: EveningWatchState, input: Input, settings: EveningWatchSettings, now: Date, calendar: Calendar = .current) -> (decision: EveningWatchDecision, action: EveningWatchAction?) {
        guard let latest = input.glucose.last else { return (EveningWatchDecision(date: now, kind: .noFreshGlucose), nil) }
        let glucose = latest.mmol
        func no(_ kind: EveningWatchDecision.Kind, until: Date? = nil, value: Double? = nil) -> (EveningWatchDecision, EveningWatchAction?) {
            (EveningWatchDecision(date: latest.date, glucose: glucose, kind: kind, until: until, value: value), nil)
        }

        guard let before5 = reading(near: latest.date.addingTimeInterval(-5 * 60), in: input.glucose),
              let change15 = change(input.glucose, minutes: 15),
              let change30 = change(input.glucose, minutes: 30)
        else { return no(.missingReadings) }
        if abs(glucose - before5.mmol) > Rule.jump { return no(.jump) }

        let late = isLate(now, settings: settings, calendar: calendar)
        let risingLimit = settings.risingFrom + (late ? Rule.lateRaise : 0)
        let highLimit = settings.highFrom + (late ? Rule.lateRaise : 0)
        let rising = glucose >= risingLimit && change15 >= Rule.rise15 && change30 >= Rule.rise30 && glucose >= before5.mmol
        let high = glucose >= highLimit && change15 >= Rule.highFalling15 && isHigh(input.glucose, latest: latest, limit: highLimit)
        guard rising || high else {
            if glucose < min(risingLimit, highLimit) { return no(.belowLimit) }
            if change15 < Rule.highFalling15 { return no(.falling, value: change15) }
            return no(.notRising, value: change30)
        }

        if input.glucose.contains(where: { latest.date.timeIntervalSince($0.date) <= Rule.lowLookback && $0.mmol < Rule.lowFloor }) {
            return no(.recentLow)
        }
        let carbsWait = input.carbs
            .filter { $0.grams >= Rule.minimumCarbs && $0.date <= now.addingTimeInterval(Rule.carbAhead) }
            .map { $0.date.addingTimeInterval(carbGap(grams: $0.grams)) }
            .filter { $0 > now }
            .max()
        if let carbsWait {
            return no(.recentCarbs, until: carbsWait)
        }
        if let bolus = input.manualBoluses.last(where: { $0.units >= Rule.minimumBolus && $0.date <= now && now.timeIntervalSince($0.date) < Rule.bolusGap }) {
            return no(.recentBolus, until: bolus.date.addingTimeInterval(Rule.bolusGap))
        }
        let gap = TimeInterval(settings.minutesBetween * 60)
        if let last = state.actions.last, now.timeIntervalSince(last.date) < gap {
            return no(.recentAction, until: last.date.addingTimeInterval(gap))
        }
        let tonight = state.actions.filter { $0.counts && $0.date >= windowStart(before: now, settings: settings, calendar: calendar) }
        let unitsTonight = tonight.reduce(0) { $0 + ($1.givenUnits ?? ($1.state == .declined ? 0 : $1.units)) }
        if tonight.count >= settings.dosesPerEvening || unitsTonight >= settings.maximumPerEvening - 0.049 {
            return no(.enoughTonight)
        }
        guard let iob = input.iob else { return no(.noInsulinOnBoard) }
        if iob >= settings.maximumIOB { return no(.highIOB, value: iob) }
        if let forecast = input.lowestForecast, forecast < Rule.forecastFloor { return no(.forecastLow, value: forecast) }
        if input.reducedInsulin { return no(.reducedInsulin) }
        let automatic = settings.mode == .automatic
        if automatic, !input.canDose { return no(.cannotDose) }

        let scale = self.scale(glucose: glucose, late: late)
        var units = (state.learnedUnits ?? settings.startUnits) * scale
        units = min(units, Rule.maximumUnits, settings.maximumPerEvening - unitsTonight)
        if let maximumBolus = input.maximumBolus, maximumBolus > 0 { units = min(units, maximumBolus) }
        units = ((units * 20) + 1e-9).rounded(.down) / 20
        guard units >= Rule.minimumUnits else { return no(.tooSmall, value: units) }

        let action = EveningWatchAction(
            kind: automatic ? .automatic : .suggestion,
            trigger: rising ? .rising : .high,
            date: now,
            glucose: glucose,
            change15: change15,
            change30: change30,
            iob: iob,
            units: units,
            scale: scale,
            state: automatic ? .delivering : .open
        )
        return (EveningWatchDecision(date: latest.date, glucose: glucose, kind: automatic ? .dosed : .suggested, value: units), action)
    }

    /// How long carbs hold the watch back.
    static func carbGap(grams: Double) -> TimeInterval {
        grams < Rule.smallCarbs ? Rule.smallCarbGap : Rule.carbGap
    }

    // MARK: - Dose

    static func scale(glucose: Double, late: Bool) -> Double {
        let byGlucose = glucose < 10 ? Rule.lowScale : glucose < 12 ? Rule.middleScale : 1
        return byGlucose * (late ? Rule.lateScale : 1)
    }

    /// How a given dose changes the learned dose: smaller after a low, larger when glucose was
    /// still high two hours on, otherwise unchanged.
    static func learnedUnits(before: Double, given: Double, scale: Double, lowest: Double, after2h: Double?) -> Double {
        let base = scale > 0 ? given / scale : given
        let units: Double
        if lowest < 4 {
            units = min(before, base) * 0.6
        } else if lowest < 5 {
            units = min(before, base) * 0.8
        } else if let after2h, after2h >= 12, lowest >= 7 {
            units = before * 1.1
        } else {
            return before
        }
        return min(max(units, Rule.learnedRange.lowerBound), Rule.learnedRange.upperBound)
    }

    // MARK: - Steps

    private static func prune(_ state: inout EveningWatchState, now: Date) {
        state.actions.removeAll { now.timeIntervalSince($0.date) > 21 * 24 * 3600 }
        state.decisions.removeAll { now.timeIntervalSince($0.date) > 72 * 3600 }
    }

    /// A bolus after an open suggestion makes it given; an automatic dose left delivering is
    /// settled from the pump's record.
    private static func settle(_ state: inout EveningWatchState, input: Input, now: Date) {
        for index in state.actions.indices {
            let action = state.actions[index]
            switch action.state {
            case .open:
                if let bolus = input.manualBoluses.first(where: { $0.date >= action.date.addingTimeInterval(-60) && $0.units >= 0.05 }) {
                    state.actions[index].state = .given
                    state.actions[index].givenUnits = bolus.units
                    state.actions[index].closedAt = bolus.date
                }
            case .delivering where now.timeIntervalSince(action.date) >= Rule.deliveringFor:
                if let bolus = input.manualBoluses.first(where: { abs($0.date.timeIntervalSince(action.date)) <= 5 * 60 && $0.units >= 0.05 }) {
                    state.actions[index].state = .given
                    state.actions[index].givenUnits = bolus.units
                    state.actions[index].closedAt = bolus.date
                } else {
                    state.actions[index].state = .failed
                    state.actions[index].closedAt = now
                }
            default:
                break
            }
        }
    }

    private static func learn(_ state: inout EveningWatchState, input: Input, settings: EveningWatchSettings, now: Date) {
        for index in state.actions.indices {
            let action = state.actions[index]
            guard action.state == .given, action.outcome == nil, let givenAt = action.closedAt,
                  now.timeIntervalSince(givenAt) >= Rule.outcomeAfter
            else { continue }
            let before = state.learnedUnits ?? settings.startUnits
            let readings = input.glucose.filter { $0.date >= givenAt && $0.date <= givenAt.addingTimeInterval(Rule.outcomeAfter) }
            // Two of the three hours, or it is not judged.
            guard readings.count >= 24, let lowest = readings.map(\.mmol).min() else {
                state.actions[index].outcome = .init(lowest: nil, after2h: nil, unitsBefore: before, unitsAfter: before)
                continue
            }
            let after2h = reading(near: givenAt.addingTimeInterval(2 * 3600), in: input.glucose)?.mmol
            let after = learnedUnits(before: before, given: action.givenUnits ?? action.units, scale: action.scale, lowest: lowest, after2h: after2h)
            state.actions[index].outcome = .init(lowest: lowest, after2h: after2h, unitsBefore: before, unitsAfter: after)
            if after != before { state.learnedUnits = after }
        }
    }

    /// A reading under `Rule.stopBelow` within four hours of an automatic dose given after the
    /// last stop.
    static func lowAfterAutomatic(_ state: EveningWatchState, input: Input, now: Date) -> EveningWatchState.Stop? {
        for action in state.actions.reversed() where action.kind == .automatic && action.state == .given {
            guard let givenAt = action.closedAt, now.timeIntervalSince(givenAt) <= Rule.stopWithin + Rule.outcomeAfter else { continue }
            if let stop = state.stop, stop.actionID == action.id || stop.date >= givenAt { continue }
            let readings = input.glucose.filter { $0.date >= givenAt && $0.date <= givenAt.addingTimeInterval(Rule.stopWithin) }
            if let lowest = readings.map(\.mmol).min(), lowest < Rule.stopBelow {
                return EveningWatchState.Stop(date: now, lowest: lowest, actionID: action.id)
            }
        }
        return nil
    }

    private static func shouldLapse(_ action: EveningWatchAction, input: Input, settings: EveningWatchSettings, now: Date, calendar: Calendar) -> Bool {
        guard let latest = input.glucose.last else { return false }
        if now.timeIntervalSince(action.date) >= Rule.lifetime { return true }
        let limit = settings.risingFrom + (isLate(now, settings: settings, calendar: calendar) ? Rule.lateRaise : 0)
        if latest.mmol < limit - Rule.lapseMargin { return true }
        if let change15 = change(input.glucose, minutes: 15), change15 < Rule.lapseFalling15 { return true }
        return input.glucose.contains { $0.date >= action.date && $0.mmol < Rule.lowFloor }
    }

    private static func lapseOpen(_ state: inout EveningWatchState, now: Date) {
        for index in state.actions.indices where state.actions[index].state == .open {
            state.actions[index].state = .lapsed
            state.actions[index].closedAt = now
        }
    }

    /// One entry per reading: a repeat of the same finding for the same reading is left out.
    private static func record(_ state: inout EveningWatchState, _ decision: EveningWatchDecision) {
        if let last = state.decisions.last, last.date == decision.date, last.kind == decision.kind { return }
        state.decisions.append(decision)
    }

    // MARK: - Glucose

    static func reading(near date: Date, in glucose: [Reading]) -> Reading? {
        glucose
            .filter { abs($0.date.timeIntervalSince(date)) <= 150 }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    /// The change from the reading `minutes` before the latest; nil without one.
    static func change(_ glucose: [Reading], minutes: Int) -> Double? {
        guard let latest = glucose.last,
              let earlier = reading(near: latest.date.addingTimeInterval(-Double(minutes) * 60), in: glucose)
        else { return nil }
        return ((latest.mmol - earlier.mmol) * 10).rounded() / 10
    }

    /// Every reading over the last half hour, with no gap over 11 minutes, near the limit.
    static func isHigh(_ glucose: [Reading], latest: Reading, limit: Double) -> Bool {
        let since = latest.date.addingTimeInterval(-Rule.highFor)
        let run = glucose.filter { $0.date >= since.addingTimeInterval(-60) && $0.date <= latest.date }
        guard let first = run.first, first.date <= since.addingTimeInterval(4 * 60) else { return false }
        for (earlier, later) in zip(run, run.dropFirst()) where later.date.timeIntervalSince(earlier.date) > 11 * 60 {
            return false
        }
        return run.allSatisfy { $0.mmol >= limit - Rule.highMargin }
    }

    // MARK: - Window

    static func minutes(_ date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func contains(_ minute: Int, from start: Int, to end: Int) -> Bool {
        if start == end { return true }
        if start < end { return minute >= start && minute < end }
        return minute >= start || minute < end
    }

    static func isInWindow(_ date: Date, settings: EveningWatchSettings, calendar: Calendar = .current) -> Bool {
        contains(minutes(date, calendar: calendar), from: settings.start, to: settings.end)
    }

    static func isLate(_ date: Date, settings: EveningWatchSettings, calendar: Calendar = .current) -> Bool {
        settings.lateFrom != Rule.lateUntil && contains(minutes(date, calendar: calendar), from: settings.lateFrom, to: Rule.lateUntil)
    }

    /// The start of the window `date` is in, or of the last one before it.
    static func windowStart(before date: Date, settings: EveningWatchSettings, calendar: Calendar = .current) -> Date {
        let startToday = calendar.date(bySettingHour: settings.start / 60, minute: settings.start % 60, second: 0, of: date) ?? date
        if startToday <= date { return startToday }
        return calendar.date(byAdding: .day, value: -1, to: startToday) ?? startToday
    }

    /// The end of the window that started at or before `date`.
    static func windowEnd(after date: Date, settings: EveningWatchSettings, calendar: Calendar = .current) -> Date {
        let start = windowStart(before: date, settings: settings, calendar: calendar)
        let endSameDay = calendar.date(bySettingHour: settings.end / 60, minute: settings.end % 60, second: 0, of: start) ?? start
        if endSameDay > start { return endSameDay }
        return calendar.date(byAdding: .day, value: 1, to: endSameDay) ?? endSameDay
    }
}
