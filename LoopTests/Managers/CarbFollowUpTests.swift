//
//  CarbFollowUpTests.swift
//  LoopTests
//
//  A favorite food's follow-up carbs: when they are added, when they wait, and when they are
//  given up on.
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

/// The follow-up entry's name as the simulator's language spells it.
private func followUpName(_ name: String) -> String {
    String(format: NSLocalizedString("%@ (later carbs)", comment: ""), name)
}

final class CarbFollowUpPlannerTests: XCTestCase {
    private let meal = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let milk = StoredFavoriteFood(id: "milk", name: "Melk", carbsQuantity: HKQuantity(unit: .gram(), doubleValue: 10), foodType: "🥛", absorptionTime: .hours(2))
    private let rule = CarbFollowUpRule.standard

    private func entry(_ id: String, foodType: String?, at date: Date) -> StoredCarbEntry {
        StoredCarbEntry(startDate: date, quantity: HKQuantity(unit: .gram(), doubleValue: 10), syncIdentifier: id, foodType: foodType)
    }

    private func planned(_ entries: [StoredCarbEntry], records: [String: CarbFollowUpRecord] = [:], mealPlans: [String: MealCarbFollowUp] = [:], assessments: [String: FavoriteCarbFollowUpAssessment] = [:], now: Date) -> [PlannedCarbFollowUp] {
        CarbFollowUpPlanner.planned(entries: entries, favorites: [milk], rules: ["milk": rule], assessments: assessments, mealPlans: mealPlans, records: records, now: now)
    }

    // MARK: Planning

