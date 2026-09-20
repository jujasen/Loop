//
//  FavoriteFoodSyncTests.swift
//  LoopTests
//
//  Favorites are edited on two phones that only meet through Nightscout, so the rules that
//  decide which side wins — and that a deletion stays deleted without eating a concurrent edit —
//  are pinned here. LoopFollow runs the same rules on its copy, and the two must agree.
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

final class FavoriteFoodSyncTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_758_000_000)

    private func food(
        id: String = "bread",
        name: String = "Brødskive",
        carbs: Double = 16,
        foodType: String = "🍞",
        absorptionTime: TimeInterval = 3 * 3600,
        folderID: String? = nil,
        updatedAt: Date,
        nsID: String? = nil
    ) -> StoredFavoriteFood {
        StoredFavoriteFood(
            id: id,
            name: name,
            carbsQuantity: HKQuantity(unit: .gram(), doubleValue: carbs),
            foodType: foodType,
            absorptionTime: absorptionTime,
            folderID: folderID,
            updatedAt: updatedAt,
            nsID: nsID
        )
    }

    /// A Nightscout document as the other app would have written it.
    private func remote(
        _ food: StoredFavoriteFood,
        nsID: String = "aaaaaaaaaaaaaaaaaaaaaaaa",
        folder: FavoriteFoodFolder? = nil,
        deletedAt: Date? = nil
    ) throws -> FavoriteFoodSyncDocument.Parsed {
        var document = FavoriteFoodSyncDocument.document(for: food, folder: folder, deletedAt: deletedAt)
        document["_id"] = nsID
        return try XCTUnwrap(FavoriteFoodSyncDocument.parse(document))
    }

    private func merge(
        foods: [StoredFavoriteFood] = [],
        folders: [FavoriteFoodFolder] = [],
        tombstones: [FavoriteFoodTombstone] = [],
        remote: [FavoriteFoodSyncDocument.Parsed] = [],
        remoteIsComplete: Bool = true
    ) -> FavoriteFoodSyncEngine.Outcome {
        FavoriteFoodSyncEngine.merge(
            .init(
                foods: foods,
                folders: folders,
                tombstones: tombstones,
                remote: remote,
                remoteIsComplete: remoteIsComplete,
                now: now
            )
        )
    }

    // MARK: - The shared document

    func testDocumentSurvivesARoundTrip() throws {
        let folder = FavoriteFoodFolder(id: "f1", name: "Frokost", emoji: "🥣")
        let original = StoredFavoriteFood(
            id: "bread",
            name: "Brødskive",
            portions: [
                FavoriteFoodPortion(id: "whole", name: "1 skive", carbsQuantity: HKQuantity(unit: .gram(), doubleValue: 16)),
                FavoriteFoodPortion(id: "half", name: "Halv skive", carbsQuantity: HKQuantity(unit: .gram(), doubleValue: 8)),
            ],
            foodType: "🍞",
            absorptionTime: 2.5 * 3600,
            folderID: folder.id,
            updatedAt: now
        )

        let parsed = try remote(original, folder: folder)

        XCTAssertEqual(parsed.food.id, original.id)
        XCTAssertEqual(parsed.food.name, original.name)
        XCTAssertEqual(parsed.food.foodType, "🍞")
        XCTAssertEqual(parsed.food.absorptionTime, 2.5 * 3600)
        XCTAssertEqual(parsed.food.portions, original.portions)
        XCTAssertEqual(parsed.food.folderID, folder.id)
        XCTAssertEqual(parsed.folder, folder)
        XCTAssertFalse(parsed.isAdopted)
        // Timestamps travel as milliseconds, so they come back to the millisecond.
        XCTAssertEqual(parsed.food.updatedAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
    }

    /// The document also reads as an ordinary Nightscout food entry, so the food editor on the
    /// site shows something sensible.
    func testDocumentLooksLikeAPlainNightscoutFood() {
        let food = StoredFavoriteFood(
            id: "yog",
            name: "Yoghurt",
            carbsQuantity: HKQuantity(unit: .gram(), doubleValue: 22),
            foodType: "🥣",
            absorptionTime: 7200,
            servingSize: "1 beger"
        )
        let document = FavoriteFoodSyncDocument.document(for: food, folder: FavoriteFoodFolder(id: "f1", name: "Frokost"))

        XCTAssertEqual(document["type"] as? String, "food")
        XCTAssertEqual(document["name"] as? String, "Yoghurt")
        XCTAssertEqual(document["carbs"] as? Double, 22)
        XCTAssertEqual(document["category"] as? String, "Frokost")
        XCTAssertEqual(document["unit"] as? String, "1 beger")
    }

    /// A food someone typed into Nightscout's own food editor is taken over rather than ignored.
    func testPlainNightscoutFoodIsAdopted() throws {
        let parsed = try XCTUnwrap(FavoriteFoodSyncDocument.parse([
            "_id": "bbbbbbbbbbbbbbbbbbbbbbbb",
            "type": "food",
            "name": "Banan",
            "carbs": 25,
            "category": "Mellommåltid",
            "unit": "1 stk",
        ]))

        XCTAssertTrue(parsed.isAdopted)
        XCTAssertEqual(parsed.food.name, "Banan")
        XCTAssertEqual(parsed.food.carbsQuantity.doubleValue(for: .gram()), 25)
        XCTAssertEqual(parsed.food.servingSize, "1 stk")
        // Its id comes from the document, so both apps adopt it as the same favorite.
        XCTAssertEqual(parsed.food.id, "bbbbbbbbbbbbbbbbbbbbbbbb")
        // And it never outranks a real edit.
        XCTAssertEqual(parsed.food.updatedAt, .distantPast)
    }

    // MARK: - Merging

    func testAFoodOnlyThisPhoneHasIsCreatedInNightscout() {
        let outcome = merge(foods: [food(updatedAt: now)])

        XCTAssertEqual(outcome.foods.map(\.id), ["bread"])
        XCTAssertEqual(outcome.creates.map(\.id), ["bread"])
        XCTAssertTrue(outcome.updates.isEmpty)
    }

    func testAFoodOnlyNightscoutHasIsAddedHere() throws {
        let folder = FavoriteFoodFolder(id: "f1", name: "Frokost", emoji: "🥣")
        let incoming = food(updatedAt: now, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let outcome = try merge(remote: [remote(incoming, folder: folder)])

        XCTAssertEqual(outcome.foods.map(\.id), ["bread"])
        XCTAssertEqual(outcome.foods.first?.nsID, "aaaaaaaaaaaaaaaaaaaaaaaa")
        // The folder it was filed in comes along with it.
        XCTAssertEqual(outcome.folders, [folder])
        XCTAssertTrue(outcome.creates.isEmpty)
    }

    func testTheNewerEditWins() throws {
        let older = food(name: "Gammel", updatedAt: now.addingTimeInterval(-600), nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let newer = food(name: "Ny", updatedAt: now)

        let remoteWins = try merge(foods: [older], remote: [remote(newer)])
        XCTAssertEqual(remoteWins.foods.first?.name, "Ny")
        XCTAssertTrue(remoteWins.updates.isEmpty)

        let localWins = try merge(
            foods: [food(name: "Ny", updatedAt: now, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")],
            remote: [remote(older)]
        )
        XCTAssertEqual(localWins.foods.first?.name, "Ny")
        XCTAssertEqual(localWins.updates.map(\.name), ["Ny"])
    }

    /// The same food on both sides, unchanged, must not be written back — otherwise the two apps
    /// would keep handing the same food to each other forever.
    func testAnUnchangedFoodIsNotPushedBack() throws {
        let unchanged = food(updatedAt: now, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let outcome = try merge(foods: [unchanged], remote: [remote(unchanged)])

        XCTAssertTrue(outcome.updates.isEmpty)
        XCTAssertTrue(outcome.creates.isEmpty)
        XCTAssertEqual(outcome.foods.map(\.id), ["bread"])
    }

    func testAFoodDeletedElsewhereDisappearsHere() throws {
        let local = food(updatedAt: now.addingTimeInterval(-600), nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let outcome = try merge(foods: [local], remote: [remote(local, deletedAt: now)])

        XCTAssertTrue(outcome.foods.isEmpty)
        XCTAssertTrue(outcome.updates.isEmpty)
    }

    /// Deleting here while the other phone edited the same food afterwards: the edit wins, and
    /// the food comes back rather than being silently lost.
    func testAnEditAfterADeleteBringsTheFoodBack() throws {
        let edited = food(name: "Endret i LoopFollow", updatedAt: now, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let tombstone = FavoriteFoodTombstone(id: "bread", nsID: "aaaaaaaaaaaaaaaaaaaaaaaa", deletedAt: now.addingTimeInterval(-600))

        let outcome = try merge(tombstones: [tombstone], remote: [remote(edited)])

        XCTAssertEqual(outcome.foods.map(\.name), ["Endret i LoopFollow"])
        XCTAssertTrue(outcome.tombstones.isEmpty)
        XCTAssertTrue(outcome.deletions.isEmpty)
    }

    func testADeletionHereIsPushedToNightscout() throws {
        let deleted = food(updatedAt: now.addingTimeInterval(-600), nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let tombstone = FavoriteFoodTombstone(id: "bread", nsID: "aaaaaaaaaaaaaaaaaaaaaaaa", deletedAt: now)

        let outcome = try merge(tombstones: [tombstone], remote: [remote(deleted)])

        XCTAssertTrue(outcome.foods.isEmpty)
        XCTAssertEqual(outcome.deletions.map(\.id), ["bread"])
        // Kept until the push has gone through; the manager drops it afterwards.
        XCTAssertEqual(outcome.tombstones.map(\.id), ["bread"])
    }

    func testALongDeadDocumentIsRemovedForGood() throws {
        let old = food(updatedAt: now.addingTimeInterval(-90 * 24 * 3600), nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let outcome = try merge(remote: [remote(old, deletedAt: now.addingTimeInterval(-60 * 24 * 3600))])

        XCTAssertEqual(outcome.purges, ["aaaaaaaaaaaaaaaaaaaaaaaa"])
        XCTAssertTrue(outcome.foods.isEmpty)
    }

    /// A food that was synced once and is gone from Nightscout was removed by someone else.
    func testASyncedFoodMissingFromNightscoutIsDroppedHere() throws {
        let stillThere = food(id: "other", name: "Annet", updatedAt: now, nsID: "bbbbbbbbbbbbbbbbbbbbbbbb")
        let removedElsewhere = food(updatedAt: now, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")

        let outcome = try merge(
            foods: [removedElsewhere, stillThere],
            remote: [remote(stillThere, nsID: "bbbbbbbbbbbbbbbbbbbbbbbb")]
        )

        XCTAssertEqual(outcome.foods.map(\.id), ["other"])
        XCTAssertTrue(outcome.creates.isEmpty)
    }

    /// …but an empty food collection is a wiped or unreadable site, not a mass deletion. The
    /// foods here are kept and pushed back rather than thrown away.
    func testAnEmptyFoodCollectionNeverEmptiesThisPhone() {
        let outcome = merge(foods: [food(updatedAt: now, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")])

        XCTAssertEqual(outcome.foods.map(\.id), ["bread"])
        XCTAssertEqual(outcome.creates.map(\.id), ["bread"])
    }

    /// …but not when the listing may have been cut short.
    func testNothingIsDroppedFromAnIncompleteListing() {
        let outcome = merge(foods: [food(updatedAt: now, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")], remoteIsComplete: false)

        XCTAssertEqual(outcome.foods.map(\.id), ["bread"])
    }

    // MARK: - Stamping local edits

    func testOnlyRealChangesAreStamped() {
        let stamp = Date(timeIntervalSince1970: 1_758_000_000)
        let existing = food(updatedAt: stamp, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")

        let untouched = FavoriteFoodEditJournal.stamp([existing], previous: [existing], now: now.addingTimeInterval(1000))
        XCTAssertEqual(untouched.first?.updatedAt, stamp)
        XCTAssertEqual(untouched.first?.nsID, "aaaaaaaaaaaaaaaaaaaaaaaa")

        var renamed = existing
        renamed.name = "Nytt navn"
        let stamped = FavoriteFoodEditJournal.stamp([renamed], previous: [existing], now: now.addingTimeInterval(1000))
        XCTAssertEqual(stamped.first?.updatedAt, now.addingTimeInterval(1000))
        // The document it belongs to is kept, so the edit updates rather than duplicates.
        XCTAssertEqual(stamped.first?.nsID, "aaaaaaaaaaaaaaaaaaaaaaaa")
    }

    func testARemovedFoodLeavesATombstone() {
        let removed = food(updatedAt: now, nsID: "aaaaaaaaaaaaaaaaaaaaaaaa")
        let tombstones = FavoriteFoodEditJournal.tombstones(previous: [removed], next: [], existing: [], now: now)

        XCTAssertEqual(tombstones.map(\.id), ["bread"])
        XCTAssertEqual(tombstones.first?.nsID, "aaaaaaaaaaaaaaaaaaaaaaaa")

        // And a food that comes back clears its tombstone.
        let cleared = FavoriteFoodEditJournal.tombstones(previous: [], next: [removed], existing: tombstones, now: now)
        XCTAssertTrue(cleared.isEmpty)
    }

    /// Renaming a folder has to reach the other phone, and it only travels with the foods in it.
    func testRenamingAFolderStampsItsFoods() {
        let folder = FavoriteFoodFolder(id: "f1", name: "Frokost", emoji: "🥣")
        var renamed = folder
        renamed.name = "Morgen"

        let filed = food(folderID: "f1", updatedAt: now.addingTimeInterval(-1000))
        let unfiled = food(id: "other", name: "Annet", updatedAt: now.addingTimeInterval(-1000))

        let stamped = FavoriteFoodEditJournal.stampFoods([filed, unfiled], inFoldersChangedFrom: [folder], to: [renamed], now: now)

        XCTAssertEqual(stamped.first?.updatedAt, now)
        XCTAssertEqual(stamped.last?.updatedAt, now.addingTimeInterval(-1000))
    }
}
