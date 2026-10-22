//
//  FavoriteFoodUsageTests.swift
//  LoopTests
//
//  Which favorite foods the carb entry screen shows first, and how the meal's time steps.
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

final class FavoriteFoodUsageTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func food(_ id: String, _ name: String) -> StoredFavoriteFood {
        StoredFavoriteFood(id: id, name: name, carbsQuantity: HKQuantity(unit: .gram(), doubleValue: 10), foodType: "🍽", absorptionTime: .hours(3))
    }

    private func entry(_ foodType: String?, daysAgo: Double) -> FavoriteFoodUsage.LoggedEntry {
        FavoriteFoodUsage.LoggedEntry(foodType: foodType, date: now.addingTimeInterval(-.days(daysAgo)))
    }

    func testEntriesCountForTheFavoriteWithTheSameName() {
        let favorites = [food("a", "Grøt"), food("b", "Melk")]
        let log = FavoriteFoodUsage.recording([
            entry("🥣 grøt", daysAgo: 1),
            entry("🥛🍼 Melk", daysAgo: 1),
            entry("🥛🍼 Melk (resten)", daysAgo: 1),
            entry("🍕", daysAgo: 1),
            entry(nil, daysAgo: 1),
        ], favorites: favorites, into: [:], now: now)
        XCTAssertEqual(log["a"]?.count, 1)
        XCTAssertEqual(log["b"]?.count, 1)
    }

    func testTheSameEntrySeenAgainIsNotCountedTwice() {
        let favorites = [food("a", "Grøt")]
        let entries = [entry("🥣 Grøt", daysAgo: 2)]
        let once = FavoriteFoodUsage.recording(entries, favorites: favorites, into: [:], now: now)
        let twice = FavoriteFoodUsage.recording(entries, favorites: favorites, into: once, now: now)
        XCTAssertEqual(twice["a"]?.count, 1)
    }

    func testTheLogKeepsServingsAfterThePhoneForgetsThem() {
        let favorites = [food("a", "Grøt")]
        let old = FavoriteFoodUsage.recording([entry("Grøt", daysAgo: 30)], favorites: favorites, into: [:], now: now)
        let later = FavoriteFoodUsage.recording([entry("Grøt", daysAgo: 1)], favorites: favorites, into: old, now: now)
        XCTAssertEqual(later["a"]?.count, 2)
        // Too old, and foods no longer favorites, drop out.
        let pruned = FavoriteFoodUsage.recording([], favorites: [], into: later, now: now)
        XCTAssertTrue(pruned.isEmpty)
        let aged = FavoriteFoodUsage.recording([], favorites: favorites, into: old, now: now.addingTimeInterval(.days(61)))
        XCTAssertNil(aged["a"])
    }

    func testTheTenEatenMostComeFirst() {
        let favorites = (0..<14).map { food("\($0)", "Food \($0)") }
        var log: FavoriteFoodUsage.Log = [:]
        log["12"] = [now, now.addingTimeInterval(-.days(1)), now.addingTimeInterval(-.days(2))]
        log["5"] = [now.addingTimeInterval(-.days(3)), now.addingTimeInterval(-.days(4))]
        log["9"] = [now.addingTimeInterval(-.days(1)), now.addingTimeInterval(-.days(5))]
        log["13"] = [now.addingTimeInterval(-.days(100))] // too old to count

        let shown = FavoriteFoodUsage.mostUsed(favorites, log: log, now: now)
        XCTAssertEqual(shown.count, 10)
        // Most servings, then the latest, then the stored order.
        XCTAssertEqual(shown.map(\.id), ["12", "9", "5", "0", "1", "2", "3", "4", "6", "7"])
    }

    func testFewerThanTenFavoritesAreAllShown() {
        let favorites = [food("a", "A"), food("b", "B")]
        XCTAssertEqual(FavoriteFoodUsage.mostUsed(favorites, log: [:], now: now).map(\.id), ["a", "b"])
    }

    // MARK: The meal's time

    private func time(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: hour, minute: minute, second: second))!
    }

    private func step(_ date: Date, _ direction: Int) -> Date {
        MealTimeRow.stepped(date, by: direction, minimumDate: time(0, 0), maximumDate: time(23, 0))
    }

    func testTheTimeStepsFiveMinutesOnTheGrid() {
        XCTAssertEqual(step(time(18, 43, 20), -1), time(18, 40))
        XCTAssertEqual(step(time(18, 43, 20), 1), time(18, 45))
        XCTAssertEqual(step(time(18, 40), -1), time(18, 35))
        XCTAssertEqual(step(time(18, 40, 40), 1), time(18, 45))
        XCTAssertEqual(step(time(18, 44, 50), 1), time(18, 45))
    }

    func testTheTimeStaysWithinItsLimits() {
        XCTAssertEqual(step(time(22, 58), 1), time(23, 0))
        XCTAssertEqual(step(time(0, 2), -1), time(0, 0))
    }
}
