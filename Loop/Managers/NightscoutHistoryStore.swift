//
//  NightscoutHistoryStore.swift
//  Loop
//
//  The weeks behind, kept on the phone for the glucose insight and the AI dose advice: glucose,
//  carbs and boluses, and what Loop forecast every half hour. Nightscout is asked only for what
//  is new since the last time, so after the first fill a refresh is a few kilobytes.
//

import CryptoKit
import Foundation
import LoopKit

struct NightscoutGlucoseReading: Codable, Equatable {
    var date: Date
    var mgdl: Double
}

struct NightscoutTreatment: Codable, Equatable {
    var date: Date
    var carbs: Double?
    var insulin: Double?
    var foodType: String?
    var isAutomatic: Bool
}

/// What Loop forecast at `date`: glucose then, and in one and two hours.
struct LoopForecastCheck: Codable, Equatable {
    var date: Date
    var startMgdl: Double
    var in60Mgdl: Double?
    var in120Mgdl: Double?
}

/// Everything the store holds, as saved.
struct NightscoutHistory: Codable, Equatable {
    var glucose: [NightscoutGlucoseReading] = []
    var treatments: [NightscoutTreatment] = []
    var forecasts: [LoopForecastCheck] = []
    /// How far each kind has been read from Nightscout.
    var glucoseReadThrough: Date?
    var treatmentsReadThrough: Date?
    var forecastsReadThrough: Date?
}

extension NightscoutHistory {
    /// Forecasts go back two weeks: Loop's devicestatus is large, and the forecast error that
    /// matters is the recent one.
    static let forecastDays = 14
    /// Treatments may be entered after the fact or deleted, so the last day is read again each time.
    static let treatmentOverlap: TimeInterval = .hours(24)
    static let glucoseOverlap: TimeInterval = .minutes(30)
    /// One forecast every half hour is plenty and keeps the file small.
    static let forecastSpacing: TimeInterval = .minutes(25)

    /// `items` with those from `since` on replaced by `fresh`, oldest first.
    static func merged<T>(_ items: [T], with fresh: [T], since: Date, date: (T) -> Date) -> [T] {
        (items.filter { date($0) < since } + fresh.filter { date($0) >= since }).sorted { date($0) < date($1) }
    }

    /// A meal bolus carries both carbs and insulin, so it comes back from both queries once.
    static func deduplicated(_ treatments: [NightscoutTreatment]) -> [NightscoutTreatment] {
        var seen: [NightscoutTreatment] = []
        for treatment in treatments.sorted(by: { $0.date < $1.date }) where !seen.contains(treatment) {
            seen.append(treatment)
        }
        return seen
    }

    /// Thins forecasts to one per `forecastSpacing`, oldest first.
    static func spaced(_ forecasts: [LoopForecastCheck], after previous: Date? = nil) -> [LoopForecastCheck] {
        var kept: [LoopForecastCheck] = []
        var last = previous
        for forecast in forecasts.sorted(by: { $0.date < $1.date }) {
            if let last, forecast.date.timeIntervalSince(last) < forecastSpacing { continue }
            kept.append(forecast)
            last = forecast.date
        }
        return kept
    }

    /// Drops what is older than `days`.
    mutating func trim(days: Int, now: Date) {
        let start = now.addingTimeInterval(-.hours(24 * Double(days)))
        glucose.removeAll { $0.date < start }
        treatments.removeAll { $0.date < start }
        let forecastStart = now.addingTimeInterval(-.hours(24 * Double(max(days, Self.forecastDays))))
        forecasts.removeAll { $0.date < forecastStart }
    }

    // MARK: Reading Nightscout documents

    static func parseGlucose(_ data: Data) -> [NightscoutGlucoseReading] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { entry in
            guard let sgv = (entry["sgv"] as? NSNumber)?.doubleValue, sgv > 0,
                  let milliseconds = (entry["date"] as? NSNumber)?.doubleValue
            else { return nil }
            return NightscoutGlucoseReading(date: Date(timeIntervalSince1970: milliseconds / 1000), mgdl: sgv)
        }
    }

    static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    static func parseTreatments(_ data: Data) -> [NightscoutTreatment] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { treatment in
            guard let date = parseDate(treatment["created_at"] as? String) else { return nil }
            let carbs = (treatment["carbs"] as? NSNumber)?.doubleValue
            let insulin = (treatment["insulin"] as? NSNumber)?.doubleValue
            guard (carbs ?? 0) > 0 || (insulin ?? 0) > 0 else { return nil }
            return NightscoutTreatment(
                date: date,
                carbs: (carbs ?? 0) > 0 ? carbs : nil,
                insulin: (insulin ?? 0) > 0 ? insulin : nil,
                foodType: (treatment["foodType"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                isAutomatic: (treatment["automatic"] as? Bool) ?? false
            )
        }
    }

    /// Loop's forecasts from devicestatus documents: values every five minutes from `startDate`.
    static func parseForecasts(_ data: Data) -> [LoopForecastCheck] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { status in
            guard let loop = status["loop"] as? [String: Any],
                  let predicted = loop["predicted"] as? [String: Any],
                  let start = parseDate(predicted["startDate"] as? String),
                  let values = (predicted["values"] as? [NSNumber])?.map(\.doubleValue),
                  let first = values.first, first > 0
            else { return nil }
            return LoopForecastCheck(
                date: start,
                startMgdl: first,
                in60Mgdl: values.count > 12 ? values[12] : nil,
                in120Mgdl: values.count > 24 ? values[24] : nil
            )
        }
    }
}

