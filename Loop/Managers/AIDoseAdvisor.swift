//
//  AIDoseAdvisor.swift
//  Loop
//
//  A second opinion on the bolus, next to Loop's own recommendation. A GPT model looks at the
//  meal (its description and photos), glucose now and today, insulin and carbs on board, the
//  therapy settings, what the caregiver wrote about the child, and the glucose insight kept up to
//  date through the day (GlucoseInsightManager): what the weeks behind and today show, and the
//  meals most like this one — and suggests a dose of its own, with its reasons.
//
//  The heavy reading of the weeks behind is done beforehand, so the advice goes to the fast model
//  at medium effort and usually comes back in seconds.
//
//  It is advice and nothing more. It is off until turned on in settings, opens on the bolus
//  screen only when asked for, and fills in the bolus field only when the caregiver accepts it.
//  Whatever the model answers, the dose shown is held to the maximum bolus and to a set amount
//  above Loop's recommendation, and none is offered on stale data or when Loop sees a low coming.
//

import Foundation
import HealthKit
import LoopKit

// MARK: - Settings

/// Stored on the phone and changed from the AI Dose Advice settings screen.
struct AIDoseAdviceSettings: Codable, Equatable {
    /// Off until turned on; while off, the bolus screen shows nothing of it.
    var isEnabled = false
    /// What the caregiver wants the model to know about the child: age, weight, activity,
    /// habits, what usually goes wrong.
    var childProfile = ""
    /// The most the suggested dose may be above Loop's recommendation, in units.
    var maximumAboveLoop = 0.5
    /// How far back the Nightscout history is kept for the glucose insight.
    var historyDays = 30

    static let maximumAboveLoopRange: ClosedRange<Double> = 0.1...2.0
    static let historyDaysRange: ClosedRange<Int> = 7...90

    init() {}

    /// Every field may be missing, so settings saved by an older build keep what they had.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = AIDoseAdviceSettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? standard.isEnabled
        childProfile = try container.decodeIfPresent(String.self, forKey: .childProfile) ?? standard.childProfile
        maximumAboveLoop = try container.decodeIfPresent(Double.self, forKey: .maximumAboveLoop) ?? standard.maximumAboveLoop
        historyDays = try container.decodeIfPresent(Int.self, forKey: .historyDays) ?? standard.historyDays
    }
}

/// One suggestion as it was shown, kept so later suggestions can be judged against what happened.
struct AIDoseAdviceRecord: Codable, Equatable {
    var date: Date
    var loopUnits: Double?
    var suggestedUnits: Double
    var carbsGrams: Double?
    var accepted: Bool
}

// MARK: - What the model sees

/// The meal as the carb entry screen knew it: everything the caregiver wrote and photographed,
/// and the meal estimate's answers.
struct AIDoseMealContext {
    var conversation: [MealCarbEstimator.Message] = []
    var foodName: String?
}

/// Everything about the moment of the bolus, already in mmol/L and units, as it goes to the model.
struct AIDoseSituation: Encodable {
    struct Point: Encodable, Equatable {
        /// Minutes from now: negative in the past, positive in the forecast.
        var minutes: Int
        var mmol: Double
    }

    struct Meal: Encodable {
        var carbsGrams: Double
        var absorptionHours: Double
        var foodType: String?
        var foodName: String?
        var minutesFromNow: Int
        var fatGrams: Double?
        var proteinGrams: Double?
        var fatProteinBoost: String?
        var isEditOfEarlierEntry: Bool
    }

    struct Therapy: Encodable {
        var carbRatioGramsPerUnit: Double?
        var insulinSensitivityMmolPerUnit: Double?
        var targetMmol: [Double]?
        var suspendThresholdMmol: Double?
        var maximumBolusUnits: Double?
        var activeOverride: String?
    }

    struct TodayCarbs: Encodable {
        var time: String
        var grams: Double
        var foodType: String?
    }

    struct TodayInsulin: Encodable {
        var time: String
        var units: Double
        var automatic: Bool
    }

    var localTime: String
    var childProfile: String
    var glucoseMmol: Double?
    var glucoseMinutesAgo: Int?
    var glucoseChangeLast15MinMmol: Double?
    var glucoseLast3Hours: [Point]
    var loopRecommendedUnits: Double?
    var loopForecast: [Point]
    var loopNotice: String?
    var insulinOnBoardUnits: Double?
    var carbsOnBoardGrams: Double?
    var therapy: Therapy
    var meal: Meal?
    var todayCarbs: [TodayCarbs]
    var todayInsulin: [TodayInsulin]
    var todayGlucose: GlucoseInsightPeriod?
}

