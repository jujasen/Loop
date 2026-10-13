//
//  OpenAIChat.swift
//  Loop
//
//  The one place the app talks to OpenAI, shared by the meal estimate, the AI dose advice and the
//  glucose insight. There are two tiers: `deep`, the newest and largest GPT model, for the nightly
//  look at the weeks behind; and `fast`, a smaller one at a fifth of the price, for everything a
//  person waits for. Within a tier the candidates are tried newest first, and the first one
//  OpenAI accepts is remembered on the phone. What each call costs is counted per day.
//

import Foundation
import LoopKit

struct OpenAIChat {
    enum Tier: String, Codable, CaseIterable {
        /// The newest, largest model: thorough and slow, and about five times the price.
        case deep
        /// A smaller model for what a person waits for.
        case fast

        /// Newest first. A model the key can't reach, or that does not exist yet, is skipped.
        var modelCandidates: [String] {
            switch self {
            case .deep: return ["gpt-6-astra", "gpt-6", "gpt-5.6", "gpt-5.5", "gpt-5.4"]
            case .fast: return ["gpt-6.1-sol", "gpt-6-sol", "gpt-5.6-sol", "gpt-5.4-mini"]
            }
        }

        /// US dollars per million tokens: input, cached input, output (reasoning counts as output).
        /// From OpenAI's list prices in October 2026, for the first candidate; only an estimate.
        var pricePerMillion: (input: Double, cachedInput: Double, output: Double) {
            switch self {
            case .deep: return (10, 1, 50)
            case .fast: return (2, 0.2, 10)
            }
        }
    }

    /// The deep tier's candidates.
    static var modelCandidates: [String] { Tier.deep.modelCandidates }

