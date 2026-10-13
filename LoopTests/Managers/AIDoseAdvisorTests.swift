//
//  AIDoseAdvisorTests.swift
//  LoopTests
//
//  AI dose advice: the limits on the dose, when none is given, the request and answer, reading
//  Nightscout documents, and finding the newest GPT model of each tier the key can reach.
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

final class AIDoseAdvisorTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let pumpSteps: (Double) -> Double = { ($0 * 20).rounded() / 20 }

    // MARK: Limits

    func testDoseWithinTheLimitsIsKeptAndRounded() {
        let result = AIDoseAdvisor.limitedDose(1.23, loopUnits: 1.0, maximumBolus: 3, settings: AIDoseAdviceSettings(), round: pumpSteps)
        XCTAssertEqual(result.units, 1.25, accuracy: 0.0001)
        XCTAssertNil(result.limitedFrom)
    }

    func testDoseIsHeldToTheAmountAboveLoop() {
        var settings = AIDoseAdviceSettings()
        settings.maximumAboveLoop = 0.5
        let result = AIDoseAdvisor.limitedDose(2.4, loopUnits: 1.0, maximumBolus: 5, settings: settings, round: pumpSteps)
        XCTAssertEqual(result.units, 1.5, accuracy: 0.0001)
        XCTAssertEqual(result.limitedFrom, 2.4)
    }

    func testDoseIsHeldToTheMaximumBolus() {
        var settings = AIDoseAdviceSettings()
        settings.maximumAboveLoop = 2
        let result = AIDoseAdvisor.limitedDose(4, loopUnits: 2.5, maximumBolus: 3, settings: settings, round: pumpSteps)
        XCTAssertEqual(result.units, 3, accuracy: 0.0001)
        XCTAssertEqual(result.limitedFrom, 4)
    }

    func testRoundingNeverCarriesTheDoseOverTheLimit() {
        var settings = AIDoseAdviceSettings()
        settings.maximumAboveLoop = 0.1
        // Limit 0.93; nearest pump step 0.95 would be over it.
        let result = AIDoseAdvisor.limitedDose(2, loopUnits: 0.83, maximumBolus: 5, settings: settings, round: pumpSteps)
        XCTAssertLessThanOrEqual(result.units, 0.93)
        XCTAssertEqual(result.units, 0.9, accuracy: 0.0001)
    }

    func testNegativeOrBrokenDoseBecomesZero() {
        XCTAssertEqual(AIDoseAdvisor.limitedDose(-1, loopUnits: 0, maximumBolus: 3, settings: AIDoseAdviceSettings(), round: pumpSteps).units, 0)
        XCTAssertEqual(AIDoseAdvisor.limitedDose(.nan, loopUnits: 1, maximumBolus: 3, settings: AIDoseAdviceSettings(), round: pumpSteps).units, 0)
    }

    func testWithoutALoopRecommendationOnlyTheAmountAboveZeroIsAllowed() {
        let result = AIDoseAdvisor.limitedDose(1, loopUnits: nil, maximumBolus: 3, settings: AIDoseAdviceSettings(), round: pumpSteps)
        XCTAssertEqual(result.units, 0.5, accuracy: 0.0001)
    }

    // MARK: When no advice is given

    func testNoAdviceOnStaleOrLowGlucoseOrAPredictedLow() {
        XCTAssertNotNil(AIDoseAdvisor.blockingReason(glucoseMgdl: 120, glucoseDate: now.addingTimeInterval(-.minutes(20)), notice: nil, loopUnits: 1, lowestForecastMgdl: 110, suspendThresholdMgdl: 72, now: now))
        XCTAssertNotNil(AIDoseAdvisor.blockingReason(glucoseMgdl: nil, glucoseDate: nil, notice: nil, loopUnits: 1, lowestForecastMgdl: 110, suspendThresholdMgdl: 72, now: now))
        XCTAssertNotNil(AIDoseAdvisor.blockingReason(glucoseMgdl: 65, glucoseDate: now, notice: nil, loopUnits: 1, lowestForecastMgdl: 110, suspendThresholdMgdl: 72, now: now))
        XCTAssertNotNil(AIDoseAdvisor.blockingReason(glucoseMgdl: 120, glucoseDate: now, notice: .staleGlucoseData, loopUnits: 1, lowestForecastMgdl: 110, suspendThresholdMgdl: 72, now: now))
        XCTAssertNotNil(AIDoseAdvisor.blockingReason(glucoseMgdl: 120, glucoseDate: now, notice: .stalePumpData, loopUnits: 1, lowestForecastMgdl: 110, suspendThresholdMgdl: 72, now: now))
        let threshold = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 72)
        XCTAssertNotNil(AIDoseAdvisor.blockingReason(glucoseMgdl: 120, glucoseDate: now, notice: .predictedGlucoseBelowSuspendThreshold(suspendThreshold: threshold), loopUnits: 1, lowestForecastMgdl: 110, suspendThresholdMgdl: 72, now: now))
    }

    func testNoAdviceWithoutALoopRecommendationOrWithALowInTheForecast() {
        XCTAssertNotNil(AIDoseAdvisor.blockingReason(glucoseMgdl: 140, glucoseDate: now, notice: nil, loopUnits: nil, lowestForecastMgdl: 110, suspendThresholdMgdl: 72, now: now))
        // No safety limit set: Loop raises no notice, but the forecast still blocks.
        XCTAssertNotNil(AIDoseAdvisor.blockingReason(glucoseMgdl: 140, glucoseDate: now, notice: nil, loopUnits: 1, lowestForecastMgdl: 65, suspendThresholdMgdl: nil, now: now))
        XCTAssertNotNil(AIDoseAdvisor.blockingReason(glucoseMgdl: 140, glucoseDate: now, notice: nil, loopUnits: 1, lowestForecastMgdl: 75, suspendThresholdMgdl: 80, now: now))
    }

    func testBelowTargetHoldsTheDoseToLoops() {
        let result = AIDoseAdvisor.limitedDose(1, loopUnits: 0.3, maximumBolus: 3, settings: AIDoseAdviceSettings(), allowsMoreThanLoop: false, round: pumpSteps)
        XCTAssertEqual(result.units, 0.3, accuracy: 0.0001)
        XCTAssertEqual(result.limitedFrom, 1)
    }

    func testAmountAboveLoopOutsideItsRangeIsHeldToIt() {
        var settings = AIDoseAdviceSettings()
        settings.maximumAboveLoop = 10
        let result = AIDoseAdvisor.limitedDose(10, loopUnits: 1, maximumBolus: 10, settings: settings, round: pumpSteps)
        XCTAssertEqual(result.units, 1 + AIDoseAdviceSettings.maximumAboveLoopRange.upperBound, accuracy: 0.0001)
    }

    func testAdviceIsGivenOnFreshGlucoseInRange() {
        XCTAssertNil(AIDoseAdvisor.blockingReason(glucoseMgdl: 140, glucoseDate: now.addingTimeInterval(-.minutes(4)), notice: nil, loopUnits: 1, lowestForecastMgdl: 110, suspendThresholdMgdl: 72, now: now))
        XCTAssertNil(AIDoseAdvisor.blockingReason(glucoseMgdl: 140, glucoseDate: now, notice: .glucoseBelowTarget, loopUnits: 1, lowestForecastMgdl: 110, suspendThresholdMgdl: 72, now: now))
    }

    func testSettingsAreOffUntilTurnedOn() {
        XCTAssertFalse(AIDoseAdviceSettings().isEnabled)
        let decoded = try? JSONDecoder().decode(AIDoseAdviceSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, AIDoseAdviceSettings())
    }

    // MARK: Request and answer

    private func situation() -> AIDoseSituation {
        AIDoseSituation(
            localTime: "søndag 11. oktober 2026 18:05",
            childProfile: "4 år, 17 kg",
            glucoseMmol: 7.8,
            glucoseMinutesAgo: 3,
            glucoseChangeLast15MinMmol: 0.4,
            glucoseLast3Hours: [.init(minutes: -10, mmol: 7.4)],
            loopRecommendedUnits: 1.2,
            loopForecast: [.init(minutes: 30, mmol: 8.5)],
            loopNotice: nil,
            insulinOnBoardUnits: 0.3,
            carbsOnBoardGrams: 5,
            therapy: .init(carbRatioGramsPerUnit: 20, insulinSensitivityMmolPerUnit: 7, targetMmol: [5.5, 6.5], suspendThresholdMmol: 4, maximumBolusUnits: 3, activeOverride: nil),
            meal: .init(carbsGrams: 30, absorptionHours: 3, foodType: "🍕 Pizza", foodName: "Pizza", minutesFromNow: 0, fatGrams: 12, proteinGrams: 10, fatProteinBoost: nil, isEditOfEarlierEntry: false),
            todayCarbs: [],
            todayInsulin: [],
            todayGlucose: nil
        )
    }

    func testRequestCarriesTheSituationAndTheMealPhotos() throws {
        let photo = Data([0xFF, 0xD8, 0xFF])
        let meal = AIDoseMealContext(conversation: [
            MealCarbEstimator.Message(role: "user", content: "pizza", images: [photo]),
            MealCarbEstimator.Message(role: "assistant", content: #"{"carbs_grams":30}"#),
        ], foodName: "Pizza")
        let status = AIDoseStatusContext(
            dataAgeMinutes: 12,
            longTermSummary: "Stabilt på dagtid, høyt på kveld.",
            longTermPoints: [],
            longTermDoseHints: ["Kveld: Loop spår for lavt"],
            todaySummary: nil,
            todayDoseHints: [],
            daypartNow: nil,
            today: nil,
            similarMeals: [],
            earlierAdvice: []
        )
        let body = try AIDoseAdvisor.requestBody(situation: situation(), status: status, meal: meal)
        XCTAssertNil(body["model"], "the model is picked when sending")
        XCTAssertEqual(body["reasoning_effort"] as? String, "medium")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        XCTAssertTrue(text.contains(#""loop_recommended_units":1.2"#))
        XCTAssertTrue(text.contains(#""child_profile":"4 år, 17 kg""#))
        XCTAssertTrue(text.contains("Omsorgspersonen skrev: pizza"))
        XCTAssertEqual(parts.filter { $0["type"] as? String == "image_url" }.count, 1)
        let image = try XCTUnwrap(parts.first { $0["type"] as? String == "image_url" }?["image_url"] as? [String: Any])
        XCTAssertEqual(image["detail"] as? String, "low", "the meal estimate has already looked closely")
        XCTAssertTrue((parts.first?["text"] as? String)?.contains("Kveld: Loop spår for lavt") == true, "the status goes first, so it can be cached")
        XCTAssertTrue(text.contains(#""data_age_minutes":12"#))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testAnswerIsRead() throws {
        let answer = #"{"dose_units":1.1,"summary":"Litt mindre enn Loop.","reasons":["Aktiv i barnehagen"],"cautions":[],"carbs_assessment":"Ser riktig ut.","confidence":"medium"}"#
        let completion = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": answer]]]])
        let parsed = try AIDoseAdvisor.parseResponse(completion)
        XCTAssertEqual(parsed.doseUnits, 1.1)
        XCTAssertEqual(parsed.reasons, ["Aktiv i barnehagen"])
    }

    func testUnreadableAnswerFails() throws {
        let completion = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "1.1 units"]]]])
        XCTAssertThrowsError(try AIDoseAdvisor.parseResponse(completion))
    }

    // MARK: Nightscout history

    func testNightscoutDocumentsAreRead() throws {
        let entries = try JSONSerialization.data(withJSONObject: [
            ["sgv": 140, "date": 1_760_000_000_000],
            ["mbg": 100, "date": 1_760_000_300_000],
        ])
        XCTAssertEqual(NightscoutHistory.parseGlucose(entries), [NightscoutGlucoseReading(date: Date(timeIntervalSince1970: 1_760_000_000), mgdl: 140)])

        let treatments = try JSONSerialization.data(withJSONObject: [
            ["created_at": "2026-10-10T16:00:00.000Z", "carbs": 25, "foodType": "🍕 Pizza"],
            ["created_at": "2026-10-10T16:01:00Z", "insulin": 1.2, "automatic": false],
            ["created_at": "2026-10-10T16:05:00Z", "eventType": "Temp Basal", "rate": 0.5],
        ])
        let parsed = NightscoutHistory.parseTreatments(treatments)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.first?.carbs, 25)
        XCTAssertEqual(parsed.first?.foodType, "🍕 Pizza")
        XCTAssertEqual(parsed.last?.insulin, 1.2)
    }

    // MARK: Newest model

    func testUnknownModelsAreSkippedAndTheWorkingOneRemembered() async throws {
        let defaults = UserDefaults(suiteName: "AIDoseAdvisorTests")!
        defaults.removePersistentDomain(forName: "AIDoseAdvisorTests")
        defer { defaults.removePersistentDomain(forName: "AIDoseAdvisorTests") }

        let working = OpenAIChat.modelCandidates[2]
        ModelStubURLProtocol.acceptedModel = working
        ModelStubURLProtocol.requestedModels = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelStubURLProtocol.self]
        let chat = OpenAIChat(apiKey: "sk-test", session: URLSession(configuration: configuration), defaults: defaults)

        _ = try await chat.send(["messages": [Any]()], timeout: 5)
        XCTAssertEqual(ModelStubURLProtocol.requestedModels, Array(OpenAIChat.modelCandidates.prefix(3)))
        XCTAssertEqual(defaults.openAIWorkingModel, working)

        ModelStubURLProtocol.requestedModels = []
        _ = try await chat.send(["messages": [Any]()], timeout: 5)
        XCTAssertEqual(ModelStubURLProtocol.requestedModels, [working], "the remembered model goes first")
    }

    func testOtherErrorsAreNotRetriedOnOlderModels() async {
        let defaults = UserDefaults(suiteName: "AIDoseAdvisorTests")!
        defaults.removePersistentDomain(forName: "AIDoseAdvisorTests")
        defer { defaults.removePersistentDomain(forName: "AIDoseAdvisorTests") }

        ModelStubURLProtocol.acceptedModel = nil
        ModelStubURLProtocol.requestedModels = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelStubURLProtocol.self]
        let chat = OpenAIChat(apiKey: "sk-bad", session: URLSession(configuration: configuration), defaults: defaults)

        do {
            _ = try await chat.send(["messages": [Any]()], timeout: 5)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Incorrect API key provided")
        }
        XCTAssertEqual(ModelStubURLProtocol.requestedModels.count, 1)
    }

    func testTheFastTierHasItsOwnModelsAndCountsWhatItCosts() async throws {
        let defaults = UserDefaults(suiteName: "AIDoseAdvisorTests")!
        defaults.removePersistentDomain(forName: "AIDoseAdvisorTests")
        defer { defaults.removePersistentDomain(forName: "AIDoseAdvisorTests") }

        let working = OpenAIChat.Tier.fast.modelCandidates[1]
        ModelStubURLProtocol.acceptedModel = working
        ModelStubURLProtocol.requestedModels = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelStubURLProtocol.self]
        let chat = OpenAIChat(apiKey: "sk-test", session: URLSession(configuration: configuration), defaults: defaults)

        _ = try await chat.send(["messages": [Any]()], timeout: 5, tier: .fast)
        XCTAssertEqual(ModelStubURLProtocol.requestedModels, Array(OpenAIChat.Tier.fast.modelCandidates.prefix(2)))
        XCTAssertEqual(defaults.openAIWorkingModel(for: .fast), working)
        XCTAssertNil(defaults.openAIWorkingModel, "the deep tier is remembered apart")

        let usage = defaults.openAIUsage(on: Date()).byTier[.fast]
        XCTAssertEqual(usage?.calls, 1)
        XCTAssertEqual(usage?.inputTokens, 900)
        XCTAssertEqual(usage?.cachedInputTokens, 100)
        XCTAssertEqual(usage?.outputTokens, 2000)
        // 900 × $2 + 100 × $0.20 + 2000 × $10, per million.
        XCTAssertEqual(defaults.openAIUsage(on: Date()).dollars, 0.02182, accuracy: 0.000001)
    }

    func testUnknownModelMessagesAreRecognised() {
        XCTAssertTrue(OpenAIChat.isUnknownModel("The model `gpt-6-astra` does not exist or you do not have access to it."))
        XCTAssertFalse(OpenAIChat.isUnknownModel("Incorrect API key provided"))
        XCTAssertFalse(OpenAIChat.isUnknownModel("Rate limit reached"))
        XCTAssertFalse(OpenAIChat.isUnknownModel("Unsupported parameter: 'reasoning_effort' is not supported with this model."))
        XCTAssertTrue(OpenAIChat.isUnsupportedReasoningEffort("Unsupported parameter: 'reasoning_effort' is not supported with this model."))
    }
}

/// Accepts only `acceptedModel`; answers other models as OpenAI does for an unknown model, and
/// everything when `acceptedModel` is nil with a wrong-key error.
private final class ModelStubURLProtocol: URLProtocol {
    static var acceptedModel: String?
    static var requestedModels: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        let model = (body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["model"] as? String ?? ""
        Self.requestedModels.append(model)

        let status: Int
        let data: Data
        if Self.acceptedModel == nil {
            status = 401
            data = Data(#"{"error":{"message":"Incorrect API key provided"}}"#.utf8)
        } else if model == Self.acceptedModel {
            status = 200
            data = Data(#"{"choices":[{"message":{"content":"{}"}}],"usage":{"prompt_tokens":1000,"completion_tokens":2000,"prompt_tokens_details":{"cached_tokens":100}}}"#.utf8)
        } else {
            status = 404
            data = Data(#"{"error":{"message":"The model `\#(model)` does not exist or you do not have access to it."}}"#.utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