/// What the phone itself holds for today, from Loop's stores.
struct AIDoseLocalHistory {
    var glucose: [GlucoseValue] = []
    var carbEntries: [StoredCarbEntry] = []
    var doses: [DoseEntry] = []
}

// MARK: - The answer

/// The model's answer, as returned.
struct AIDoseModelAnswer: Codable, Equatable {
    var doseUnits: Double
    var summary: String
    var reasons: [String]
    var cautions: [String]
    var carbsAssessment: String
    var confidence: String

    enum CodingKeys: String, CodingKey {
        case doseUnits = "dose_units"
        case summary, reasons, cautions
        case carbsAssessment = "carbs_assessment"
        case confidence
    }
}

/// The answer as it is shown: the dose held to the limits, and why it was held, if it was.
struct AIDoseAdvice: Equatable {
    var answer: AIDoseModelAnswer
    /// The dose that may be accepted into the bolus field.
    var units: Double
    /// Loop's recommendation when the advice was asked for.
    var loopUnits: Double?
    /// Set when the model's dose was above a limit and was lowered to `units`.
    var limitedFrom: Double?
    var date: Date
}

enum AIDoseAdviceState: Equatable {
    /// The section is closed.
    case off
    case loading
    case ready(AIDoseAdvice)
    /// No advice is given now, and why.
    case unavailable(String)
    case failed(String)
}

// MARK: - Advisor

final class AIDoseAdvisor {
    static let shared: AIDoseAdvisor? = OpenAIChat.shared.map { AIDoseAdvisor(chat: $0) }

    enum AdviceError: LocalizedError {
        case unreadableResponse

        var errorDescription: String? {
            String(localized: "The AI answer could not be read. Try again.", comment: "Error shown when the AI dose advice response could not be parsed")
        }
    }

    private let chat: OpenAIChat

    init(chat: OpenAIChat) {
        self.chat = chat
    }

    /// Asks the fast model for its dose; usually a few seconds.
    func advise(situation: AIDoseSituation, status: AIDoseStatusContext?, meal: AIDoseMealContext?) async throws -> AIDoseModelAnswer {
        let data = try await chat.send(try Self.requestBody(situation: situation, status: status, meal: meal), timeout: 90, tier: .fast)
        return try Self.parseResponse(data)
    }

    // MARK: Limits

    /// The model's dose held to Loop's maximum bolus and to `maximumAboveLoop` over Loop's own
    /// recommendation, then rounded to what the pump can give.
    /// With `allowsMoreThanLoop` false — glucose already below target — it is held to Loop's dose.
    static func limitedDose(
        _ suggested: Double,
        loopUnits: Double?,
        maximumBolus: Double?,
        settings: AIDoseAdviceSettings,
        allowsMoreThanLoop: Bool = true,
        round: (Double) -> Double
    ) -> (units: Double, limitedFrom: Double?) {
        let asked = suggested.isFinite ? max(0, suggested) : 0
        let range = AIDoseAdviceSettings.maximumAboveLoopRange
        let above = allowsMoreThanLoop ? min(max(settings.maximumAboveLoop, range.lowerBound), range.upperBound) : 0
        var limit = (loopUnits ?? 0) + above
        if let maximumBolus {
            limit = min(limit, maximumBolus)
        }
        let held = min(asked, limit)
        var units = round(held)
        // Rounding to the pump's steps must not carry it back over the limit.
        if units > limit + 0.0001 {
            units = round(max(0, held - 0.05))
            if units > limit + 0.0001 {
                units = 0
            }
        }
        units = max(0, units)
        let wasLimited = asked > held + 0.0001
        return (units, wasLimited ? asked : nil)
    }

