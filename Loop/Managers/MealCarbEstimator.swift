//
//  MealCarbEstimator.swift
//  Loop
//
//  Turns a free-text meal description ("en brødskive med leverpostei og et glass melk"), photos
//  of the plate, or both, into the three things the carb entry screen needs — grams, absorption
//  time and an emoji — by asking Claude. The caregiver can add details afterwards ("he only ate
//  half"), and the whole meal is re-evaluated with everything said so far, so the conversation is
//  kept here.
//
//  The estimate only fills in the carb entry. Nothing is saved and no insulin is recommended until
//  the caregiver reviews the numbers and continues to the bolus screen as usual.
//

import UIKit
import LoopKit

/// One estimate for the whole meal, as returned by the model.
struct MealCarbEstimate: Codable, Equatable {
    struct Item: Codable, Equatable, Hashable {
        var food: String
        var amount: String
        var carbsGrams: Double
        /// Carbs per 100 g of the food, so someone with a kitchen scale can work the amount out
        /// themselves. Absent from estimates made before it was asked for.
        var carbsPer100g: Double? = nil

        enum CodingKeys: String, CodingKey {
            case food, amount
            case carbsGrams = "carbs_grams"
            case carbsPer100g = "carbs_per_100g"
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
    /// Fat and protein in the amount eaten, from which later carbs are worked out. Absent from
    /// estimates made before later carbs existed.
    var fatGrams: Double? = nil
    var proteinGrams: Double? = nil
    /// Why the absorption time is what it is, in one short sentence. Absent from older estimates.
    var absorptionReason: String? = nil

    enum CodingKeys: String, CodingKey {
        case name, emoji, items, assumptions, confidence
        case carbsGrams = "carbs_grams"
        case absorptionHours = "absorption_hours"
        case absorptionReason = "absorption_reason"
        case fatGrams = "fat_grams"
        case proteinGrams = "protein_grams"
    }

    /// Fat and protein for the later carbs, or `nil` when the estimate gave none.
    var nutrition: MealNutrition? {
        guard let fatGrams, let proteinGrams, fatGrams.isFinite, proteinGrams.isFinite else { return nil }
        return MealNutrition(fatGrams: max(0, fatGrams), proteinGrams: max(0, proteinGrams), carbGrams: roundedCarbs)
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

    /// Built into the app at build time (`ANTHROPIC_API_KEY` in the xcconfig, `AnthropicAPIKey` in
    /// Info.plist). Without it the feature stays hidden.
    static let shared: MealCarbEstimator? = AIChat.shared.map { MealCarbEstimator(chat: $0) }

    private let chat: AIChat

    init(chat: AIChat) {
        self.chat = chat
    }

    convenience init(apiKey: String, session: URLSession = .shared) {
        self.init(chat: AIChat(apiKey: apiKey, session: session))
    }

    /// Asks for a complete estimate of the meal described across `conversation`, which alternates
    /// the caregiver's descriptions with the model's earlier estimates. It goes to the fast tier
    /// (see `AIChat`): it was built for a mini model, and someone is waiting for it.
    ///
    /// The model may search the web first, for packaged products it doesn't know the label of
    /// (Tine Yoghurt Junior and the like). The answer is then plain text ending in the JSON, read
    /// leniently. If that fails in any way (search turned off for the key, an answer that can't
    /// be read), it asks once more without search, with the schema enforced as before.
    func estimate(conversation: [Message]) async throws -> MealCarbEstimate {
        // Photos make the model take noticeably longer, and so does a search.
        let hasPhotos = conversation.contains { !$0.images.isEmpty }
        if let estimate = try? await send(Self.requestBody(conversation: conversation, webSearch: true), timeout: hasPhotos ? 150 : 90) {
            return estimate
        }
        try Task.checkCancellation()
        return try await send(Self.requestBody(conversation: conversation), timeout: hasPhotos ? 120 : 60)
    }

    private func send(_ body: [String: Any], timeout: TimeInterval) async throws -> MealCarbEstimate {
        let data: Data
        do {
            data = try await chat.send(body, timeout: timeout, tier: .fast)
        } catch AIChat.ChatError.network(let error) {
            throw EstimateError.network(error)
        } catch AIChat.ChatError.server(let message) {
            throw EstimateError.server(message)
        }
        return try Self.parseResponse(data)
    }

    /// What is added to the description when carbs were typed in before asking.
    static func knownCarbsNote(_ grams: Double) -> String {
        let formatted = NumberFormatter.localizedString(from: NSNumber(value: grams), number: .decimal)
        return "Karbo jeg vet: \(formatted) g (fra emballasjen eller oppskriften). Bruk akkurat dette tallet som carbs_grams; vurder bare absorpsjonstiden og resten."
    }

    /// Asks for the fat and protein in a favorite food's first serving size, scaled to the food's
    /// own carbs: the model may picture a slightly different amount than the one in the register.
    func estimateNutrition(of food: StoredFavoriteFood) async throws -> MealNutrition? {
        let portion = food.defaultPortion
        let grams = portion.carbsQuantity.doubleValue(for: .gram())
        var description = "Favorittmat: \(food.name)"
        if portion.hasName {
            description += ", \(portion.name)"
        }
        description += ". \(NumberFormatter.localizedString(from: NSNumber(value: grams), number: .decimal)) g karbo. Anslå fett og protein for akkurat denne mengden, slik den vanligvis lages for et lite barn."

        let estimate = try await estimate(conversation: [Message(role: "user", content: description)])
        guard let nutrition = estimate.nutrition else { return nil }
        guard estimate.roundedCarbs > 0, grams > 0 else {
            return MealNutrition(fatGrams: nutrition.fatGrams, proteinGrams: nutrition.proteinGrams, carbGrams: grams)
        }
        return nutrition.scaled(toCarbs: grams)
    }

    // MARK: - Request and response

    /// With `webSearch` the model may search the web, and the schema is given in words instead of
    /// enforced (a search answer comes with citations, which an enforced format does not allow).
    static func requestBody(conversation: [Message], webSearch: Bool = false) -> [String: Any] {
        let system = webSearch ? systemPrompt + "\n\n" + webSearchPrompt : systemPrompt
        let messages = [Message(role: "system", content: system)] + conversation
        var body: [String: Any] = [
            "reasoning_effort": "low",
            "messages": messages.map { ["role": $0.role, "content": content(of: $0)] },
        ]
        if webSearch {
            body["web_search"] = true
        } else {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "meal_estimate",
                    "strict": true,
                    "schema": schema,
                ] as [String: Any],
            ] as [String: Any]
        }
        return body
    }

