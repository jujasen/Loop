//
//  MealCarbEstimatorTests.swift
//  LoopTests
//
//  The estimate goes straight into a carb entry, so what the app does with an odd answer —
//  an absorption time outside Loop's range, two emoji, a refusal, a broken body — is pinned here.
//

import XCTest
import LoopKit
@testable import Loop

final class MealCarbEstimatorTests: XCTestCase {
    private let range = TimeInterval(minutes: 30)...TimeInterval(hours: 8)

    private func completion(content: String) -> Data {
        let body: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private let estimateJSON = """
        {"name":"Brødskive med melk","emoji":"🥪","carbs_grams":28.64,"absorption_hours":3,
         "items":[{"food":"Grovbrød","amount":"1 skive","carbs_grams":18.64},{"food":"Melk","amount":"1 glass","carbs_grams":10}],
         "assumptions":["Antatt et lite glass melk."],"confidence":"medium"}
        """

    func testParsesCompletion() throws {
        let estimate = try MealCarbEstimator.parseResponse(completion(content: estimateJSON))
        XCTAssertEqual(estimate.name, "Brødskive med melk")
        XCTAssertEqual(estimate.items.count, 2)
        XCTAssertEqual(estimate.confidence, .medium)
        XCTAssertEqual(estimate.roundedCarbs, 28.6)
        XCTAssertEqual(estimate.absorptionTime(in: range), .hours(3))
    }

    func testAbsorptionTimeIsHeldToLoopsRange() {
        var estimate = try! MealCarbEstimator.parseResponse(completion(content: estimateJSON))
        estimate.absorptionHours = 12
        XCTAssertEqual(estimate.absorptionTime(in: range), .hours(8))
        estimate.absorptionHours = 0
        XCTAssertEqual(estimate.absorptionTime(in: range), .minutes(30))
        estimate.absorptionHours = .nan
        XCTAssertEqual(estimate.absorptionTime(in: range), .minutes(30))
    }

    func testNegativeCarbsBecomeZero() {
        var estimate = try! MealCarbEstimator.parseResponse(completion(content: estimateJSON))
        estimate.carbsGrams = -4
        XCTAssertEqual(estimate.roundedCarbs, 0)
    }

    func testKeepsOnlyTheFirstEmoji() {
        var estimate = try! MealCarbEstimator.parseResponse(completion(content: estimateJSON))
        estimate.emoji = " 🍕🥤 "
        XCTAssertEqual(estimate.foodTypeEmoji, "🍕")
        estimate.emoji = "👨‍👩‍👧 x"
        XCTAssertEqual(estimate.foodTypeEmoji, "👨‍👩‍👧")
        estimate.emoji = ""
        XCTAssertEqual(estimate.foodTypeEmoji, "🍽️")
    }

    func testRefusalIsAnError() {
        let body: [String: Any] = ["choices": [["message": ["role": "assistant", "content": NSNull(), "refusal": "No."]]]]
        let data = try! JSONSerialization.data(withJSONObject: body)
        XCTAssertThrowsError(try MealCarbEstimator.parseResponse(data)) { error in
            XCTAssertEqual(error.localizedDescription, "No.")
        }
    }

    func testUnreadableContentIsAnError() {
        XCTAssertThrowsError(try MealCarbEstimator.parseResponse(completion(content: "about 30 g")))
        XCTAssertThrowsError(try MealCarbEstimator.parseResponse(Data("not json".utf8)))
    }

    func testFollowUpCarriesTheEarlierEstimate() throws {
        let estimate = try MealCarbEstimator.parseResponse(completion(content: estimateJSON))
        let message = MealCarbEstimator.assistantMessage(for: estimate)
        XCTAssertEqual(message.role, "assistant")
        let decoded = try JSONDecoder().decode(MealCarbEstimate.self, from: Data(message.content.utf8))
        XCTAssertEqual(decoded, estimate)
    }

    func testRequestBodyPutsSystemPromptFirstAndAsksForTheSchema() throws {
        let conversation = [MealCarbEstimator.Message(role: "user", content: "pizza")]
        let body = MealCarbEstimator.requestBody(conversation: conversation)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages.last?["content"], "pizza")
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testServerErrorMessageIsShown() async {
        StubURLProtocol.response = (401, Data(#"{"error":{"message":"Incorrect API key provided"}}"#.utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let estimator = MealCarbEstimator(apiKey: "sk-test", session: URLSession(configuration: configuration))

        do {
            _ = try await estimator.estimate(conversation: [.init(role: "user", content: "eple")])
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Incorrect API key provided")
        }
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }
}

private final class StubURLProtocol: URLProtocol {
    static var response: (Int, Data) = (200, Data())
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let (status, data) = Self.response
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
