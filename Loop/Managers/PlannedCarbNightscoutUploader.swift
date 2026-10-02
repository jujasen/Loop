//
//  PlannedCarbNightscoutUploader.swift
//  Loop
//
//  Shows waiting later carbs in the caregiver app, as one Nightscout treatment per plan.
//

import Foundation
import CryptoKit
import LoopKit
import os.log

/// The Nightscout treatment that stands for waiting later carbs.
///
/// It deliberately has no `carbs` field, so nothing counts it as carbs: LoopFollow draws it as a
/// hollow ring at the due time with a dashed line to the expiry. When the later carbs are added,
/// dropped or cancelled, the treatment is deleted — added carbs then arrive as an ordinary entry.
/// LoopFollow reads these fields (`Controllers/Nightscout/Treatments/PlannedCarbs.swift`), so
/// change both apps together.
enum PlannedCarbTreatment {
    static let eventType = "Planned Carbs"

    static func document(for followUp: PlannedCarbFollowUp) -> [String: Any] {
        let grams = NumberFormatter.localizedString(from: NSNumber(value: followUp.rule.carbGrams), number: .decimal)
        var document: [String: Any] = [
            "eventType": eventType,
            "created_at": iso8601(followUp.dueDate),
            "timestamp": iso8601(followUp.dueDate),
            "plannedCarbs": followUp.rule.carbGrams,
            "absorptionTime": Int((followUp.rule.absorptionTime / 60).rounded()),
            "expiresAt": iso8601(followUp.expiryDate),
            "plannedCarbsID": followUp.triggerID,
            "enteredBy": "Loop",
            "notes": String(format: NSLocalizedString("Later carbs %1$@ g · %2$@", comment: "Nightscout note for waiting later carbs (1: grams)(2: name of the meal)"), grams, followUp.mealDescription),
        ]
        if let foodType = CarbFoodLabel(emoji: followUp.emoji, name: followUp.mealName).foodType {
            document["foodType"] = foodType
        }
        if let reason = followUp.reason, !reason.isEmpty {
            document["reason"] = reason
        }
        return document
    }

    /// Changes when anything shown in the caregiver app changes, so an unchanged plan is not
    /// uploaded again on every loop.
    static func fingerprint(of document: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

@MainActor
final class PlannedCarbNightscoutUploader {
    static let shared = PlannedCarbNightscoutUploader()

    private struct Uploaded: Codable, Equatable {
        var nsID: String
        var fingerprint: String
    }

    private let log = OSLog(category: "PlannedCarbNightscoutUploader")
    private var latest: [PlannedCarbFollowUp] = []
    private var isSyncing = false
    private var needsAnotherSync = false
    private var isObserving = false

    private let uploadedKey = "com.loopkit.Loop.plannedCarbTreatments"

    private init() {}

    func start(manager: CarbFollowUpManager) {
        guard !isObserving else { return }
        isObserving = true
        NotificationCenter.default.addObserver(forName: .carbFollowUpsDidChange, object: manager, queue: .main) { [weak self] _ in
            let planned = manager.planned
            Task { @MainActor in
                self?.latest = planned
                await self?.sync()
            }
        }
        // Retries after a failed upload, and catches up on treatments left behind when the app
        // was stopped mid-plan.
        NotificationCenter.default.addObserver(forName: .LoopCompleted, object: nil, queue: .main) { [weak self] _ in
            let planned = manager.planned
            Task { @MainActor in
                self?.latest = planned
                await self?.sync()
            }
        }
    }

    private var uploaded: [String: Uploaded] {
        get {
            guard let data = UserDefaults.standard.data(forKey: uploadedKey) else { return [:] }
            return (try? JSONDecoder().decode([String: Uploaded].self, from: data)) ?? [:]
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: uploadedKey)
        }
    }

    private func sync() async {
        guard !isSyncing else {
            needsAnotherSync = true
            return
        }
        guard let credentials = try? KeychainManager().getNightscoutCredentials(), !credentials.apiSecret.isEmpty else { return }

        isSyncing = true
        defer { isSyncing = false }

        repeat {
            needsAnotherSync = false
            await syncOnce(api: NightscoutTreatmentAPI(siteURL: credentials.siteURL, apiSecret: credentials.apiSecret))
        } while needsAnotherSync
    }

    private func syncOnce(api: NightscoutTreatmentAPI) async {
        let desired = Dictionary(latest.map { ($0.triggerID, PlannedCarbTreatment.document(for: $0)) }, uniquingKeysWith: { first, _ in first })
        var uploaded = self.uploaded

        do {
            for (triggerID, upload) in uploaded where desired[triggerID] == nil {
                try await api.delete(upload.nsID)
                uploaded[triggerID] = nil
            }

            for (triggerID, document) in desired {
                let fingerprint = PlannedCarbTreatment.fingerprint(of: document)
                if let existing = uploaded[triggerID] {
                    guard existing.fingerprint != fingerprint else { continue }
                    var replacement = document
                    replacement["_id"] = existing.nsID
                    try await api.update(replacement)
                    uploaded[triggerID] = Uploaded(nsID: existing.nsID, fingerprint: fingerprint)
                } else if let nsID = try await api.create(document) {
                    uploaded[triggerID] = Uploaded(nsID: nsID, fingerprint: fingerprint)
                }
            }
        } catch {
            log.error("Could not share later carbs with Nightscout: %{public}@", String(describing: error))
        }

        self.uploaded = uploaded
    }
}

/// The treatments part of the Nightscout API, with the API secret the Nightscout service holds.
struct NightscoutTreatmentAPI {
    let siteURL: URL
    let apiSecret: String

    private var secretHash: String {
        Insecure.SHA1.hash(data: Data(apiSecret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func request(path: String, method: String, body: Any? = nil) throws -> URLRequest {
        var request = URLRequest(url: siteURL.appendingPathComponent(path))
        request.httpMethod = method
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

    /// Creates the treatment and returns its `_id`.
    func create(_ document: [String: Any]) async throws -> String? {
        let data = try await send(request(path: "api/v1/treatments/", method: "POST", body: [document]))
        let json = try? JSONSerialization.jsonObject(with: data)
        let stored = (json as? [[String: Any]])?.first ?? (json as? [String: Any])
        return stored?["_id"] as? String
    }

    func update(_ document: [String: Any]) async throws {
        _ = try await send(request(path: "api/v1/treatments/", method: "PUT", body: document))
    }

    func delete(_ nsID: String) async throws {
        do {
            _ = try await send(request(path: "api/v1/treatments/\(nsID)", method: "DELETE"))
        } catch NightscoutFoodAPI.APIError.http(404, _) {
            // Already gone.
        }
    }
}
