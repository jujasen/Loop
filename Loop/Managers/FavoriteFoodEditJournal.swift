//
//  FavoriteFoodEditJournal.swift
//  Loop
//
//  Turns a plain "here is the new list" write into something the Nightscout sync can reason
//  about: when each food last changed, and which foods were removed.
//

import Foundation
import LoopKit

enum FavoriteFoodEditJournal {
    /// Stamps the foods that actually changed with `now`, and leaves the rest alone.
    ///
    /// Reordering, or saving a food without touching it, is not a change: stamping those would
    /// make this phone win every sync race for no reason.
    static func stamp(_ foods: [StoredFavoriteFood], previous: [StoredFavoriteFood], now: Date = Date()) -> [StoredFavoriteFood] {
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return foods.map { food in
            var stamped = food

            guard let existing = previousByID[food.id] else {
                stamped.updatedAt = now
                return stamped
            }

            // A food that came back from the store keeps whatever document it was already tied to.
            stamped.nsID = food.nsID ?? existing.nsID
            stamped.updatedAt = existing.hasSameContent(as: stamped) ? existing.updatedAt : now
            return stamped
        }
    }

    /// Leaves a tombstone for every food that disappeared, and clears the tombstone of any food
    /// that came back.
    static func tombstones(
        previous: [StoredFavoriteFood],
        next: [StoredFavoriteFood],
        existing: [FavoriteFoodTombstone],
        now: Date = Date()
    ) -> [FavoriteFoodTombstone] {
        let remainingIDs = Set(next.map { $0.id })
        var tombstones = existing.filter { !remainingIDs.contains($0.id) }

        for removed in previous where !remainingIDs.contains(removed.id) {
            guard !tombstones.contains(where: { $0.id == removed.id }) else { continue }
            tombstones.append(FavoriteFoodTombstone(id: removed.id, nsID: removed.nsID, deletedAt: now))
        }

        return tombstones
    }

    /// A folder only reaches Nightscout as part of the foods filed in it, so renaming one counts
    /// as an edit of those foods.
    static func stampFoods(
        _ foods: [StoredFavoriteFood],
        inFoldersChangedFrom previous: [FavoriteFoodFolder],
        to next: [FavoriteFoodFolder],
        now: Date = Date()
    ) -> [StoredFavoriteFood] {
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let renamed = Set(next.filter { folder in
            guard let existing = previousByID[folder.id] else { return false }
            return existing != folder
        }.map { $0.id })

        guard !renamed.isEmpty else { return foods }

        return foods.map { food in
            guard let folderID = food.folderID, renamed.contains(folderID) else { return food }
            var stamped = food
            stamped.updatedAt = now
            return stamped
        }
    }
}
