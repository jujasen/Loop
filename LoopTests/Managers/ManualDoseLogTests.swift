//
//  ManualDoseLogTests.swift
//  LoopTests
//
//  Which doses stop a remote bolus, and which make the bolus screen warn.
//

import LoopKit
import XCTest
@testable import Loop

final class ManualDoseLogTests: XCTestCase {
    private var defaults: UserDefaults!
    private var log: ManualDoseLog!
    private let suite = "ManualDoseLogTests"

    /// 20 November 2026 at 22:17 UTC, the evening two corrections came two minutes apart.
    private let now = Date(timeIntervalSince1970: 1_795_385_820)

    private func minutes(_ value: Double) -> Date {
        now.addingTimeInterval(value * 60)
    }

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        log = ManualDoseLog(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: - A remote bolus

    func testRemoteBolusIsStoppedByADoseOnThePhoneTheSenderHadNotSeen() throws {
        let phone = try log.began(units: 0.3, source: .phone, at: minutes(-2))
        log.finished(phone, error: nil)

        // LoopFollow last saw a dose twenty minutes ago.
        XCTAssertThrowsError(try log.began(units: 0.5, source: .remote, knownDosesUntil: minutes(-20), at: now)) { error in
            guard let stopped = error as? RemoteBolusStopped else { return XCTFail("\(error)") }
            XCTAssertEqual(stopped.units, 0.5)
            XCTAssertEqual(stopped.doses.map(\.units), [0.3])
            XCTAssertEqual(stopped.doses.map(\.source), [.phone])
        }
        // Nothing was recorded for the stopped bolus.
        XCTAssertEqual(log.doses.map(\.units), [0.3])
    }

    func testRemoteBolusGoesThroughWhenTheSenderHadSeenTheDose() throws {
        let phone = try log.began(units: 0.3, source: .phone, at: minutes(-10))
        log.finished(phone, error: nil)

        // Nightscout shows a dose a few seconds after it was requested here.
        XCTAssertNoThrow(try log.began(units: 0.5, source: .remote, knownDosesUntil: minutes(-10).addingTimeInterval(6), at: now))
        XCTAssertEqual(log.doses.map(\.source), [.phone, .remote])
    }

    func testTheSendersTimeMayBeTheDosesOwnCutToMilliseconds() throws {
        let requested = minutes(-10).addingTimeInterval(0.1239)
        log.finished(try log.began(units: 0.3, source: .phone, at: requested), error: nil)

        // What LoopFollow read from the uploaded log and sent back.
        let text = ManualDoseLogNightscout.formatter.string(from: requested)
        let known = try XCTUnwrap(ManualDoseLogNightscout.formatter.date(from: text))
        XCTAssertNoThrow(try log.began(units: 0.5, source: .remote, knownDosesUntil: known, at: now))

        // A second before the dose is not knowing of it.
        log.finished(try log.began(units: 0.2, source: .phone, at: minutes(-1)), error: nil)
        XCTAssertThrowsError(try log.began(units: 0.5, source: .remote, knownDosesUntil: minutes(-1).addingTimeInterval(-1), at: now.addingTimeInterval(1)))
    }

    func testADoseStillBeingSentToThePumpStopsTheRemoteBolusToo() throws {
        // Requested on the phone a second ago; the pump has not answered yet.
        try log.began(units: 0.3, source: .phone, at: now.addingTimeInterval(-1))
        XCTAssertThrowsError(try log.began(units: 0.5, source: .remote, knownDosesUntil: minutes(-20), at: now))
    }

    func testADoseThePumpRefusedDoesNotStopARemoteBolus() throws {
        let phone = try log.began(units: 0.3, source: .phone, at: minutes(-2))
        log.finished(phone, error: PumpManagerError.deviceState(nil))
        XCTAssertTrue(log.doses.isEmpty)
        XCTAssertNoThrow(try log.began(units: 0.5, source: .remote, knownDosesUntil: minutes(-20), at: now))
    }

    func testADoseWithALostAnswerStillStopsARemoteBolus() throws {
        let phone = try log.began(units: 0.3, source: .phone, at: minutes(-2))
        log.finished(phone, error: PumpManagerError.uncertainDelivery)
        XCTAssertEqual(log.doses.count, 1)
        XCTAssertThrowsError(try log.began(units: 0.5, source: .remote, knownDosesUntil: minutes(-20), at: now))
    }

    func testAnOldDoseDoesNotStopARemoteBolus() throws {
        let phone = try log.began(units: 0.3, source: .phone, at: minutes(-181))
        log.finished(phone, error: nil)
        XCTAssertNoThrow(try log.began(units: 0.5, source: .remote, knownDosesUntil: minutes(-600), at: now))
    }

    func testASenderThatSaysNothingIsNotChecked() throws {
        let phone = try log.began(units: 0.3, source: .phone, at: minutes(-2))
        log.finished(phone, error: nil)
        XCTAssertNoThrow(try log.began(units: 0.5, source: .remote, knownDosesUntil: nil, at: now))
    }

    func testTheEveningWatchsDoseStopsARemoteBolusAndIsNamed() throws {
        let watch = try log.began(units: 0.25, source: .eveningWatch, at: minutes(-4))
        log.finished(watch, error: nil)
        XCTAssertThrowsError(try log.began(units: 0.5, source: .remote, knownDosesUntil: minutes(-30), at: now)) { error in
            let details = (error as? RemoteBolusStopped)?.remoteActionDetails
            XCTAssertEqual(details?["reason"] as? String, "unknownDoses")
            let doses = details?["doses"] as? [[String: Any]]
            XCTAssertEqual(doses?.count, 1)
            XCTAssertEqual(doses?.first?["source"] as? String, "eveningWatch")
            XCTAssertEqual(doses?.first?["units"] as? Double, 0.25)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(details ?? [:]))
        }
    }

