//
//  PumpDeliveryCheckTests.swift
//  LoopTests
//
//  The pump delivery alert: the model on real Nightscout moments (the same as LoopFollow's),
//  how Loop's doses are read into it, and when the alert is issued.
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

private let oslo = TimeZone(identifier: "Europe/Oslo")!

private func at(_ offset: Int, _ fixture: PumpDeliveryFixtures.Fixture) -> Date {
    fixture.now.addingTimeInterval(TimeInterval(offset))
}

private var sensitivitySchedule: InsulinSensitivitySchedule {
    InsulinSensitivitySchedule(
        unit: .millimolesPerLiter,
        dailyItems: PumpDeliveryFixtures.sensitivityMmol.map { RepeatingScheduleValue(startTime: TimeInterval($0.0), value: $0.1) },
        timeZone: oslo
    )!
}

private var carbRatioSchedule: CarbRatioSchedule {
    CarbRatioSchedule(
        unit: .gram(),
        dailyItems: PumpDeliveryFixtures.carbRatio.map { RepeatingScheduleValue(startTime: TimeInterval($0.0), value: $0.1) },
        timeZone: oslo
    )!
}

private func makeCheck(_ fixture: PumpDeliveryFixtures.Fixture) -> PumpDeliveryCheck {
    PumpDeliveryCheck(
        glucose: fixture.glucose.map { .init(date: at($0.0, fixture), mgdl: Double($0.1)) },
        doses: fixture.doses.map { .init(start: at($0.0, fixture), end: at($0.0, fixture), units: $0.1) },
        carbs: fixture.carbs.map { .init(date: at($0.0, fixture), grams: $0.1, absorption: $0.2 * 60) },
        sensitivity: .init(items: PumpDeliveryFixtures.sensitivityMmol.map { (secondsFromMidnight: $0.0, value: $0.1 * 18) }, timeZone: oslo),
        carbRatio: .init(items: PumpDeliveryFixtures.carbRatio.map { (secondsFromMidnight: $0.0, value: $0.1) }, timeZone: oslo),
        curve: .init(peak: 55 * 60, duration: 6 * 3600, delay: 10 * 60)
    )
}

final class PumpDeliveryCheckTests: XCTestCase {

    // MARK: - Insulin curve