    func testMealOfTheFavoriteIsPlannedNinetyMinutesLater() {
        let result = planned([entry("a", foodType: "🥛 Melk", at: meal)], now: meal.addingTimeInterval(.minutes(5)))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.triggerID, "a")
        XCTAssertEqual(result.first?.dueDate, meal.addingTimeInterval(.minutes(90)))
        XCTAssertEqual(result.first?.expiryDate, meal.addingTimeInterval(.hours(3)))
        XCTAssertEqual(result.first?.foodType, "🥛 " + followUpName("Melk"))
    }

    func testNameMatchesWhateverTheCase() {
        XCTAssertEqual(planned([entry("a", foodType: "🥛 melk", at: meal)], now: meal).count, 1)
    }

    func testOtherFoodsAndTheFollowUpItselfAreNotMeals() {
        let entries = [
            entry("a", foodType: "🥣 Grøt", at: meal),
            entry("b", foodType: "🥛 " + followUpName("Melk"), at: meal),
            entry("c", foodType: "🥛", at: meal),
        ]
        XCTAssertTrue(planned(entries, now: meal).isEmpty)
    }

    func testFavoriteWithoutRuleIsNotPlanned() {
        let result = CarbFollowUpPlanner.planned(entries: [entry("a", foodType: "🥛 Melk", at: meal)], favorites: [milk], rules: [:], records: [:], now: meal)
        XCTAssertTrue(result.isEmpty)
    }

    func testMealAlreadyFollowedUpIsNotPlannedAgain() {
        for outcome in [CarbFollowUpRecord.Outcome.added, .dropped, .cancelled] {
            let records = ["a": CarbFollowUpRecord(favoriteID: "milk", outcome: outcome, date: meal)]
            XCTAssertTrue(planned([entry("a", foodType: "🥛 Melk", at: meal)], records: records, now: meal).isEmpty, "\(outcome)")
        }
    }

    func testSecondGlassTheSameEveningIsNotFollowedUpAgain() {
        let records = ["a": CarbFollowUpRecord(favoriteID: "milk", outcome: .added, date: meal.addingTimeInterval(.minutes(90)))]
        let entries = [entry("a", foodType: "🥛 Melk", at: meal), entry("b", foodType: "🥛 Melk", at: meal.addingTimeInterval(.minutes(100)))]
        XCTAssertTrue(planned(entries, records: records, now: meal.addingTimeInterval(.minutes(110))).isEmpty)
    }

    func testTwoGlassesBeforeTheFollowUpMakeOneFollowUpTimedFromTheLast() {
        let second = meal.addingTimeInterval(.minutes(20))
        let result = planned([entry("a", foodType: "🥛 Melk", at: meal), entry("b", foodType: "🥛 Melk", at: second)], now: second)

        XCTAssertEqual(result.map(\.triggerID), ["b"])
        XCTAssertEqual(result.first?.dueDate, second.addingTimeInterval(.minutes(90)))
    }

    func testExpiredMealStaysAnHourForALoopToDropIt() {
        XCTAssertEqual(planned([entry("a", foodType: "🥛 Melk", at: meal)], now: meal.addingTimeInterval(.hours(3))).count, 1)
        XCTAssertTrue(planned([entry("a", foodType: "🥛 Melk", at: meal)], now: meal.addingTimeInterval(.hours(4))).isEmpty)
    }

    func testLongDelayGetsAnHourToTurnUp() {
        let late = CarbFollowUpRule(carbGrams: 6, absorptionTime: .hours(4), delay: .hours(3))
        XCTAssertEqual(CarbFollowUpPlanner.expiryDate(start: meal, rule: late), meal.addingTimeInterval(.hours(4)))
    }

    // MARK: Deciding

    private var followUp: PlannedCarbFollowUp {
        planned([entry("a", foodType: "🥛 Melk", at: meal)], now: meal).first!
    }

    /// Readings every five minutes, ending at `end`.
    private func glucose(_ mmol: [Double], endingAt end: Date) -> [GlucoseValue] {
        mmol.reversed().enumerated().map { index, value in
            SimpleGlucoseValue(
                startDate: end.addingTimeInterval(-TimeInterval.minutes(5) * Double(index)),
                quantity: HKQuantity(unit: .millimolesPerLiter, doubleValue: value)
            )
        }
    }

    private let due = Date(timeIntervalSinceReferenceDate: 800_000_000).addingTimeInterval(.minutes(90))

    func testWaitsUntilDue() {
        let now = due.addingTimeInterval(-.minutes(1))
        XCTAssertEqual(CarbFollowUpPlanner.decide(followUp, glucose: glucose([7, 8, 9, 10], endingAt: now), now: now), .wait)
    }

    func testAddsWhenDueAndRising() {
        XCTAssertEqual(CarbFollowUpPlanner.decide(followUp, glucose: glucose([7, 7.5, 8, 8.6], endingAt: due), now: due), .add)
    }

    func testAddsWhenDueAndFlat() {
        XCTAssertEqual(CarbFollowUpPlanner.decide(followUp, glucose: glucose([8, 8, 8, 8], endingAt: due), now: due), .add)
    }

    func testWaitsWhileStillFalling() {
        XCTAssertEqual(CarbFollowUpPlanner.decide(followUp, glucose: glucose([10, 9, 8, 7], endingAt: due), now: due), .wait)
    }

    func testWaitsBelowSixEvenWhenRising() {
        XCTAssertEqual(CarbFollowUpPlanner.decide(followUp, glucose: glucose([4.5, 5, 5.5, 5.9], endingAt: due), now: due), .wait)
    }

    func testAddsAtExactlySix() {
        XCTAssertEqual(CarbFollowUpPlanner.decide(followUp, glucose: glucose([5.5, 5.7, 5.8, 6.0], endingAt: due), now: due), .add)
    }

    func testWaitsWithoutRecentGlucose() {
        let now = due.addingTimeInterval(.minutes(20))
        XCTAssertEqual(CarbFollowUpPlanner.decide(followUp, glucose: glucose([7, 8, 9, 10], endingAt: due), now: now), .wait)
    }

    func testWaitsWithoutAReadingToCompareWith() {
        XCTAssertEqual(CarbFollowUpPlanner.decide(followUp, glucose: glucose([9], endingAt: due), now: due), .wait)
    }

    func testDropsOnceExpired() {
        let now = meal.addingTimeInterval(.hours(3))
        XCTAssertEqual(CarbFollowUpPlanner.decide(followUp, glucose: glucose([10, 9, 8, 7], endingAt: now), now: now), .drop)
    }

    // MARK: Meal plans

    func testMealPlanWinsOverTheFavoriteRule() {
        let other = CarbFollowUpRule(carbGrams: 9, absorptionTime: .hours(5), delay: .hours(2))
        let result = planned([entry("a", foodType: "🥛 Melk", at: meal)], mealPlans: ["a": MealCarbFollowUp(rule: other, source: .manual)], now: meal)

        XCTAssertEqual(result.first?.rule, other)
        XCTAssertEqual(result.first?.source, .manual)
        XCTAssertEqual(result.first?.dueDate, meal.addingTimeInterval(.hours(2)))
    }

    func testTurnedDownMealHasNoLaterCarbs() {
        let result = planned([entry("a", foodType: "🥛 Melk", at: meal)], mealPlans: ["a": MealCarbFollowUp(rule: nil, source: .ai)], now: meal)
        XCTAssertTrue(result.isEmpty)
    }

    func testMealWithoutANameGetsLaterCarbsFromItsPlan() {
        let result = planned([entry("a", foodType: "🍽️", at: meal)], mealPlans: ["a": MealCarbFollowUp(rule: rule, source: .manual)], now: meal)

        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result.first?.favoriteID)
        XCTAssertEqual(result.first?.mealName, "")
        XCTAssertFalse(result.first!.mealDescription.isEmpty)
    }

    func testAIMealGetsLaterCarbsFromItsPlan() {
        let result = planned([entry("a", foodType: "🍕 Pizza", at: meal)], mealPlans: ["a": MealCarbFollowUp(rule: rule, source: .ai, reason: "Ost og deig")], now: meal)

        XCTAssertEqual(result.first?.mealName, "Pizza")
        XCTAssertEqual(result.first?.source, .ai)
        XCTAssertEqual(result.first?.reason, "Ost og deig")
    }

    func testFavoriteRuleThatIsTheUntouchedSuggestionCountsAsAI() {
        let assessments = ["milk": FavoriteCarbFollowUpAssessment(contentKey: "x", suggestion: rule, reason: "Helmelk")]
        let result = planned([entry("a", foodType: "🥛 Melk", at: meal)], assessments: assessments, now: meal)

        XCTAssertEqual(result.first?.source, .ai)
        XCTAssertEqual(result.first?.reason, "Helmelk")
    }

    // MARK: Suggestions

    func testSuggestionIsRoundedAndKeptInRange() {
        let suggestion = CarbFollowUpPlanner.suggestion(grams: 6.4, delayMinutes: 97, absorptionHours: 3.8, mealCarbs: 30)
        XCTAssertEqual(suggestion, CarbFollowUpRule(carbGrams: 6, absorptionTime: .hours(4), delay: .minutes(90)))
    }

    func testSuggestionIsCappedAtFifteenGramsAndHalfTheMeal() {
        XCTAssertEqual(CarbFollowUpPlanner.suggestion(grams: 40, delayMinutes: 120, absorptionHours: 5, mealCarbs: 100)?.carbGrams, 15)
        XCTAssertEqual(CarbFollowUpPlanner.suggestion(grams: 12, delayMinutes: 120, absorptionHours: 5, mealCarbs: 10)?.carbGrams, 5)
    }

    func testSmallSuggestionIsNoSuggestion() {
        XCTAssertNil(CarbFollowUpPlanner.suggestion(grams: 2.4, delayMinutes: 90, absorptionHours: 4, mealCarbs: 30))
        XCTAssertNil(CarbFollowUpPlanner.suggestion(grams: 8, delayMinutes: 90, absorptionHours: 4, mealCarbs: 4))
        XCTAssertNil(CarbFollowUpPlanner.suggestion(grams: .nan, delayMinutes: 90, absorptionHours: 4, mealCarbs: 30))
    }

    func testSuggestionTimingIsHeldToTheSteppers() {
        let suggestion = CarbFollowUpPlanner.suggestion(grams: 6, delayMinutes: 5, absorptionHours: 20, mealCarbs: 30)
        XCTAssertEqual(suggestion?.delay, CarbFollowUpRule.delayRange.lowerBound)
        XCTAssertEqual(suggestion?.absorptionTime, CarbFollowUpRule.absorptionRange.upperBound)
    }

    func testEstimateReadsLaterCarbs() throws {
        let json = #"{"name":"Havregrøt","emoji":"🥣","carbs_grams":30,"absorption_hours":3,"items":[],"assumptions":[],"confidence":"high","later_carbs":{"grams":6,"delay_minutes":90,"absorption_hours":4,"reason":"Helmelk"}}"#
        let estimate = try JSONDecoder().decode(MealCarbEstimate.self, from: Data(json.utf8))
        XCTAssertEqual(estimate.laterCarbRule, CarbFollowUpRule(carbGrams: 6, absorptionTime: .hours(4), delay: .minutes(90)))
        XCTAssertEqual(estimate.laterCarbs?.reason, "Helmelk")
    }

    func testEstimateWithoutLaterCarbsStillReads() throws {
        let json = #"{"name":"Eple","emoji":"🍎","carbs_grams":10,"absorption_hours":2,"items":[],"assumptions":[],"confidence":"high"}"#
        let estimate = try JSONDecoder().decode(MealCarbEstimate.self, from: Data(json.utf8))
        XCTAssertNil(estimate.laterCarbRule)
    }

    // MARK: Nightscout

    func testNightscoutTreatmentIsNeverCarbs() {
        let followUp = planned([entry("a", foodType: "🥛 Melk", at: meal)], now: meal).first!
        let document = PlannedCarbTreatment.document(for: followUp)

        XCTAssertNil(document["carbs"])
        XCTAssertEqual(document["eventType"] as? String, "Planned Carbs")
        XCTAssertEqual(document["plannedCarbs"] as? Double, 6)
        XCTAssertEqual(document["absorptionTime"] as? Int, 240)
        XCTAssertEqual(document["plannedCarbsID"] as? String, "a")
        XCTAssertEqual(document["foodType"] as? String, "🥛 Melk")
        XCTAssertTrue((document["created_at"] as? String)?.hasSuffix("Z") == true)
        XCTAssertTrue((document["expiresAt"] as? String)?.hasSuffix("Z") == true)
    }

    func testNightscoutFingerprintFollowsTheContent() {
        let followUp = planned([entry("a", foodType: "🥛 Melk", at: meal)], now: meal).first!
        var changed = followUp
        changed.rule.carbGrams = 8

        XCTAssertEqual(PlannedCarbTreatment.fingerprint(of: PlannedCarbTreatment.document(for: followUp)), PlannedCarbTreatment.fingerprint(of: PlannedCarbTreatment.document(for: followUp)))
        XCTAssertNotEqual(PlannedCarbTreatment.fingerprint(of: PlannedCarbTreatment.document(for: followUp)), PlannedCarbTreatment.fingerprint(of: PlannedCarbTreatment.document(for: changed)))
    }

    func testPrunesRecordsOlderThanADay() {
        let now = meal.addingTimeInterval(.hours(30))
        let records = [
            "old": CarbFollowUpRecord(favoriteID: "milk", outcome: .added, date: meal),
            "new": CarbFollowUpRecord(favoriteID: "milk", outcome: .added, date: now),
        ]
        XCTAssertEqual(Array(CarbFollowUpPlanner.pruned(records, now: now).keys), ["new"])
    }
}

