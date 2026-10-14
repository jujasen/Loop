//
//  GlucoseInsightNightscout.swift
//  Loop
//
//  Shares the glucose insight with LoopFollow through Nightscout. It is one document in the food
//  collection, the collection both apps already write for favorite foods, replaced on every
//  upload. It has no name and no carbs, so neither app, nor Nightscout's food editor, takes it for
//  a food.
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

    /// The document as Nightscout stores it, with its fixed `_id`.
    func json() throws -> [String: Any] {
        guard var object = try JSONSerialization.jsonObject(with: Self.encoder().encode(self)) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        object["_id"] = Self.id
        return object
    }
}

/// Puts the insight in Nightscout when it has changed.
@MainActor
final class GlucoseInsightUploader {
    private let log = OSLog(category: "GlucoseInsightUploader")
    private var lastUploaded: GlucoseInsightStatus?
    private var task: Task<Void, Never>?

    func upload(_ status: GlucoseInsightStatus, aiEnabled: Bool, usage: OpenAIDailyUsage, now: Date = Date()) {
        guard status != lastUploaded, status.longTerm != nil || status.today != nil else { return }
        let document = GlucoseInsightDocument(status: status, aiEnabled: aiEnabled, usage: usage, now: now)
        task?.cancel()
        task = Task {
            do {
                try await Self.put(document)
                self.lastUploaded = status
            } catch is CancellationError {
            } catch {
                self.log.error("Uploading the insight failed: %{public}@", String(describing: error))
            }
        }
    }

    private static func put(_ document: GlucoseInsightDocument) async throws {
        guard let credentials = try? KeychainManager().getNightscoutCredentials(), !credentials.apiSecret.isEmpty else { return }
        var request = URLRequest(url: credentials.siteURL.appendingPathComponent("api/v1/food/"))
        request.httpMethod = "PUT"
        request.timeoutInterval = 60
        request.setValue(Insecure.SHA1.hash(data: Data(credentials.apiSecret.utf8)).map { String(format: "%02x", $0) }.joined(), forHTTPHeaderField: "api-secret")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: document.json())
        let (_, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }
}
