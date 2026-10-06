//
//  FatProteinBoostTests.swift
//  LoopTests
//
//  The fat and protein boost: which meals get one, when it starts and ends, and what it learns.
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

private let milk = StoredFavoriteFood(id: "milk", name: "Melk", carbsQuantity: HKQuantity(unit: .gram(), doubleValue: 14), foodType: "🥛", absorptionTime: .hours(4))
private let porridge = StoredFavoriteFood(id: "porridge", name: "Havregrøt", carbsQuantity: HKQuantity(unit: .gram(), doubleValue: 20), foodType: "🥣", absorptionTime: .hours(4))
private let smoothie = StoredFavoriteFood(id: "smoothie", name: "Smoothie", carbsQuantity: HKQuantity(unit: .gram(), doubleValue: 12), foodType: "🥤", absorptionTime: .minutes(30))

/// A glass of whole milk (≈ 300 ml): 10 g fat, 10 g protein = 1.3 units.
/// Porridge with butter: 8 g fat, 5 g protein = 0.9 units.
/// A smoothie with yoghurt: 6 g fat, 6 g protein = 0.8 units.
private let assessments: [String: FavoriteNutritionAssessment] = [
    "milk": FavoriteNutritionAssessment(contentKey: "", nutrition: MealNutrition(fatGrams: 10, proteinGrams: 10, carbGrams: 14)),
    "porridge": FavoriteNutritionAssessment(contentKey: "", nutrition: MealNutrition(fatGrams: 8, proteinGrams: 5, carbGrams: 20)),
    "smoothie": FavoriteNutritionAssessment(contentKey: "", nutrition: MealNutrition(fatGrams: 6, proteinGrams: 6, carbGrams: 12)),
]

