//
//  MealCarbEstimator.swift
//  Loop
//
//  Turns a free-text meal description ("en brødskive med leverpostei og et glass melk"), photos
//  of the plate, or both, into the three things the carb entry screen needs — grams, absorption
//  time and an emoji — by asking OpenAI. The caregiver can add details afterwards ("he only ate
//  half"), and the whole meal is re-evaluated with everything said so far, so the conversation is
//  kept here.
//
//  The estimate only fills in the carb entry. Nothing is saved and no insulin is recommended until
//  the caregiver reviews the numbers and continues to the bolus screen as usual.
//

import UIKit

/// One estimate for the whole meal, as returned by the model.
struct MealCarbEstimate: Codable, Equatable {
    struct Item: Codable, Equatable, Hashable {
        var food: String
        var amount: String
        var carbsGrams: Double

        enum CodingKeys: String, CodingKey {
            case food, amount
            case carbsGrams = "carbs_grams"
        }
    }

    enum Confidence: String, Codable {
        case high, medium, low
    }

    var name: String
    var emoji: String
    var carbsGrams: Double
    var absorptionHours: Double
    var items: [Item]
    var assumptions: [String]
    var confidence: Confidence

    enum CodingKeys: String, CodingKey {
        case name, emoji, items, assumptions, confidence
        case carbsGrams = "carbs_grams"
        case absorptionHours = "absorption_hours"
    }

    /// Grams rounded to what the carb entry field shows (one decimal).
    var roundedCarbs: Double {
        max(0, (carbsGrams * 10).rounded() / 10)
    }

    /// Absorption time held to Loop's allowed range, whatever the model returned.
    func absorptionTime(in range: ClosedRange<TimeInterval>) -> TimeInterval {
        let seconds = absorptionHours.isFinite ? absorptionHours * 3600 : range.lowerBound
        return min(max(seconds, range.lowerBound), range.upperBound)
    }

    /// A single emoji for the food type field; the model occasionally returns more than one.
    var foodTypeEmoji: String {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "🍽️" }
        return String(first)
    }
}

final class MealCarbEstimator {
    enum EstimateError: LocalizedError {
        case network(Error)
        case server(String)
        case unreadableResponse

        var errorDescription: String? {
            switch self {
            case .network(let error):
                return error.localizedDescription
            case .server(let message):
                return message
            case .unreadableResponse:
                return String(localized: "The estimate could not be read. Try again.", comment: "Error shown when the meal estimate response could not be parsed")
            }
        }
    }

    struct Message: Codable, Equatable {
        var role: String
        var content: String
        /// JPEG photos of the meal sent along with `content` (see `preparedPhoto(_:)`). They are
        /// kept with the message so a follow-up still shows the model the same plate.
        var images: [Data] = []

        enum CodingKeys: String, CodingKey {
            case role, content
        }
    }

    /// How many photos one message may carry.
    static let maxPhotosPerMessage = 4

