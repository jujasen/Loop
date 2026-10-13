//
//  GlucoseInsightTests.swift
//  LoopTests
//
//  The glucose insight: meals and what muddles them, lows, Loop's forecast error, the meals most
//  like a new one, when the numbers and texts are due, and keeping the Nightscout history.
//

import XCTest
@testable import Loop

final class GlucoseInsightTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        return calendar
    }()

    /// Monday 12 October 2026 at `hour`:`minute` in Oslo.
    private func monday(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: hour, minute: minute))!
        return calendar.date(byAdding: .day, value: dayOffset, to: date)!
    }

    private func mgdl(_ mmol: Double) -> Double { mmol * 18.0182 }

    /// Readings every five minutes from `start`, from `mmol(minutes)`.
    private func readings(from start: Date, hours: Double, _ mmol: (Int) -> Double) -> [NightscoutGlucoseReading] {
        stride(from: 0, through: Int(hours * 60), by: 5).map {
            NightscoutGlucoseReading(date: start.addingTimeInterval(.minutes(Double($0))), mgdl: mgdl(mmol($0)))
        }
    }

    private func carbs(_ grams: Double, at date: Date, _ food: String? = nil) -> NightscoutTreatment {
        NightscoutTreatment(date: date, carbs: grams, insulin: nil, foodType: food, isAutomatic: false)
    }

    private func bolus(_ units: Double, at date: Date, automatic: Bool = false) -> NightscoutTreatment {
        NightscoutTreatment(date: date, carbs: nil, insulin: units, foodType: nil, isAutomatic: automatic)
    }

    // MARK: Meals

    func testEntriesAnHourApartAreOneMealWithItsBolusAndCurve() {
        let start = monday(17)
        let glucose = readings(from: start.addingTimeInterval(-.minutes(30)), hours: 5) { minute in
            let sinceMeal = minute - 30
            switch sinceMeal {
            case ..<0: return 6
            case 0..<60: return 6 + Double(sinceMeal) / 60 * 5   // up to 11
            case 60..<180: return 11 - Double(sinceMeal - 60) / 120 * 4 // down to 7 at 3 h
            default: return 7
            }
        }
        let treatments = [
            carbs(24, at: start, "🥣 Havregrøt"),
            bolus(1.2, at: start.addingTimeInterval(.minutes(2))),
            carbs(14, at: start.addingTimeInterval(.minutes(10)), "🥛 Melk"),
            bolus(0.1, at: start.addingTimeInterval(.minutes(40)), automatic: true),
        ]
        let meals = GlucoseInsight.meals(glucose: glucose, treatments: treatments, now: start.addingTimeInterval(.hours(5)), calendar: calendar)
        XCTAssertEqual(meals.count, 1)
        let meal = meals[0]
        XCTAssertEqual(meal.carbsGrams, 38)
        XCTAssertEqual(meal.foods, ["🥣 Havregrøt", "🥛 Melk"])
        XCTAssertEqual(meal.bolusUnits, 1.2)
        XCTAssertEqual(meal.automaticUnitsWithin3h, 0.1)
        XCTAssertEqual(meal.startMmol, 6)
        XCTAssertEqual(meal.peakMmol, 11)
        XCTAssertEqual(meal.after3hMmol, 7)
        XCTAssertEqual(meal.daypart, "ettermiddag 15-19")
        XCTAssertTrue(meal.isClean)
    }

    func testCarbsForALowAreNotAMealAndMarkTheMealBefore() {
        let start = monday(12)
        // 7 at lunch, a low of 3.6 at 2 h, back up after juice.
        let glucose = readings(from: start, hours: 5) { minute in
            switch minute {
            case 110..<140: return 3.6
            default: return 7
            }
        }
        let treatments = [
            carbs(30, at: start, "🍝"),
            bolus(1.5, at: start),
            carbs(10, at: start.addingTimeInterval(.minutes(120)), "🧃"),
        ]
        let meals = GlucoseInsight.meals(glucose: glucose, treatments: treatments, now: start.addingTimeInterval(.hours(6)), calendar: calendar)
        XCTAssertEqual(meals.count, 1, "juice for a low is not a meal")
        XCTAssertEqual(meals[0].flags, [.treatedLow])
        XCTAssertEqual(meals[0].lowestWithin4hMmol, 3.6)
    }

    func testExtraCarbsCorrectionsLowStartsAndUnfinishedMealsAreMarked() {
        let start = monday(8)
        let glucose = readings(from: start, hours: 8) { _ in 8 }
        let treatments = [
            carbs(20, at: start),
            bolus(1, at: start),
            bolus(0.5, at: start.addingTimeInterval(.minutes(100))), // correction, no carbs near
            carbs(15, at: start.addingTimeInterval(.minutes(150))),  // a snack: extra carbs
        ]
        let meals = GlucoseInsight.meals(glucose: glucose, treatments: treatments, now: start.addingTimeInterval(.hours(5)), calendar: calendar)
        XCTAssertEqual(meals.count, 2)
        XCTAssertEqual(Set(meals[0].flags), [.correction, .extraCarbs])
        XCTAssertEqual(meals[1].flags, [.unfinished], "the snack is less than four hours ago")

        let lowStart = readings(from: start, hours: 4) { $0 < 20 ? 4.2 : 6 }
        let lowMeal = GlucoseInsight.meals(glucose: lowStart, treatments: [carbs(20, at: start.addingTimeInterval(.minutes(5))), bolus(0.8, at: start.addingTimeInterval(.minutes(5)))], now: start.addingTimeInterval(.hours(6)), calendar: calendar)
        XCTAssertEqual(lowMeal.first?.flags, [.startedLow], "a meal with a bolus is a meal, even under 5")
        let rescue = GlucoseInsight.meals(glucose: lowStart, treatments: [carbs(20, at: start.addingTimeInterval(.minutes(5)))], now: start.addingTimeInterval(.hours(6)), calendar: calendar)
        XCTAssertTrue(rescue.isEmpty, "carbs under 5 without a bolus are for a low")
    }

    func testLowEpisodesNeedTwoReadingsInARow() {
        let start = monday(2)
        let glucose = readings(from: start, hours: 2) { minute in
            switch minute {
            case 10: return 3.5               // one reading: not an episode
            case 40, 45, 50: return 3.4       // one episode
            case 90, 95: return 3.7           // another
            default: return 6
            }
        }
        XCTAssertEqual(GlucoseInsight.lowEpisodeStarts(glucose), [start.addingTimeInterval(.minutes(40)), start.addingTimeInterval(.minutes(90))])
        XCTAssertEqual(GlucoseInsight.period(glucose)?.lowEpisodes, 2)
    }

    // MARK: Loop's forecast

    func testForecastErrorIsWorkedOutPerPartOfTheDayAndTodayAgainstUsual() {
        var history = NightscoutHistory()
        // Seven evenings where Loop forecast 7 an hour on, 9 two hours on, and it was 10.
        for day in -7 ..< 0 {
            let evening = monday(21, dayOffset: day)
            history.glucose += readings(from: evening, hours: 2.5) { _ in 10 }
            history.forecasts.append(LoopForecastCheck(date: evening, startMgdl: mgdl(8), in60Mgdl: mgdl(7), in120Mgdl: mgdl(9)))
        }
        // Today, mornings: Loop misses by 2 where it usually misses by 0.
        for day in -3 ..< 1 {
            for half in 0..<3 {
                let morning = monday(7, half * 30, dayOffset: day)
                history.forecasts.append(LoopForecastCheck(date: morning, startMgdl: mgdl(6), in60Mgdl: mgdl(day == 0 ? 4 : 6), in120Mgdl: nil))
            }
            history.glucose += readings(from: monday(7, dayOffset: day), hours: 3) { _ in 6 }
        }

        let longTerm = GlucoseInsight.longTerm(history: history, advice: [], days: 30, now: monday(10), calendar: calendar)
        let evening = longTerm.dayparts.first { $0.name == "kveld 19-24" }
        XCTAssertEqual(evening?.loopForecastError1hMmol, 3)
        XCTAssertEqual(evening?.loopForecastError2hMmol, 1)
        XCTAssertEqual(evening?.forecastChecks, 7)

        let today = GlucoseInsight.today(history: history, now: monday(10), calendar: calendar)
        XCTAssertEqual(today.loopForecastError1hMmol, 2)
        XCTAssertEqual(today.usualForecastError1hMmol, 0)
        XCTAssertEqual(today.forecastDeviationMmol, 2)
    }

    // MARK: Similar meals

    func testSimilarMealsAreTheSameTimeAndFoodFirst() {
        func meal(_ date: Date, _ grams: Double, _ food: String, flags: [GlucoseInsightMeal.Flag] = []) -> GlucoseInsightMeal {
            GlucoseInsightMeal(date: date, daypart: GlucoseInsight.daypartName(date, calendar: calendar), carbsGrams: grams, foods: [food], bolusUnits: 1, automaticUnitsWithin3h: 0, startMmol: 6, peakMmol: 9, after2hMmol: 8, after3hMmol: 7, lowestWithin4hMmol: 6, flags: flags)
        }
        let porridgeEvening = meal(monday(18, dayOffset: -3), 25, "🥣 Havregrøt m/ melk")
        let porridgeMorning = meal(monday(7, dayOffset: -2), 25, "🥣 Havregrøt")
        let pizzaEvening = meal(monday(18, 30, dayOffset: -1), 40, "🍕 Pizza")
        let muddled = meal(monday(18, dayOffset: -1), 25, "🥣 Havregrøt", flags: [.correction])
        let similar = GlucoseInsight.similarMeals(to: 24, foodType: "🥣 Havregrøt", at: monday(18, 10), in: [porridgeMorning, pizzaEvening, muddled, porridgeEvening], count: 2, calendar: calendar)
        XCTAssertEqual(similar, [porridgeEvening, muddled])
        XCTAssertEqual(GlucoseInsight.foodWords("🍕 Pizza m/ ost"), ["🍕", "pizza", "ost"])
    }

    // MARK: AI dose outcomes

    func testAIDoseOutcomesAreReadFromGlucoseOnceFinished() {
        var history = NightscoutHistory()
        let shown = monday(12)
        history.glucose = readings(from: shown, hours: 6) { $0 == 200 ? 3.5 : 7 }
        let records = [
            AIDoseAdviceRecord(date: shown, loopUnits: 1, suggestedUnits: 1.3, carbsGrams: 30, accepted: true),
            AIDoseAdviceRecord(date: monday(15, 30), loopUnits: 1, suggestedUnits: 0.8, carbsGrams: 20, accepted: false),
        ]
        let longTerm = GlucoseInsight.longTerm(history: history, advice: records, days: 30, now: monday(18), calendar: calendar)
        XCTAssertEqual(longTerm.advice.count, 2)
        XCTAssertEqual(longTerm.advice[0].after3hMmol, 7)
        XCTAssertEqual(longTerm.advice[0].lowestWithin4hMmol, 3.5)
        XCTAssertNil(longTerm.advice[1].after3hMmol, "less than four hours ago")
    }

    // MARK: When

    private func status(dataAt: Date?, longTermTextAt: Date? = nil, todayTextAt: Date? = nil, meals: [GlucoseInsightMeal] = [], lows: [Date] = [], now: Date) -> GlucoseInsightStatus {
        var status = GlucoseInsightStatus()
        status.dataUpdatedAt = dataAt
        status.longTerm = GlucoseInsightLongTerm(days: 30, last7Days: nil, earlierDays: nil, dayparts: [], weekdayDaytime: nil, weekendDaytime: nil, averageDailyCarbsGrams: 0, averageDailyBolusUnits: 0, meals: [], advice: [], computedAt: now)
        status.today = GlucoseInsightToday(period: nil, lowEpisodeStarts: lows, hoursAboveTen: 0, meals: meals, loopForecastError1hMmol: nil, usualForecastError1hMmol: nil, forecastDeviationMmol: nil, computedAt: now)
        status.longTermText = longTermTextAt.map { GlucoseInsightText(summary: "", points: [], doseHints: [], createdAt: $0) }
        status.todayText = todayTextAt.map { GlucoseInsightText(summary: "", points: [], doseHints: [], createdAt: $0) }
        return status
    }

    func testNumbersAreReadEveryHalfHourAndNotRetriedAtOnce() {
        let now = monday(12)
        let attempts = GlucoseInsightAttempts()
        XCTAssertTrue(GlucoseInsightSchedule.dueWork(status: status(dataAt: nil, now: now), attempts: attempts, aiEnabled: false, lastDataAttempt: nil, now: now, calendar: calendar).data)
        XCTAssertFalse(GlucoseInsightSchedule.dueWork(status: status(dataAt: now.addingTimeInterval(-.minutes(20)), now: now), attempts: attempts, aiEnabled: false, lastDataAttempt: nil, now: now, calendar: calendar).data)
        XCTAssertTrue(GlucoseInsightSchedule.dueWork(status: status(dataAt: now.addingTimeInterval(-.minutes(31)), now: now), attempts: attempts, aiEnabled: false, lastDataAttempt: nil, now: now, calendar: calendar).data)
        XCTAssertFalse(GlucoseInsightSchedule.dueWork(status: status(dataAt: nil, now: now), attempts: attempts, aiEnabled: false, lastDataAttempt: now.addingTimeInterval(-.minutes(5)), now: now, calendar: calendar).data, "a failed read waits ten minutes")
    }

    func testNoTextIsWrittenWithoutAI() {
        let now = monday(12)
        let due = GlucoseInsightSchedule.dueWork(status: status(dataAt: now, now: now), attempts: GlucoseInsightAttempts(), aiEnabled: false, lastDataAttempt: nil, now: now, calendar: calendar)
        XCTAssertFalse(due.longTermText)
        XCTAssertFalse(due.todayText)
    }

    func testTheLongTermTextIsWrittenOnceANightWithinTheCeiling() {
        let attempts = GlucoseInsightAttempts()
        // Written yesterday at 04:10: due again after 04:00 today, not before.
        let written = monday(4, 10, dayOffset: -1)
        XCTAssertFalse(GlucoseInsightSchedule.dueWork(status: status(dataAt: monday(3), longTermTextAt: written, now: monday(3)), attempts: attempts, aiEnabled: true, lastDataAttempt: nil, now: monday(3), calendar: calendar).longTermText)
        XCTAssertTrue(GlucoseInsightSchedule.dueWork(status: status(dataAt: monday(4, 5), longTermTextAt: written, now: monday(4, 5)), attempts: attempts, aiEnabled: true, lastDataAttempt: nil, now: monday(4, 5), calendar: calendar).longTermText)
        XCTAssertFalse(GlucoseInsightSchedule.dueWork(status: status(dataAt: monday(9), longTermTextAt: monday(4, 6), now: monday(9)), attempts: attempts, aiEnabled: true, lastDataAttempt: nil, now: monday(9), calendar: calendar).longTermText)

        var spent = GlucoseInsightAttempts()
        spent.record(.deep, at: monday(4, 5), calendar: calendar)
        spent.record(.deep, at: monday(5), calendar: calendar)
        XCTAssertFalse(GlucoseInsightSchedule.dueWork(status: status(dataAt: monday(9), longTermTextAt: written, now: monday(9)), attempts: spent, aiEnabled: true, lastDataAttempt: nil, now: monday(9), calendar: calendar).longTermText, "two tries a day at most")

        var failed = GlucoseInsightAttempts()
        failed.record(.deep, at: monday(4, 5), calendar: calendar)
        XCTAssertFalse(GlucoseInsightSchedule.dueWork(status: status(dataAt: monday(4, 20), longTermTextAt: written, now: monday(4, 20)), attempts: failed, aiEnabled: true, lastDataAttempt: nil, now: monday(4, 20), calendar: calendar).longTermText, "a retry waits half an hour")
    }

    func testTodaysTextIsWrittenInTheMorningAndWhenAMealIsOverOrAfterALow() {
        let attempts = GlucoseInsightAttempts()
        func due(_ status: GlucoseInsightStatus, _ now: Date, _ attempts: GlucoseInsightAttempts = GlucoseInsightAttempts()) -> Bool {
            GlucoseInsightSchedule.dueWork(status: status, attempts: attempts, aiEnabled: true, lastDataAttempt: nil, now: now, calendar: calendar).todayText
        }
        XCTAssertFalse(due(status(dataAt: monday(5), longTermTextAt: monday(4, 5), now: monday(5)), monday(5)), "not before 06")
        XCTAssertTrue(due(status(dataAt: monday(6, 5), longTermTextAt: monday(4, 5), todayTextAt: monday(21, dayOffset: -1), now: monday(6, 5)), monday(6, 5)))
        XCTAssertFalse(due(status(dataAt: monday(10), longTermTextAt: monday(4, 5), todayTextAt: monday(7), now: monday(10)), monday(10)), "nothing new since")

        let breakfast = GlucoseInsightMeal(date: monday(7, 30), daypart: "morgen 06-09", carbsGrams: 20, foods: [], bolusUnits: 1, automaticUnitsWithin3h: 0, startMmol: nil, peakMmol: nil, after2hMmol: nil, after3hMmol: nil, lowestWithin4hMmol: nil, flags: [])
        XCTAssertTrue(due(status(dataAt: monday(10, 40), longTermTextAt: monday(4, 5), todayTextAt: monday(7), meals: [breakfast], now: monday(10, 40)), monday(10, 40)), "breakfast is three hours behind")
        XCTAssertTrue(due(status(dataAt: monday(9), longTermTextAt: monday(4, 5), todayTextAt: monday(7), lows: [monday(8, 30)], now: monday(9)), monday(9)), "a low since")
        XCTAssertFalse(due(status(dataAt: monday(7, 30), longTermTextAt: monday(4, 5), todayTextAt: monday(7), lows: [monday(7, 20)], now: monday(7, 30)), monday(7, 30)), "not within 45 minutes of the last")

        var spent = attempts
        for hour in 6..<14 { spent.record(.fast, at: monday(hour), calendar: calendar) }
        XCTAssertFalse(due(status(dataAt: monday(15), longTermTextAt: monday(4, 5), todayTextAt: monday(7), lows: [monday(14)], now: monday(15)), monday(15), spent), "eight a day at most")
    }

    func testAttemptsStartAgainEachDay() {
        var attempts = GlucoseInsightAttempts()
        attempts.record(.fast, at: monday(20), calendar: calendar)
        attempts.record(.deep, at: monday(21), calendar: calendar)
        XCTAssertEqual(attempts.on(monday(22), calendar: calendar).fast, 1)
        XCTAssertEqual(attempts.on(monday(8, dayOffset: 1), calendar: calendar).fast, 0)
        XCTAssertEqual(attempts.on(monday(8, dayOffset: 1), calendar: calendar).lastDeep, monday(21))
    }

    // MARK: Nightscout history

    func testRereadingReplacesTheOverlapSoDeletedEntriesGo() {
        let old = [carbs(20, at: monday(8)), carbs(30, at: monday(12)), carbs(10, at: monday(13))]
        let fresh = [carbs(30, at: monday(12)), carbs(15, at: monday(14))] // 13:00 was deleted
        let merged = NightscoutHistory.merged(old, with: fresh, since: monday(11), date: \.date)
        XCTAssertEqual(merged.map(\.date), [monday(8), monday(12), monday(14)])
    }

    func testAMealBolusFromBothQueriesIsKeptOnce() {
        let mealBolus = NightscoutTreatment(date: monday(12), carbs: 30, insulin: 1.5, foodType: nil, isAutomatic: false)
        XCTAssertEqual(NightscoutHistory.deduplicated([mealBolus, carbs(10, at: monday(15)), mealBolus]), [mealBolus, carbs(10, at: monday(15))])
    }

    func testForecastsAreKeptEveryHalfHourAndOldDataIsTrimmed() {
        let forecasts = (0..<12).map { LoopForecastCheck(date: monday(10, $0 * 5), startMgdl: 100, in60Mgdl: nil, in120Mgdl: nil) }
        XCTAssertEqual(NightscoutHistory.spaced(forecasts).map(\.date), [monday(10), monday(10, 25), monday(10, 50)])
        XCTAssertEqual(NightscoutHistory.spaced(forecasts, after: monday(9, 50)).map(\.date), [monday(10, 15), monday(10, 40)])

        var history = NightscoutHistory(glucose: [NightscoutGlucoseReading(date: monday(10, dayOffset: -31), mgdl: 100), NightscoutGlucoseReading(date: monday(10), mgdl: 100)])
        history.trim(days: 30, now: monday(12))
        XCTAssertEqual(history.glucose.count, 1)
    }

    func testLoopsForecastIsReadFromDevicestatus() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            ["created_at": "2026-10-13T17:17:45.000Z", "loop": ["predicted": ["startDate": "2026-10-13T17:17:41Z", "values": (0..<30).map { 100 + $0 }]]],
            ["created_at": "2026-10-13T17:22:45.000Z", "pump": ["battery": 1]],
        ])
        let parsed = NightscoutHistory.parseForecasts(data)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.startMgdl, 100)
        XCTAssertEqual(parsed.first?.in60Mgdl, 112)
        XCTAssertEqual(parsed.first?.in120Mgdl, 124)
    }

    func testTheStoreKeepsWhatItSaves() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GlucoseInsightTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let history = NightscoutHistory(glucose: [NightscoutGlucoseReading(date: monday(10), mgdl: 120)], glucoseReadThrough: monday(10))
        await NightscoutHistoryStore(fileURL: url).save(history)
        let loaded = await NightscoutHistoryStore(fileURL: url).history()
        XCTAssertEqual(loaded, history)
    }

    // MARK: Writing the texts

    func testTextRequestsUseTheRightEffortAndAnswersAreRead() throws {
        let body = try GlucoseInsightWriter.requestBody(system: GlucoseInsightWriter.todayPrompt, input: ["a": 1], reasoning: "medium")
        XCTAssertEqual(body["reasoning_effort"] as? String, "medium")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))

        let answer = #"{"summary":"Rolig dag.","points":["Frokost gikk fint"],"dose_hints":[]}"#
        let completion = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": answer]]]])
        let text = try GlucoseInsightWriter.parse(completion, now: monday(12))
        XCTAssertEqual(text.summary, "Rolig dag.")
        XCTAssertEqual(text.points, ["Frokost gikk fint"])
        XCTAssertEqual(text.createdAt, monday(12))
    }
}
