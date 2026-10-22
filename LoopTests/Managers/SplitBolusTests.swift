//
//  SplitBolusTests.swift
//  LoopTests
//
//  The split bolus: how a meal is split, when the rest is offered, and what it learns.
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

/// Readings every five minutes from `start`, one per value.
private func readings(_ mmol: [Double], from start: Date) -> [GlucoseValue] {
    mmol.enumerated().map { index, value in
        SimpleGlucoseValue(startDate: start.addingTimeInterval(.minutes(5) * Double(index)), quantity: HKQuantity(unit: .millimolesPerLiter, doubleValue: value))
    }
}

/// Six hours of readings from `start`, `value(minutes)` each.
private func evening(from start: Date, _ value: (Double) -> Double) -> [GlucoseValue] {
    readings(stride(from: 0.0, through: 360, by: 5).map(value), from: start)
}

final class SplitBolusPlannerTests: XCTestCase {
    private let milkTime = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let settings = SplitBolusSettings.standard

    private func suggestion(carbs: Double = 14, calibration: SplitBolusCalibration = SplitBolusCalibration(), basis: SplitBolusHistoryBasis? = nil, carbRatio: Double? = 15, share: Double? = nil, delay: TimeInterval? = nil) -> SplitBolusSuggestion {
        SplitBolusPlanner.suggestion(carbs: carbs, foodType: "🥛🍼 Melk", mealDate: milkTime, settings: settings, calibration: calibration, basis: basis, carbRatio: carbRatio, chosenShare: share, chosenDelay: delay)!
    }

    private func plan(_ state: SplitBolusPlan.State = .waiting, givenAfter: TimeInterval? = nil) -> SplitBolusPlan {
        var plan = SplitBolusPlanner.plan(from: suggestion(), nowEntryID: "now", laterCarbRatio: 15, id: "p", now: milkTime)
        plan.state = state
        if let givenAfter {
            plan.givenAt = milkTime.addingTimeInterval(givenAfter)
        }
        return plan
    }

    // MARK: The split

    func testMilkSplitsFiftyFiveFortyFiveWithTheRestAfterTwoHours() {
        let split = suggestion()
        XCTAssertEqual(split.nowShare, 0.55)
        XCTAssertEqual(split.nowCarbs, 8) // 7.7
        XCTAssertEqual(split.laterCarbs, 6)
        XCTAssertEqual(split.delay, .hours(2))
        XCTAssertEqual(split.due, milkTime.addingTimeInterval(.hours(2)))
        XCTAssertEqual(split.delaySource, .standard)
        XCTAssertEqual(split.nowUnits!, 8 / 15, accuracy: 0.001)
        XCTAssertEqual(split.laterUnits!, 0.4, accuracy: 0.001)
        XCTAssertEqual(split.mealName, "Melk")
    }

    func testNoCarbsNoSplit() {
        XCTAssertNil(SplitBolusPlanner.suggestion(carbs: 0, foodType: nil, mealDate: milkTime, settings: settings, calibration: SplitBolusCalibration(), basis: nil, carbRatio: 15))
    }

    func testWithoutACarbRatioThereAreNoUnits() {
        let split = suggestion(carbRatio: nil)
        XCTAssertNil(split.nowUnits)
        XCTAssertNil(split.laterUnits)
    }

    func testHistoryTimesTheRestHalfAnHourBeforeTheRise() {
        let basis = SplitBolusHistoryBasis(count: 12, medianRiseStart: .minutes(160), medianPeak: .hours(4), earlyLows: 3)
        let split = suggestion(basis: basis)
        XCTAssertEqual(split.delay, .minutes(135))
        XCTAssertEqual(split.delaySource, .history)
    }

    func testTooFewServingsSayNothingAboutTime() {
        let basis = SplitBolusHistoryBasis(count: 3, medianRiseStart: .minutes(200), medianPeak: .hours(4), earlyLows: 0)
        XCTAssertEqual(suggestion(basis: basis).delaySource, .standard)
    }