    func testCurveEnds() {
        let curve = PumpDeliveryCheck.InsulinCurve(peak: 55 * 60, duration: 6 * 3600, delay: 10 * 60)
        XCTAssertEqual(curve.remaining(after: 0), 1)
        XCTAssertEqual(curve.remaining(after: 10 * 60), 1)
        XCTAssertEqual(curve.remaining(after: 6 * 3600 + 10 * 60), 0)
        let samples = stride(from: 0.0, through: 6.5 * 3600, by: 300).map(curve.remaining(after:))
        XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 })
    }

    func testCurveMatchesLoopsModel() {
        for preset in [ExponentialInsulinModelPreset.fiasp, .rapidActingChild, .rapidActingAdult] {
            let curve = PumpDeliveryCheck.InsulinCurve(preset)
            XCTAssertEqual(curve.peak, preset.peakActivity)
            XCTAssertEqual(curve.duration, preset.actionDuration)
            XCTAssertEqual(curve.delay, preset.delay)
            for minutes in stride(from: 0.0, through: 400, by: 15) {
                XCTAssertEqual(curve.remaining(after: .minutes(minutes)), preset.percentEffectRemaining(at: .minutes(minutes)), accuracy: 1e-9, "\(preset) at \(minutes) min")
            }
        }
    }

    // MARK: - Real episodes

    func testHistory() throws {
        XCTAssertEqual(PumpDeliveryFixtures.all.filter(\.shouldFire).count, 3)
        for fixture in PumpDeliveryFixtures.all {
            let check = makeCheck(fixture)
            let latest = try XCTUnwrap(check.glucose.last)
            let assessment = try XCTUnwrap(check.assess(at: latest), fixture.name)

            // Same model as the Python one the limits were tuned with.
            XCTAssertEqual(assessment.unexplainedRise, fixture.unexplainedRise, accuracy: 2, fixture.name)
            XCTAssertEqual(assessment.insulinDrop, fixture.insulinDrop, accuracy: 2, fixture.name)

            let fired = check.suspectedFailure(now: fixture.now) != nil
            XCTAssertEqual(fired, fixture.shouldFire, fixture.name)
        }
    }

    /// The same moments through Loop's own schedules: ISF in mmol/L and carb ratio as LoopKit schedules.
    func testHistoryWithLoopSchedules() {
        for fixture in PumpDeliveryFixtures.all {
            var check = makeCheck(fixture)
            check.sensitivity = PumpDeliveryCheck.sensitivity(sensitivitySchedule)
            check.carbRatio = PumpDeliveryCheck.carbRatio(carbRatioSchedule)
            XCTAssertEqual(check.suspectedFailure(now: fixture.now) != nil, fixture.shouldFire, fixture.name)
        }
    }

    // MARK: - Guards

    func testNoAlertOnStaleGlucose() throws {
        let fixture = try XCTUnwrap(PumpDeliveryFixtures.all.first { $0.shouldFire })
        XCTAssertNil(makeCheck(fixture).suspectedFailure(now: fixture.now.addingTimeInterval(15 * 60)))
    }

    func testNoAlertWithGapInReadings() throws {
        let fixture = try XCTUnwrap(PumpDeliveryFixtures.all.first { $0.shouldFire })
        var check = makeCheck(fixture)
        check.glucose.removeAll { (-20 * 60 ... -5 * 60).contains($0.date.timeIntervalSince(fixture.now)) }
        XCTAssertNil(check.suspectedFailure(now: fixture.now))
    }

    func testNoAlertWhenTooLittleInsulin() throws {
        let fixture = try XCTUnwrap(PumpDeliveryFixtures.all.first { $0.shouldFire })
        var check = makeCheck(fixture)
        check.doses = []
        XCTAssertNil(check.suspectedFailure(now: fixture.now))
    }

    // MARK: - Loop's doses

    func testDosesFromLoop() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let now = start.addingTimeInterval(.minutes(50))
        let scheduled = HKQuantity(unit: DoseEntry.unitsPerHour, doubleValue: 0.6)
        let entries = [
            DoseEntry(type: .basal, startDate: start, endDate: start.addingTimeInterval(.minutes(10)), value: 0.6, unit: .unitsPerHour, scheduledBasalRate: scheduled),
            DoseEntry(type: .bolus, startDate: start.addingTimeInterval(.minutes(5)), endDate: start.addingTimeInterval(.minutes(6)), value: 1.5, unit: .units, deliveredUnits: 1.2),
            // 20 min suspended: 0.2 U less than planned.
            DoseEntry(type: .suspend, startDate: start.addingTimeInterval(.minutes(10)), endDate: start.addingTimeInterval(.minutes(30)), value: 0, unit: .units, scheduledBasalRate: scheduled),
            // Double the basal, programmed for 30 min but only 20 of them by now: 0.2 U extra.
            DoseEntry(type: .tempBasal, startDate: start.addingTimeInterval(.minutes(30)), endDate: start.addingTimeInterval(.minutes(60)), value: 1.2, unit: .unitsPerHour, scheduledBasalRate: scheduled),
        ]
        let doses = PumpDeliveryCheck.doses(entries, now: now)
        XCTAssertEqual(doses.count, 3)
        XCTAssertEqual(doses[0], .init(start: start.addingTimeInterval(.minutes(5)), end: start.addingTimeInterval(.minutes(5)), units: 1.2))
        XCTAssertEqual(doses[1].units, -0.2, accuracy: 1e-9)
        XCTAssertEqual(doses[2].end, now)
        XCTAssertEqual(doses[2].units, 0.2, accuracy: 1e-9)
    }

    func testCarbsFromLoop() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [
            StoredCarbEntry(startDate: date, quantity: HKQuantity(unit: .gram(), doubleValue: 20), absorptionTime: .hours(2)),
            StoredCarbEntry(startDate: date, quantity: HKQuantity(unit: .gram(), doubleValue: 10)),
            StoredCarbEntry(startDate: date.addingTimeInterval(.hours(1)), quantity: HKQuantity(unit: .gram(), doubleValue: 10)),
        ]
        let carbs = PumpDeliveryCheck.carbs(entries, defaultAbsorption: .hours(3), now: date.addingTimeInterval(.minutes(30)))
        XCTAssertEqual(carbs, [.init(date: date, grams: 20, absorption: .hours(2)), .init(date: date, grams: 10, absorption: .hours(3))])
    }

    // MARK: - Alert

    func testAlertText() throws {
        let fixture = try XCTUnwrap(PumpDeliveryFixtures.all.first { $0.shouldFire })
        let assessment = try XCTUnwrap(makeCheck(fixture).suspectedFailure(now: fixture.now))
        let alert = PumpDeliveryAlertManager.alert(for: assessment, unit: .millimolesPerLiter)
        XCTAssertEqual(alert.identifier, PumpDeliveryAlertManager.alertIdentifier)
        XCTAssertEqual(alert.interruptionLevel, .timeSensitive)
        XCTAssertEqual(alert.trigger, .immediate)
        XCTAssertTrue(alert.backgroundContent.body.contains(PumpDeliveryText.advice))
    }
}

