//
//  BolusSuggestionNightscout.swift
//  Loop
//
//  A bolus suggestion the bolus screen opens with (from the evening watch), and the Nightscout
//  treatments the suggestions are shared through with LoopFollow.
//

import CryptoKit
import Foundation
import LoopKit
import UserNotifications

/// A dose suggested to the caregiver: the bolus screen opens with it in the field and the reason
/// under the recommendation.
struct BolusSuggestion: Equatable, Identifiable {
    var id: String
    var units: Double
    var reason: String
}

/// Contract with LoopFollow (`Remote/AISuggestion/AIBolusSuggestion.swift`); change both apps
/// together: an open suggestion is an "AI Bolus Suggestion" treatment, with no `insulin` or
/// `carbs` field so it never counts as either, deleted when it is given, declined or lapses.
enum BolusSuggestionTreatment {
    static let eventType = "AI Bolus Suggestion"

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Nightscout's v1 treatments API, with the API secret the Nightscout service holds.
struct SuggestionNightscoutAPI {
    let siteURL: URL
    let apiSecret: String

    static func fromKeychain() -> SuggestionNightscoutAPI? {
        guard let credentials = try? KeychainManager().getNightscoutCredentials(), !credentials.apiSecret.isEmpty else { return nil }
        return SuggestionNightscoutAPI(siteURL: credentials.siteURL, apiSecret: credentials.apiSecret)
    }

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

    /// Stores the treatment and returns its `_id`.
    func create(_ document: [String: Any]) async throws -> String? {
        let (data, response) = try await URLSession.shared.data(for: try request(path: "api/v1/treatments.json", method: "POST", body: [document]))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AIChat.ChatError.server("Nightscout \(http.statusCode)")
        }
        let created = try? JSONSerialization.jsonObject(with: data)
        let first = (created as? [[String: Any]])?.first ?? created as? [String: Any]
        return first?["_id"] as? String
    }

    /// Whether it is still there: gone when someone deleted it, for example from LoopFollow.
    func exists(_ nsID: String) async throws -> Bool {
        var components = URLComponents(url: siteURL.appendingPathComponent("api/v1/treatments.json"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "find[_id]", value: nsID), URLQueryItem(name: "count", value: "1")]
        guard let url = components?.url else { return true }
        var urlRequest = try request(path: "api/v1/treatments.json", method: "GET")
        urlRequest.url = url
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AIChat.ChatError.server("Nightscout \(http.statusCode)")
        }
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return true }
        return !list.isEmpty
    }

    /// Deletes it; one that is already gone is not an error.
    func delete(_ nsID: String) async throws {
        let (_, response) = try await URLSession.shared.data(for: try request(path: "api/v1/treatments/\(nsID)", method: "DELETE"))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode), http.statusCode != 404 {
            throw AIChat.ChatError.server("Nightscout \(http.statusCode)")
        }
    }
}

/// The meal watch ("Watch the meal") was taken out of the app: its open suggestions leave
/// Nightscout and the notifications and stored meals go, once.
enum MealWatchLeftovers {
    private static let keys = ["com.loopkit.Loop.mealWatches", "com.loopkit.Loop.mealWatchUploads", "com.loopkit.Loop.mealWatchFoods"]
    private static let notificationPrefix = "mealWatch."

    static func remove(defaults: UserDefaults = .standard) {
        guard keys.contains(where: { defaults.object(forKey: $0) != nil }) else { return }
        let uploaded = Array((defaults.dictionary(forKey: "com.loopkit.Loop.mealWatchUploads") as? [String: String] ?? [:]).values)
        keys.forEach(defaults.removeObject(forKey:))
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers: requests.map(\.identifier).filter { $0.hasPrefix(notificationPrefix) })
        }
        center.getDeliveredNotifications { notifications in
            center.removeDeliveredNotifications(withIdentifiers: notifications.map(\.request.identifier).filter { $0.hasPrefix(notificationPrefix) })
        }
        guard !uploaded.isEmpty, let api = SuggestionNightscoutAPI.fromKeychain() else { return }
        Task {
            for nsID in uploaded {
                try? await api.delete(nsID)
            }
        }
    }
}