    func testLearnedBeatsHistoryAndChosenBeatsLearned() {
        let basis = SplitBolusHistoryBasis(count: 12, medianRiseStart: .minutes(160), medianPeak: .hours(4), earlyLows: 3)
        var calibration = SplitBolusCalibration()
        calibration.delay = .minutes(105)
        calibration.nowShare = 0.5
        let learned = suggestion(calibration: calibration, basis: basis)
        XCTAssertEqual(learned.delay, .minutes(105))
        XCTAssertEqual(learned.nowShare, 0.5)
        XCTAssertEqual(learned.delaySource, .learned)

        let chosen = suggestion(calibration: calibration, basis: basis, share: 0.7, delay: .minutes(150))
        XCTAssertEqual(chosen.delay, .minutes(150))
        XCTAssertEqual(chosen.nowShare, 0.7)
        XCTAssertEqual(chosen.delaySource, .chosen)
    }

    func testLearnedExtraGoesOnTheRest() {
        var calibration = SplitBolusCalibration()
        calibration.extra = 0.2
        let split = suggestion(calibration: calibration)
        XCTAssertEqual(split.nowCarbs, 8)
        XCTAssertEqual(split.laterCarbs, 7) // 6 × 1.2 = 7.2
    }

    func testValuesStayWithinTheirLimits() {
        let split = suggestion(share: 0.95, delay: .hours(5))
        XCTAssertEqual(split.nowShare, 0.8)
        // No real upper limit on the rest: five hours stays five hours.
        XCTAssertEqual(split.delay, .hours(5))
        XCTAssertEqual(suggestion(delay: .hours(30)).delay, .hours(12))
        XCTAssertEqual(suggestion(delay: .minutes(20)).delay, .minutes(90))
    }

    func testTheRestIsItsOwnFood() {
        let entry = plan().laterEntry(at: milkTime.addingTimeInterval(.hours(2)))
        XCTAssertEqual(entry.quantity.doubleValue(for: .gram()), 6)
        XCTAssertEqual(entry.absorptionTime, SplitBolusSettings.laterAbsorptionTime)
        XCTAssertEqual(CarbFoodLabel(foodType: entry.foodType).emoji, "🥛🍼")
        XCTAssertFalse(SplitBolusPlanner.isSameFood(entry.foodType, as: "🥛🍼 Melk"))
        XCTAssertTrue(SplitBolusPlanner.isSameFood("🥛🍼 Melk", as: "🥛🍼 melk"))
        XCTAssertTrue(SplitBolusPlanner.isSameFood("🥛🍼", as: "🥛🍼 Melk"))
        XCTAssertFalse(SplitBolusPlanner.isSameFood("🥣 Havregrøt", as: "🥛🍼 Melk"))
    }

    // MARK: History

    func testHistoryFindsTheRiseThePeakAndEarlyLows() {
        var treatments: [NightscoutTreatment] = []
        var glucose: [NightscoutGlucoseReading] = []
        for day in 1...6 {
            let date = milkTime.addingTimeInterval(-.hours(24 * Double(day)))
            treatments.append(NightscoutTreatment(date: date, carbs: 14, insulin: nil, foodType: "🥛🍼 Melk", isAutomatic: false))
            // Flat at 7 for two hours (a dip to 3.8 on two evenings), rising from 2½ hours, highest at 4.
            for minutes in stride(from: 0.0, through: 360, by: 5) {
                let mmol: Double
                if minutes < 150 { mmol = (day <= 2 && minutes == 60) ? 3.8 : 7 }
                else if minutes <= 240 { mmol = 7 + (minutes - 150) / 90 * 5 }
                else { mmol = 12 - (minutes - 240) / 120 * 4 }
                glucose.append(NightscoutGlucoseReading(date: date.addingTimeInterval(.minutes(minutes)), mgdl: mmol * 18))
            }
        }
        // Another food at the same time does not count.
        treatments.append(NightscoutTreatment(date: milkTime.addingTimeInterval(-.hours(24 * 7)), carbs: 20, insulin: nil, foodType: "🥣 Havregrøt", isAutomatic: false))

        let basis = SplitBolusPlanner.historyBasis(foodType: "🥛🍼 Melk", mealDate: milkTime, treatments: treatments, glucose: glucose)!
        XCTAssertEqual(basis.count, 6)
        XCTAssertEqual(basis.earlyLows, 2)
        XCTAssertEqual(basis.medianPeak, .hours(4))
        // 1.5 mmol/L over 7 is reached 27 minutes into the rise, at the next reading after it.
        XCTAssertEqual(basis.medianRiseStart!, .minutes(180), accuracy: .minutes(5))
        XCTAssertEqual(SplitBolusPlanner.delay(from: basis), .minutes(150))
    }

