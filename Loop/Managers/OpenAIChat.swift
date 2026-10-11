//
//  OpenAIChat.swift
//  Loop
//
//  The one place the app talks to OpenAI, shared by the meal estimate and the AI dose advice. It
//  uses the newest GPT model the API key can reach: the candidates are tried newest first, and
//  the first one OpenAI accepts is remembered on the phone.
//

import Foundation
import LoopKit

struct OpenAIChat {
    /// Newest first. A model the key can't reach, or that does not exist yet, is skipped.
    static let modelCandidates = ["gpt-6-astra", "gpt-6", "gpt-5.6", "gpt-5.5", "gpt-5.4"]

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
    var models: [String] {
        let candidates = Self.modelCandidates
        guard let working = defaults.openAIWorkingModel, let index = candidates.firstIndex(of: working) else {
            return candidates
        }
        // A newer model may have become available since; it is tried again once a week.
        if let checked = defaults.openAIWorkingModelDate, Date().timeIntervalSince(checked) > .hours(24 * 7) {
            return candidates
        }
        return Array(candidates[index...])
    }

    /// Sends a chat completion — `body` without `model` — and returns the response data from the
    /// newest model that accepts it.
    func send(_ body: [String: Any], timeout: TimeInterval) async throws -> Data {
        var lastError: Error = ChatError.server("No OpenAI model available")
        let models = self.models
        let triedNewest = models.first == Self.modelCandidates.first
        func remember(_ model: String) {
            defaults.openAIWorkingModel = model
            if triedNewest {
                defaults.openAIWorkingModelDate = Date()
            }
        }
        for model in models {
            var withModel = body
            withModel["model"] = model
            do {
                let data = try await post(withModel, timeout: timeout)
                remember(model)
                return data
            } catch ChatError.server(let message) where Self.isUnknownModel(message) {
                lastError = ChatError.server(message)
                continue
            } catch ChatError.server(let message) where Self.isUnsupportedReasoningEffort(message) && withModel["reasoning_effort"] != nil {
                // A model without that setting still answers without it.
                withModel["reasoning_effort"] = nil
                let data = try await post(withModel, timeout: timeout)
                remember(model)
                return data
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

    static func serverMessage(from data: Data) -> String? {
        struct ErrorBody: Decodable {
            struct Detail: Decodable { var message: String }
            var error: Detail
        }
        return (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
    }
}

extension UserDefaults {
    private enum OpenAIKey: String {
        case workingModel = "com.loopkit.Loop.openAIWorkingModel"
        case workingModelDate = "com.loopkit.Loop.openAIWorkingModelDate"
    }

    /// The newest model OpenAI last accepted.
    var openAIWorkingModel: String? {
        get { string(forKey: OpenAIKey.workingModel.rawValue) }
        set { set(newValue, forKey: OpenAIKey.workingModel.rawValue) }
    }

    var openAIWorkingModelDate: Date? {
        get { object(forKey: OpenAIKey.workingModelDate.rawValue) as? Date }
        set { set(newValue, forKey: OpenAIKey.workingModelDate.rawValue) }
    }
}