    /// Built into the app at build time (`OPENAI_API_KEY` in the xcconfig, `OpenAIAPIKey` in
    /// Info.plist). Without it the AI features stay hidden.
    static let shared: OpenAIChat? = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "OpenAIAPIKey") as? String else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return OpenAIChat(apiKey: trimmed)
    }()

    enum ChatError: LocalizedError {
        case network(Error)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .network(let error):
                return error.localizedDescription
            case .server(let message):
                return message
            }
        }
    }

    let apiKey: String
    let session: URLSession
    let defaults: UserDefaults

    init(apiKey: String, session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.apiKey = apiKey
        self.session = session
        self.defaults = defaults
    }

    /// The candidates to try, the one that worked last time first.
    func models(for tier: Tier = .deep) -> [String] {
        let candidates = tier.modelCandidates
        guard let working = defaults.openAIWorkingModel(for: tier), let index = candidates.firstIndex(of: working) else {
            return candidates
        }
        // A newer model may have become available since; it is tried again once a week.
        if let checked = defaults.openAIWorkingModelDate(for: tier), Date().timeIntervalSince(checked) > .hours(24 * 7) {
            return candidates
        }
        return Array(candidates[index...])
    }

    /// Sends a chat completion — `body` without `model` — and returns the response data from the
    /// newest model of `tier` that accepts it.
    func send(_ body: [String: Any], timeout: TimeInterval, tier: Tier = .deep) async throws -> Data {
        var lastError: Error = ChatError.server("No OpenAI model available")
        let models = self.models(for: tier)
        let triedNewest = models.first == tier.modelCandidates.first
        func remember(_ model: String, _ data: Data) {
            defaults.setOpenAIWorkingModel(model, for: tier)
            if triedNewest {
                defaults.setOpenAIWorkingModelDate(Date(), for: tier)
            }
            defaults.addOpenAIUsage(Self.usage(from: data), tier: tier)
        }
        for model in models {
            var withModel = body
            withModel["model"] = model
            do {
                let data = try await post(withModel, timeout: timeout)
                remember(model, data)
                return data
            } catch ChatError.server(let message) where Self.isUnsupportedReasoningEffort(message) && withModel["reasoning_effort"] != nil {
                // A model without that setting still answers without it.
                withModel["reasoning_effort"] = nil
                let data = try await post(withModel, timeout: timeout)
                remember(model, data)
                return data
            } catch ChatError.server(let message) where Self.isUnknownModel(message) {
                lastError = ChatError.server(message)
                continue
            }
        }
        throw lastError
    }

    private func post(_ body: [String: Any], timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ChatError.network(error)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ChatError.server(Self.serverMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return data
    }

    /// OpenAI's wording when a model does not exist or the key has no access to it.
    static func isUnknownModel(_ message: String) -> Bool {
        let lowered = message.lowercased()
        // "'reasoning_effort' is not supported with this model" is about the setting, not the model.
        guard !lowered.contains("reasoning_effort") else { return false }
        return lowered.contains("model") && (
            lowered.contains("does not exist") ||
            lowered.contains("not found") ||
            lowered.contains("do not have access") ||
            lowered.contains("not supported") ||
            lowered.contains("invalid model")
        )
    }

    static func isUnsupportedReasoningEffort(_ message: String) -> Bool {
        message.lowercased().contains("reasoning_effort")
    }

    /// The tokens a response says it used; zero when it does not say.
    static func usage(from data: Data) -> OpenAIUsage {
        struct Body: Decodable {
            struct Usage: Decodable {
                struct Details: Decodable { var cached_tokens: Int? }
                var prompt_tokens: Int?
                var completion_tokens: Int?
                var prompt_tokens_details: Details?
            }
            var usage: Usage?
        }
        guard let usage = (try? JSONDecoder().decode(Body.self, from: data))?.usage else { return OpenAIUsage(calls: 1) }
        let cached = usage.prompt_tokens_details?.cached_tokens ?? 0
        return OpenAIUsage(
            calls: 1,
            inputTokens: max(0, (usage.prompt_tokens ?? 0) - cached),
            cachedInputTokens: cached,
            outputTokens: usage.completion_tokens ?? 0
        )
    }

    static func serverMessage(from data: Data) -> String? {
        struct ErrorBody: Decodable {
            struct Detail: Decodable { var message: String }
            var error: Detail
        }
        return (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
    }
}

/// Tokens used, added up per day and tier.
struct OpenAIUsage: Codable, Equatable {
    var calls = 0
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0

    static func + (lhs: OpenAIUsage, rhs: OpenAIUsage) -> OpenAIUsage {
        OpenAIUsage(
            calls: lhs.calls + rhs.calls,
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens
        )
    }

    /// In US dollars, at the tier's list price.
    func dollars(_ tier: OpenAIChat.Tier) -> Double {
        let price = tier.pricePerMillion
        return (Double(inputTokens) * price.input + Double(cachedInputTokens) * price.cachedInput + Double(outputTokens) * price.output) / 1_000_000
    }
}

/// One day's use of each tier.
struct OpenAIDailyUsage: Codable, Equatable {
    /// "yyyy-MM-dd" in local time.
    var day: String
    var byTier: [OpenAIChat.Tier: OpenAIUsage] = [:]

    var dollars: Double {
        byTier.reduce(0) { $0 + $1.value.dollars($1.key) }
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension UserDefaults {
    private enum OpenAIKey: String {
        case workingModel = "com.loopkit.Loop.openAIWorkingModel"
        case workingModelDate = "com.loopkit.Loop.openAIWorkingModelDate"
        case usage = "com.loopkit.Loop.openAIDailyUsage"
    }

    /// The deep tier's keys are the ones used before there were tiers.
    private func openAIKey(_ key: OpenAIKey, _ tier: OpenAIChat.Tier) -> String {
        tier == .deep ? key.rawValue : "\(key.rawValue).\(tier.rawValue)"
    }

    /// The newest deep model OpenAI last accepted.
    var openAIWorkingModel: String? {
        get { openAIWorkingModel(for: .deep) }
        set { setOpenAIWorkingModel(newValue, for: .deep) }
    }

    func openAIWorkingModel(for tier: OpenAIChat.Tier) -> String? {
        string(forKey: openAIKey(.workingModel, tier))
    }

    func setOpenAIWorkingModel(_ model: String?, for tier: OpenAIChat.Tier) {
        set(model, forKey: openAIKey(.workingModel, tier))
    }

    func openAIWorkingModelDate(for tier: OpenAIChat.Tier) -> Date? {
        object(forKey: openAIKey(.workingModelDate, tier)) as? Date
    }

    func setOpenAIWorkingModelDate(_ date: Date?, for tier: OpenAIChat.Tier) {
        set(date, forKey: openAIKey(.workingModelDate, tier))
    }

    /// The last two weeks, newest last.
    var openAIDailyUsage: [OpenAIDailyUsage] {
        get {
            guard let data = data(forKey: OpenAIKey.usage.rawValue) else { return [] }
            return (try? JSONDecoder().decode([OpenAIDailyUsage].self, from: data)) ?? []
        }
        set { set(try? JSONEncoder().encode(Array(newValue.suffix(14))), forKey: OpenAIKey.usage.rawValue) }
    }

    func openAIUsage(on date: Date) -> OpenAIDailyUsage {
        let day = OpenAIDailyUsage.dayKey(date)
        return openAIDailyUsage.last { $0.day == day } ?? OpenAIDailyUsage(day: day)
    }

    func addOpenAIUsage(_ usage: OpenAIUsage, tier: OpenAIChat.Tier, now: Date = Date()) {
        var days = openAIDailyUsage
        let day = OpenAIDailyUsage.dayKey(now)
        if days.last?.day != day {
            days.append(OpenAIDailyUsage(day: day))
        }
        days[days.count - 1].byTier[tier] = (days[days.count - 1].byTier[tier] ?? OpenAIUsage()) + usage
        openAIDailyUsage = days
    }
}
