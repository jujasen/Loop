//
//  GlucoseInsightNightscout.swift
//  Loop
//
//  Shares the glucose insight with LoopFollow through Nightscout. It is one document in the food
//  collection, the collection both apps already write for favorite foods, replaced on every
//  upload. It has no name and no carbs, so neither app, nor Nightscout's food editor, takes it for
//  a food.
//
//  Nightscout up to 15.0.6 finds the document to replace by `_id` *and* `created_at`, and stamps
//  a missing `created_at` with the time of the request. So the document carries a fixed
//  `created_at`, and one already stored under another is deleted and put back once.
//

import CryptoKit
import Foundation
import LoopKit
import os.log

/// The insight as it goes to Nightscout.
struct GlucoseInsightDocument: Codable, Equatable {
    /// "loopinsight1" in hex: a fixed object id, so each upload replaces the one before.
    static let id = "6c6f6f70696e736967687431"
    static let documentType = "loopInsight"
    static let currentVersion = 1
    /// Never changes, so Nightscout up to 15.0.6 finds the stored document by it.
    static let createdAt = "2026-01-01T00:00:00.000Z"

    struct Usage: Codable, Equatable {
        var calls: Int
        var dollars: Double
    }

    var type = Self.documentType
    var version = Self.currentVersion
    var uploadedAt: Date
    var aiEnabled: Bool
    var aiUsageToday: Usage
    var insight: GlucoseInsightStatus

    /// The status without what LoopFollow doesn't show: the weeks' meal list is only for the dose advice.
    init(status: GlucoseInsightStatus, aiEnabled: Bool, usage: OpenAIDailyUsage, now: Date) {
        var status = status
        status.longTerm?.meals = []
        self.uploadedAt = now
        self.aiEnabled = aiEnabled
        self.aiUsageToday = Usage(calls: usage.byTier.values.reduce(0) { $0 + $1.calls }, dollars: (usage.dollars * 100).rounded() / 100)
        self.insight = status
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// The document as Nightscout stores it, with its fixed `_id` and `created_at`.
    func json() throws -> [String: Any] {
        guard var object = try JSONSerialization.jsonObject(with: Self.encoder().encode(self)) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        object["_id"] = Self.id
        object["created_at"] = Self.createdAt
        return object
    }
}

/// How the last upload went, for the insight tab.
enum GlucoseInsightSharing: Equatable {
    case shared(Date)
    case failed(String, Date)
}

/// Puts the insight in Nightscout when it has changed.
@MainActor
final class GlucoseInsightUploader {
    enum UploadError: LocalizedError, Equatable {
        case noNightscout
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .noNightscout:
                return String(localized: "Nightscout is not set up.", comment: "Glucose insight sharing error: no Nightscout credentials")
            case let .http(status):
                return String(format: NSLocalizedString("Nightscout answered %d.", comment: "Glucose insight sharing error: Nightscout refused the upload (1: HTTP status)"), status)
            }
        }
    }

    private let log = OSLog(category: "GlucoseInsightUploader")
    private var lastUploaded: GlucoseInsightStatus?
    private var task: Task<Void, Never>?
    /// Told how each upload went.
    var onResult: (GlucoseInsightSharing) -> Void = { _ in }

    func upload(_ status: GlucoseInsightStatus, aiEnabled: Bool, usage: OpenAIDailyUsage, now: Date = Date()) {
        guard status != lastUploaded, status.longTerm != nil || status.today != nil else { return }
        let document = GlucoseInsightDocument(status: status, aiEnabled: aiEnabled, usage: usage, now: now)
        task?.cancel()
        task = Task {
            do {
                try await Self.put(document)
                self.lastUploaded = status
                self.onResult(.shared(Date()))
            } catch is CancellationError {
            } catch {
                self.log.error("Uploading the insight failed: %{public}@", String(describing: error))
                self.onResult(.failed(error.localizedDescription, Date()))
            }
        }
    }

    private static func put(_ document: GlucoseInsightDocument) async throws {
        guard let credentials = try? KeychainManager().getNightscoutCredentials(), !credentials.apiSecret.isEmpty else {
            throw UploadError.noNightscout
        }
        let body = try JSONSerialization.data(withJSONObject: document.json())
        do {
            try await send("api/v1/food/", method: "PUT", body: body, credentials: credentials)
        } catch UploadError.http(let status) where status >= 500 {
            // Nightscout up to 15.0.6 can't replace a document stored under another
            // `created_at` (the first upload got the server's time) and fails on the duplicate
            // `_id`. Once it is deleted and put back, it carries the fixed `created_at`.
            try await send("api/v1/food/\(GlucoseInsightDocument.id)", method: "DELETE", body: nil, credentials: credentials)
            try await send("api/v1/food/", method: "PUT", body: body, credentials: credentials)
        }
    }

    private static func send(_ path: String, method: String, body: Data?, credentials: (siteURL: URL, apiSecret: String)) async throws {
        var request = URLRequest(url: credentials.siteURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue(Insecure.SHA1.hash(data: Data(credentials.apiSecret.utf8)).map { String(format: "%02x", $0) }.joined(), forHTTPHeaderField: "api-secret")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UploadError.http(http.statusCode)
        }
    }
}