    func testHistoryOnlyCountsTheSameTimeOfDay() {
        let morning = milkTime.addingTimeInterval(-.hours(24 + 8))
        let treatments = [NightscoutTreatment(date: morning, carbs: 14, insulin: nil, foodType: "🥛🍼 Melk", isAutomatic: false)]
        let glucose = stride(from: 0.0, through: 360, by: 5).map { NightscoutGlucoseReading(date: morning.addingTimeInterval(.minutes($0)), mgdl: 130) }
        XCTAssertNil(SplitBolusPlanner.historyBasis(foodType: "🥛🍼 Melk", mealDate: milkTime, treatments: treatments, glucose: glucose))
    }

    // MARK: When the rest is due

    private func recent(_ mmol: [Double], endingAt end: Date) -> [GlucoseValue] {
        readings(mmol, from: end.addingTimeInterval(-.minutes(5) * Double(mmol.count - 1)))
    }

    func testNotDueYetWaits() {
        let now = milkTime.addingTimeInterval(.minutes(110))
        XCTAssertEqual(SplitBolusPlanner.decide(plan(), glucose: recent([8, 8.5, 9, 9.2], endingAt: now), now: now), .wait)
    }

    func testDueWithGlucoseFitIsOffered() {
        let now = milkTime.addingTimeInterval(.minutes(121))
        XCTAssertEqual(SplitBolusPlanner.decide(plan(), glucose: recent([8, 8.5, 9, 9.2], endingAt: now), now: now), .notify)
    }

    func testDueWithoutGlucoseIsStillOffered() {
        let now = milkTime.addingTimeInterval(.minutes(121))
        XCTAssertEqual(SplitBolusPlanner.decide(plan(), glucose: [], now: now), .notify)
    }

    func testLowWaitsOnceThenSkips() {
        let now = milkTime.addingTimeInterval(.minutes(121))
        XCTAssertEqual(SplitBolusPlanner.decide(plan(), glucose: recent([5.2, 5, 4.9, 4.8], endingAt: now), now: now), .postpone)

        var postponed = plan(.postponed)
        postponed.due = now.addingTimeInterval(SplitBolusPlanner.postponement)
        let later = postponed.due.addingTimeInterval(.minutes(1))
        XCTAssertEqual(SplitBolusPlanner.decide(postponed, glucose: recent([4.8, 4.7, 4.6, 4.6], endingAt: later), now: later), .skip)
        XCTAssertEqual(SplitBolusPlanner.decide(postponed, glucose: recent([5, 5.5, 6, 6.4], endingAt: later), now: later), .notify)
    }

    func testFallingFastWaitsEvenInRange() {
        let now = milkTime.addingTimeInterval(.minutes(121))
        XCTAssertEqual(SplitBolusPlanner.decide(plan(), glucose: recent([9.5, 8.8, 8.2, 7.6], endingAt: now), now: now), .postpone)
    }

    func testAnUnloggedRestExpires() {
        let stillOpen = milkTime.addingTimeInterval(.hours(7))
        XCTAssertEqual(SplitBolusPlanner.decide(plan(.notified), glucose: [], now: stillOpen), .wait)
        let now = milkTime.addingTimeInterval(.hours(8) + .minutes(1))
        XCTAssertEqual(SplitBolusPlanner.decide(plan(.notified), glucose: [], now: now), .expire)
        XCTAssertEqual(SplitBolusPlanner.decide(plan(.given), glucose: [], now: now), .wait)
    }

    // MARK: Learning

