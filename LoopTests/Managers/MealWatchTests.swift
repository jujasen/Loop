//
//  MealWatchTests.swift
//  LoopTests
//
//  When the meal watch asks the AI, and how far its dose may go.
//

import XCTest
@testable import Loop

final class MealWatchTests: XCTestCase {
    private let meal = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func watch(lastCheck: Date? = nil, suggestions: [MealWatchSuggestion] = []) -> MealWatch {
        MealWatch(id: "w", entryID: "e", mealDate: meal, carbs: 14, foodType: "🥛 Melk", until: meal.addingTimeInterval(.hours(5)), lastCheck: lastCheck, suggestions: suggestions)
    }

    private func now(glucose: Double = 8, change: Double? = 0, lowest: Double? = 7, forecast120: Double = 8, loopUnits: Double? = 0, minutesAgo: Int = 2) -> LoopNow {
        LoopNow(
            date: meal,
            glucoseMmol: glucose,
            glucoseMinutesAgo: minutesAgo,
            change15MinMmol: change,
            lastHour: [],
            insulinOnBoardUnits: 0.3,
            carbsOnBoardGrams: 5,
            forecast: [.init(minutes: 120, mmol: forecast120)],
            lowestForecastMmol: lowest,
            loopRecommendedBolusUnits: loopUnits,
            activeOverride: nil
        )
    }

    private func at(_ minutes: Double) -> Date { meal.addingTimeInterval(.minutes(minutes)) }

    private func suggestion(at minutes: Double, state: MealWatchSuggestion.State) -> MealWatchSuggestion {
        MealWatchSuggestion(id: UUID().uuidString, date: at(minutes), units: 0.3, reason: "", glucoseMmol: 9, loopUnits: 0, expiresAt: at(minutes + 20), state: state)
    }

    func testNothingIsAskedBeforeHalfAnHourOrWithinAQuarter() {
        XCTAssertEqual(MealWatchGate.decide(watch(), now: now(change: 1), history: [], at: at(20)), .wait)
        XCTAssertEqual(MealWatchGate.decide(watch(lastCheck: at(40)), now: now(change: 1), history: [], at: at(50)), .wait)
        XCTAssertEqual(MealWatchGate.decide(watch(lastCheck: at(40)), now: now(change: 1), history: [], at: at(55)), .ask)
    }

    func testRisingGlucoseOrAHighForecastOrLoopsOwnRecommendationIsAsked() {
        XCTAssertEqual(MealWatchGate.decide(watch(), now: now(change: 0.6), history: [], at: at(60)), .ask)
        XCTAssertEqual(MealWatchGate.decide(watch(), now: now(forecast120: 11), history: [], at: at(60)), .ask)
        XCTAssertEqual(MealWatchGate.decide(watch(), now: now(loopUnits: 0.2), history: [], at: at(60)), .ask)
        XCTAssertEqual(MealWatchGate.decide(watch(), now: now(), history: [], at: at(60)), .skip("nothing happening"))
    }

    func testWhenTheSameMealUsuallyRisesItIsAskedBeforeTheRise() {
        let earlier = (0..<3).map { day in
            MealWatchHistoryMeal(date: meal.addingTimeInterval(-.hours(24 * Double(day + 1))), carbs: 14, foods: ["Melk"], mealBolusUnits: 0.8, laterBoluses: [], curve: [], riseStartMinutes: 150)
        }
        XCTAssertEqual(MealWatchGate.typicalRiseStart(earlier), 150)
        XCTAssertEqual(MealWatchGate.decide(watch(), now: now(), history: earlier, at: at(125)), .ask)
        XCTAssertEqual(MealWatchGate.decide(watch(), now: now(), history: earlier, at: at(60)), .skip("nothing happening"))
        XCTAssertNil(MealWatchGate.typicalRiseStart(Array(earlier.prefix(2))), "two meals are not a pattern")
    }

    func testNeverAskedLowFallingForecastLowOrStale() {
        XCTAssertEqual(MealWatchGate.decide(watch(), now: now(glucose: 5.8, change: 1), history: [], at: at(60)), .skip("glucose under 6.0"))
        XCTAssertEqual(MealWatchGate.decide(watch(), now: now(change: -0.4), history: [], at: at(60)), .skip("falling"))
        XCTAssertEqual(MealWatchGate.decide(watch(), now: now(change: 1, lowest: 4.2), history: [], at: at(60)), .skip("forecast low"))
        XCTAssertEqual(MealWatchGate.decide(watch(), now: now(change: 1, minutesAgo: 15), history: [], at: at(60)), .skip("no fresh glucose"))
        XCTAssertEqual(MealWatchGate.decide(watch(), now: nil, history: [], at: at(60)), .skip("no fresh glucose"))
    }

