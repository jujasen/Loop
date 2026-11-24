//
//  LowWatchTests.swift
//  LoopTests
//
//  When the low watch suggests fast carbs, how many grams, and what keeps it quiet.
//

import XCTest
@testable import Loop

final class LowWatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private var on: LowWatchSettings {
        var settings = LowWatchSettings()
        settings.isOn = true
        return settings
    }

    /// Readings every five minutes up to `at`, the last one equal to the last value given.
    private func readings(_ values: [Double], until at: Date? = nil) -> [EveningWatch.Reading] {
        let end = at ?? now
        return values.enumerated().map { index, mmol in
            EveningWatch.Reading(date: end.addingTimeInterval(-Double(values.count - 1 - index) * 300), mmol: mmol)
        }
    }

    private func input(_ values: [Double], carbs: [LowWatch.Carbs] = [], lowest20: Double? = 3.6, lowest60: Double? = 3.4, at: Date? = nil) -> LowWatch.Input {
        LowWatch.Input(glucose: readings(values, until: at), carbs: carbs, iob: 0.4, lowest20: lowest20, lowest60: lowest60)
    }

    private let falling: [Double] = [7.0, 6.8, 6.5, 6.2, 5.9, 5.6, 5.3]

    // MARK: - When

    func testLoopsForecastOfALowWithin20MinutesSuggests() throws {
        let action = try XCTUnwrap(LowWatch.decide(LowWatchState(), input: input(falling), now: now))
        XCTAssertEqual(action.trigger, .forecast)
        XCTAssertEqual(action.state, .open)
        XCTAssertEqual(action.glucose, 5.3)
        XCTAssertEqual(action.lowestForecast, 3.6)
    }

    func testNothingWhenTheForecastStaysUpOrGlucoseIsSixOrMore() {
        XCTAssertNil(LowWatch.decide(LowWatchState(), input: input(falling, lowest20: 4.2), now: now))
        XCTAssertNil(LowWatch.decide(LowWatchState(), input: input([7.5, 7.2, 6.9, 6.6, 6.3, 6.1, 6.0]), now: now))
        XCTAssertNil(LowWatch.decide(LowWatchState(), input: input(falling, lowest20: nil), now: now), "no forecast and not yet under 4.4")
    }

    func testNotWhileGlucoseIsRising() {
        XCTAssertNil(LowWatch.decide(LowWatchState(), input: input([5.0, 4.9, 4.8, 4.7, 4.6, 4.7, 4.9]), now: now))
    }

    func testUnder4Point4AndFallingSuggestsWithoutAForecast() throws {
        let action = try XCTUnwrap(LowWatch.decide(LowWatchState(), input: input([5.2, 5.0, 4.8, 4.6, 4.5, 4.4, 4.3], lowest20: nil, lowest60: nil), now: now))
        XCTAssertEqual(action.trigger, .low)
        XCTAssertEqual(action.grams, 2, "from glucose itself: (5.5 − 4.3) / 0.7 rounds to 2")
    }

    func testNothingRightAfterCarbsOrWithOldOrJumpingReadings() {
        let justEntered = LowWatch.Carbs(date: now.addingTimeInterval(-5 * 60), grams: 4, entered: now.addingTimeInterval(-5 * 60))
        XCTAssertNil(LowWatch.decide(LowWatchState(), input: input(falling, carbs: [justEntered]), now: now))
        let earlier = LowWatch.Carbs(date: now.addingTimeInterval(-25 * 60), grams: 4, entered: now.addingTimeInterval(-25 * 60))
        XCTAssertNotNil(LowWatch.decide(LowWatchState(), input: input(falling, carbs: [earlier]), now: now))
        let forTonight = LowWatch.Carbs(date: now.addingTimeInterval(2 * 3600), grams: 30, entered: now.addingTimeInterval(-5 * 60))
        XCTAssertNotNil(LowWatch.decide(LowWatchState(), input: input(falling, carbs: [forTonight]), now: now), "carbs entered for later do not treat the low")

        XCTAssertNil(LowWatch.decide(LowWatchState(), input: input(falling, at: now.addingTimeInterval(-10 * 60)), now: now))
        XCTAssertNil(LowWatch.decide(LowWatchState(), input: input([7.0, 6.8, 6.5, 6.2, 5.9, 7.6, 5.3]), now: now))
    }

    func testTwentyMinutesBetweenTwo() {
        var state = LowWatchState()
        var earlier = LowWatchAction(trigger: .forecast, date: now.addingTimeInterval(-15 * 60), glucose: 5.6, nadir: 3.5, grams: 3, state: .eaten)
        state.actions = [earlier]
        XCTAssertNil(LowWatch.decide(state, input: input(falling), now: now))
        earlier.date = now.addingTimeInterval(-21 * 60)
        state.actions = [earlier]
        XCTAssertNotNil(LowWatch.decide(state, input: input(falling), now: now))
    }

    // MARK: - Grams

    func testGramsLiftTheLowestForecastTo5Point5() {
        XCTAssertEqual(LowWatch.grams(nadir: 2.7), 4)
        XCTAssertEqual(LowWatch.grams(nadir: 3.4), 3)
        XCTAssertEqual(LowWatch.grams(nadir: 4.8), 2, "never under 2")
        XCTAssertEqual(LowWatch.grams(nadir: 1.0), 6, "never over 6")
    }

    func testGramsFromGlucoseWhenItIsUnderTheForecast() throws {
        let action = try XCTUnwrap(LowWatch.decide(LowWatchState(), input: input([4.6, 4.5, 4.3, 4.1, 3.9, 3.7, 3.5], lowest20: 3.6, lowest60: 3.8), now: now))
        XCTAssertEqual(action.nadir, 3.5)
        XCTAssertEqual(action.grams, 3)
    }

    // MARK: - Ticks

    func testCarbsEnteredAfterTheSuggestionAnswerIt() {
        let first = LowWatch.tick(LowWatchState(), input: input(falling), settings: on, now: now)
        guard case .suggest(let action) = first.effect else { return XCTFail("no suggestion") }
        let later = now.addingTimeInterval(5 * 60)
        let given = LowWatch.Carbs(date: later.addingTimeInterval(-60), grams: 4, entered: later.addingTimeInterval(-60))
        let second = LowWatch.tick(first.state, input: input(falling + [5.1], carbs: [given], at: later), settings: on, now: later)
        XCTAssertEqual(second.effect, .none)
        XCTAssertEqual(second.state.actions.first?.id, action.id)
        XCTAssertEqual(second.state.actions.first?.state, .eaten)
        XCTAssertEqual(second.state.actions.first?.eatenGrams, 4)
    }

    func testOnlyOneOpenAndItLapsesWhenGlucoseComesUpOrAfterHalfAnHour() {
        let first = LowWatch.tick(LowWatchState(), input: input(falling), settings: on, now: now)
        let still = LowWatch.tick(first.state, input: input(falling + [5.0], at: now.addingTimeInterval(300)), settings: on, now: now.addingTimeInterval(300))
        XCTAssertEqual(still.effect, .none)
        XCTAssertEqual(still.state.actions.count, 1)
        XCTAssertNotNil(still.state.open)

        let up = LowWatch.tick(first.state, input: input([4.6, 4.6, 4.7, 4.8, 5.0, 5.2, 5.4], lowest20: 5.0, at: now.addingTimeInterval(600)), settings: on, now: now.addingTimeInterval(600))
        XCTAssertEqual(up.state.actions.first?.state, .lapsed)

        let old = LowWatch.tick(first.state, input: input(falling, lowest20: 4.5, at: now.addingTimeInterval(31 * 60)), settings: on, now: now.addingTimeInterval(31 * 60))
        XCTAssertEqual(old.state.actions.first?.state, .lapsed)
    }

    func testOffDoesNothingAndClosesWhatIsOpen() {
        let off = LowWatch.tick(LowWatchState(), input: input(falling), settings: LowWatchSettings(), now: now)
        XCTAssertEqual(off.effect, .none)
        XCTAssertTrue(off.state.actions.isEmpty)

        let first = LowWatch.tick(LowWatchState(), input: input(falling), settings: on, now: now)
        let turnedOff = LowWatch.tick(first.state, input: input(falling), settings: LowWatchSettings(), now: now.addingTimeInterval(60))
        XCTAssertNil(turnedOff.state.open)
    }

    func testNightIs21To07() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        func at(_ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: hour))!
        }
        XCTAssertTrue(LowWatch.isNight(at(22), calendar: calendar))
        XCTAssertTrue(LowWatch.isNight(at(3), calendar: calendar))
        XCTAssertFalse(LowWatch.isNight(at(7), calendar: calendar))
        XCTAssertFalse(LowWatch.isNight(at(13), calendar: calendar))
    }

    func testSettingsFromBeforeAreOff() throws {
        let decoded = try JSONDecoder().decode(LowWatchSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.isOn)
        XCTAssertFalse(decoded.soundAtNight)
    }

    // MARK: - Nightscout and words

    func testTheTreatmentHasNoCarbsField() {
        let action = LowWatchAction(trigger: .forecast, date: now, glucose: 5.3, change15: -0.9, lowestForecast: 3.6, nadir: 3.4, grams: 3, state: .open)
        let document = LowWatchTreatment.suggestion(action)
        XCTAssertEqual(document["eventType"] as? String, "Low Watch Suggestion")
        XCTAssertEqual(document["source"] as? String, "lowWatch")
        XCTAssertEqual(document["grams"] as? Double, 3)
        XCTAssertNil(document["carbs"])
        XCTAssertNil(document["insulin"])
    }

    func testTheCarbScreenOpensWithTheGrams() throws {
        let action = LowWatchAction(trigger: .forecast, date: now, glucose: 5.3, nadir: 3.4, grams: 3, state: .open)
        let entry = try XCTUnwrap(NSUserActivity.forLowWatch(action, now: now).newCarbEntry)
        XCTAssertEqual(entry.quantity.doubleValue(for: .gram()), 3)
        XCTAssertEqual(entry.absorptionTime, .minutes(30))
        XCTAssertEqual(entry.foodType, LowWatchText.symbol)
    }
}
