//
//  RemoteCarbEditTests.swift
//  LoopTests
//
//  A carb entry changed from a caregiver's phone.
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

final class RemoteCarbEditTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func entry(startedHoursAgo hours: Double = 1) -> StoredCarbEntry {
        StoredCarbEntry(
            startDate: now.addingTimeInterval(-.hours(hours)),
            quantity: HKQuantity(unit: .gram(), doubleValue: 30),
            syncIdentifier: "ABC-123",
            foodType: "🍕 Pizza",
            absorptionTime: .hours(4)
        )
    }

    private func replacement(_ edit: RemoteCarbEdit, replacing entry: StoredCarbEntry) throws -> NewCarbEntry {
        try LoopDataManager.carbEntry(for: edit, replacing: entry, defaultAbsorptionTime: .hours(3), now: now)
    }

    func testAmountOnly_KeepsTimeFoodAndAbsorption() throws {
        let original = entry()
        let new = try replacement(RemoteCarbEdit(syncIdentifier: "ABC-123", amountInGrams: 45), replacing: original)

        XCTAssertEqual(new.quantity.doubleValue(for: .gram()), 45)
        XCTAssertEqual(new.startDate, original.startDate)
        XCTAssertEqual(new.foodType, "🍕 Pizza")
        XCTAssertEqual(new.absorptionTime, .hours(4))
        XCTAssertEqual(new.date, now)
    }

    func testEveryValue_IsReplaced() throws {
        let start = now.addingTimeInterval(-.minutes(20))
        let new = try replacement(
            RemoteCarbEdit(syncIdentifier: "ABC-123", amountInGrams: 12, absorptionTime: .hours(2), foodType: "🍎 Eple", startDate: start),
            replacing: entry()
        )

        XCTAssertEqual(new.quantity.doubleValue(for: .gram()), 12)
        XCTAssertEqual(new.startDate, start)
        XCTAssertEqual(new.foodType, "🍎 Eple")
        XCTAssertEqual(new.absorptionTime, .hours(2))
    }

    func testEmptyFoodType_ClearsIt() throws {
        let new = try replacement(RemoteCarbEdit(syncIdentifier: "ABC-123", foodType: ""), replacing: entry())
        XCTAssertNil(new.foodType)
    }

    func testOldEntry_AmountCanBeCorrectedWithoutMovingIt() throws {
        let original = entry(startedHoursAgo: 20)
        let new = try replacement(RemoteCarbEdit(syncIdentifier: "ABC-123", amountInGrams: 20, startDate: original.startDate), replacing: original)
        XCTAssertEqual(new.startDate, original.startDate)
    }

    func testStartDate_OutsideNewEntryWindow_Throws() {
        let tooEarly = now.addingTimeInterval(-.hours(13))
        XCTAssertThrowsError(try replacement(RemoteCarbEdit(syncIdentifier: "ABC-123", startDate: tooEarly), replacing: entry()))

        let tooLate = now.addingTimeInterval(.hours(2))
        XCTAssertThrowsError(try replacement(RemoteCarbEdit(syncIdentifier: "ABC-123", startDate: tooLate), replacing: entry()))
    }

    func testAmount_OutOfRange_Throws() {
        XCTAssertThrowsError(try replacement(RemoteCarbEdit(syncIdentifier: "ABC-123", amountInGrams: 0), replacing: entry()))
        let tooMuch = LoopConstants.maxCarbEntryQuantity.doubleValue(for: .gram()) + 1
        XCTAssertThrowsError(try replacement(RemoteCarbEdit(syncIdentifier: "ABC-123", amountInGrams: tooMuch), replacing: entry()))
    }

    func testAbsorption_OutOfRange_Throws() {
        XCTAssertThrowsError(try replacement(RemoteCarbEdit(syncIdentifier: "ABC-123", absorptionTime: .minutes(10)), replacing: entry()))
        XCTAssertThrowsError(try replacement(RemoteCarbEdit(syncIdentifier: "ABC-123", absorptionTime: .hours(9)), replacing: entry()))
    }

    func testEntryWithoutAbsorption_GetsDefault() throws {
        let original = StoredCarbEntry(startDate: now, quantity: HKQuantity(unit: .gram(), doubleValue: 10), syncIdentifier: "ABC-123")
        let new = try replacement(RemoteCarbEdit(syncIdentifier: "ABC-123", amountInGrams: 15), replacing: original)
        XCTAssertEqual(new.absorptionTime, .hours(3))
    }
}
