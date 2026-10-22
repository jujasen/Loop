//
//  FavoriteFoodUsage.swift
//  Loop
//
//  Which favorite foods are eaten most, so the carb entry screen can show those first.
//

import Foundation
import LoopKit

/// How often each favorite food has been logged, kept on the phone.
///
/// The phone only keeps a week of carb entries, so every time the carb entry screen opens the
/// week's entries are copied into a longer log: one date per serving, per food. Entries are
/// matched to a food by the dish's name in `foodType` (`CarbFoodLabel`), which means a food
/// logged from LoopFollow counts the same as one picked here, and a rest of a split bolus
/// ("Melk (resten)") never counts as another serving.
enum FavoriteFoodUsage {
    /// The carb entry screen shows this many foods; the rest are a tap away.
    static let quickPickCount = 10
    /// Servings older than this no longer count, so what is eaten now rises to the top.
    static let window: TimeInterval = .days(90)
    /// Two entries this close are one serving (logged twice, or seen twice on the way in).
    static let sameServing: TimeInterval = .minutes(1)

    /// Food id → dates it was logged.
    typealias Log = [String: [Date]]

    struct LoggedEntry: Equatable {
        var foodType: String?
        var date: Date
    }

    /// The favorite a logged entry is a serving of: the one with the same name, ignoring case.
    static func food(for foodType: String?, in favorites: [StoredFavoriteFood]) -> StoredFavoriteFood? {
        let name = CarbFoodLabel(foodType: foodType).name
        guard !name.isEmpty else { return nil }
        return favorites.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame }
    }

    /// `log` with `entries` added, servings older than `window` and foods no longer favorites
    /// dropped.
    static func recording(_ entries: [LoggedEntry], favorites: [StoredFavoriteFood], into log: Log, now: Date) -> Log {
        let ids = Set(favorites.map(\.id))
        let oldest = now.addingTimeInterval(-window)
        var log = log.filter { ids.contains($0.key) }

        for entry in entries where entry.date >= oldest {
            guard let food = food(for: entry.foodType, in: favorites) else { continue }
            var dates = log[food.id] ?? []
            if !dates.contains(where: { abs($0.timeIntervalSince(entry.date)) < sameServing }) {
                dates.append(entry.date)
            }
            log[food.id] = dates
        }

        return log
            .mapValues { $0.filter { $0 >= oldest }.sorted() }
            .filter { !$0.value.isEmpty }
    }

    /// The `limit` favorites eaten most often lately: most servings first, then the most
    /// recently eaten. Foods never logged fill the remaining places in their stored order.
    static func mostUsed(_ favorites: [StoredFavoriteFood], log: Log, now: Date, limit: Int = quickPickCount) -> [StoredFavoriteFood] {
        let oldest = now.addingTimeInterval(-window)
        let ranked = favorites.enumerated().sorted { a, b in
            let aDates = (log[a.element.id] ?? []).filter { $0 >= oldest }
            let bDates = (log[b.element.id] ?? []).filter { $0 >= oldest }
            if aDates.count != bDates.count { return aDates.count > bDates.count }
            let aLast = aDates.max() ?? .distantPast, bLast = bDates.max() ?? .distantPast
            if aLast != bLast { return aLast > bLast }
            return a.offset < b.offset
        }
        return Array(ranked.prefix(limit).map(\.element))
    }
}

extension UserDefaults {
    private static let favoriteFoodUsageKey = "com.loopkit.Loop.favoriteFoodUsage"

    /// Stored as seconds since 1970, so the log is a plain property list.
    var favoriteFoodUsage: FavoriteFoodUsage.Log {
        get {
            guard let stored = dictionary(forKey: Self.favoriteFoodUsageKey) as? [String: [Double]] else { return [:] }
            return stored.mapValues { $0.map(Date.init(timeIntervalSince1970:)) }
        }
        set {
            set(newValue.mapValues { $0.map(\.timeIntervalSince1970) }, forKey: Self.favoriteFoodUsageKey)
        }
    }
}
