//
//  EveningWatchTests.swift
//  LoopTests
//
//  When the evening watch suggests or gives a dose, how large, and what stops it.
//

import XCTest
@testable import Loop

final class EveningWatchTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        return calendar
    }()

    /// 30 October 2026 at this hour and minute in Oslo (the next day before 06:00).
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        let day = DateComponents(calendar: calendar, year: 2026, month: 10, day: hour < 6 ? 31 : 30, hour: hour, minute: minute)
        return calendar.date(from: day)!
    }

    private func settings(_ mode: EveningWatchSettings.Mode = .automatic) -> EveningWatchSettings {
        var settings = EveningWatchSettings()
        settings.mode = mode
        return settings
    }

    /// Readings every 5 minutes up to `now`, the last one equal to the last value given.
    private func readings(_ values: [Double], until now: Date) -> [EveningWatch.Reading] {
        values.enumerated().map { index, mmol in
            EveningWatch.Reading(date: now.addingTimeInterval(-Double(values.count - 1 - index) * 300), mmol: mmol)
        }
    }

    private func input(_ glucose: [EveningWatch.Reading], boluses: [EveningWatch.Dose] = [], carbs: [EveningWatch.Carbs] = [], iob: Double? = 0.3, forecast: Double? = 6.5, canDose: Bool = true, reducedInsulin: Bool = false) -> EveningWatch.Input {
        EveningWatch.Input(glucose: glucose, manualBoluses: boluses, carbs: carbs, iob: iob, lowestForecast: forecast, maximumBolus: 2, canDose: canDose, reducedInsulin: reducedInsulin)
    }

    /// Flat at 7 for a while, then up to the last values.
    private let rising: [Double] = [7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8.2, 8.4, 8.6, 8.8, 9.0, 9.3]
    private let rising11: [Double] = [9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9.9, 10.1, 10.4, 10.6, 10.9, 11.2]
    private let high: [Double] = [9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 12.4, 12.5, 12.6, 12.5, 12.4, 12.5, 12.6, 12.5]

    private func decide(_ values: [Double], at now: Date, state: EveningWatchState = EveningWatchState(), settings: EveningWatchSettings? = nil, boluses: [EveningWatch.Dose] = [], carbs: [EveningWatch.Carbs] = [], iob: Double? = 0.3, forecast: Double? = 6.5, canDose: Bool = true, reducedInsulin: Bool = false) -> (decision: EveningWatchDecision, action: EveningWatchAction?) {
        EveningWatch.decide(state, input: input(readings(values, until: now), boluses: boluses, carbs: carbs, iob: iob, forecast: forecast, canDose: canDose, reducedInsulin: reducedInsulin), settings: settings ?? self.settings(), now: now, calendar: calendar)
    }

    // MARK: - Window

    func testWindowRunsPastMidnightAndLateStartsAt23() {
        let settings = settings()
        XCTAssertFalse(EveningWatch.isInWindow(at(20, 29), settings: settings, calendar: calendar))
        XCTAssertTrue(EveningWatch.isInWindow(at(20, 30), settings: settings, calendar: calendar))
        XCTAssertTrue(EveningWatch.isInWindow(at(0, 59), settings: settings, calendar: calendar))
        XCTAssertFalse(EveningWatch.isInWindow(at(1, 0), settings: settings, calendar: calendar))
        XCTAssertFalse(EveningWatch.isLate(at(22, 59), settings: settings, calendar: calendar))
        XCTAssertTrue(EveningWatch.isLate(at(23, 0), settings: settings, calendar: calendar))
        XCTAssertTrue(EveningWatch.isLate(at(0, 30), settings: settings, calendar: calendar))
        XCTAssertEqual(EveningWatch.windowStart(before: at(0, 30), settings: settings, calendar: calendar), at(20, 30))
    }

    // MARK: - Dose

    func testRisingJustOverTheLimitGivesHalfTheDose() {
        let result = decide(rising, at: at(21, 30))
        XCTAssertEqual(result.decision.kind, .dosed)
        XCTAssertEqual(result.action?.trigger, .rising)
        XCTAssertEqual(result.action?.units, 0.25)
        XCTAssertEqual(result.action?.state, .delivering)
    }

    func testSuggestModeSuggestsInstead() {
        let result = decide(rising, at: at(21, 30), settings: settings(.suggest))
        XCTAssertEqual(result.decision.kind, .suggested)
        XCTAssertEqual(result.action?.kind, .suggestion)
        XCTAssertEqual(result.action?.state, .open)
    }

    func testHighAndFlatGivesTheWholeDose() {
        let result = decide(high, at: at(21, 30))
        XCTAssertEqual(result.action?.trigger, .high)
        XCTAssertEqual(result.action?.units, 0.5)
    }

    func testLateLimitsAreHigherAndTheDoseSmaller() {
        XCTAssertEqual(decide(rising, at: at(23, 30)).decision.kind, .belowLimit)
        let late = decide(rising11, at: at(23, 30))
        // 0.5 × 0.7 under 12 × 0.6 late = 0.21, rounded down to the pod's 0.05.
        XCTAssertEqual(late.action?.units, 0.2)
    }

    func testFlatJustOverTheRisingLimitIsNotEnough() {
        let flat = [Double](repeating: 9.4, count: 24)
        XCTAssertEqual(decide(flat, at: at(21, 30)).decision.kind, .notRising)
    }

    func testLearnedDoseIsUsedAndCapped() {
        var state = EveningWatchState()
        state.learnedUnits = 0.8
        XCTAssertEqual(decide(high, at: at(21, 30), state: state).action?.units, 0.8)

        var settings = settings()
        settings.maximumPerEvening = 1.0
        state.actions = [action(at: at(20, 40), units: 0.7, state: .given)]
        XCTAssertEqual(decide(high, at: at(22, 30), state: state, settings: settings).action?.units, 0.3)
    }

    // MARK: - What stops it

    func testNothingAfterARecentLow() {
        var values = rising
        values[10] = 5.8
        XCTAssertEqual(decide(values, at: at(21, 30)).decision.kind, .recentLow)
    }

    func testNothingAfterOrBeforeAMeal() {
        XCTAssertEqual(decide(rising, at: at(21, 30), carbs: [.init(date: at(20, 30), grams: 10)]).decision.kind, .recentCarbs)
        XCTAssertEqual(decide(rising, at: at(21, 30), carbs: [.init(date: at(22, 15), grams: 10)]).decision.kind, .recentCarbs)
        XCTAssertEqual(decide(rising, at: at(21, 30), carbs: [.init(date: at(21, 0), grams: 2)]).decision.kind, .dosed)
    }

    func testNothingRightAfterADoseByHand() {
        XCTAssertEqual(decide(rising, at: at(21, 30), boluses: [.init(date: at(20, 45), units: 0.35)]).decision.kind, .recentBolus)
        XCTAssertEqual(decide(rising, at: at(21, 30), boluses: [.init(date: at(20, 25), units: 0.35)]).decision.kind, .dosed)
    }

    func testInsulinOnBoardForecastOverrideAndPump() {
        XCTAssertEqual(decide(rising, at: at(21, 30), iob: 1.0).decision.kind, .highIOB)
        XCTAssertEqual(decide(rising, at: at(21, 30), iob: nil).decision.kind, .noInsulinOnBoard)
        XCTAssertEqual(decide(rising, at: at(21, 30), forecast: 3.8).decision.kind, .forecastLow)
        XCTAssertEqual(decide(rising, at: at(21, 30), reducedInsulin: true).decision.kind, .reducedInsulin)
        XCTAssertEqual(decide(rising, at: at(21, 30), canDose: false).decision.kind, .cannotDose)
        XCTAssertEqual(decide(rising, at: at(21, 30), settings: settings(.suggest), canDose: false).decision.kind, .suggested)
    }

    func testSensorJumpAndMissingReadings() {
        var jump = rising
        jump[jump.count - 1] = 11
        XCTAssertEqual(decide(jump, at: at(21, 30)).decision.kind, .jump)
        let now = at(21, 30)
        let gap = readings(rising, until: now).filter { $0.date != now.addingTimeInterval(-15 * 60) }
        XCTAssertEqual(EveningWatch.decide(EveningWatchState(), input: input(gap), settings: settings(), now: now, calendar: calendar).decision.kind, .missingReadings)
    }

    func testWaitsBetweenAndStopsForTheNight() {
        var state = EveningWatchState()
        state.actions = [action(at: at(21, 0), units: 0.25, state: .given)]
        XCTAssertEqual(decide(rising, at: at(21, 30), state: state).decision.kind, .recentAction)
        XCTAssertEqual(decide(rising, at: at(22, 15), state: state).decision.kind, .dosed)

        state.actions = [action(at: at(20, 35), units: 0.25, state: .given), action(at: at(21, 50), units: 0.25, state: .given), action(at: at(23, 5), units: 0.25, state: .declined)]
        XCTAssertEqual(decide(high, at: at(0, 30), state: state).decision.kind, .enoughTonight)
    }

    // MARK: - Ticks

    func testSuggestionStaysUntilAnsweredAndLapsesWhenGlucoseComesDown() {
        var state = EveningWatchState()
        let settings = settings(.suggest)
        var now = at(21, 30)
        var glucose = readings(rising, until: now)
        var result = EveningWatch.tick(state, input: input(glucose), settings: settings, now: now, calendar: calendar)
        guard case .suggest(let suggestion) = result.effect else { return XCTFail("no suggestion") }
        state = result.state

        // An hour on, still waiting: it does not lapse by time.
        for _ in 0 ..< 12 {
            now = now.addingTimeInterval(300)
            glucose.append(.init(date: now, mmol: 9.4))
            result = EveningWatch.tick(state, input: input(glucose), settings: settings, now: now, calendar: calendar)
            state = result.state
            XCTAssertEqual(result.effect, .none)
        }
        XCTAssertEqual(state.open?.id, suggestion.id)

        for mmol in [8.6, 8.2, 7.9] {
            now = now.addingTimeInterval(300)
            glucose.append(.init(date: now, mmol: mmol))
            state = EveningWatch.tick(state, input: input(glucose), settings: settings, now: now, calendar: calendar).state
        }
        XCTAssertNil(state.open)
        XCTAssertEqual(state.actions.last?.state, .lapsed)
    }

    func testABolusAfterTheSuggestionGivesIt() {
        var state = EveningWatchState()
        state.actions = [action(at: at(21, 30), units: 0.25, state: .open, kind: .suggestion)]
        let now = at(21, 40)
        let result = EveningWatch.tick(state, input: input(readings(rising + [9.4, 9.5], until: now), boluses: [.init(date: at(21, 36), units: 0.3)]), settings: settings(.suggest), now: now, calendar: calendar)
        XCTAssertEqual(result.state.actions.first?.state, .given)
        XCTAssertEqual(result.state.actions.first?.givenUnits, 0.3)
    }

    func testALowAfterAnAutomaticDoseStopsAutomaticOnce() {
        var state = EveningWatchState()
        var given = action(at: at(22, 0), units: 0.25, state: .given)
        given.closedAt = at(22, 0)
        state.actions = [given]
        let now = at(0, 30)
        var glucose = readings([Double](repeating: 6, count: 30), until: now)
        glucose[glucose.count - 3].mmol = 3.8
        let result = EveningWatch.tick(state, input: input(glucose), settings: settings(), now: now, calendar: calendar)
        XCTAssertEqual(result.effect, .stop)
        XCTAssertEqual(result.state.stop?.lowest, 3.8)
        XCTAssertEqual(result.state.stop?.actionID, given.id)

        // Turned on again: the same low does not stop it again.
        let again = EveningWatch.tick(result.state, input: input(glucose), settings: settings(), now: now.addingTimeInterval(300), calendar: calendar)
        XCTAssertNotEqual(again.effect, .stop)
    }

    func testLearnsFromWhatFollowed() {
        XCTAssertEqual(EveningWatch.learnedUnits(before: 0.5, given: 0.25, scale: 0.5, lowest: 4.5, after2h: 6), 0.4, accuracy: 1e-9)
        XCTAssertEqual(EveningWatch.learnedUnits(before: 0.5, given: 0.25, scale: 0.5, lowest: 3.5, after2h: 5), 0.3, accuracy: 1e-9)
        XCTAssertEqual(EveningWatch.learnedUnits(before: 0.5, given: 0.5, scale: 1, lowest: 8, after2h: 13), 0.55, accuracy: 1e-9)
        XCTAssertEqual(EveningWatch.learnedUnits(before: 0.5, given: 0.5, scale: 1, lowest: 7, after2h: 9), 0.5, accuracy: 1e-9)
        XCTAssertEqual(EveningWatch.learnedUnits(before: 0.78, given: 0.5, scale: 1, lowest: 8, after2h: 13), 0.8, accuracy: 1e-9)
    }

    func testSettingsFromAnOlderBuildAndOutOfRange() throws {
        let decoded = try JSONDecoder().decode(EveningWatchSettings.self, from: Data(#"{"mode":"suggest","risingFrom":2}"#.utf8))
        XCTAssertEqual(decoded.mode, .suggest)
        XCTAssertEqual(decoded.highFrom, 11)
        XCTAssertEqual(decoded.clamped.risingFrom, 8)
    }

    // MARK: - 30 October

    /// The evening Julia gave 0.5 U at 20:08, 0.35 U at 22:25 and 0.35 U at 00:02 by hand. With
    /// those left out, automatic mode gives a dose of its own around 22:20 and keeps within its limits.
    func testReplayOf30October() {
        let start = at(18, 0)
        func date(_ minutes: Int) -> Date { start.addingTimeInterval(Double(minutes) * 60) }
        let corrections = [129, 266, 363]
        let byHand = Oct30.manualBoluses.filter { !corrections.contains($0.0) }.map { EveningWatch.Dose(date: date($0.0), units: $0.1) }
        let carbs = Oct30.carbs.map { EveningWatch.Carbs(date: date($0.0), grams: $0.1) }

        var state = EveningWatchState()
        var given: [EveningWatch.Dose] = []
        for minute in stride(from: 0, through: 8 * 60, by: 5) {
            let now = date(minute)
            let glucose = Oct30.glucose.filter { $0.0 <= minute }.map { EveningWatch.Reading(date: date($0.0), mmol: $0.1) }
            let loop = Oct30.loop.last { $0.0 <= minute }
            let input = EveningWatch.Input(
                glucose: glucose,
                manualBoluses: (byHand + given).filter { $0.date <= now }.sorted { $0.date < $1.date },
                carbs: carbs,
                iob: loop?.1,
                lowestForecast: loop?.2,
                maximumBolus: 2,
                canDose: true,
                reducedInsulin: false
            )
            let result = EveningWatch.tick(state, input: input, settings: settings(), now: now, calendar: calendar)
            state = result.state
            if case .dose(let action) = result.effect, let index = state.actions.firstIndex(where: { $0.id == action.id }) {
                state.actions[index].state = .given
                state.actions[index].givenUnits = action.units
                state.actions[index].closedAt = now
                given.append(.init(date: now, units: action.units))
            }
        }

        let doses = state.actions.filter { $0.state == .given }
        print("30 October:", doses.map { "\(EveningWatchText.time($0.date)) \($0.glucose) \($0.trigger.rawValue) \($0.units) U" })
        XCTAssertFalse(doses.isEmpty)
        XCTAssertTrue(doses.allSatisfy { EveningWatch.isInWindow($0.date, settings: settings(), calendar: calendar) })
        XCTAssertTrue(doses.allSatisfy { $0.units <= 0.5 })
        XCTAssertLessThanOrEqual(doses.reduce(0) { $0 + $1.units }, 1.2 + 1e-9)
        let first = doses[0].date
        XCTAssertGreaterThanOrEqual(first, at(21, 30))
        XCTAssertLessThanOrEqual(first, at(22, 45))
        XCTAssertNil(state.stop)
    }

    // MARK: - Helpers

    private func action(at date: Date, units: Double, state: EveningWatchAction.State, kind: EveningWatchAction.Kind = .automatic) -> EveningWatchAction {
        var action = EveningWatchAction(kind: kind, trigger: .rising, date: date, glucose: 10, units: units, scale: 0.7, state: state)
        if state == .given {
            action.givenUnits = units
            action.closedAt = date
        }
        return action
    }
}

private enum Oct30 {
    // 30 October 2026 from 18:00 (Europe/Oslo): minutes after 18:00 and mmol/L, from Nightscout.
    static let glucose: [(Int, Double)] = [(4, 7.3), (9, 7.2), (14, 7.8), (19, 8.7), (24, 9.5), (29, 10.5), (34, 11.4), (39, 11.8), (44, 11.8), (49, 11.6), (54, 11.0), (59, 10.4), (64, 9.4), (69, 8.1), (74, 7.2), (79, 6.7), (84, 6.7), (89, 7.3), (94, 7.9), (99, 8.4), (104, 8.8), (109, 8.8), (114, 8.7), (119, 9.3), (124, 10.2), (129, 10.8), (134, 10.9), (139, 10.6), (144, 10.0), (149, 9.4), (154, 8.9), (159, 8.5), (164, 8.3), (169, 8.0), (174, 7.7), (179, 7.4), (184, 7.5), (189, 7.6), (194, 7.5), (199, 7.5), (204, 7.8), (209, 7.9), (214, 8.1), (219, 8.1), (224, 8.1), (229, 8.1), (234, 8.0), (239, 8.0), (244, 8.1), (249, 8.2), (254, 8.5), (259, 8.9), (264, 9.1), (269, 9.3), (274, 9.4), (279, 9.5), (284, 9.5), (289, 9.1), (294, 8.8), (299, 8.5), (304, 8.4), (309, 8.6), (314, 8.7), (319, 8.8), (324, 8.8), (329, 8.9), (334, 8.9), (339, 9.0), (344, 9.2), (349, 9.4), (354, 9.6), (359, 9.8), (364, 10.0), (369, 10.0), (374, 10.0), (379, 10.1), (384, 10.2), (389, 10.3), (394, 10.2), (399, 10.3), (404, 10.2), (409, 10.0), (414, 10.0), (419, 9.9), (424, 9.8), (429, 9.7), (434, 9.6), (439, 9.6), (444, 9.6), (449, 9.7), (454, 9.8), (459, 10.0), (464, 10.0), (469, 9.9), (474, 9.5), (479, 9.4), (484, 9.5), (489, 9.8), (494, 10.0), (499, 10.0), (504, 10.0), (509, 10.0), (514, 9.9), (519, 9.9), (524, 9.9), (529, 9.9), (534, 10.1), (539, 10.2), (544, 10.0), (549, 9.7), (554, 9.5), (559, 9.3), (564, 9.3), (569, 9.3), (574, 9.4), (579, 9.5), (584, 9.5), (589, 9.3), (594, 9.3), (599, 9.2)]
    /// Boluses by hand (minutes, units): the dinner bolus and Julia's corrections at 20:08, 22:25 and 00:02.
    static let manualBoluses: [(Int, Double)] = [(363, 0.35), (266, 0.35), (129, 0.5), (32, 0.24999999999999997), (21, 1.0)]
    static let carbs: [(Int, Double)] = [(68, 7.0), (19, 22.0)]
    /// Loop's insulin on board and lowest forecast (minutes, units, mmol/L).
    static let loop: [(Int, Double, Double)] = [(5, 0.5, 7.2), (9, 0.5, 7.0), (14, 0.47, 7.7), (19, 0.46, 7.8), (21, 0.46, 4.2), (24, 1.43, 4.8), (29, 1.43, 5.5), (32, 1.4, 4.3), (34, 1.62, 5.7), (39, 1.62, 5.4), (44, 1.59, 4.8), (49, 1.55, 4.6), (54, 1.5, 4.3), (59, 1.43, 3.7), (64, 1.37, 2.8), (68, 1.3, 4.1), (68, 1.3, 4.2), (69, 1.3, 2.5), (74, 1.25, 2.4), (79, 1.17, 3.2), (84, 1.12, 4.5), (89, 1.15, 6.0), (94, 1.24, 6.8), (99, 1.29, 7.0), (104, 1.33, 6.6), (109, 1.33, 6.3), (114, 1.28, 6.0), (119, 1.22, 6.6), (124, 1.22, 7.9), (129, 1.59, 4.9), (134, 1.59, 4.1), (140, 1.51, 3.1), (144, 1.44, 2.5), (149, 1.4, 2.7), (154, 1.28, 2.7), (159, 1.19, 2.9), (164, 1.11, 3.2), (169, 1.07, 3.8), (174, 0.94, 3.7), (180, 0.86, 3.8), (184, 0.78, 4.2), (189, 0.75, 5.1), (194, 0.63, 5.0), (199, 0.56, 4.9), (204, 0.49, 5.2), (209, 0.47, 5.7), (214, 0.39, 5.8), (219, 0.34, 5.6), (224, 0.29, 5.4), (229, 0.23, 5.9), (234, 0.18, 5.5), (239, 0.15, 5.5), (244, 0.13, 6.3), (249, 0.14, 6.7), (254, 0.17, 7.4), (259, 0.26, 7.7), (264, 0.29, 7.8), (269, 0.57, 6.2), (274, 0.61, 6.5), (279, 0.58, 6.2), (284, 0.56, 6.2), (289, 0.53, 6.1), (294, 0.45, 5.4), (299, 0.41, 5.2), (304, 0.36, 5.5), (309, 0.37, 6.0), (314, 0.34, 6.4), (319, 0.32, 6.7), (324, 0.33, 6.8), (329, 0.33, 7.2), (335, 0.35, 7.1), (339, 0.38, 7.1), (344, 0.41, 6.9), (349, 0.45, 7.0), (354, 0.48, 7.1), (359, 0.52, 7.2), (364, 0.81, 5.1), (369, 0.81, 5.1), (374, 0.78, 5.1), (379, 0.75, 5.3), (385, 0.74, 6.2), (390, 0.7, 6.1), (394, 0.66, 6.0), (400, 0.59, 6.3), (404, 0.59, 6.4), (409, 0.56, 6.4), (414, 0.54, 6.7), (419, 0.51, 6.7), (424, 0.48, 6.5), (429, 0.45, 6.6), (434, 0.42, 6.8), (439, 0.4, 7.1), (445, 0.4, 7.0), (449, 0.43, 6.9), (454, 0.45, 7.1), (459, 0.48, 7.3), (464, 0.51, 7.0), (469, 0.51, 6.6), (474, 0.49, 6.1), (479, 0.46, 6.0), (485, 0.44, 6.6), (489, 0.45, 7.1), (495, 0.47, 7.4), (499, 0.47, 7.2), (504, 0.45, 7.2), (510, 0.46, 7.2), (514, 0.46, 7.1), (519, 0.44, 7.2), (524, 0.45, 6.9), (530, 0.45, 7.1), (534, 0.46, 7.3), (539, 0.49, 7.1), (544, 0.49, 6.7), (549, 0.47, 6.2), (554, 0.45, 6.0), (559, 0.43, 5.8), (564, 0.41, 6.2), (569, 0.39, 6.7), (574, 0.37, 6.9), (579, 0.38, 7.0), (584, 0.41, 6.8), (589, 0.41, 6.6), (594, 0.39, 6.7), (599, 0.37, 6.9)]
}