    func testOneSuggestionAtATimeWithACooldownAndTwoAMeal() {
        XCTAssertEqual(MealWatchGate.decide(watch(suggestions: [suggestion(at: 50, state: .open)]), now: now(change: 1), history: [], at: at(60)), .skip("a suggestion is open"))
        XCTAssertEqual(MealWatchGate.decide(watch(suggestions: [suggestion(at: 50, state: .declined)]), now: now(change: 1), history: [], at: at(80)), .skip("cooldown"))
        XCTAssertEqual(MealWatchGate.decide(watch(suggestions: [suggestion(at: 50, state: .declined)]), now: now(change: 1), history: [], at: at(100)), .ask)
        XCTAssertEqual(MealWatchGate.decide(watch(suggestions: [suggestion(at: 50, state: .given), suggestion(at: 100, state: .declined)]), now: now(change: 1), history: [], at: at(200)), .skip("enough suggestions for this meal"))
        XCTAssertEqual(MealWatchGate.decide(watch(), now: now(change: 1), history: [], at: at(301)), .skip("ended"))
    }

    func testTheDoseIsHeldToLoopPlusTheMarginAndTheMaximumBolus() {
        XCTAssertEqual(MealWatchGate.allowedUnits(loopUnits: 0.2, maximumAboveLoop: 0.5, maximumBolus: 3), 0.7, accuracy: 0.0001)
        XCTAssertEqual(MealWatchGate.allowedUnits(loopUnits: -0.3, maximumAboveLoop: 0.5, maximumBolus: 3), 0.5, accuracy: 0.0001, "a negative recommendation counts as none")
        XCTAssertEqual(MealWatchGate.allowedUnits(loopUnits: 1, maximumAboveLoop: 0.5, maximumBolus: 1.2), 1.2, accuracy: 0.0001)

        XCTAssertEqual(MealWatchGate.clamp(0.43, allowed: 0.7), 0.4)
        XCTAssertEqual(MealWatchGate.clamp(2, allowed: 0.7), 0.7)
        XCTAssertNil(MealWatchGate.clamp(0.04, allowed: 0.7))
        XCTAssertNil(MealWatchGate.clamp(.nan, allowed: 0.7))
        XCTAssertNil(MealWatchGate.clamp(-1, allowed: 0.7))
    }

    func testEarlierMealsCarryTheirCurveRiseAndLaterBoluses() {
        let calendar = Calendar.current
        let earlier = meal.addingTimeInterval(-.hours(24))
        var history = NightscoutHistory()
        // Flat at 6 for two hours, then up to 11.
        history.glucose = stride(from: 0, through: 300, by: 5).map { minute in
            NightscoutGlucoseReading(date: earlier.addingTimeInterval(.minutes(Double(minute))), mgdl: (minute < 120 ? 6 : 6 + Double(minute - 120) / 36) * 18.0182)
        }
        history.treatments = [
            NightscoutTreatment(date: earlier, carbs: 14, insulin: nil, foodType: "🥛 Melk", isAutomatic: false),
            NightscoutTreatment(date: earlier.addingTimeInterval(.minutes(150)), carbs: nil, insulin: 0.4, foodType: nil, isAutomatic: false),
            NightscoutTreatment(date: earlier.addingTimeInterval(.minutes(160)), carbs: nil, insulin: 0.1, foodType: nil, isAutomatic: true),
        ]
        let meals = [GlucoseInsightMeal(date: earlier, daypart: GlucoseInsight.daypartName(earlier, calendar: calendar), carbsGrams: 14, foods: ["🥛 Melk"], bolusUnits: 0.8, automaticUnitsWithin3h: 0, startMmol: 6, peakMmol: 11, after2hMmol: 6, after3hMmol: 7.7, lowestWithin4hMmol: 6, flags: [])]

        let result = MealWatchGate.historyMeals(like: 14, foodType: "🥛 Melk", at: meal, meals: meals, history: history, calendar: calendar)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.curve.count, 11)
        XCTAssertEqual(result.first?.riseStartMinutes, 180, "1.5 over the start at the first half hour past 2 h 54 min")
        XCTAssertEqual(result.first?.laterBoluses, [.init(minutes: 150, units: 0.4)], "only manual boluses")
    }

    func testTheAnswerIsReadAndARefusalIsAnError() throws {
        let answer = #"{"suggest":true,"units":0.35,"reason":"Stiger."}"#
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": answer]]]])
        XCTAssertEqual(try MealWatchAdvisor.parse(data), .init(suggest: true, units: 0.35, reason: "Stiger."))
        let refusal = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": NSNull(), "refusal": "Nei."]]]])
        XCTAssertThrowsError(try MealWatchAdvisor.parse(refusal))
    }

    func testTheNightscoutTreatmentHasNoInsulinOrCarbs() {
        let suggestion = suggestion(at: 60, state: .open)
        let document = MealWatchTreatment.document(for: suggestion, in: watch())
        XCTAssertEqual(document["eventType"] as? String, "AI Bolus Suggestion")
        XCTAssertEqual(document["units"] as? Double, 0.3)
        XCTAssertEqual(document["suggestionID"] as? String, suggestion.id)
        XCTAssertNil(document["insulin"])
        XCTAssertNil(document["carbs"])
    }
}
