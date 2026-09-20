//
//  FavoriteFoodNightscoutSync.swift
//  Loop
//
//  Shares favorite foods with a caregiver app (LoopFollow) through Nightscout's food
//  collection, so the same list can be read and edited from both phones.
//

import Foundation
import HealthKit
import CryptoKit
import LoopKit
import os.log

/// A favorite food deleted here, kept until the deletion has reached Nightscout.
///
/// A deletion travels as an edit carrying `deletedAt`, so the same last-writer-wins rule decides
/// between "deleted here" and "edited on the other phone": the food only stays gone when nobody
/// has changed it since.
public struct FavoriteFoodTombstone: Codable, Equatable, Identifiable {
    public var id: String
    public var nsID: String?
    public var deletedAt: Date

    public init(id: String, nsID: String?, deletedAt: Date = Date()) {
        self.id = id
        self.nsID = nsID
        self.deletedAt = deletedAt
    }
}

/// The document the two apps exchange. It doubles as an ordinary Nightscout food entry — name,
/// carbs, category — with everything else in a `loopFavorite` block:
///
/// ```json
/// { "_id": "…", "type": "food", "name": "Brødskive", "category": "Frokost",
///   "carbs": 16, "portion": 1, "unit": "1 skive",
///   "loopFavorite": { "id": "…", "foodType": "🍞", "absorptionTime": 10800,
///                     "portions": [{"id":"…","name":"1 skive","carbs":16}],
///                     "folder": {"id":"…","name":"Frokost","emoji":"🥣"},
///                     "updatedAt": 1758364800000, "deletedAt": null } }
/// ```
///
/// LoopFollow writes and reads the same shape — the two must be changed together.
enum FavoriteFoodSyncDocument {
    static let blockKey = "loopFavorite"

    /// How long a deleted food stays in Nightscout before it is removed for good. Long enough
    /// that a phone that was off the whole time still learns about the deletion.
    static let tombstoneLifetime: TimeInterval = 30 * 24 * 60 * 60

    /// Absorption time used for a food adopted from a plain Nightscout entry.
    static let defaultAbsorptionTime: TimeInterval = 3 * 60 * 60

    struct Parsed {
        var nsID: String
        var food: StoredFavoriteFood
        var folder: FavoriteFoodFolder?
        var deletedAt: Date?
        /// True when the document had no `loopFavorite` block — a plain food entry made in
        /// Nightscout's food editor, which we take over on the next write.
        var isAdopted: Bool
        /// The document as Nightscout stores it, so writing back keeps fields we don't model.
        var raw: [String: Any]
    }

    // MARK: - Reading

    static func parse(_ raw: [String: Any]) -> Parsed? {
        guard let nsID = raw["_id"] as? String, !nsID.isEmpty else { return nil }

        if let block = raw[blockKey] as? [String: Any] {
            return parse(block: block, nsID: nsID, raw: raw)
        }
        return adopt(raw, nsID: nsID)
    }

    private static func parse(block: [String: Any], nsID: String, raw: [String: Any]) -> Parsed? {
        guard let id = block["id"] as? String, !id.isEmpty else { return nil }

        let portions = (block["portions"] as? [[String: Any]])?.compactMap(portion(from:)) ?? []
        let folder = folder(from: block["folder"] as? [String: Any])

        let food = StoredFavoriteFood(
            id: id,
            portions: portions.isEmpty ? [FavoriteFoodPortion(carbsQuantity: grams(number(raw["carbs"]) ?? 0))] : portions,
            name: (raw["name"] as? String) ?? (block["name"] as? String) ?? "",
            foodType: (block["foodType"] as? String) ?? "",
            absorptionTime: number(block["absorptionTime"]) ?? defaultAbsorptionTime,
            folderID: folder?.id,
            updatedAt: date(from: block["updatedAt"]) ?? .distantPast,
            nsID: nsID
        )

        return Parsed(
            nsID: nsID,
            food: food,
            folder: folder,
            deletedAt: date(from: block["deletedAt"]),
            isAdopted: false,
            raw: raw
        )
    }

