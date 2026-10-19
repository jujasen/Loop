//
//  SplitBolusNightscout.swift
//  Loop
//
//  Shows a split's waiting rest in the caregiver app, as one Nightscout treatment per open
//  split, so a parent can see it and log it from LoopFollow while the phone is with the child.
//

import CryptoKit
import Foundation
import LoopKit
import os.log

/// The Nightscout treatment that stands for the rest of a split bolus while it waits.
///
/// Contract with LoopFollow (`Controllers/Nightscout/Treatments/SplitBolusRest.swift`), so change
/// both apps together:
///
/// - `eventType`: "Split Bolus Rest"
/// - `created_at`, `timestamp`: when the rest is due (UTC), moved on when it waits for glucose
/// - `expiresAt`: when Loop lets the rest go if nobody logs it (UTC)
/// - `splitBolusID`: the split's id, the same for as long as it waits
/// - `state`: "waiting" (not due yet), "due" (the notification went out) or "postponed"
///   (glucose was low or falling when due; checked again at `created_at`)
/// - `restCarbs`: grams of the rest; `restUnits`: rough insulin for it from the carb ratio, or
///   missing without one
/// - `restFoodType`: the `foodType` the rest is logged with, "🥛🍼 Melk (resten)" — LoopFollow
///   sends a remote carb entry with exactly this, and Loop takes such an entry for the rest
/// - `absorptionTime`: minutes, for that carb entry
/// - `foodType`, `mealName`, `mealDate`, `mealCarbs`, `nowCarbs`: the meal it belongs to
///
/// It deliberately has no `carbs` or `insulin` field: the rest is not carbs or insulin until it
/// is logged, so it must never count toward COB, IOB or the day's totals. When the rest is given,
/// skipped, expires or the split is called off, the treatment is deleted; a given rest then
/// arrives as an ordinary carb entry.
enum SplitBolusTreatment {
    static let eventType = "Split Bolus Rest"

    static func state(of plan: SplitBolusPlan) -> String? {
        switch plan.state {
        case .waiting: return "waiting"
        case .notified: return "due"
        case .postponed: return "postponed"
        case .given, .skipped, .expired, .cancelled: return nil
        }
    }

    /// The treatment for an open split, `nil` for one that is done.
    static func document(for plan: SplitBolusPlan) -> [String: Any]? {
        guard let state = state(of: plan) else { return nil }
        let restFoodType = plan.restFoodType
        var document: [String: Any] = [
            "eventType": eventType,
            "created_at": iso8601(plan.due),
            "timestamp": iso8601(plan.due),
            "expiresAt": iso8601(plan.due.addingTimeInterval(SplitBolusPlanner.restWindow)),
            "splitBolusID": plan.id,
            "state": state,
            "restCarbs": plan.laterCarbs,
            "absorptionTime": Int((SplitBolusSettings.laterAbsorptionTime / 60).rounded()),
            "mealName": plan.mealName,
            "mealDate": iso8601(plan.mealDate),
            "mealCarbs": plan.totalCarbs,
            "nowCarbs": plan.nowCarbs,
            "enteredBy": "Loop",
            "notes": String(format: NSLocalizedString("Rest of split bolus %1$@ · %2$@", comment: "Nightscout note for the waiting rest of a split bolus (1: carbs)(2: name of the meal)"), SplitBolusPlanner.grams(plan.laterCarbs), plan.mealDescription),
        ]
        if let restFoodType {
            document["restFoodType"] = restFoodType
        }
        if let foodType = plan.foodType {
            document["foodType"] = foodType
        }
        if let units = plan.laterUnits {
            document["restUnits"] = (units * 100).rounded() / 100
        }
        return document
    }