private func entry(_ id: String, _ food: StoredFavoriteFood, at date: Date) -> StoredCarbEntry {
    StoredCarbEntry(startDate: date, quantity: food.carbsQuantity, syncIdentifier: id, foodType: food.foodType + " " + food.name)
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

final class FatProteinBoostPlannerTests: XCTestCase {
    private let dinner = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let settings = FatProteinBoostSettings.standard

    private func planned(_ entries: [StoredCarbEntry], glucose: [GlucoseValue] = [], records: [String: FatProteinBoostRecord] = [:], declined: [String: Date] = [:], mealNutrition: [String: MealNutrition] = [:], settings: FatProteinBoostSettings = .standard, factor: Double = 1, now: Date) -> [FatProteinBoostPlan] {
        FatProteinBoostPlanner.planned(entries: entries, glucose: glucose, favorites: [milk, porridge, smoothie], assessments: assessments, mealNutrition: mealNutrition, declined: declined, records: records, settings: settings, factor: factor, now: now)
    }

    // MARK: Which meals

    func testPorridgeAndMilkCountTogetherAndAreTimedFromTheMilk() {
        let entries = [entry("a", porridge, at: dinner), entry("b", milk, at: dinner.addingTimeInterval(.minutes(25)))]
        let result = planned(entries, now: dinner.addingTimeInterval(.minutes(30)))

        XCTAssertEqual(result.count, 1)
        let plan = try! XCTUnwrap(result.first)
        XCTAssertEqual(plan.triggerID, "b")
        XCTAssertEqual(plan.mealName, "Havregrøt + Melk")
        XCTAssertEqual(plan.units, 2.22, accuracy: 0.01)
        XCTAssertEqual(plan.earliestStart, dinner.addingTimeInterval(.minutes(25 + 90)))
        XCTAssertEqual(plan.latestStart, plan.earliestStart.addingTimeInterval(.hours(3)))
        XCTAssertEqual(plan.strength, 1.35, accuracy: 0.001) // 1 + 0.15 × 2.22 = 1.33, rounded to 5 %
        XCTAssertEqual(plan.duration, .hours(4))
    }

    func testPorridgeAloneIsBelowTheLimit() {
        XCTAssertTrue(planned([entry("a", porridge, at: dinner)], now: dinner).isEmpty)
    }

    func testFoodWithNothingKnownGetsNothing() {
        let bread = StoredCarbEntry(startDate: dinner, quantity: HKQuantity(unit: .gram(), doubleValue: 15), syncIdentifier: "a", foodType: "🍞 Brød")
        XCTAssertTrue(planned([bread], now: dinner).isEmpty)
    }

    func testFatAndProteinFoundForTheMealWinOverTheFavorite() {
        let nutrition = ["a": MealNutrition(fatGrams: 25, proteinGrams: 20, carbGrams: 20)]
        let plan = planned([entry("a", porridge, at: dinner)], mealNutrition: nutrition, now: dinner).first
        XCTAssertEqual(plan?.units ?? 0, 3.05, accuracy: 0.01)
        XCTAssertEqual(plan?.duration, .hours(5))
    }

    func testSmoothieThatTreatedALowIsLeftOut() {
        // Milk alone is 1.3 units; the smoothie after a low would make it 2.1.
        let entries = [entry("a", milk, at: dinner), entry("b", smoothie, at: dinner.addingTimeInterval(.minutes(40)))]
        let low = glucose([4.6, 4.4, 4.2], endingAt: dinner.addingTimeInterval(.minutes(40)))
        let plan = try! XCTUnwrap(planned(entries, glucose: low, now: dinner.addingTimeInterval(.minutes(45))).first)
        XCTAssertEqual(plan.units, 1.3, accuracy: 0.01)
        XCTAssertEqual(plan.mealName, "Melk")
    }

    func testSmoothieWithoutALowCounts() {
        let entries = [entry("a", milk, at: dinner), entry("b", smoothie, at: dinner.addingTimeInterval(.minutes(40)))]
        let fine = glucose([7, 7.2, 7.4], endingAt: dinner.addingTimeInterval(.minutes(40)))
        XCTAssertEqual(planned(entries, glucose: fine, now: dinner.addingTimeInterval(.minutes(45))).first?.units ?? 0, 2.08, accuracy: 0.01)
    }

    func testMealWithARecordOrTurnedOffIsNotPlannedAgain() {
        let entries = [entry("a", porridge, at: dinner), entry("b", milk, at: dinner.addingTimeInterval(.minutes(20)))]
        for state in [FatProteinBoostRecord.State.active, .skipped, .ended, .merged, .cancelled] {
            let records = ["a": FatProteinBoostRecord(state: state, mealName: "", units: 2, strength: 1.3, date: dinner)]
            XCTAssertTrue(planned(entries, records: records, now: dinner.addingTimeInterval(.minutes(30))).isEmpty, "\(state)")
        }
        XCTAssertFalse(planned(entries, now: dinner.addingTimeInterval(.minutes(30))).isEmpty)
        XCTAssertTrue(planned(entries, declined: ["b": dinner], now: dinner.addingTimeInterval(.minutes(30))).isEmpty)
    }

    func testTurnedOffInSettingsPlansNothing() {
        var off = FatProteinBoostSettings.standard
        off.isEnabled = false
        XCTAssertTrue(planned([entry("a", milk, at: dinner)], settings: off, now: dinner).isEmpty)
    }

    func testMoreThanAnHourApartAreTwoMeals() {
        let entries = [entry("a", milk, at: dinner), entry("b", milk, at: dinner.addingTimeInterval(.minutes(61)))]
        XCTAssertEqual(planned(entries, now: dinner.addingTimeInterval(.minutes(62))).map(\.triggerID), ["a", "b"])
    }

    // MARK: Strength

    func testStrengthFollowsTheUnitsTheFactorAndTheCaps() {
        XCTAssertEqual(FatProteinBoostPlanner.strength(units: 1, settings: settings, factor: 1), 1.15, accuracy: 0.001)
        XCTAssertEqual(FatProteinBoostPlanner.strength(units: 3, settings: settings, factor: 1), 1.45, accuracy: 0.001)
        XCTAssertEqual(FatProteinBoostPlanner.strength(units: 6, settings: settings, factor: 1), 1.5, accuracy: 0.001)
        XCTAssertEqual(FatProteinBoostPlanner.strength(units: 2, settings: settings, factor: 1.5), 1.45, accuracy: 0.001)
        XCTAssertEqual(FatProteinBoostPlanner.strength(units: 1, settings: settings, factor: 0.5), 1.1, accuracy: 0.001)

        var high = settings
        high.maximumStrength = 3
        XCTAssertEqual(FatProteinBoostPlanner.strength(units: 20, settings: high, factor: 2), FatProteinBoostSettings.strengthLimit, accuracy: 0.001)
    }

    // MARK: Starting

    private var plan: FatProteinBoostPlan {
        let entries = [entry("a", porridge, at: dinner), entry("b", milk, at: dinner.addingTimeInterval(.minutes(25)))]
        return planned(entries, now: dinner.addingTimeInterval(.minutes(30))).first!
    }

    func testWaitsUntilItsEarliestStart() {
        let now = plan.earliestStart.addingTimeInterval(-.minutes(5))
        XCTAssertEqual(FatProteinBoostPlanner.decide(plan, glucose: glucose([12, 13, 14], endingAt: now), otherOverrideIsActive: false, settings: settings, now: now), .wait)
    }

    func testStartsWhenHighAndRisingOrLevel() {
        let now = plan.earliestStart.addingTimeInterval(.minutes(10))
        XCTAssertEqual(FatProteinBoostPlanner.decide(plan, glucose: glucose([9, 9.5, 10, 10.5], endingAt: now), otherOverrideIsActive: false, settings: settings, now: now), .start)
        XCTAssertEqual(FatProteinBoostPlanner.decide(plan, glucose: glucose([12, 12, 11.9, 11.9], endingAt: now), otherOverrideIsActive: false, settings: settings, now: now), .start)
    }

    func testWaitsWhileFallingOrBelowTheStart() {
        let now = plan.earliestStart.addingTimeInterval(.minutes(10))
        // The dip after the meal: still high but on its way down.
        XCTAssertEqual(FatProteinBoostPlanner.decide(plan, glucose: glucose([11.3, 10, 8.7, 8.2], endingAt: now), otherOverrideIsActive: false, settings: settings, now: now), .wait)
        XCTAssertEqual(FatProteinBoostPlanner.decide(plan, glucose: glucose([6, 6.5, 7, 7.5], endingAt: now), otherOverrideIsActive: false, settings: settings, now: now), .wait)
    }

    func testWaitsWithoutFreshGlucose() {
        let now = plan.earliestStart.addingTimeInterval(.minutes(30))
        let stale = glucose([10, 11, 12], endingAt: now.addingTimeInterval(-.minutes(20)))
        XCTAssertEqual(FatProteinBoostPlanner.decide(plan, glucose: stale, otherOverrideIsActive: false, settings: settings, now: now), .wait)
    }

    func testNeverReplacesSomeoneElsesOverride() {
        let now = plan.earliestStart.addingTimeInterval(.minutes(10))
        XCTAssertEqual(FatProteinBoostPlanner.decide(plan, glucose: glucose([10, 11, 12], endingAt: now), otherOverrideIsActive: true, settings: settings, now: now), .wait)
    }

    func testSkippedPastItsWindow() {
        let now = plan.latestStart
        XCTAssertEqual(FatProteinBoostPlanner.decide(plan, glucose: glucose([10, 11, 12], endingAt: now), otherOverrideIsActive: false, settings: settings, now: now), .skip)
    }

    // MARK: Running

    private func activeRecord(start: Date, id: UUID) -> FatProteinBoostRecord {
        FatProteinBoostRecord(state: .active, mealName: "Havregrøt + Melk", units: 2.2, strength: 1.35, overrideID: id, start: start, plannedEnd: start.addingTimeInterval(.hours(4)), date: start)
    }

    func testKeepsRunningWhileHighAndEndsOnceDown() {
        let start = plan.earliestStart
        let override = FatProteinBoostPlanner.override(strength: 1.35, duration: .hours(4), start: start)
        let record = activeRecord(start: start, id: override.syncIdentifier)
        let now = start.addingTimeInterval(.hours(1))

        XCTAssertEqual(FatProteinBoostPlanner.decideActive(record, current: override, glucose: glucose([12, 11], endingAt: now), settings: settings, now: now), .keep)
        XCTAssertEqual(FatProteinBoostPlanner.decideActive(record, current: override, glucose: glucose([7.4, 6.9], endingAt: now), settings: settings, now: now), .endNow)
    }

    func testNoticesItFinishedOrWasEndedBySomeoneElse() {
        let start = plan.earliestStart
        let override = FatProteinBoostPlanner.override(strength: 1.35, duration: .hours(4), start: start)
        let record = activeRecord(start: start, id: override.syncIdentifier)
        let high = { (now: Date) in glucose([12], endingAt: now) }

        let later = start.addingTimeInterval(.hours(4) + .minutes(1))
        XCTAssertEqual(FatProteinBoostPlanner.decideActive(record, current: override, glucose: high(later), settings: settings, now: later), .finished)
        XCTAssertEqual(FatProteinBoostPlanner.decideActive(record, current: nil, glucose: high(later), settings: settings, now: later), .finished)

        let soon = start.addingTimeInterval(.hours(1))
        XCTAssertEqual(FatProteinBoostPlanner.decideActive(record, current: nil, glucose: high(soon), settings: settings, now: soon), .cancelled)
        let other = FatProteinBoostPlanner.override(strength: 0.8, duration: .hours(1), start: soon)
        XCTAssertEqual(FatProteinBoostPlanner.decideActive(record, current: other, glucose: high(soon), settings: settings, now: soon), .cancelled)
    }

    func testOverrideKeepsTheScheduledRangeAndIsNamed() {
        let override = FatProteinBoostPlanner.override(strength: 1.3, duration: .hours(3), start: dinner)
        XCTAssertNil(override.settings.targetRange)
        XCTAssertEqual(override.settings.insulinNeedsScaleFactor, 1.3)
        XCTAssertEqual(override.duration, .finite(.hours(3)))
        guard case .preset(let preset) = override.context else { return XCTFail("Not a preset") }
        XCTAssertEqual(preset.symbol, "🧈")
    }

    func testMergingKeepsTheStrongerAndTheLaterEnd() {
        let start = dinner
        let record = FatProteinBoostRecord(state: .active, mealName: "Middag", units: 1.5, strength: 1.2, overrideID: UUID(), start: start, plannedEnd: start.addingTimeInterval(.hours(3)), date: start)
        let now = start.addingTimeInterval(.hours(2))
        var later = plan
        later.mealEnd = start.addingTimeInterval(.minutes(30))
        let merged = FatProteinBoostPlanner.merged(active: record, with: later, now: now)
        XCTAssertEqual(merged.strength, 1.35, accuracy: 0.001)
        XCTAssertEqual(merged.end, now.addingTimeInterval(.hours(4)))
    }

    // MARK: Learning

    private func outcome(_ mmol: [Double], factor: Double = 1) -> FatProteinBoostOutcome? {
        let start = dinner
        let end = start.addingTimeInterval(.hours(3))
        let record = FatProteinBoostRecord(state: .ended, mealName: "Grøt", units: 2, strength: 1.3, start: start, plannedEnd: end, end: end, date: start)
        // One reading every five minutes from the start until two hours after the end.
        let count = Int((end.addingTimeInterval(.hours(2)).timeIntervalSince(start)) / .minutes(5)) + 1
        let values = (0..<count).map { mmol[min($0 * mmol.count / count, mmol.count - 1)] }
        return FatProteinBoostPlanner.outcome(of: record, glucose: glucose(values, endingAt: end.addingTimeInterval(.hours(2))), factor: factor, now: end.addingTimeInterval(.hours(2)))
    }

    func testStayingHighMakesTheNextOneStronger() {
        let result = try! XCTUnwrap(outcome([10, 13, 14, 12, 9, 8, 7]))
        XCTAssertEqual(result.verdict, .high)
        XCTAssertEqual(result.factorAfter, 1.15, accuracy: 0.001)
    }

    func testALowMakesTheNextOneWeakerEvenAfterAHigh() {
        let result = try! XCTUnwrap(outcome([10, 13, 14, 9, 6, 4.5, 3.8]))
        XCTAssertEqual(result.verdict, .low)
        XCTAssertEqual(result.factorAfter, 0.8, accuracy: 0.001)
    }

    func testANightInRangeChangesNothing() {
        let result = try! XCTUnwrap(outcome([10, 9.5, 9, 8, 7, 6.5, 6.5]))
        XCTAssertEqual(result.verdict, .good)
        XCTAssertEqual(result.factorAfter, 1)
    }

    func testTheFactorStaysWithinItsRange() {
        XCTAssertEqual(outcome([13, 14, 14, 14, 14, 13, 13], factor: 1.95)?.factorAfter ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(outcome([8, 6, 5, 3.5, 4, 5, 6], factor: 0.55)?.factorAfter ?? 0, 0.5, accuracy: 0.001)
    }

    func testNothingIsLearnedBeforeTheTwoHoursAfterOrWithTooFewReadings() {
        let start = dinner
        let end = start.addingTimeInterval(.hours(3))
        let record = FatProteinBoostRecord(state: .ended, mealName: "Grøt", units: 2, strength: 1.3, start: start, plannedEnd: end, end: end, date: start)
        XCTAssertNil(FatProteinBoostPlanner.outcome(of: record, glucose: glucose([12, 12, 12], endingAt: end), factor: 1, now: end.addingTimeInterval(.hours(1))))
        XCTAssertNil(FatProteinBoostPlanner.outcome(of: record, glucose: glucose([12, 12, 12], endingAt: end), factor: 1, now: end.addingTimeInterval(.hours(2))))
    }

    // MARK: Carb entry screen

    func testPreviewCountsTheMilkAfterThePorridge() {
        let porridgeEntry = entry("a", porridge, at: dinner)
        let pending = entry("pending", milk, at: dinner.addingTimeInterval(.minutes(20)))
        let preview = FatProteinBoostPlanner.preview(entry: pending, earlier: [porridgeEntry], favorites: [milk, porridge], assessments: assessments, mealNutrition: [:], settings: settings, factor: 1)
        XCTAssertEqual(preview.units, 2.22, accuracy: 0.01)
        XCTAssertEqual(preview.strength ?? 0, 1.35, accuracy: 0.001)
        XCTAssertEqual(preview.source, .favorite)
        XCTAssertEqual(preview.earliestStart, dinner.addingTimeInterval(.minutes(110)))
    }

    func testPreviewOfAFoodWithNothingKnown() {
        let pending = StoredCarbEntry(startDate: dinner, quantity: HKQuantity(unit: .gram(), doubleValue: 10), syncIdentifier: "pending", foodType: "🍞")
        let preview = FatProteinBoostPlanner.preview(entry: pending, earlier: [], favorites: [milk], assessments: assessments, mealNutrition: [:], settings: settings, factor: 1)
        XCTAssertEqual(preview.source, .none)
        XCTAssertNil(preview.strength)
    }
}

final class FatProteinBoostManagerTests: XCTestCase {
    private let dinner = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var defaults: UserDefaults!
    private var now = Date()
    private var entries: [StoredCarbEntry] = []
    private var samples: [StoredGlucoseSample] = []
    private var override: TemporaryScheduleOverride?
    private var enacted: [TemporaryScheduleOverride?] = []

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "FatProteinBoostManagerTests")
        defaults.removePersistentDomain(forName: "FatProteinBoostManagerTests")
        defaults.favoriteFoods = [milk, porridge]
        defaults.favoriteNutritionAssessments = assessments
        entries = [entry("a", porridge, at: dinner), entry("b", milk, at: dinner.addingTimeInterval(.minutes(25)))]
        enacted = []
        override = nil
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "FatProteinBoostManagerTests")
        super.tearDown()
    }

    private func makeManager() -> FatProteinBoostManager {
        FatProteinBoostManager(
            defaults: defaults,
            now: { [unowned self] in self.now },
            fetchCarbEntries: { [unowned self] start, completion in
                completion(.success(self.entries.filter { $0.startDate >= start }))
            },
            fetchGlucose: { [unowned self] _, completion in
                completion(.success(self.samples))
            },
            currentOverride: { [unowned self] in self.override },
            enactOverride: { [unowned self] override in
                self.override = override
                self.enacted.append(override)
            }
        )
    }

    /// Readings every five minutes ending now, appended to the ones before.
    private func addGlucose(_ mmol: [Double]) {
        samples += mmol.reversed().enumerated().map { index, value in
            StoredGlucoseSample(
                startDate: now.addingTimeInterval(-TimeInterval.minutes(5) * Double(index)),
                quantity: HKQuantity(unit: .millimolesPerLiter, doubleValue: value)
            )
        }.reversed()
    }

    private func run(_ manager: FatProteinBoostManager) {
        let done = expectation(description: "runDue")
        manager.runDue { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testStartsOnceWhenGlucoseTurnsUpAndEndsWhenItComesDown() {
        let manager = makeManager()

        // The dip after dinner: waits.
        now = dinner.addingTimeInterval(.minutes(120))
        addGlucose([11, 10, 9, 8.5])
        run(manager)
        XCTAssertTrue(enacted.isEmpty)
        XCTAssertEqual(manager.planned.map(\.triggerID), ["b"])

        // The late rise: starts, and only once.
        now = dinner.addingTimeInterval(.minutes(150))
        addGlucose([8.6, 9.2, 9.9, 10.6])
        run(manager)
        run(manager)
        XCTAssertEqual(enacted.count, 1)
        let started = try! XCTUnwrap(override)
        XCTAssertEqual(started.settings.insulinNeedsScaleFactor ?? 0, 1.35, accuracy: 0.001)
        XCTAssertEqual(started.startDate, now)
        XCTAssertEqual(defaults.fatProteinBoostRecords["b"]?.state, .active)
        XCTAssertTrue(manager.planned.isEmpty)

        // Down below 7: ended.
        now = dinner.addingTimeInterval(.minutes(330))
        addGlucose([8, 7.6, 7.2, 6.8])
        run(manager)
        XCTAssertEqual(enacted.count, 2)
        XCTAssertNil(override)
        XCTAssertEqual(defaults.fatProteinBoostRecords["b"]?.state, .ended)
    }

    func testLeavesAnOverrideStartedByHandAlone() {
        let manager = makeManager()
        override = TemporaryScheduleOverride(context: .custom, settings: TemporaryScheduleOverrideSettings(targetRange: nil, insulinNeedsScaleFactor: 0.8), startDate: dinner, duration: .finite(.hours(6)), enactTrigger: .local, syncIdentifier: UUID())

        now = dinner.addingTimeInterval(.minutes(150))
        addGlucose([10, 11, 12, 13])
        run(manager)
        XCTAssertTrue(enacted.isEmpty)
    }

    func testEndedByHandIsNotStartedAgainOrLearnedFrom() {
        let manager = makeManager()
        now = dinner.addingTimeInterval(.minutes(150))
        addGlucose([10, 11, 12, 13])
        run(manager)
        XCTAssertNotNil(override)

        override = nil // cancelled from LoopFollow
        now = dinner.addingTimeInterval(.minutes(170))
        addGlucose([13, 13, 13, 13])
        run(manager)
        XCTAssertEqual(enacted.count, 1)
        XCTAssertEqual(defaults.fatProteinBoostRecords["b"]?.state, .cancelled)
        XCTAssertEqual(defaults.fatProteinBoostRecords["b"]?.isEvaluated, true)
    }

    func testSkippedWhenGlucoseNeverTurnsUp() {
        let manager = makeManager()
        now = dinner.addingTimeInterval(.minutes(25 + 90 + 180))
        addGlucose([6, 6.2, 6.1, 6])
        run(manager)
        XCTAssertTrue(enacted.isEmpty)
        XCTAssertEqual(defaults.fatProteinBoostRecords["b"]?.state, .skipped)
    }
}