    /// Turns a plain Nightscout food entry into a favorite. Its id comes from the document, so
    /// both apps adopt the same entry as the same favorite.
    private static func adopt(_ raw: [String: Any], nsID: String) -> Parsed? {
        guard let name = raw["name"] as? String, !name.isEmpty, let carbs = number(raw["carbs"]) else {
            return nil
        }

        let category = (raw["category"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let folder = category.isEmpty ? nil : FavoriteFoodFolder(id: "ns-category-\(category)", name: category)

        let food = StoredFavoriteFood(
            id: nsID,
            name: name,
            carbsQuantity: grams(carbs),
            foodType: "",
            absorptionTime: defaultAbsorptionTime,
            servingSize: (raw["unit"] as? String) ?? "",
            folderID: folder?.id,
            // Never newer than a real edit, so adopting can't overwrite one.
            updatedAt: .distantPast,
            nsID: nsID
        )

        return Parsed(nsID: nsID, food: food, folder: folder, deletedAt: nil, isAdopted: true, raw: raw)
    }

    private static func portion(from raw: [String: Any]) -> FavoriteFoodPortion? {
        guard let carbs = number(raw["carbs"]) else { return nil }
        return FavoriteFoodPortion(
            id: (raw["id"] as? String) ?? UUID().uuidString,
            name: (raw["name"] as? String) ?? "",
            carbsQuantity: grams(carbs)
        )
    }

    private static func folder(from raw: [String: Any]?) -> FavoriteFoodFolder? {
        guard let raw, let id = raw["id"] as? String, let name = raw["name"] as? String else { return nil }
        return FavoriteFoodFolder(id: id, name: name, emoji: (raw["emoji"] as? String) ?? "")
    }

    // MARK: - Writing

    /// Builds the document to send for `food`. Starting from the stored document keeps any
    /// fields Nightscout or its food editor added that we don't model.
    static func document(for food: StoredFavoriteFood, folder: FavoriteFoodFolder?, deletedAt: Date? = nil, base: [String: Any]? = nil) -> [String: Any] {
        var document = base ?? [:]

        document["type"] = "food"
        document["name"] = food.name
        document["category"] = folder?.name ?? ""
        if document["subcategory"] == nil { document["subcategory"] = "" }
        document["carbs"] = food.carbsQuantity.doubleValue(for: .gram())
        document["portion"] = 1
        document["unit"] = food.defaultPortion.hasName ? food.defaultPortion.name : "portion"

        var block: [String: Any] = [
            "id": food.id,
            "foodType": food.foodType,
            "absorptionTime": food.absorptionTime,
            "portions": food.portions.map {
                ["id": $0.id, "name": $0.name, "carbs": $0.carbsQuantity.doubleValue(for: .gram())]
            },
            "updatedAt": milliseconds(from: max(food.updatedAt, deletedAt ?? food.updatedAt)),
        ]

        if let folder {
            block["folder"] = ["id": folder.id, "name": folder.name, "emoji": folder.emoji]
        }
        if let deletedAt {
            block["deletedAt"] = milliseconds(from: deletedAt)
        }

        document[blockKey] = block

        if let nsID = food.nsID, document["_id"] == nil {
            document["_id"] = nsID
        }

        return document
    }

    // MARK: - Helpers

    private static func grams(_ value: Double) -> HKQuantity {
        HKQuantity(unit: .gram(), doubleValue: value)
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func date(from value: Any?) -> Date? {
        guard let milliseconds = number(value), milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func milliseconds(from date: Date) -> Double {
        (date.timeIntervalSince1970 * 1000).rounded()
    }
}

private extension StoredFavoriteFood {
    /// Ordering of the memberwise arguments differs from the public initializer only to keep the
    /// parse site readable.
    init(id: String, portions: [FavoriteFoodPortion], name: String, foodType: String, absorptionTime: TimeInterval, folderID: String?, updatedAt: Date, nsID: String?) {
        self.init(id: id, name: name, portions: portions, foodType: foodType, absorptionTime: absorptionTime, folderID: folderID, updatedAt: updatedAt, nsID: nsID)
    }
}

/// Decides, per food, which side is newer — without touching storage or the network, so the
/// rules can be tested on their own. LoopFollow runs the same rules on its copy.
enum FavoriteFoodSyncEngine {
    struct Outcome {
        var foods: [StoredFavoriteFood] = []
        var folders: [FavoriteFoodFolder] = []
        var tombstones: [FavoriteFoodTombstone] = []

        /// Foods to POST as new Nightscout documents.
        var creates: [StoredFavoriteFood] = []
        /// Foods to PUT, by document id.
        var updates: [StoredFavoriteFood] = []
        /// Foods to PUT carrying a `deletedAt`.
        var deletions: [FavoriteFoodTombstone] = []
        /// Documents whose deletion is old enough to remove for good.
        var purges: [String] = []
    }

    struct Input {
        var foods: [StoredFavoriteFood]
        var folders: [FavoriteFoodFolder]
        var tombstones: [FavoriteFoodTombstone]
        var remote: [FavoriteFoodSyncDocument.Parsed]
        /// False when the fetch may have been cut short. A food missing from a partial listing
        /// says nothing about whether it still exists, so nothing is removed locally.
        var remoteIsComplete: Bool
        var now: Date
    }

    static func merge(_ input: Input) -> Outcome {
        var outcome = Outcome()
        outcome.folders = input.folders

        var remoteByID: [String: FavoriteFoodSyncDocument.Parsed] = [:]
        for parsed in input.remote {
            if let existing = remoteByID[parsed.food.id], existing.food.updatedAt > parsed.food.updatedAt {
                continue
            }
            remoteByID[parsed.food.id] = parsed
        }

        var handledRemoteIDs = Set<String>()
        var tombstoneByID: [String: FavoriteFoodTombstone] = [:]
        for tombstone in input.tombstones {
            tombstoneByID[tombstone.id] = tombstone
        }

        // An empty listing is never taken as "everything was deleted": a wiped or unreadable
        // food collection would otherwise empty this phone's list too. With nothing to compare
        // against, the foods here are pushed back instead.
        let remoteHasAnything = !remoteByID.isEmpty

        // 1. Foods this phone holds.
        for local in input.foods {
            guard let remote = remoteByID[local.id] else {
                if local.nsID != nil, input.remoteIsComplete, remoteHasAnything {
                    // Synced once and gone from Nightscout now: removed for good elsewhere.
                    continue
                }
                outcome.foods.append(local)
                outcome.creates.append(local)
                continue
            }

            handledRemoteIDs.insert(local.id)

            if let deletedAt = remote.deletedAt, deletedAt >= local.updatedAt {
                continue
            }

            if remote.food.updatedAt > local.updatedAt {
                outcome.foods.append(remote.food)
                adopt(folder: remote.folder, into: &outcome.folders)
            } else {
                var merged = local
                merged.nsID = remote.nsID
                outcome.foods.append(merged)

                let folder = outcome.folders.first(where: { $0.id == merged.folderID })
                if remote.isAdopted || remote.deletedAt != nil || !remote.food.hasSameContent(as: merged) || folderDiffers(remote: remote.folder, local: folder) {
                    outcome.updates.append(merged)
                }
            }
        }

        // 2. Foods only Nightscout knows about.
        for (id, remote) in remoteByID where !handledRemoteIDs.contains(id) {
            if let deletedAt = remote.deletedAt {
                if input.now.timeIntervalSince(deletedAt) > FavoriteFoodSyncDocument.tombstoneLifetime {
                    outcome.purges.append(remote.nsID)
                }
                tombstoneByID[id] = nil
                continue
            }

            if let tombstone = tombstoneByID[id] {
                if tombstone.deletedAt >= remote.food.updatedAt {
                    var pending = tombstone
                    pending.nsID = remote.nsID
                    outcome.deletions.append(pending)
                    tombstoneByID[id] = pending
                    continue
                }
                // Changed on the other phone after we deleted it, so the change wins.
                tombstoneByID[id] = nil
            }

            outcome.foods.append(remote.food)
            adopt(folder: remote.folder, into: &outcome.folders)
        }

        // 3. Deletions of foods Nightscout no longer lists: nothing left to tell it about.
        for tombstone in tombstoneByID.values where remoteByID[tombstone.id] == nil {
            tombstoneByID[tombstone.id] = nil
        }

        outcome.tombstones = tombstoneByID.values
            .filter { input.now.timeIntervalSince($0.deletedAt) <= FavoriteFoodSyncDocument.tombstoneLifetime }
            .sorted { $0.deletedAt < $1.deletedAt }

        outcome.foods = ordered(outcome.foods, like: input.foods)
        outcome.folders = outcome.folders.filter { folder in
            outcome.foods.contains(where: { $0.folderID == folder.id }) || input.folders.contains(where: { $0.id == folder.id })
        }

        return outcome
    }

    private static func adopt(folder: FavoriteFoodFolder?, into folders: inout [FavoriteFoodFolder]) {
        guard let folder else { return }
        if let index = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[index] = folder
        }
        else {
            folders.append(folder)
        }
    }

    private static func folderDiffers(remote: FavoriteFoodFolder?, local: FavoriteFoodFolder?) -> Bool {
        switch (remote, local) {
        case (nil, nil): return false
        case let (remote?, local?): return remote != local
        default: return true
        }
    }

    private static func ordered(_ foods: [StoredFavoriteFood], like original: [StoredFavoriteFood]) -> [StoredFavoriteFood] {
        let positions = Dictionary(original.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return foods.enumerated().sorted { lhs, rhs in
            let left = positions[lhs.element.id]
            let right = positions[rhs.element.id]
            switch (left, right) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map { $0.element }
    }
}

/// Runs the sharing: reads Nightscout's food collection every loop cycle, applies what the
/// caregiver app changed, and writes back what changed here.
@MainActor
final class FavoriteFoodSyncManager: ObservableObject {
    static let shared = FavoriteFoodSyncManager()

    private let log = OSLog(category: "FavoriteFoodSync")

    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isSyncing = false

    private var pendingSync: Task<Void, Never>?
    private var isObserving = false

    private init() {}

    /// Sharing needs nothing but Nightscout credentials: the Nightscout service already holds an
    /// API secret that may write, so there is nothing for the user to set up here.
    var isConfigured: Bool {
        credentials != nil
    }

    private var credentials: (siteURL: URL, apiSecret: String)? {
        guard let stored = try? KeychainManager().getNightscoutCredentials() else { return nil }
        guard !stored.apiSecret.isEmpty else { return nil }
        return stored
    }

    /// Starts listening. Called once at launch, and safe to call again.
    func start() {
        guard !isObserving else { return }
        isObserving = true

        NotificationCenter.default.addObserver(
            forName: .LoopCompleted,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }

        NotificationCenter.default.addObserver(
            forName: .favoriteFoodsEditedLocally,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.syncSoon() }
        }

        syncSoon(delay: 5)
    }

    /// Syncs after a short delay, so a handful of edits in a row travel as one round trip.
    func syncSoon(delay: TimeInterval = 2) {
        guard isConfigured else { return }

        pendingSync?.cancel()
        pendingSync = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    func sync() async {
        guard let credentials else { return }
        guard !isSyncing else { return }

        isSyncing = true
        defer { isSyncing = false }

        let api = NightscoutFoodAPI(siteURL: credentials.siteURL, apiSecret: credentials.apiSecret)

        do {
            let documents = try await api.fetch()
            let remote = documents.compactMap(FavoriteFoodSyncDocument.parse)

            let outcome = FavoriteFoodSyncEngine.merge(
                .init(
                    foods: UserDefaults.standard.favoriteFoods,
                    folders: UserDefaults.standard.favoriteFoodFolders,
                    tombstones: UserDefaults.standard.favoriteFoodTombstones,
                    remote: remote,
                    // Nightscout's food endpoint returns the whole collection, so anything
                    // missing from it really is gone.
                    remoteIsComplete: true,
                    now: Date()
                )
            )

            UserDefaults.standard.applySyncedFavoriteFoods(
                foods: outcome.foods,
                folders: outcome.folders,
                tombstones: outcome.tombstones
            )

            let rawByNSID = Dictionary(remote.map { ($0.nsID, $0.raw) }, uniquingKeysWith: { first, _ in first })
            try await push(outcome: outcome, rawByNSID: rawByNSID, api: api)

            lastSync = Date()
            lastError = nil
            NotificationCenter.default.post(name: .favoriteFoodsChangedBySync, object: nil)
        }
        catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Favorite food sync failed: %{public}@", String(describing: error))
        }
    }

    private func push(outcome: FavoriteFoodSyncEngine.Outcome, rawByNSID: [String: [String: Any]], api: NightscoutFoodAPI) async throws {
        let folders = UserDefaults.standard.favoriteFoodFolders

        func folder(for food: StoredFavoriteFood) -> FavoriteFoodFolder? {
            folders.first(where: { $0.id == food.folderID })
        }

        if !outcome.creates.isEmpty {
            let documents = outcome.creates.map { FavoriteFoodSyncDocument.document(for: $0, folder: folder(for: $0)) }
            let created = try await api.create(documents)

            var stored = UserDefaults.standard.favoriteFoods
            var changed = false
            for document in created {
                guard let nsID = document["_id"] as? String,
                      let block = document[FavoriteFoodSyncDocument.blockKey] as? [String: Any],
                      let id = block["id"] as? String,
                      let index = stored.firstIndex(where: { $0.id == id })
                else { continue }
                stored[index].nsID = nsID
                changed = true
            }
            if changed {
                UserDefaults.standard.applySyncedFavoriteFoods(foods: stored, folders: folders, tombstones: UserDefaults.standard.favoriteFoodTombstones)
            }
        }

        for food in outcome.updates {
            guard let nsID = food.nsID else { continue }
            var document = FavoriteFoodSyncDocument.document(for: food, folder: folder(for: food), base: rawByNSID[nsID])
            document["_id"] = nsID
            try await api.update(document)
        }

        var remaining = UserDefaults.standard.favoriteFoodTombstones
        for tombstone in outcome.deletions {
            guard let nsID = tombstone.nsID,
                  let raw = rawByNSID[nsID],
                  let parsed = FavoriteFoodSyncDocument.parse(raw)
            else { continue }

            var document = FavoriteFoodSyncDocument.document(for: parsed.food, folder: parsed.folder, deletedAt: tombstone.deletedAt, base: raw)
            document["_id"] = nsID
            try await api.update(document)

            // Nightscout carries the deletion now, so this phone no longer has to.
            remaining.removeAll(where: { $0.id == tombstone.id })
        }
        if remaining != UserDefaults.standard.favoriteFoodTombstones {
            UserDefaults.standard.applySyncedFavoriteFoods(
                foods: UserDefaults.standard.favoriteFoods,
                folders: folders,
                tombstones: remaining
            )
        }

        for nsID in outcome.purges {
            try await api.delete(nsID)
        }
    }
}

/// The bit of Nightscout's v1 API that stores food. Authenticated with the API secret Loop
/// already uses for uploading. The endpoint has no `.json` alias, and its list route returns the
/// whole collection.
struct NightscoutFoodAPI {
    enum APIError: LocalizedError {
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case let .http(status, body):
                switch status {
                case 401, 403:
                    return "Nightscout rejected the API secret (\(status))."
                case 404:
                    return "This Nightscout site has no food API."
                default:
                    return "Nightscout returned \(status). \(body)"
                }
            }
        }
    }

    let siteURL: URL
    let apiSecret: String

    private var secretHash: String {
        Insecure.SHA1.hash(data: Data(apiSecret.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func request(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: siteURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(secretHash, forHTTPHeaderField: "api-secret")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(http.statusCode, String(body.prefix(200)))
        }
        return data
    }

    func fetch() async throws -> [[String: Any]] {
        let data = try await send(request(path: "api/v1/food/", method: "GET"))
        return (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
    }

    /// Creates documents and returns them as stored, so the caller learns their `_id`s.
    func create(_ documents: [[String: Any]]) async throws -> [[String: Any]] {
        guard !documents.isEmpty else { return [] }
        var request = request(path: "api/v1/food/", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: documents)

        let data = try await send(request)
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return array
        }
        if let single = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return [single]
        }
        return []
    }

    func update(_ document: [String: Any]) async throws {
        var request = request(path: "api/v1/food/", method: "PUT")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: document)
        _ = try await send(request)
    }

    func delete(_ nsID: String) async throws {
        _ = try await send(request(path: "api/v1/food/\(nsID)", method: "DELETE"))
    }
}

extension Notification.Name {
    /// Posted when favorite foods were edited on this phone.
    static let favoriteFoodsEditedLocally = Notification.Name("com.loopkit.Loop.favoriteFoodsEditedLocally")
    /// Posted when the sync changed the stored favorite foods, so open screens can reload.
    static let favoriteFoodsChangedBySync = Notification.Name("com.loopkit.Loop.favoriteFoodsChangedBySync")
}

extension KeychainManager {
    /// The Nightscout site and API secret the Nightscout service stored. Read directly, because
    /// the service lives in a plugin the app doesn't link against.
    fileprivate func getNightscoutCredentials() throws -> (siteURL: URL, apiSecret: String) {
        let credentials = try getInternetCredentials(account: "NightscoutAPI")
        return (siteURL: credentials.url, apiSecret: credentials.password)
    }
}