    /// Why no advice may be given right now, or `nil` when it may.
    static func blockingReason(glucoseMgdl: Double?, glucoseDate: Date?, notice: BolusEntryViewModel.Notice?, loopUnits: Double?, lowestForecastMgdl: Double?, suspendThresholdMgdl: Double?, now: Date) -> String? {
        switch notice {
        case .staleGlucoseData?, .futureGlucoseData?:
            return String(localized: "No recent glucose — AI advice needs a CGM reading from the last 15 minutes.", comment: "AI dose advice is not given: glucose data is stale")
        case .stalePumpData?:
            return String(localized: "The pump has not reported recently, so insulin on board is uncertain.", comment: "AI dose advice is not given: pump data is stale")
        case .predictedGlucoseBelowSuspendThreshold?:
            return String(localized: "Loop sees glucose going below the safety limit. No AI dose is suggested.", comment: "AI dose advice is not given: a low is predicted")
        default:
            break
        }
        guard let glucoseMgdl, let glucoseDate, now.timeIntervalSince(glucoseDate) <= .minutes(15) else {
            return String(localized: "No recent glucose — AI advice needs a CGM reading from the last 15 minutes.", comment: "AI dose advice is not given: glucose data is stale")
        }
        if glucoseMgdl < 70 {
            return String(localized: "Glucose is low. No AI dose is suggested.", comment: "AI dose advice is not given: glucose is low")
        }
        // Loop's notice needs a safety limit to be set; the forecast itself is checked as well.
        if let lowest = lowestForecastMgdl, lowest < max(70, suspendThresholdMgdl ?? 0) {
            return String(localized: "Loop sees glucose going below the safety limit. No AI dose is suggested.", comment: "AI dose advice is not given: a low is predicted")
        }
        guard loopUnits != nil else {
            return String(localized: "Loop has no recommendation right now, so there is nothing to compare with.", comment: "AI dose advice is not given: Loop could not recommend a bolus")
        }
        return nil
    }

    // MARK: Request and response

    static func requestBody(situation: AIDoseSituation, status: AIDoseStatusContext?, meal: AIDoseMealContext?) throws -> [String: Any] {
        let encoder = GlucoseInsightWriter.encoder()
        let situationJSON = String(data: try encoder.encode(situation), encoding: .utf8) ?? "{}"

        // What changes least goes first, so OpenAI can reuse it from one request to the next.
        var parts: [[String: Any]] = []
        if let status {
            let statusJSON = String(data: try encoder.encode(status), encoding: .utf8) ?? "{}"
            parts.append(["type": "text", "text": "Status for barnet, oppdatert gjennom dagen (JSON):\n\(statusJSON)"])
        } else {
            parts.append(["type": "text", "text": "Status for barnet: ikke tilgjengelig ennå. Vær ekstra forsiktig og hold deg nær Loop."])
        }
        parts.append(["type": "text", "text": "Situasjonen nå (JSON):\n\(situationJSON)"])
        if let meal, !meal.conversation.isEmpty {
            parts.append(["type": "text", "text": "Slik måltidet ble beskrevet og anslått på karboskjermen, i rekkefølge:"])
            for message in meal.conversation {
                let who = message.role == "assistant" ? "Måltidsanslaget svarte" : "Omsorgspersonen skrev"
                if !message.content.isEmpty {
                    parts.append(["type": "text", "text": "\(who): \(message.content)"])
                }
                for image in message.images {
                    parts.append([
                        "type": "image_url",
                        // The meal estimate has already looked closely; low detail is enough to check it.
                        "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())", "detail": "low"],
                    ])
                }
            }
        }