    /// The JSON in an answer that may have text around it: from the first «{» that starts an
    /// estimate to the last «}».
    static func jsonObject(in text: String) -> Data? {
        if let data = text.data(using: .utf8), (try? JSONDecoder().decode(MealCarbEstimate.self, from: data)) != nil {
            return data
        }
        guard let end = text.lastIndex(of: "}") else { return nil }
        var start = text.startIndex
        while let open = text[start...].firstIndex(of: "{"), open < end {
            let candidate = String(text[open...end])
            if let data = candidate.data(using: .utf8), (try? JSONDecoder().decode(MealCarbEstimate.self, from: data)) != nil {
                return data
            }
            start = text.index(after: open)
        }
        return nil
    }

    /// Plain text, or — when the message carries photos — the text followed by the photos as
    /// image parts.
    static func content(of message: Message) -> Any {
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
        guard let content = message.content.flatMap(jsonObject(in:)),
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

    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["name", "emoji", "carbs_grams", "absorption_hours", "absorption_reason", "items", "assumptions", "confidence", "fat_grams", "protein_grams"],
        "properties": [
            "name": ["type": "string"],
            "emoji": ["type": "string"],
            "carbs_grams": ["type": "number"],
            "absorption_hours": ["type": "number"],
            "absorption_reason": ["type": "string"],
            "items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["food", "amount", "carbs_grams", "carbs_per_100g"],
                    "properties": [
                        "food": ["type": "string"],
                        "amount": ["type": "string"],
                        "carbs_grams": ["type": "number"],
                        "carbs_per_100g": ["type": "number"],
                    ],
                ] as [String: Any],
            ] as [String: Any],
            "assumptions": ["type": "array", "items": ["type": "string"]] as [String: Any],
            "confidence": ["type": "string", "enum": ["high", "medium", "low"]] as [String: Any],
            "fat_grams": ["type": "number"],
            "protein_grams": ["type": "number"],
        ] as [String: Any],
    ]

    private static let systemPrompt = """
        You estimate carbohydrates for meals logged in Loop, an automated insulin delivery app for a young child with type 1 diabetes. The caregiver describes a meal in free text, usually in Norwegian. Your estimate fills in the carb entry, and the caregiver reviews it before any insulin is given.

        Return:
        - name: a short name for the meal (2-4 words), in the caregiver's language.
        - emoji: exactly one emoji for the main food of the meal (for example 🥪 for open sandwiches, not the drink next to them).
        - carbs_grams: total digestible carbohydrates in grams for the amount actually eaten. Count available carbohydrate as on Norwegian and European labels (fibre is not included).
        - absorption_hours: how long the carbs take to absorb, between 0.5 and 8, in steps of 0.5. Loop's reference points: 2 h for fast carbs (juice, fruit, candy, white bread alone), 3 h for an ordinary mixed meal, 4 h for slow meals (pasta, rice, whole grains, or meals with moderate fat and protein), 5-6 h for very fatty or protein-heavy meals (pizza, taco, burgers, creamy sauces). More reference points for a small child: juice, sports drink, glucose tablets, fruit puree pouches and dried fruit 1-1.5 h; fresh fruit, rice cakes, biscuits and sweet yoghurt or milk drinks 1.5-2 h; milk and plain yoghurt, bread with spread, cereal with milk and porridge 2-2.5 h; dinner with potatoes or bread 3 h; pasta, rice, pancakes or waffles with fat 3-4 h. Decide from what is actually in it: fat, protein and fibre slow it, liquids and sugar speed it up. When the caregiver gives the carbs, the absorption time is what they need from you, so think it through.
        - absorption_reason: one short sentence, in the caregiver's language, on why that absorption time (for example «2 t: melkeprodukt med sukker og litt fett – raskere enn et måltid»).
        - items: each component with the amount you assumed and its carbs. The item carbs must add up to carbs_grams. In amount, say how many pieces and roughly what they weigh (for example «1 stk, ca. 70 g»). carbs_per_100g is the food's carbs per 100 g, so the caregiver can weigh it and work it out.
        - assumptions: short notes, in the caregiver's language, on anything you had to guess — portion size, brand, recipe. Empty when nothing was guessed.
        - confidence: high when amounts and foods are clear, medium when portions had to be guessed, low when the description is vague.
        - fat_grams and protein_grams: total fat and protein in grams for the amount actually eaten, from Norwegian food tables (Matvaretabellen) and labels. Count butter, oil, cheese, cream and whole milk that go with the food.

        The caregiver often asks it as a question, the way they would ask a chatbot («Hvor mye kh i en nonstop og en seigmann?», «hvor mye karbo i grove rundstykker med havregryn»). Treat a question exactly like a description: what is named is what the child eats now. «En», «ett» or a plural without a number means one piece or one typical portion for a small child; say which in assumptions.

        The caregiver may attach one or more photos of the meal, with or without text. Use them to identify the foods and judge the portions — the plate, cutlery, a glass or a hand gives the scale. Several photos are of the same meal, from different angles or at different moments; do not count food twice. When a photo shows a nutrition label, use its carbohydrate values. When the text and the photos disagree, the text wins, since the caregiver knows what was actually eaten. Name in assumptions anything in the photos you could not identify.

        When the caregiver gives the carbs (on its own, from a label or as «Karbo jeg vet»), use exactly that number as carbs_grams and keep the items adding up to it; do not estimate the carbs again.

        When no amount is given, assume a typical portion for a small child and say so in assumptions. Use Norwegian products and recipes when the food is Norwegian. When the caregiver adds more information later, re-evaluate the whole meal from scratch with everything you know, and return a complete new estimate, not just the change. Never give insulin or dosing advice.
        """

    /// Added when the model may search the web.
    static let webSearchPrompt = """
        You can search the web. Do it when the meal has a packaged or branded product whose label you don't know for certain (for example Tine Yoghurt Junior klemmepose, a Nora or Freia product, a ready meal or a café item): look up its nutrition facts, preferably on the producer's site, Kassalapp or Oda, and use the carbohydrate per package or per 100 g. Say in assumptions where the number came from, briefly (for example «Tine.no: 10,8 g karbo per 90 g pose»). Don't search for ordinary foods you know well, and never when the caregiver gave the carbs. Search in Norwegian.

        End your answer with the estimate as one JSON object and nothing after it, with exactly these keys: name, emoji, carbs_grams, absorption_hours, absorption_reason, items (each with food, amount, carbs_grams, carbs_per_100g), assumptions, confidence ("high", "medium" or "low"), fat_grams, protein_grams.
        """
}