final class CarbFollowUpManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private let meal = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var entries: [StoredCarbEntry] = []
    private var glucose: [StoredGlucoseSample] = []
    private var added: [NewCarbEntry] = []

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "CarbFollowUpManagerTests")
        defaults.removePersistentDomain(forName: "CarbFollowUpManagerTests")
        defaults.favoriteFoods = [StoredFavoriteFood(id: "milk", name: "Melk", carbsQuantity: HKQuantity(unit: .gram(), doubleValue: 10), foodType: "🥛", absorptionTime: .hours(2))]
        defaults.carbFollowUpRules = ["milk": .standard]
        entries = [StoredCarbEntry(startDate: meal, quantity: HKQuantity(unit: .gram(), doubleValue: 10), syncIdentifier: "a", foodType: "🥛 Melk")]
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "CarbFollowUpManagerTests")
        super.tearDown()
    }

    private func makeManager() -> CarbFollowUpManager {
        CarbFollowUpManager(
            defaults: defaults,
            now: { [unowned self] in self.now },
            fetchCarbEntries: { [unowned self] start, completion in
                completion(.success(self.entries.filter { $0.startDate >= start }))
            },
            fetchGlucose: { [unowned self] _, completion in
                completion(.success(self.glucose))
            },
            addCarbEntry: { [unowned self] entry, completion in
                self.added.append(entry)
                self.entries.append(StoredCarbEntry(startDate: entry.startDate, quantity: entry.quantity, syncIdentifier: UUID().uuidString, foodType: entry.foodType, absorptionTime: entry.absorptionTime))
                completion(.success(self.entries.last!))
            }
        )
    }

    private func setGlucose(_ mmol: [Double]) {
        glucose = mmol.reversed().enumerated().map { index, value in
            StoredGlucoseSample(
                startDate: now.addingTimeInterval(-TimeInterval.minutes(5) * Double(index)),
                quantity: HKQuantity(unit: .millimolesPerLiter, doubleValue: value)
            )
        }
    }

    private func run(_ manager: CarbFollowUpManager) {
        let done = expectation(description: "runDue")
        manager.runDue { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testAddsTheFollowUpOnceAndOnlyOnce() {
        let manager = makeManager()
        now = meal.addingTimeInterval(.minutes(95))
        setGlucose([7, 7.5, 8, 8.5])

        run(manager)
        run(manager)

        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.quantity.doubleValue(for: .gram()), 6)
        XCTAssertEqual(added.first?.absorptionTime, .minutes(240))
        XCTAssertEqual(added.first?.startDate, now)
        XCTAssertEqual(added.first?.foodType, "🥛 " + followUpName("Melk"))
        XCTAssertTrue(manager.planned.isEmpty)
        XCTAssertEqual(defaults.carbFollowUpRecords["a"]?.outcome, .added)
    }

    func testKeepsWaitingWhileFallingThenAddsWhenItTurns() {
        let manager = makeManager()
        now = meal.addingTimeInterval(.minutes(90))
        setGlucose([9, 8, 7, 6.5])
        run(manager)
        XCTAssertTrue(added.isEmpty)
        XCTAssertEqual(manager.planned.map(\.triggerID), ["a"])

        now = meal.addingTimeInterval(.minutes(120))
        setGlucose([6.2, 6.3, 6.6, 7.1])
        run(manager)
        XCTAssertEqual(added.count, 1)
    }

    func testDropsWhenGlucoseNeverTurns() {
        let manager = makeManager()
        now = meal.addingTimeInterval(.hours(3) - .minutes(1))
        setGlucose([6, 5.5, 5, 4.5])
        run(manager)
        XCTAssertTrue(added.isEmpty)
        XCTAssertNil(defaults.carbFollowUpRecords["a"])

        now = meal.addingTimeInterval(.hours(3) + .minutes(4))
        run(manager)
        XCTAssertTrue(added.isEmpty)
        XCTAssertTrue(manager.planned.isEmpty)
        XCTAssertEqual(defaults.carbFollowUpRecords["a"]?.outcome, .dropped)
    }

    func testCancelledFollowUpIsNeverAdded() {
        let manager = makeManager()
        now = meal.addingTimeInterval(.minutes(30))
        run(manager)
        let followUp = try! XCTUnwrap(manager.planned.first)

        manager.cancel(followUp)
        now = meal.addingTimeInterval(.minutes(95))
        setGlucose([7, 7.5, 8, 8.5])
        run(manager)

        XCTAssertTrue(added.isEmpty)
        XCTAssertEqual(defaults.carbFollowUpRecords["a"]?.outcome, .cancelled)
    }

    func testAddNowSkipsTheConditions() {
        let manager = makeManager()
        now = meal.addingTimeInterval(.minutes(30))
        setGlucose([9, 8, 7, 6])
        run(manager)
        let followUp = try! XCTUnwrap(manager.planned.first)

        let done = expectation(description: "addNow")
        manager.addNow(followUp) { done.fulfill() }
        wait(for: [done], timeout: 2)

        XCTAssertEqual(added.count, 1)
        XCTAssertTrue(manager.planned.isEmpty)
        XCTAssertEqual(defaults.carbFollowUpRecords["a"]?.outcome, .added)
    }

    func testMealPlanWithoutAFavoriteIsAdded() {
        defaults.carbFollowUpRules = [:]
        entries = [StoredCarbEntry(startDate: meal, quantity: HKQuantity(unit: .gram(), doubleValue: 20), syncIdentifier: "b", foodType: "🍕 Pizza")]
        defaults.setCarbFollowUpMealPlan(MealCarbFollowUp(rule: .standard, source: .ai), forMeal: "b", now: meal)
        let manager = makeManager()
        now = meal.addingTimeInterval(.minutes(95))
        setGlucose([7, 7.5, 8, 8.5])
        run(manager)

        XCTAssertEqual(added.first?.foodType, "🍕 " + followUpName("Pizza"))
    }

    func testDeletedMealTakesItsFollowUpWithIt() {
        let manager = makeManager()
        now = meal.addingTimeInterval(.minutes(30))
        run(manager)
        XCTAssertEqual(manager.planned.count, 1)

        entries = []
        now = meal.addingTimeInterval(.minutes(95))
        setGlucose([7, 7.5, 8, 8.5])
        run(manager)

        XCTAssertTrue(added.isEmpty)
        XCTAssertTrue(manager.planned.isEmpty)
    }
}