    func testEveryUnknownDoseIsListedOldestFirst() throws {
        log.finished(try log.began(units: 0.2, source: .phone, at: minutes(-9)), error: nil)
        log.finished(try log.began(units: 0.5, source: .phone, at: minutes(-3)), error: nil)
        XCTAssertThrowsError(try log.began(units: 0.3, source: .remote, knownDosesUntil: minutes(-15), at: now)) { error in
            XCTAssertEqual((error as? RemoteBolusStopped)?.doses.map(\.units), [0.2, 0.5])
        }
    }

    // MARK: - The bolus screen

    func testTheBolusScreenWarnsAfterARemoteBolusButNotAfterItsOwn() throws {
        log.finished(try log.began(units: 0.4, source: .phone, at: minutes(-3)), error: nil)
        XCTAssertNil(log.fromElsewhere(now: now))

        log.finished(try log.began(units: 0.5, source: .remote, at: minutes(-2)), error: nil)
        XCTAssertEqual(log.fromElsewhere(now: now)?.units, 0.5)
        XCTAssertEqual(log.fromElsewhere(now: now)?.source, .remote)
    }

    func testTheWarningGoesAfterHalfAnHour() throws {
        log.finished(try log.began(units: 0.5, source: .remote, at: minutes(-29)), error: nil)
        XCTAssertNotNil(log.fromElsewhere(now: now))
        XCTAssertNil(log.fromElsewhere(now: minutes(2)))
    }

    func testTheNewestDoseFromElsewhereIsTheOneShown() throws {
        log.finished(try log.began(units: 0.25, source: .eveningWatch, at: minutes(-20)), error: nil)
        log.finished(try log.began(units: 0.5, source: .remote, at: minutes(-5)), error: nil)
        XCTAssertEqual(log.fromElsewhere(now: now)?.units, 0.5)
    }

    // MARK: - Storage and Nightscout

    func testTheLogSurvivesARestartAndForgetsAfterADay() throws {
        log.finished(try log.began(units: 0.3, source: .phone, at: minutes(-25 * 60)), error: nil)
        log.finished(try log.began(units: 0.5, source: .remote, at: minutes(-5)), error: nil)

        let restarted = ManualDoseLog(defaults: defaults)
        XCTAssertEqual(restarted.doses.map(\.units), [0.5])
        XCTAssertEqual(restarted.doses.first?.delivered, true)
    }

    func testTheNightscoutDocumentHasTheLastSixHoursAndNoInsulin() throws {
        log.finished(try log.began(units: 0.3, source: .phone, at: minutes(-7 * 60)), error: nil)
        log.finished(try log.began(units: 0.5, source: .remote, at: minutes(-5)), error: nil)

        let document = ManualDoseLogNightscout.document(doses: log.doses, now: now)
        XCTAssertEqual(document["eventType"] as? String, "Manual Dose Log")
        XCTAssertNil(document["insulin"])
        let doses = document["doses"] as? [[String: Any]]
        XCTAssertEqual(doses?.count, 1)
        XCTAssertEqual(doses?.first?["source"] as? String, "remote")
        XCTAssertEqual(doses?.first?["delivered"] as? Bool, true)
        XCTAssertEqual((doses?.first?["date"] as? String).flatMap(ManualDoseLogNightscout.formatter.date(from:)), minutes(-5))
        XCTAssertTrue(JSONSerialization.isValidJSONObject(document))
    }
}