// MARK: - Store

actor NightscoutHistoryStore {
    static let shared = NightscoutHistoryStore()

    enum StoreError: LocalizedError {
        case noNightscout

        var errorDescription: String? {
            String(localized: "Nightscout is not set up, so the weeks behind can't be read.", comment: "Glucose insight error: no Nightscout credentials")
        }
    }

    private let fileURL: URL
    private var cached: NightscoutHistory?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
    }

    private static var defaultFileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GlucoseInsight", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("NightscoutHistory.json")
    }

    /// What is on the phone, without asking Nightscout.
    func history() -> NightscoutHistory {
        if let cached { return cached }
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(NightscoutHistory.self, from: $0) } ?? NightscoutHistory()
        cached = loaded
        return loaded
    }

    func save(_ history: NightscoutHistory) {
        cached = history
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Reads what is new from Nightscout, keeps `days` days and returns it all.
    func refresh(days: Int, now: Date = Date()) async throws -> NightscoutHistory {
        guard let credentials = try? KeychainManager().getNightscoutCredentials(), !credentials.apiSecret.isEmpty else {
            throw StoreError.noNightscout
        }
        let client = Client(siteURL: credentials.siteURL, apiSecret: credentials.apiSecret)
        var history = self.history()
        let start = now.addingTimeInterval(-.hours(24 * Double(days)))

        let glucoseSince = max(start, (history.glucoseReadThrough ?? start).addingTimeInterval(-NightscoutHistory.glucoseOverlap))
        let treatmentsSince = max(start, (history.treatmentsReadThrough ?? start).addingTimeInterval(-NightscoutHistory.treatmentOverlap))
        async let glucose = client.glucose(since: glucoseSince, until: now)
        async let treatments = client.treatments(since: treatmentsSince)
        history.glucose = NightscoutHistory.merged(history.glucose, with: try await glucose, since: glucoseSince, date: \.date)
        history.glucoseReadThrough = now
        history.treatments = NightscoutHistory.merged(history.treatments, with: try await treatments, since: treatmentsSince, date: \.date)
        history.treatmentsReadThrough = now

        // Forecasts a day at a time: a day of devicestatus is about half a megabyte.
        let forecastStart = now.addingTimeInterval(-.hours(24 * Double(NightscoutHistory.forecastDays)))
        var forecastSince = max(forecastStart, history.forecastsReadThrough ?? forecastStart)
        while forecastSince < now {
            let until = min(now, forecastSince.addingTimeInterval(.hours(24)))
            let fresh = try await client.forecasts(since: forecastSince, until: until)
            let kept = history.forecasts.filter { $0.date < forecastSince }
            history.forecasts = kept + NightscoutHistory.spaced(fresh, after: kept.last?.date)
            history.forecastsReadThrough = until
            forecastSince = until
            // Saved as it goes, so a first fill that is cut short carries on next time.
            save(history)
        }

        history.trim(days: days, now: now)
        save(history)
        return history
    }

    // MARK: Nightscout

    private struct Client {
        let siteURL: URL
        let secretHash: String

        init(siteURL: URL, apiSecret: String) {
            self.siteURL = siteURL
            self.secretHash = Insecure.SHA1.hash(data: Data(apiSecret.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        func get(_ path: String, _ query: [URLQueryItem]) async throws -> Data {
            var components = URLComponents(url: siteURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
            components.queryItems = query
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 60
            request.setValue(secretHash, forHTTPHeaderField: "api-secret")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            return data
        }

        static func iso(_ date: Date) -> String {
            ISO8601DateFormatter().string(from: date)
        }

        func glucose(since: Date, until: Date) async throws -> [NightscoutGlucoseReading] {
            let minutes = max(1, until.timeIntervalSince(since) / 60)
            let data = try await get("api/v1/entries/sgv.json", [
                URLQueryItem(name: "find[date][$gte]", value: String(Int(since.timeIntervalSince1970 * 1000))),
                URLQueryItem(name: "count", value: String(Int(minutes / 5 * 1.5) + 20)),
            ])
            return NightscoutHistory.parseGlucose(data)
        }

        /// Carbs and insulin asked for apart: Loop uploads hundreds of temp basals a day, which
        /// would otherwise crowd the oldest meals out of the count.
        func treatments(since: Date) async throws -> [NightscoutTreatment] {
            func query(_ field: String) async throws -> [NightscoutTreatment] {
                NightscoutHistory.parseTreatments(try await get("api/v1/treatments.json", [
                    URLQueryItem(name: "find[created_at][$gte]", value: Self.iso(since)),
                    URLQueryItem(name: "find[\(field)][$gt]", value: "0"),
                    URLQueryItem(name: "count", value: "10000"),
                ]))
            }
            async let carbs = query("carbs")
            async let insulin = query("insulin")
            return NightscoutHistory.deduplicated(try await carbs + insulin)
        }

        func forecasts(since: Date, until: Date) async throws -> [LoopForecastCheck] {
            let data = try await get("api/v1/devicestatus.json", [
                URLQueryItem(name: "find[created_at][$gte]", value: Self.iso(since)),
                URLQueryItem(name: "find[created_at][$lt]", value: Self.iso(until)),
                URLQueryItem(name: "count", value: "1000"),
            ])
            return NightscoutHistory.parseForecasts(data)
        }
    }
}