    private func outcome(_ plan: SplitBolusPlan, calibration: SplitBolusCalibration = SplitBolusCalibration(), _ value: (Double) -> Double) -> SplitBolusOutcome? {
        SplitBolusPlanner.outcome(of: plan, glucose: evening(from: milkTime, value), calibration: calibration, settings: settings, now: milkTime.addingTimeInterval(.hours(6) + .minutes(5)))
    }

    func testALateRestIsLearnedFromThreeHoursAfterIt() {
        var late = plan(.given, givenAfter: .hours(5))
        late.delay = .hours(5)
        late.due = milkTime.addingTimeInterval(.hours(5))
        let glucose = readings(stride(from: 0.0, through: 480, by: 5).map { $0 >= 300 && $0 <= 330 ? 3.8 : 7 }, from: milkTime)
        XCTAssertEqual(SplitBolusPlanner.outcomeEnd(of: late), milkTime.addingTimeInterval(.hours(8)))
        XCTAssertNil(SplitBolusPlanner.outcome(of: late, glucose: glucose, calibration: SplitBolusCalibration(), settings: settings, now: milkTime.addingTimeInterval(.hours(7))))
        let result = SplitBolusPlanner.outcome(of: late, glucose: glucose, calibration: SplitBolusCalibration(), settings: settings, now: milkTime.addingTimeInterval(.hours(8) + .minutes(5)))!
        // Low after the late rest: the rest goes another 15 minutes later, past the old 3-hour limit.
        XCTAssertEqual(result.lowestAfterRestMgdl!, 3.8 * 18.0182, accuracy: 0.5)
        XCTAssertEqual(result.delayAfter, .minutes(315))
    }

    func testNothingIsLearnedBeforeSixHours() {
        XCTAssertNil(SplitBolusPlanner.outcome(of: plan(.given, givenAfter: .hours(2)), glucose: evening(from: milkTime) { _ in 7 }, calibration: SplitBolusCalibration(), settings: settings, now: milkTime.addingTimeInterval(.hours(5))))
    }

    func testAGoodEveningChangesNothing() {
        let result = outcome(plan(.given, givenAfter: .hours(2))) { _ in 7 }!
        XCTAssertFalse(result.changed)
    }

    func testAnEarlyLowGivesLessNow() {
        let result = outcome(plan(.given, givenAfter: .hours(2))) { $0 == 60 ? 3.8 : 7 }!
        XCTAssertEqual(result.nowShareAfter, 0.5)
        XCTAssertEqual(result.delayAfter, .hours(2))
    }

    func testStayingHighAddsExtraOnTheRest() {
        let result = outcome(plan(.given, givenAfter: .hours(2))) { $0 >= 180 && $0 <= 280 ? 11.5 : 7 }!
        XCTAssertEqual(result.extraAfter, 0.1)
        XCTAssertEqual(result.nowShareAfter, 0.55)
    }

    func testALowAfterTheRestMovesItLaterOrTakesExtraOff() {
        let low: (Double) -> Double = { $0 == 200 ? 3.7 : 7 }
        XCTAssertEqual(outcome(plan(.given, givenAfter: .hours(2)), low)!.delayAfter, .minutes(135))

        var calibration = SplitBolusCalibration()
        calibration.extra = 0.2
        let withExtra = outcome(plan(.given, givenAfter: .hours(2)), calibration: calibration, low)!
        XCTAssertEqual(withExtra.extraAfter, 0.1)
        XCTAssertEqual(withExtra.delayAfter, .hours(2))
    }

    func testARiseBeforeTheRestBringsItEarlier() {
        // Up from 6 to 8.5 by the time the rest was logged at 2 hours.
        let result = outcome(plan(.given, givenAfter: .hours(2))) { $0 < 90 ? 6 : $0 <= 120 ? 6 + ($0 - 90) / 30 * 2.5 : 8.5 }!
        XCTAssertTrue(result.roseBeforeRest)
        XCTAssertEqual(result.delayAfter, .minutes(105))
    }

