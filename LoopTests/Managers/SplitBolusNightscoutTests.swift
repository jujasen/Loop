//
//  SplitBolusNightscoutTests.swift
//  LoopTests
//
//  The split's waiting rest in Nightscout for LoopFollow, and a rest logged from there.
//

import XCTest
import LoopKit
@testable import Loop

final class SplitBolusNightscoutTests: XCTestCase {
    private let milkTime = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func plan(_ state: SplitBolusPlan.State = .waiting, id: String = "p", foodType: String? = "🥛🍼 Melk") -> SplitBolusPlan {
        let suggestion = SplitBolusPlanner.suggestion(carbs: 14, foodType: foodType, mealDate: milkTime, settings: .standard, calibration: SplitBolusCalibration(), basis: nil, carbRatio: 15)!
        var plan = SplitBolusPlanner.plan(from: suggestion, nowEntryID: "now", laterCarbRatio: 15, id: id, now: milkTime)
        plan.state = state
        return plan
    }

    private var milkRest: String { "🥛🍼 Melk " + SplitBolusPlanner.restSuffix }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: The treatment

    func testAWaitingRestIsATreatmentWithoutCarbsOrInsulin() throws {
        let document = try XCTUnwrap(SplitBolusTreatment.document(for: plan()))
        XCTAssertEqual(document["eventType"] as? String, "Split Bolus Rest")
        XCTAssertEqual(document["created_at"] as? String, iso(milkTime.addingTimeInterval(.hours(2))))
        XCTAssertEqual(document["timestamp"] as? String, document["created_at"] as? String)
        XCTAssertEqual(document["expiresAt"] as? String, iso(milkTime.addingTimeInterval(.hours(8))))
        XCTAssertEqual(document["splitBolusID"] as? String, "p")
        XCTAssertEqual(document["state"] as? String, "waiting")
        XCTAssertEqual(document["restCarbs"] as? Double, 6)
        XCTAssertEqual(document["restUnits"] as? Double, 0.4)
        XCTAssertEqual(document["restFoodType"] as? String, milkRest)
        XCTAssertEqual(document["absorptionTime"] as? Int, 180)
        XCTAssertEqual(document["foodType"] as? String, "🥛🍼 Melk")
        XCTAssertEqual(document["mealName"] as? String, "Melk")
        XCTAssertEqual(document["mealDate"] as? String, iso(milkTime))
        XCTAssertEqual(document["mealCarbs"] as? Double, 14)
        XCTAssertEqual(document["nowCarbs"] as? Double, 8)
        XCTAssertNil(document["carbs"], "Not carbs until logged")
        XCTAssertNil(document["insulin"])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: document))
    }

    func testTheStateFollowsTheSplitAndAClosedSplitHasNoTreatment() {
        XCTAssertEqual(SplitBolusTreatment.document(for: plan(.notified))?["state"] as? String, "due")
        XCTAssertEqual(SplitBolusTreatment.document(for: plan(.postponed))?["state"] as? String, "postponed")
        for state in [SplitBolusPlan.State.given, .skipped, .expired, .cancelled] {
            XCTAssertNil(SplitBolusTreatment.document(for: plan(state)), "\(state)")
        }
    }

    func testTheRestOfAMealWithoutANameStillHasAFoodType() {
        XCTAssertEqual(plan(foodType: nil).restFoodType, "✂️ " + NSLocalizedString("Rest", comment: ""))
        XCTAssertEqual(plan().laterEntry(at: milkTime).foodType, milkRest)
    }

    // MARK: Syncing

    private final class FakeAPI: SplitBolusTreatmentAPI {
        var stored: [String: [String: Any]] = [:]
        var calls: [String] = []
        var failCreate = false
        private var next = 0

        func create(_ document: [String: Any]) async throws -> String? {
            if failCreate { throw URLError(.timedOut) }
            next += 1
            let id = "ns\(next)"
            stored[id] = document
            calls.append("create \(id)")
            return id
        }

        func delete(_ nsID: String) async throws {
            stored[nsID] = nil
            calls.append("delete \(nsID)")
        }
    }

    func testOpenSplitsAreUploadedOnceAndRemovedWhenDone() async {
        let api = FakeAPI()
        var result = await SplitBolusTreatment.sync(plans: [plan()], uploaded: [:], api: api)
        XCTAssertNil(result.error)
        XCTAssertEqual(api.calls, ["create ns1"])
        XCTAssertEqual(result.uploaded["p"]?.nsID, "ns1")

        result = await SplitBolusTreatment.sync(plans: [plan()], uploaded: result.uploaded, api: api)
        XCTAssertEqual(api.calls, ["create ns1"], "Unchanged: nothing sent")

        // Due: the state changes, so the treatment is put back with it.
        result = await SplitBolusTreatment.sync(plans: [plan(.notified)], uploaded: result.uploaded, api: api)
        XCTAssertEqual(api.calls, ["create ns1", "delete ns1", "create ns2"])
        XCTAssertEqual(api.stored["ns2"]?["state"] as? String, "due")

        // Given from LoopFollow: gone from Nightscout.
        result = await SplitBolusTreatment.sync(plans: [], uploaded: result.uploaded, api: api)
        XCTAssertEqual(api.calls.last, "delete ns2")
        XCTAssertTrue(result.uploaded.isEmpty)
        XCTAssertTrue(api.stored.isEmpty)
    }

    func testAFailedUploadIsTriedAgainNextTime() async {
        let api = FakeAPI()
        api.failCreate = true
        var result = await SplitBolusTreatment.sync(plans: [plan()], uploaded: [:], api: api)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.uploaded.isEmpty)

        api.failCreate = false
        result = await SplitBolusTreatment.sync(plans: [plan()], uploaded: result.uploaded, api: api)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.uploaded["p"]?.nsID, "ns1")
    }

    // MARK: A rest logged elsewhere

    private func carb(_ id: String?, _ foodType: String?, after minutes: Double) -> SplitBolusPlanner.LoggedCarb {
        .init(id: id, foodType: foodType, date: milkTime.addingTimeInterval(.minutes(minutes)))
    }

    func testARestSentFromLoopFollowIsFound() {
        let found = SplitBolusPlanner.loggedRest(for: plan(.notified), in: [carb("now", "🥛🍼 Melk", after: 0), carb("lf", milkRest, after: 125)], claimed: [])
        XCTAssertEqual(found?.id, "lf")
    }

    func testARestIsKnownByItsNameInEitherLanguage() {
        let plan = plan()
        XCTAssertTrue(SplitBolusPlanner.isRest(milkRest, of: plan))
        XCTAssertTrue(SplitBolusPlanner.isRest("🥛 melk (rest)", of: plan))
        XCTAssertTrue(SplitBolusPlanner.isRest("Melk " + SplitBolusPlanner.restSuffix, of: plan))
        XCTAssertFalse(SplitBolusPlanner.isRest("🥛🍼 Melk", of: plan), "Another serving is not the rest")
        XCTAssertFalse(SplitBolusPlanner.isRest("🥣 Havregrøt " + SplitBolusPlanner.restSuffix, of: plan), "The rest of another meal")
        XCTAssertFalse(SplitBolusPlanner.isRest(nil, of: plan))
    }

    func testOnlyARestInsideTheWindowAndNotTakenCounts() {
        let plan = plan(.notified)
        XCTAssertNil(SplitBolusPlanner.loggedRest(for: plan, in: [carb("old", milkRest, after: -10)], claimed: []), "Before the meal: an earlier evening's rest")
        XCTAssertEqual(SplitBolusPlanner.loggedRest(for: plan, in: [carb("late", milkRest, after: 245)], claimed: [])?.id, "late", "Long after the reminder still counts")
        XCTAssertNil(SplitBolusPlanner.loggedRest(for: plan, in: [carb("later", milkRest, after: 485)], claimed: []), "After the rest was let go")
        XCTAssertNil(SplitBolusPlanner.loggedRest(for: plan, in: [carb("taken", milkRest, after: 125)], claimed: ["taken"]))
        XCTAssertEqual(SplitBolusPlanner.loggedRest(for: plan, in: [carb("early", milkRest, after: 90)], claimed: [])?.id, "early", "Given before it was due still counts")
        var given = plan
        given.state = .given
        XCTAssertNil(SplitBolusPlanner.loggedRest(for: given, in: [carb("lf", milkRest, after: 125)], claimed: []))
    }
}