    /// Scales a photo down to what the model needs to read a plate and re-encodes it as JPEG, so a
    /// few photos stay well within the request size and upload quickly on a phone connection.
    static func preparedPhoto(_ image: UIImage, maxDimension: CGFloat = 1024) -> Data? {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxDimension / longest)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.7)
    }

    static let model = "gpt-5.4-mini"

    /// Built into the app at build time (`OPENAI_API_KEY` in the xcconfig, `OpenAIAPIKey` in
    /// Info.plist). Without it the feature stays hidden.
    static let shared: MealCarbEstimator? = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "OpenAIAPIKey") as? String else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return MealCarbEstimator(apiKey: trimmed)
    }()

    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Asks for a complete estimate of the meal described across `conversation`, which alternates
    /// the caregiver's descriptions with the model's earlier estimates.
    func estimate(conversation: [Message]) async throws -> MealCarbEstimate {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        // Photos make the model take noticeably longer.
        request.timeoutInterval = conversation.contains { !$0.images.isEmpty } ? 90 : 45
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(conversation: conversation))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EstimateError.network(error)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw EstimateError.server(Self.serverMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
        return try Self.parseResponse(data)
    }

    // MARK: - Request and response

    static func requestBody(conversation: [Message]) -> [String: Any] {
        let messages = [Message(role: "system", content: systemPrompt)] + conversation
        return [
            "model": model,
            "reasoning_effort": "low",
            "messages": messages.map { ["role": $0.role, "content": content(of: $0)] },
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "meal_estimate",
                    "strict": true,
                    "schema": schema,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    /// Plain text, or — when the message carries photos — the text followed by the photos as
    /// image parts.
    private static func content(of message: Message) -> Any {
        guard !message.images.isEmpty else { return message.content }
        var parts: [[String: Any]] = []
        if !message.content.isEmpty {
            parts.append(["type": "text", "text": message.content])
        }
        for image in message.images {
            parts.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())", "detail": "high"],
            ])
        }
        return parts
    }

    static func parseResponse(_ data: Data) throws -> MealCarbEstimate {
        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    var content: String?
                    var refusal: String?
                }
                var message: Message
            }
            var choices: [Choice]
        }

        guard let completion = try? JSONDecoder().decode(Completion.self, from: data),
              let message = completion.choices.first?.message
        else {
            throw EstimateError.unreadableResponse
        }
        if let refusal = message.refusal, !refusal.isEmpty {
            throw EstimateError.server(refusal)
        }
        guard let content = message.content?.data(using: .utf8),
              let estimate = try? JSONDecoder().decode(MealCarbEstimate.self, from: content),
              estimate.carbsGrams.isFinite
        else {
            throw EstimateError.unreadableResponse
        }
        return estimate
    }

    /// The model's estimate as it goes back into the conversation, so a follow-up is judged
    /// against what it said before.
    static func assistantMessage(for estimate: MealCarbEstimate) -> Message {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let content = (try? encoder.encode(estimate)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return Message(role: "assistant", content: content)
    }

    private static func serverMessage(from data: Data) -> String? {
        struct ErrorBody: Decodable {
            struct Detail: Decodable { var message: String }
            var error: Detail
        }
        return (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
    }

    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["name", "emoji", "carbs_grams", "absorption_hours", "items", "assumptions", "confidence"],
        "properties": [
            "name": ["type": "string"],
            "emoji": ["type": "string"],
            "carbs_grams": ["type": "number"],
            "absorption_hours": ["type": "number"],
            "items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["food", "amount", "carbs_grams"],
                    "properties": [
                        "food": ["type": "string"],
                        "amount": ["type": "string"],
                        "carbs_grams": ["type": "number"],
                    ],
                ] as [String: Any],
            ] as [String: Any],
            "assumptions": ["type": "array", "items": ["type": "string"]] as [String: Any],
            "confidence": ["type": "string", "enum": ["high", "medium", "low"]] as [String: Any],
        ] as [String: Any],
    ]

    private static let systemPrompt = """
        You estimate carbohydrates for meals logged in Loop, an automated insulin delivery app for a young child with type 1 diabetes. The caregiver describes a meal in free text, usually in Norwegian. Your estimate fills in the carb entry, and the caregiver reviews it before any insulin is given.

        Return:
        - name: a short name for the meal (2-4 words), in the caregiver's language.
        - emoji: exactly one emoji for the main food of the meal (for example 🥪 for open sandwiches, not the drink next to them).
        - carbs_grams: total digestible carbohydrates in grams for the amount actually eaten. Count available carbohydrate as on Norwegian and European labels (fibre is not included).
        - absorption_hours: how long the carbs take to absorb, between 0.5 and 8, in steps of 0.5. Loop's reference points: 2 h for fast carbs (juice, fruit, candy, white bread alone), 3 h for an ordinary mixed meal, 4 h for slow meals (pasta, rice, whole grains, or meals with moderate fat and protein), 5-6 h for very fatty or protein-heavy meals (pizza, taco, burgers, creamy sauces).
        - items: each component with the amount you assumed and its carbs. The item carbs must add up to carbs_grams.
        - assumptions: short notes, in the caregiver's language, on anything you had to guess — portion size, brand, recipe. Empty when nothing was guessed.
        - confidence: high when amounts and foods are clear, medium when portions had to be guessed, low when the description is vague.

        The caregiver may attach one or more photos of the meal, with or without text. Use them to identify the foods and judge the portions — the plate, cutlery, a glass or a hand gives the scale. Several photos are of the same meal, from different angles or at different moments; do not count food twice. When a photo shows a nutrition label, use its carbohydrate values. When the text and the photos disagree, the text wins, since the caregiver knows what was actually eaten. Name in assumptions anything in the photos you could not identify.

        When no amount is given, assume a typical portion for a small child and say so in assumptions. Use Norwegian products and recipes when the food is Norwegian. When the caregiver adds more information later, re-evaluate the whole meal from scratch with everything you know, and return a complete new estimate, not just the change. Never give insulin or dosing advice.
        """
}