    func testWithoutTheRestOnlyTheEarlyPartIsLearnedFrom() {
        let result = outcome(plan(.skipped)) { $0 == 60 ? 3.8 : $0 >= 180 ? 12 : 7 }!
        XCTAssertFalse(result.restWasGiven)
        XCTAssertEqual(result.nowShareAfter, 0.5)
        XCTAssertEqual(result.extraAfter, 0)
    }

    func testCalledOffSplitsTeachNothing() {
        XCTAssertNil(outcome(plan(.cancelled)) { _ in 3 })
    }

    func testOnlyMovedValuesBecomeLearned() {
        let unchanged = SplitBolusPlanner.applying(outcome(plan(.given, givenAfter: .hours(2))) { _ in 7 }!, to: SplitBolusCalibration())
        XCTAssertNil(unchanged.nowShare)
        XCTAssertNil(unchanged.delay)
        XCTAssertEqual(unchanged.outcomes.count, 1)

        let lower = SplitBolusPlanner.applying(outcome(plan(.given, givenAfter: .hours(2))) { $0 == 60 ? 3.8 : 7 }!, to: SplitBolusCalibration())
        XCTAssertEqual(lower.nowShare, 0.5)
        XCTAssertNil(lower.delay)
    }

    func testLearningStaysWithinLimits() {
        var calibration = SplitBolusCalibration()
        calibration.nowShare = 0.4
        let result = outcome(plan(.given, givenAfter: .hours(2)), calibration: calibration) { $0 == 60 ? 3.8 : 7 }!
        XCTAssertEqual(result.nowShareAfter, 0.4)
    }
}

final class SplitBolusManagerTests: XCTestCase {
    private let milkTime = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var defaults: UserDefaults!
    private var now: Date!
    private var glucose: [GlucoseValue] = []
    private var carbs: [SplitBolusPlanner.LoggedCarb] = []
    private var sent: [UNNotificationRequest] = []
    private var removed: [String] = []
    private var manager: SplitBolusManager!

    override func setUp() {
        defaults = UserDefaults(suiteName: "SplitBolusManagerTests")
        defaults.removePersistentDomain(forName: "SplitBolusManagerTests")
        now = milkTime
        sent = []
        removed = []
        carbs = []
        manager = SplitBolusManager(
            defaults: defaults,
            now: { self.now },
            fetchGlucose: { start, completion in
                completion(.success(self.glucose.filter { $0.startDate >= start }.map {
                    StoredGlucoseSample(startDate: $0.startDate, quantity: $0.quantity)
                }))
            },
            fetchCarbs: { start, completion in
                completion(.success(self.carbs.filter { $0.date >= start }))
            },
            carbRatio: { _ in 15 },
            history: { NightscoutHistory() },
            notify: { self.sent.append($0) },
            removeNotifications: { self.removed += $0 }
        )
    }

    private func run() async {
        let done = expectation(description: "run")
        manager.runDue { done.fulfill() }
        await fulfillment(of: [done], timeout: 1)
    }

    private func XCTUnwrapAsync<T>(_ value: T?) async throws -> T {
        try XCTUnwrap(value)
    }