    /// Changes when anything LoopFollow shows changes, so an unchanged split is not uploaded
    /// again on every loop.
    static func fingerprint(of document: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// A treatment already in Nightscout for a split, by split id.
    struct Uploaded: Codable, Equatable {
        var nsID: String
        var fingerprint: String
    }

    /// Brings Nightscout in line with the open splits and returns what is there afterwards.
    /// A changed split is deleted and created again rather than updated: Nightscout up to 15.0.6
    /// finds the treatment to replace by its `created_at` too, which moves with a postponed rest.
    /// Stops at the first failure and keeps what got done, so the next run picks up from there.
    static func sync(plans: [SplitBolusPlan], uploaded: [String: Uploaded], api: SplitBolusTreatmentAPI) async -> (uploaded: [String: Uploaded], error: Error?) {
        var desired: [String: [String: Any]] = [:]
        for plan in plans {
            if let document = document(for: plan) {
                desired[plan.id] = document
            }
        }
        var uploaded = uploaded

        do {
            for (id, upload) in uploaded.sorted(by: { $0.key < $1.key }) {
                let fingerprint = desired[id].map(Self.fingerprint)
                guard fingerprint != upload.fingerprint else { continue }
                try await api.delete(upload.nsID)
                uploaded[id] = nil
            }
            for (id, document) in desired.sorted(by: { $0.key < $1.key }) where uploaded[id] == nil {
                if let nsID = try await api.create(document) {
                    uploaded[id] = Uploaded(nsID: nsID, fingerprint: fingerprint(of: document))
                }
            }
        } catch {
            return (uploaded, error)
        }
        return (uploaded, nil)
    }
}

/// The part of Nightscout's treatments API the split needs.
protocol SplitBolusTreatmentAPI {
    /// Stores the treatment and returns its `_id`.
    func create(_ document: [String: Any]) async throws -> String?
    /// Deletes it; one that is already gone is not an error.
    func delete(_ nsID: String) async throws
}

/// Nightscout's v1 treatments API, with the API secret the Nightscout service holds.
struct NightscoutTreatmentAPI: SplitBolusTreatmentAPI {
    let siteURL: URL
    let apiSecret: String

    private var secretHash: String {
        Insecure.SHA1.hash(data: Data(apiSecret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func request(path: String, method: String, body: Any? = nil) throws -> URLRequest {
        var request = URLRequest(url: siteURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue(secretHash, forHTTPHeaderField: "api-secret")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NightscoutFoodAPI.APIError.http(http.statusCode, String((String(data: data, encoding: .utf8) ?? "").prefix(200)))
        }
        return data
    }

    func create(_ document: [String: Any]) async throws -> String? {
        let data = try await send(request(path: "api/v1/treatments/", method: "POST", body: [document]))
        let json = try? JSONSerialization.jsonObject(with: data)
        let stored = (json as? [[String: Any]])?.first ?? (json as? [String: Any])
        return stored?["_id"] as? String
    }

    func delete(_ nsID: String) async throws {
        do {
            _ = try await send(request(path: "api/v1/treatments/\(nsID)", method: "DELETE"))
        } catch NightscoutFoodAPI.APIError.http(404, _) {
            // Already gone.
        }
    }
}

/// Keeps the treatments in Nightscout in line with the splits: on every change, and after every
/// loop, which retries a failed upload and catches up after the app was stopped.
@MainActor
final class SplitBolusNightscoutUploader {
    static let shared = SplitBolusNightscoutUploader()

    private let log = OSLog(category: "SplitBolusNightscoutUploader")
    private var manager: SplitBolusManager?
    private var isSyncing = false
    private var needsAnotherSync = false
    private var observers: [NSObjectProtocol] = []

    private let uploadedKey = "com.loopkit.Loop.splitBolusTreatments"

    private init() {}

    func start(manager: SplitBolusManager) {
        guard self.manager == nil else { return }
        self.manager = manager
        for name in [Notification.Name.splitBolusDidChange, .LoopCompleted] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.sync() }
            })
        }
    }

    private var uploaded: [String: SplitBolusTreatment.Uploaded] {
        get {
            guard let data = UserDefaults.standard.data(forKey: uploadedKey) else { return [:] }
            return (try? JSONDecoder().decode([String: SplitBolusTreatment.Uploaded].self, from: data)) ?? [:]
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: uploadedKey)
        }
    }

    private func sync() async {
        guard let manager else { return }
        guard !isSyncing else {
            needsAnotherSync = true
            return
        }
        let uploaded = self.uploaded
        // Nothing open and nothing left behind: no need to ask for the credentials.
        guard !uploaded.isEmpty || !manager.openPlans.isEmpty else { return }
        guard let credentials = try? KeychainManager().getNightscoutCredentials(), !credentials.apiSecret.isEmpty else { return }

        isSyncing = true
        defer { isSyncing = false }

        let api = NightscoutTreatmentAPI(siteURL: credentials.siteURL, apiSecret: credentials.apiSecret)
        repeat {
            needsAnotherSync = false
            let result = await SplitBolusTreatment.sync(plans: manager.openPlans, uploaded: self.uploaded, api: api)
            self.uploaded = result.uploaded
            if let error = result.error {
                log.error("Could not share the split bolus with Nightscout: %{public}@", String(describing: error))
                return
            }
        } while needsAnotherSync
    }
}
