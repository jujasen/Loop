//
//  AIChat.swift
//  Loop
//
//  The one place the app talks to an AI model, Claude (Anthropic), shared by the meal estimate,
//  the AI dose advice and the glucose insight. Callers write their requests in the chat
//  completions shape the app has always used, and read the answer in that shape; `send`
//  translates both ways to Claude's Messages API.
//
//  There are three tiers: `deep` for the nightly look at the weeks behind, `fast` for what a
//  person waits for (meal estimate, dose advice), and `quick`, the cheapest, for the frequent
//  calls nobody waits on (the day's insight). Within a tier the candidates are
//  tried in order, and the first one accepted is remembered on the phone. What each call costs
//  is counted per day.
//

import Foundation
import LoopKit

struct AIChat {
    enum Tier: String, Codable, CaseIterable {
        /// The thorough model, for the nightly look back.
        case deep
        /// A capable model for what a person waits for.
        case fast
        /// The cheapest model, for frequent calls nobody waits on.
        case quick

        /// Newest first. A model the key can't reach, or that does not exist yet, is skipped.
        var modelCandidates: [String] {
            switch self {
            case .deep, .fast: return ["claude-sonnet-5-5", "claude-sonnet-5"]
            case .quick: return ["claude-haiku-5-5"]
            }
        }

        /// Sonnet may fall back to another Claude model when a safety classifier declines;
        /// Haiku has no such fallback.
        var usesRefusalFallback: Bool { self != .quick }

        /// US dollars per million tokens: input, cached input, output (thinking counts as output).
        /// List prices in October 2026 for the first candidate; only an estimate.
        var pricePerMillion: (input: Double, cachedInput: Double, output: Double) {
            switch self {
            case .deep, .fast: return (2, 0.2, 10)
            case .quick: return (0.1, 0.01, 0.5)
            }
        }
    }

    /// The key built into the app (`ANTHROPIC_API_KEY` in the xcconfig, `AnthropicAPIKey` in
    /// Info.plist). Without it the AI features stay hidden.
    static let shared: AIChat? = builtInKey().map { AIChat(apiKey: $0) }