        return [
            "reasoning_effort": "medium",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": parts],
            ] as [[String: Any]],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "dose_advice",
                    "strict": true,
                    "schema": schema,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    static func parseResponse(_ data: Data) throws -> AIDoseModelAnswer {
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
            throw AdviceError.unreadableResponse
        }
        if let refusal = message.refusal, !refusal.isEmpty {
            throw OpenAIChat.ChatError.server(refusal)
        }
        guard let content = message.content?.data(using: .utf8),
              let answer = try? JSONDecoder().decode(AIDoseModelAnswer.self, from: content),
              answer.doseUnits.isFinite
        else {
            throw AdviceError.unreadableResponse
        }
        return answer
    }

    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["dose_units", "summary", "reasons", "cautions", "carbs_assessment", "confidence"],
        "properties": [
            "dose_units": ["type": "number"],
            "summary": ["type": "string"],
            "reasons": ["type": "array", "items": ["type": "string"]] as [String: Any],
            "cautions": ["type": "array", "items": ["type": "string"]] as [String: Any],
            "carbs_assessment": ["type": "string"],
            "confidence": ["type": "string", "enum": ["high", "medium", "low"]] as [String: Any],
        ] as [String: Any],
    ]

    static let systemPrompt = """
        Du gir en andre vurdering av en bolusdose for et lite barn med type 1-diabetes som bruker Loop, et automatisk insulinsystem (Omnipod DASH). Loop har allerede regnet ut sin anbefalte dose. Omsorgspersonen ser Loops forslag og ditt forslag side om side og velger selv. Ingenting gis uten at et menneske godtar det.

        Du får:
        - Status for barnet, laget på forhånd fra Nightscout og oppdatert gjennom dagen: long_term_summary, long_term_points og long_term_dose_hints (skrevet i natt fra de siste ukene), today_summary og today_dose_hints (skrevet i dag), daypart_now (tallene for denne delen av døgnet: tid i mål, hvor mye Loops prognose bommer — positivt betyr at Loop spår for lavt — og hvordan rene måltider har gått), today (dagens tall, med forecast_deviation_mmol: over +1 betyr mer insulinbehov enn vanlig i dag, under −1 mindre), similar_meals (de mest like tidligere måltidene med dose og blodsukker før, topp, etter 2 og 3 timer og laveste innen 4 timer; måltider med flags er forstyrret av ekstra karbo, korreksjon eller behandlet føling og veier mindre), og earlier_advice (tidligere AI-forslag, om de ble godtatt og hvordan det gikk). data_age_minutes sier hvor gamle tallene er. Tallene er riktige; ikke regn dem om.
        - situation: klokkeslett, blodsukker nå (mmol/L) og de siste 3 timene, Loops anbefalte dose og prognose, aktivt insulin (IOB) og aktive karbohydrater (COB), terapiinnstillinger (karboratio g/E, insulinsensitivitet mmol/L per E, målområde, sikkerhetsgrense, maks bolus, aktiv overstyring), måltidet som legges inn nå (karbo, absorpsjonstid, mattype, fett og protein, eventuell fett/protein-boost Loop vil starte senere), dagens karbo og insulin og dagens blodsukker.
        - child_profile: det omsorgspersonen har skrevet om barnet — alder, vekt, aktivitet, vaner. Ta det på alvor, for eksempel høyere aktivitet i barnehagen på dagtid.
        - Beskrivelsen og bildene av måltidet fra karboskjermen. Vurder måltidet selv: ser karbomengden riktig ut for det som er på tallerkenen og for et barn på denne alderen? Si det i carbs_assessment, og ta hensyn til det i dosen.

        Slik vurderer du:
        - Start fra det Loop vet, og vurder om situasjonen tilsier mer eller mindre: trend, tid på døgnet, aktivitet, måltidets sammensetning, hvordan lignende måltider har gått (similar_meals), hva statusen sier om denne delen av døgnet og om i dag, og om barnet ofte går lavt eller høyt etter måltider.
        - Bruk dose_hints fra statusen når de passer. Er statusen gammel (data_age_minutes over 120) eller mangler, hold deg nærmere Loop.
        - Loop justerer basal automatisk etterpå og ser karboene som legges inn nå. Ikke dobbelttell: IOB er allerede insulin i kroppen.
        - Et lite barn er svært følsomt for insulin. Føling er farligere enn et forbigående høyt blodsukker. Når du er usikker, foreslå mindre, ikke mer. Hvis barnet er aktivt, eller blodsukkeret faller, vær forsiktig.
        - Hvis fett og protein vil gi en sen stigning og Loop har en fett/protein-boost for måltidet, ikke dekk den sene stigningen med ekstra insulin nå.
        - Aldri foreslå mer enn maks bolus. Foreslå 0 hvis blodsukkeret er lavt eller faller raskt mot lavt.
        - dose_units: din anbefalte dose i enheter, med to desimaler.
        - summary: én eller to setninger på norsk om hva du foreslår sammenlignet med Loop og hvorfor.
        - reasons: korte punkter på norsk med det som trakk dosen opp eller ned.
        - cautions: korte advarsler på norsk (for eksempel aktivitet, usikker karbomengde, fallende trend). Tom liste når det ikke er noen.
        - carbs_assessment: én setning på norsk om karbomengden virker riktig ut fra beskrivelse og bilder. Hvis det ikke er noe måltid, skriv det.
        - confidence: high, medium eller low.
        """
}

// MARK: - Storage

extension UserDefaults {
    private enum AIDoseAdviceKey: String {
        case settings = "com.loopkit.Loop.aiDoseAdviceSettings"
        case records = "com.loopkit.Loop.aiDoseAdviceRecords"
    }

    var aiDoseAdviceSettings: AIDoseAdviceSettings {
        get { aiDoseDecoded(forKey: AIDoseAdviceKey.settings.rawValue) ?? AIDoseAdviceSettings() }
        set { set(try? JSONEncoder().encode(newValue), forKey: AIDoseAdviceKey.settings.rawValue) }
    }

    /// The last suggestions shown, newest last.
    var aiDoseAdviceRecords: [AIDoseAdviceRecord] {
        get { aiDoseDecoded(forKey: AIDoseAdviceKey.records.rawValue) ?? [] }
        set { set(try? JSONEncoder().encode(Array(newValue.suffix(30))), forKey: AIDoseAdviceKey.records.rawValue) }
    }

    private func aiDoseDecoded<T: Decodable>(forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