/// The manager with the fixture moments as its stores.
final class PumpDeliveryAlertManagerTests: XCTestCase {
    private final class Issuer: AlertIssuer {
        var issued: [Alert] = []
        var retracted: [Alert.Identifier] = []
        var onIssue: (() -> Void)?
        func issueAlert(_ alert: Alert) {
            issued.append(alert)
            onIssue?()
        }
        func retractAlert(identifier: Alert.Identifier) { retracted.append(identifier) }
    }

    private var defaults: UserDefaults!
    private let suiteName = "PumpDeliveryAlertManagerTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeManager(_ fixture: PumpDeliveryFixtures.Fixture, issuer: Issuer) -> PumpDeliveryAlertManager {
        let glucose = fixture.glucose.map {
            StoredGlucoseSample(startDate: at($0.0, fixture), quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: Double($0.1)))
        }
        // Each fixture piece as an instant dose, as the model sees boluses.
        let doses = fixture.doses.map {
            DoseEntry(type: .bolus, startDate: at($0.0, fixture), value: $0.1, unit: .units)
        }
        let carbs = fixture.carbs.map {
            StoredCarbEntry(startDate: at($0.0, fixture), quantity: HKQuantity(unit: .gram(), doubleValue: $0.1), absorptionTime: $0.2 * 60)
        }
        return PumpDeliveryAlertManager(
            fetchGlucose: { start, end, completion in completion(.success(glucose.filter { $0.startDate >= start && $0.startDate <= end })) },
            fetchDoses: { start, end, completion in completion(.success(doses.filter { $0.startDate >= start && $0.startDate <= end })) },
            fetchCarbs: { start, end, completion in completion(.success(carbs.filter { $0.startDate >= start && $0.startDate <= end })) },
            sensitivity: { sensitivitySchedule },
            carbRatio: { carbRatioSchedule },
            insulinModel: { ExponentialInsulinModelPreset.fiasp },
            defaultAbsorption: { .hours(3) },
            glucoseUnit: { .millimolesPerLiter },
            alertIssuer: issuer,
            defaults: defaults
        )
    }

    func testCheckReadsTheStores() {
        for fixture in PumpDeliveryFixtures.all {
            let done = expectation(description: fixture.name)
            makeManager(fixture, issuer: Issuer()).check(now: fixture.now) { assessment in
                XCTAssertEqual(assessment != nil, fixture.shouldFire, fixture.name)
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
        }
    }

    func testAlertsOnceAnHour() throws {
        let fixture = try XCTUnwrap(PumpDeliveryFixtures.all.first { $0.shouldFire })
        let issuer = Issuer()
        let manager = makeManager(fixture, issuer: issuer)

        let first = expectation(description: "alert")
        issuer.onIssue = { first.fulfill() }
        manager.checkIfDue(now: fixture.now)
        wait(for: [first], timeout: 5)
        XCTAssertEqual(issuer.issued.first?.identifier, PumpDeliveryAlertManager.alertIdentifier)
        XCTAssertEqual(defaults.pumpDeliveryAlertLast?.issued, fixture.now)

        // Five minutes on, the same readings still meet the limits, but it stays quiet.
        let none = expectation(description: "no second alert")
        none.isInverted = true
        issuer.onIssue = { none.fulfill() }
        manager.checkIfDue(now: fixture.now.addingTimeInterval(.minutes(5)))
        wait(for: [none], timeout: 1)
        XCTAssertEqual(issuer.issued.count, 1)
    }

    func testOnByDefaultAndSwitchedOff() throws {
        XCTAssertTrue(defaults.pumpDeliveryAlertEnabled)

        let fixture = try XCTUnwrap(PumpDeliveryFixtures.all.first { $0.shouldFire })
        let issuer = Issuer()
        let manager = makeManager(fixture, issuer: issuer)
        manager.isEnabled = false
        XCTAssertFalse(defaults.pumpDeliveryAlertEnabled)
        XCTAssertEqual(issuer.retracted, [PumpDeliveryAlertManager.alertIdentifier])

        let none = expectation(description: "no alert")
        none.isInverted = true
        issuer.onIssue = { none.fulfill() }
        manager.checkIfDue(now: fixture.now)
        wait(for: [none], timeout: 1)
        XCTAssertTrue(issuer.issued.isEmpty)
    }

    func testNoAlertAtOrdinaryHighs() {
        let issuer = Issuer()
        for fixture in PumpDeliveryFixtures.all where !fixture.shouldFire {
            let none = expectation(description: fixture.name)
            none.isInverted = true
            issuer.onIssue = { none.fulfill() }
            makeManager(fixture, issuer: issuer).checkIfDue(now: fixture.now)
            wait(for: [none], timeout: 0.5)
        }
        XCTAssertTrue(issuer.issued.isEmpty)
    }
}