    private static func builtInKey() -> String? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "AnthropicAPIKey") as? String else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

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
        guard let working = defaults.aiWorkingModel(for: tier), let index = candidates.firstIndex(of: working) else {
            return candidates
        }
        // A newer model may have become available since; it is tried again once a week.
        if let checked = defaults.aiWorkingModelDate(for: tier), Date().timeIntervalSince(checked) > .hours(24 * 7) {
            return candidates
        }
        return Array(candidates[index...])
    }

    /// Sends a chat completion — `body` without `model` — and returns the response data, in chat
    /// completions shape, from the first model of `tier` that accepts it.
    func send(_ body: [String: Any], timeout: TimeInterval, tier: Tier = .deep) async throws -> Data {
        var lastError: Error = ChatError.server("No AI model available")
        let models = self.models(for: tier)
        let triedNewest = models.first == tier.modelCandidates.first
        func remember(_ model: String, _ data: Data) {
            defaults.setAIWorkingModel(model, for: tier)
            if triedNewest {
                defaults.setAIWorkingModelDate(Date(), for: tier)
            }
            defaults.addAIUsage(Self.usage(from: data, tier: tier), tier: tier)
        }
        for model in models {
            var withModel = body
            withModel["model"] = model
            do {
                let data = try await post(withModel, timeout: timeout, tier: tier)
                remember(model, data)
                return data
            } catch ChatError.server(let message) where Self.isUnsupportedEffort(message) && withModel["reasoning_effort"] != nil {
                // A model without that setting still answers without it.
                withModel["reasoning_effort"] = nil
                let data = try await post(withModel, timeout: timeout, tier: tier)
                remember(model, data)
                return data
            } catch ChatError.server(let message) where Self.isUnknownModel(message) {
                lastError = ChatError.server(message)
                continue
            }
        }
        throw lastError
    }

    private func post(_ body: [String: Any], timeout: TimeInterval, tier: Tier) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        var claudeBody = Self.claudeRequest(from: body)
        if tier.usesRefusalFallback {
            request.setValue(Self.refusalFallbackBeta, forHTTPHeaderField: "anthropic-beta")
            claudeBody["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: claudeBody)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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
        return try Self.completion(fromClaude: data)
    }

    // MARK: - Claude

    static let anthropicVersion = "2026-10-21"
    /// Lets the server answer with another Claude model when a safety classifier declines.
    static let refusalFallbackBeta = "server-side-fallback-2026-07-01"

    /// A chat completions body as a Claude Messages request: system messages become the cached
    /// system prompt, `image_url` data URLs base64 images, `response_format`'s schema the output
    /// format and `reasoning_effort` the effort. Thinking stays on (adaptive), as these models want.
    static func claudeRequest(from body: [String: Any]) -> [String: Any] {
        var system: [String] = []
        var messages: [[String: Any]] = []
        for message in body["messages"] as? [[String: Any]] ?? [] {
            let role = message["role"] as? String ?? "user"
            if role == "system" || role == "developer" {
                if let text = message["content"] as? String {
                    system.append(text)
                }
                continue
            }
            messages.append(["role": role == "assistant" ? "assistant" : "user", "content": claudeContent(message["content"])])
        }

        var request: [String: Any] = [
            "model": body["model"] as? String ?? "",
            "max_tokens": 16000,
            "messages": messages,
        ]
        if !system.isEmpty {
            request["system"] = [["type": "text", "text": system.joined(separator: "\n\n"), "cache_control": ["type": "ephemeral"]]]
        }
        var outputConfig: [String: Any] = [:]
        if let effort = body["reasoning_effort"] as? String, ["low", "medium", "high"].contains(effort) {
            outputConfig["effort"] = effort
        }
        if let format = body["response_format"] as? [String: Any],
           let jsonSchema = format["json_schema"] as? [String: Any],
           let schema = jsonSchema["schema"] {
            outputConfig["format"] = ["type": "json_schema", "schema": schema]
        }
        if !outputConfig.isEmpty {
            request["output_config"] = outputConfig
        }
        return request
    }

    private static func claudeContent(_ content: Any?) -> Any {
        guard let parts = content as? [[String: Any]] else { return content as? String ?? "" }
        return parts.compactMap { part -> [String: Any]? in
            switch part["type"] as? String {
            case "text":
                return ["type": "text", "text": part["text"] as? String ?? ""]
            case "image_url":
                guard let url = (part["image_url"] as? [String: Any])?["url"] as? String,
                      url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
                let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
                let mediaType = header.split(separator: ";").first.map(String.init) ?? "image/jpeg"
                return ["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": String(url[url.index(after: comma)...])]]
            default:
                return nil
            }
        }
    }

    /// Claude's answer in chat completions shape: the text blocks as the message content, a
    /// refusal as `refusal`, and the token counts as `usage`.
    static func completion(fromClaude data: Data) throws -> Data {
        struct Response: Decodable {
            struct Block: Decodable {
                var type: String
                var text: String?
            }
            struct StopDetails: Decodable {
                var explanation: String?
            }
            struct Usage: Decodable {
                var input_tokens: Int?
                var output_tokens: Int?
                var cache_read_input_tokens: Int?
                var cache_creation_input_tokens: Int?
            }
            var content: [Block]
            var stop_reason: String?
            var stop_details: StopDetails?
            var usage: Usage?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ChatError.server("Unreadable answer from Claude")
        }
        var message: [String: Any] = ["role": "assistant"]
        if response.stop_reason == "refusal" {
            message["content"] = NSNull()
            message["refusal"] = response.stop_details?.explanation ?? "Claude declined to answer."
        } else {
            message["content"] = response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        }
        let cached = response.usage?.cache_read_input_tokens ?? 0
        let input = (response.usage?.input_tokens ?? 0) + (response.usage?.cache_creation_input_tokens ?? 0) + cached
        let completion: [String: Any] = [
            "choices": [["message": message]],
            "usage": [
                "prompt_tokens": input,
                "completion_tokens": response.usage?.output_tokens ?? 0,
                "prompt_tokens_details": ["cached_tokens": cached],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: completion)
    }

    // MARK: - Errors and usage

    /// Anthropic's wording when a model does not exist or the key has no access to it.
    static func isUnknownModel(_ message: String) -> Bool {
        let lowered = message.lowercased()
        // "effort is not supported with this model" is about the setting, not the model.
        guard !lowered.contains("effort") else { return false }
        return lowered.contains("model") && (
            lowered.contains("does not exist") ||
            lowered.contains("not found") ||
            lowered.contains("do not have access") ||
            lowered.contains("not supported") ||
            lowered.contains("invalid model")
        )
    }

    static func isUnsupportedEffort(_ message: String) -> Bool {
        message.lowercased().contains("effort")
    }

    /// The tokens a response says it used, priced for `tier`; zero when it does not say.
    static func usage(from data: Data, tier: Tier = .deep) -> AIUsage {
        struct Body: Decodable {
            struct Usage: Decodable {
                struct Details: Decodable { var cached_tokens: Int? }
                var prompt_tokens: Int?
                var completion_tokens: Int?
                var prompt_tokens_details: Details?
            }
            var usage: Usage?
        }
        guard let usage = (try? JSONDecoder().decode(Body.self, from: data))?.usage else { return AIUsage(calls: 1) }
        let cached = usage.prompt_tokens_details?.cached_tokens ?? 0
        var result = AIUsage(
            calls: 1,
            inputTokens: max(0, (usage.prompt_tokens ?? 0) - cached),
            cachedInputTokens: cached,
            outputTokens: usage.completion_tokens ?? 0
        )
        let price = tier.pricePerMillion
        result.cost = (Double(result.inputTokens) * price.input + Double(cached) * price.cachedInput + Double(result.outputTokens) * price.output) / 1_000_000
        return result
    }

    /// The `error.message` the API answers with on failure.
    static func serverMessage(from data: Data) -> String? {
        struct ErrorBody: Decodable {
            struct Detail: Decodable { var message: String }
            var error: Detail
        }
        return (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
    }
}

/// Tokens used, added up per day and tier.
struct AIUsage: Codable, Equatable {
    var calls = 0
    var inputTokens = 0
    var cachedInputTokens = 0
    var outputTokens = 0
    /// US dollars at the list price of the model that answered; `nil` for days counted before
    /// the cost was kept, priced now at the tier's price.
    var cost: Double?

    static func + (lhs: AIUsage, rhs: AIUsage) -> AIUsage {
        AIUsage(
            calls: lhs.calls + rhs.calls,
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cost: lhs.cost == nil && rhs.cost == nil ? nil : (lhs.cost ?? 0) + (rhs.cost ?? 0)
        )
    }

    /// In US dollars.
    func dollars(_ tier: AIChat.Tier) -> Double {
        if let cost {
            return cost
        }
        let price = tier.pricePerMillion
        return (Double(inputTokens) * price.input + Double(cachedInputTokens) * price.cachedInput + Double(outputTokens) * price.output) / 1_000_000
    }
}

/// One day's use of each tier.
struct AIDailyUsage: Codable, Equatable {
    /// "yyyy-MM-dd" in local time.
    var day: String
    var byTier: [AIChat.Tier: AIUsage] = [:]

    var dollars: Double {
        byTier.reduce(0) { $0 + $1.value.dollars($1.key) }
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension UserDefaults {
    private enum AIKey: String {
        case workingModel = "com.loopkit.Loop.aiWorkingModel"
        case workingModelDate = "com.loopkit.Loop.aiWorkingModelDate"
        case usage = "com.loopkit.Loop.aiDailyUsage"
    }

    /// The deep tier's keys are the ones used before there were tiers.
    private func aiKey(_ key: AIKey, _ tier: AIChat.Tier) -> String {
        tier == .deep ? key.rawValue : "\(key.rawValue).\(tier.rawValue)"
    }

    /// The newest deep model last accepted.
    var aiWorkingModel: String? {
        get { aiWorkingModel(for: .deep) }
        set { setAIWorkingModel(newValue, for: .deep) }
    }

    func aiWorkingModel(for tier: AIChat.Tier) -> String? {
        string(forKey: aiKey(.workingModel, tier))
    }

    func setAIWorkingModel(_ model: String?, for tier: AIChat.Tier) {
        set(model, forKey: aiKey(.workingModel, tier))
    }

    func aiWorkingModelDate(for tier: AIChat.Tier) -> Date? {
        object(forKey: aiKey(.workingModelDate, tier)) as? Date
    }

    func setAIWorkingModelDate(_ date: Date?, for tier: AIChat.Tier) {
        set(date, forKey: aiKey(.workingModelDate, tier))
    }

    /// The last two weeks, newest last.
    var aiDailyUsage: [AIDailyUsage] {
        get {
            guard let data = data(forKey: AIKey.usage.rawValue) else { return [] }
            return (try? JSONDecoder().decode([AIDailyUsage].self, from: data)) ?? []
        }
        set { set(try? JSONEncoder().encode(Array(newValue.suffix(14))), forKey: AIKey.usage.rawValue) }
    }

    func aiUsage(on date: Date) -> AIDailyUsage {
        let day = AIDailyUsage.dayKey(date)
        return aiDailyUsage.last { $0.day == day } ?? AIDailyUsage(day: day)
    }

    func addAIUsage(_ usage: AIUsage, tier: AIChat.Tier, now: Date = Date()) {
        var days = aiDailyUsage
        let day = AIDailyUsage.dayKey(now)
        if days.last?.day != day {
            days.append(AIDailyUsage(day: day))
        }
        days[days.count - 1].byTier[tier] = (days[days.count - 1].byTier[tier] ?? AIUsage()) + usage
        aiDailyUsage = days
    }
}