@MainActor
final class FavoriteCarbFollowUpAssessorTests: XCTestCase {
    private var defaults: UserDefaults!
    private let milk = StoredFavoriteFood(id: "milk", name: "Melk", carbsQuantity: HKQuantity(unit: .gram(), doubleValue: 10), foodType: "🥛", absorptionTime: .hours(2))
    private let suggestion = CarbFollowUpRule(carbGrams: 5, absorptionTime: .hours(4), delay: .minutes(90))

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "FavoriteCarbFollowUpAssessorTests")
        defaults.removePersistentDomain(forName: "FavoriteCarbFollowUpAssessorTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "FavoriteCarbFollowUpAssessorTests")
        super.tearDown()
    }

    private var key: String { FavoriteCarbFollowUpAssessment.contentKey(for: milk) }

    func testEveryFoodIsAssessedOnce() {
        XCTAssertEqual(FavoriteCarbFollowUpAssessor.foodsNeedingAssessment([milk], assessments: [:], rules: [:]).map(\.id), ["milk"])
        XCTAssertTrue(FavoriteCarbFollowUpAssessor.foodsNeedingAssessment([milk], assessments: ["milk": .init(contentKey: key)], rules: [:]).isEmpty)
    }

    func testEditedFoodIsAssessedAgain() {
        XCTAssertEqual(FavoriteCarbFollowUpAssessor.foodsNeedingAssessment([milk], assessments: ["milk": .init(contentKey: "older")], rules: [:]).count, 1)
    }

    func testHandMadeChoicesAreLeftAlone() {
        XCTAssertTrue(FavoriteCarbFollowUpAssessor.foodsNeedingAssessment([milk], assessments: [:], rules: ["milk": .standard]).isEmpty)
        XCTAssertTrue(FavoriteCarbFollowUpAssessor.foodsNeedingAssessment([milk], assessments: ["milk": .init(contentKey: "older", userChanged: true)], rules: [:]).isEmpty)
    }

    func testSuggestionBecomesTheRule() {
        FavoriteCarbFollowUpAssessor.apply(.init(contentKey: key, suggestion: suggestion, reason: "Helmelk"), to: "milk", defaults: defaults)
        XCTAssertEqual(defaults.carbFollowUpRules["milk"], suggestion)
        XCTAssertEqual(defaults.carbFollowUpAssessments["milk"]?.reason, "Helmelk")
    }

    func testNewSuggestionReplacesTheOldOne() {
        FavoriteCarbFollowUpAssessor.apply(.init(contentKey: "older", suggestion: suggestion), to: "milk", defaults: defaults)
        FavoriteCarbFollowUpAssessor.apply(.init(contentKey: key, suggestion: nil), to: "milk", defaults: defaults)
        XCTAssertNil(defaults.carbFollowUpRules["milk"])
    }

    func testSuggestionNeverOverwritesAHandMadeRule() {
        defaults.carbFollowUpRules = ["milk": .standard]
        FavoriteCarbFollowUpAssessor.apply(.init(contentKey: key, suggestion: suggestion), to: "milk", defaults: defaults)
        XCTAssertEqual(defaults.carbFollowUpRules["milk"], .standard)
    }
}