    func testTheRestIsOfferedOnceWhenDueAndLearnedFromAfterSixHours() async throws {
        let split = try await XCTUnwrapAsync(await manager.suggestion(carbs: 14, foodType: "🥛🍼 Melk", mealDate: milkTime))
        manager.add(split, nowEntryID: "now")
        XCTAssertEqual(manager.openPlans.count, 1)

        glucose = evening(from: milkTime) { _ in 7 }
        now = milkTime.addingTimeInterval(.minutes(100))
        await run()
        XCTAssertTrue(sent.isEmpty)

        now = milkTime.addingTimeInterval(.minutes(122))
        await run()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].content.userInfo[SplitBolusManager.planIDUserInfoKey] as? String, manager.dueRest?.id)
        await run()
        XCTAssertEqual(sent.count, 1, "Offered once")

        let planID = try XCTUnwrap(manager.dueRest?.id)
        manager.markGiven(planID: planID, entryID: "rest")
        XCTAssertNil(manager.dueRest)
        XCTAssertTrue(removed.contains(SplitBolusManager.notificationPrefix + planID))

        // Rising past 10 for two hours later in the evening.
        glucose = evening(from: milkTime) { $0 >= 180 && $0 <= 300 ? 11 : 7 }
        now = milkTime.addingTimeInterval(.hours(6) + .minutes(5))
        await run()
        let calibration = defaults.splitBolusCalibration
        XCTAssertEqual(calibration.extra, 0.1)
        XCTAssertEqual(calibration.outcomes.count, 1)
        XCTAssertTrue(defaults.splitBolusPlans.allSatisfy(\.isEvaluated))
    }

    func testACalledOffRestIsNeverOffered() async throws {
        let split = try await XCTUnwrapAsync(await manager.suggestion(carbs: 14, foodType: "🥛🍼 Melk", mealDate: milkTime))
        manager.add(split, nowEntryID: "now")
        manager.cancel(planID: try XCTUnwrap(manager.openPlans.first?.id))
        glucose = evening(from: milkTime) { _ in 8 }
        now = milkTime.addingTimeInterval(.minutes(125))
        await run()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(manager.openPlans.isEmpty)
    }

    func testARestSentFromLoopFollowIsTakenAsGiven() async throws {
        let split = try await XCTUnwrapAsync(await manager.suggestion(carbs: 14, foodType: "🥛🍼 Melk", mealDate: milkTime))
        manager.add(split, nowEntryID: "now")
        glucose = evening(from: milkTime) { _ in 7 }
        now = milkTime.addingTimeInterval(.minutes(122))
        await run()
        let planID = try XCTUnwrap(manager.dueRest?.id)
        XCTAssertEqual(sent.count, 1)

        let restFoodType = try XCTUnwrap(manager.plan(withID: planID)?.restFoodType)
        carbs = [
            .init(id: "now", foodType: "🥛🍼 Melk", date: milkTime),
            .init(id: "remote", foodType: restFoodType, date: milkTime.addingTimeInterval(.minutes(130))),
        ]
        now = milkTime.addingTimeInterval(.minutes(132))
        await run()

        let plan = try XCTUnwrap(manager.plan(withID: planID))
        XCTAssertEqual(plan.state, .given)
        XCTAssertEqual(plan.laterEntryID, "remote")
        XCTAssertEqual(plan.givenAt, milkTime.addingTimeInterval(.minutes(130)), "Learned from when it was eaten")
        XCTAssertNil(manager.dueRest)
        XCTAssertTrue(removed.contains(SplitBolusManager.notificationPrefix + planID), "The offer on the phone goes away")
    }

    func testARestSentBeforeItIsDueIsNeverOffered() async throws {
        let split = try await XCTUnwrapAsync(await manager.suggestion(carbs: 14, foodType: "🥛🍼 Melk", mealDate: milkTime))
        manager.add(split, nowEntryID: "now")
        glucose = evening(from: milkTime) { _ in 7 }
        carbs = [.init(id: "remote", foodType: "🥛🍼 Melk " + SplitBolusPlanner.restSuffix, date: milkTime.addingTimeInterval(.minutes(100)))]
        now = milkTime.addingTimeInterval(.minutes(122))
        await run()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(defaults.splitBolusPlans.first?.state, .given)
    }

    func testLowGlucoseWaitsHalfAnHourThenSkips() async throws {
        let split = try await XCTUnwrapAsync(await manager.suggestion(carbs: 14, foodType: "🥛🍼 Melk", mealDate: milkTime))
        manager.add(split, nowEntryID: "now")
        glucose = evening(from: milkTime) { _ in 4.6 }
        now = milkTime.addingTimeInterval(.minutes(121))
        await run()
        XCTAssertEqual(manager.openPlans.first?.state, .postponed)
        XCTAssertNil(sent.last?.content.userInfo[SplitBolusManager.planIDUserInfoKey], "The wait notice offers nothing to log")

        now = milkTime.addingTimeInterval(.minutes(152))
        await run()
        XCTAssertTrue(manager.openPlans.isEmpty)
        XCTAssertEqual(defaults.splitBolusPlans.first?.state, .skipped)
        XCTAssertEqual(sent.count, 2)
    }
}
