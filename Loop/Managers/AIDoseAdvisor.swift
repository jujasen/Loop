//
//  AIDoseAdvisor.swift
//  Loop
//
//  A second opinion on the bolus, next to Loop's own recommendation. A GPT model looks at the
//  meal (its description and photos), glucose now and today, insulin and carbs on board, the
//  therapy settings, what the caregiver wrote about the child, and how glucose went after meals
//  over the last weeks in Nightscout — and suggests a dose of its own, with its reasons.
//
//  It is advice and nothing more. It is off until turned on in settings, opens on the bolus
//  screen only when asked for, and fills in the bolus field only when the caregiver accepts it.
//  Whatever the model answers, the dose shown is held to the maximum bolus and to a set amount
//  above Loop's recommendation, and none is offered on stale data or when Loop sees a low coming.
//

import CryptoKit
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
    /// How far back Nightscout history is summarised.
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
    var todayGlucose: NightscoutHistorySummary.Daypart?
    var history: NightscoutHistorySummary?
    var earlierAdvice: [AIDoseAdviceRecord]
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

    /// Asks the newest GPT model for its dose. Slow: it reasons at length, so it may take half a
    /// minute.
    func advise(situation: AIDoseSituation, meal: AIDoseMealContext?) async throws -> AIDoseModelAnswer {
        let data = try await chat.send(try Self.requestBody(situation: situation, meal: meal), timeout: 180)
        return try Self.parseResponse(data)
    }

    // MARK: Limits

    /// The model's dose held to Loop's maximum bolus and to `maximumAboveLoop` over Loop's own
    /// recommendation, then rounded to what the pump can give.
    static func limitedDose(
        _ suggested: Double,
        loopUnits: Double?,
        maximumBolus: Double?,
        settings: AIDoseAdviceSettings,
        round: (Double) -> Double
    ) -> (units: Double, limitedFrom: Double?) {
        let asked = suggested.isFinite ? max(0, suggested) : 0
        var limit = (loopUnits ?? 0) + settings.maximumAboveLoop
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
    static func blockingReason(glucoseMgdl: Double?, glucoseDate: Date?, notice: BolusEntryViewModel.Notice?, now: Date) -> String? {
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
        return nil
    }

    // MARK: Request and response

    static func requestBody(situation: AIDoseSituation, meal: AIDoseMealContext?) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let localTime = DateFormatter()
        localTime.dateFormat = "yyyy-MM-dd HH:mm"
        encoder.dateEncodingStrategy = .formatted(localTime)
        let situationJSON = String(data: try encoder.encode(situation), encoding: .utf8) ?? "{}"

        var parts: [[String: Any]] = [["type": "text", "text": "Situasjonen nå (JSON):\n\(situationJSON)"]]
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
                        "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())", "detail": "high"],
                    ])
                }
            }
        }

        return [
            "reasoning_effort": "high",
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
        - situation: klokkeslett, blodsukker nå (mmol/L) og de siste 3 timene, Loops anbefalte dose og prognose, aktivt insulin (IOB) og aktive karbohydrater (COB), terapiinnstillinger (karboratio g/E, insulinsensitivitet mmol/L per E, målområde, sikkerhetsgrense, maks bolus, aktiv overstyring), måltidet som legges inn nå (karbo, absorpsjonstid, mattype, fett og protein, eventuell fett/protein-boost Loop vil starte senere), dagens karbo og insulin, dagens blodsukker, et sammendrag av Nightscout-historikken (blodsukker per tid på døgnet og hvordan det gikk etter tidligere måltider: dose, blodsukker før, topp, etter 2 og 3 timer og laveste innen 4 timer), og tidligere AI-forslag med om de ble godtatt.
        - child_profile: det omsorgspersonen har skrevet om barnet — alder, vekt, aktivitet, vaner. Ta det på alvor, for eksempel høyere aktivitet i barnehagen på dagtid.
        - Beskrivelsen og bildene av måltidet fra karboskjermen. Vurder måltidet selv: ser karbomengden riktig ut for det som er på tallerkenen og for et barn på denne alderen? Si det i carbs_assessment, og ta hensyn til det i dosen.

        Slik vurderer du:
        - Start fra det Loop vet, og vurder om situasjonen tilsier mer eller mindre: trend, tid på døgnet, aktivitet, måltidets sammensetning, hvordan lignende måltider på samme tid har gått i historikken, og om barnet ofte går lavt eller høyt etter måltider.
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

// MARK: - Nightscout history

/// How glucose went over the last weeks, worked out from Nightscout and kept small enough to send.
struct NightscoutHistorySummary: Codable, Equatable {
    struct Daypart: Codable, Equatable {
        var name: String
        var meanMmol: Double
        var timeInRangePercent: Int
        var belowRangePercent: Int
        var aboveRangePercent: Int
        var readings: Int
    }

    struct MealOutcome: Codable, Equatable {
        var time: String
        var carbsGrams: Double
        var foodType: String?
        var bolusUnits: Double
        var startMmol: Double?
        var peakMmol: Double?
        var mmolAfter2h: Double?
        var mmolAfter3h: Double?
        var lowestMmolWithin4h: Double?
    }

    var days: Int
    var dayparts: [Daypart]
    var averageDailyCarbsGrams: Double
    var averageDailyInsulinFromBolusesUnits: Double
    var meals: [MealOutcome]
    var createdAt: Date
}

struct NightscoutGlucoseReading: Equatable {
    var date: Date
    var mgdl: Double
}

struct NightscoutTreatment: Equatable {
    var date: Date
    var carbs: Double?
    var insulin: Double?
    var foodType: String?
    var isAutomatic: Bool
}

enum NightscoutHistory {
    /// Day parts in local time; the day is mostly kindergarten hours.
    static let dayparts: [(name: String, hours: Range<Int>)] = [
        ("natt 00-06", 0..<6),
        ("morgen 06-09", 6..<9),
        ("dag 09-15", 9..<15),
        ("ettermiddag 15-19", 15..<19),
        ("kveld 19-24", 19..<24),
    ]

    static let rangeMgdl: ClosedRange<Double> = 70...180 // 3.9–10 mmol/L
    /// Most meals sent; the newest are kept.
    static let maximumMeals = 60

    static func mmol(_ mgdl: Double) -> Double {
        (mgdl / 18.0182 * 10).rounded() / 10
    }

    static func daypart(readings: [NightscoutGlucoseReading], name: String) -> NightscoutHistorySummary.Daypart? {
        guard !readings.isEmpty else { return nil }
        let count = Double(readings.count)
        let below = readings.filter { $0.mgdl < rangeMgdl.lowerBound }.count
        let above = readings.filter { $0.mgdl > rangeMgdl.upperBound }.count
        let mean = readings.map(\.mgdl).reduce(0, +) / count
        return NightscoutHistorySummary.Daypart(
            name: name,
            meanMmol: mmol(mean),
            timeInRangePercent: Int((Double(readings.count - below - above) / count * 100).rounded()),
            belowRangePercent: Int((Double(below) / count * 100).rounded()),
            aboveRangePercent: Int((Double(above) / count * 100).rounded()),
            readings: readings.count
        )
    }

    static func summarize(glucose: [NightscoutGlucoseReading], treatments: [NightscoutTreatment], days: Int, now: Date, calendar: Calendar = .current) -> NightscoutHistorySummary {
        let start = now.addingTimeInterval(-.hours(24 * Double(days)))
        let glucose = glucose.filter { $0.date >= start && $0.date <= now }.sorted { $0.date < $1.date }
        let treatments = treatments.filter { $0.date >= start && $0.date <= now }.sorted { $0.date < $1.date }

        let parts = dayparts.compactMap { part in
            daypart(readings: glucose.filter { part.hours.contains(calendar.component(.hour, from: $0.date)) }, name: part.name)
        }

        let totalCarbs = treatments.compactMap(\.carbs).reduce(0, +)
        let totalBolus = treatments.compactMap(\.insulin).reduce(0, +)

        func reading(near date: Date) -> Double? {
            let close = glucose.filter { abs($0.date.timeIntervalSince(date)) <= .minutes(10) }
            return close.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.mgdl
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nb_NO")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE d. MMM HH:mm"

        var meals: [NightscoutHistorySummary.MealOutcome] = []
        for treatment in treatments {
            guard let carbs = treatment.carbs, carbs > 0 else { continue }
            let bolus = treatments
                .filter { !$0.isAutomatic && $0.date >= treatment.date.addingTimeInterval(-.minutes(20)) && $0.date <= treatment.date.addingTimeInterval(.minutes(30)) }
                .compactMap(\.insulin)
                .reduce(0, +)
            let after = glucose.filter { $0.date >= treatment.date && $0.date <= treatment.date.addingTimeInterval(.hours(4)) }
            let firstThree = after.filter { $0.date <= treatment.date.addingTimeInterval(.hours(3)) }
            meals.append(NightscoutHistorySummary.MealOutcome(
                time: formatter.string(from: treatment.date),
                carbsGrams: carbs,
                foodType: treatment.foodType,
                bolusUnits: (bolus * 100).rounded() / 100,
                startMmol: reading(near: treatment.date).map(mmol),
                peakMmol: firstThree.map(\.mgdl).max().map(mmol),
                mmolAfter2h: reading(near: treatment.date.addingTimeInterval(.hours(2))).map(mmol),
                mmolAfter3h: reading(near: treatment.date.addingTimeInterval(.hours(3))).map(mmol),
                lowestMmolWithin4h: after.map(\.mgdl).min().map(mmol)
            ))
        }

        return NightscoutHistorySummary(
            days: days,
            dayparts: parts,
            averageDailyCarbsGrams: (totalCarbs / Double(days)).rounded(),
            averageDailyInsulinFromBolusesUnits: (totalBolus / Double(days) * 10).rounded() / 10,
            meals: Array(meals.suffix(maximumMeals)),
            createdAt: now
        )
    }

    // MARK: Reading Nightscout

    static func parseGlucose(_ data: Data) -> [NightscoutGlucoseReading] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array.compactMap { entry in
            guard let sgv = (entry["sgv"] as? NSNumber)?.doubleValue, sgv > 0,
                  let milliseconds = (entry["date"] as? NSNumber)?.doubleValue
            else { return nil }
            return NightscoutGlucoseReading(date: Date(timeIntervalSince1970: milliseconds / 1000), mgdl: sgv)
        }
    }

    static func parseTreatments(_ data: Data) -> [NightscoutTreatment] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return array.compactMap { treatment in
            guard let created = treatment["created_at"] as? String,
                  let date = withFraction.date(from: created) ?? plain.date(from: created)
            else { return nil }
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

    /// The summary, from the phone's copy when it is under three hours old.
    static func summary(days: Int, now: Date = Date(), defaults: UserDefaults = .standard) async -> NightscoutHistorySummary? {
        if let cached = defaults.aiDoseHistorySummary, cached.days == days, now.timeIntervalSince(cached.createdAt) < .hours(3) {
            return cached
        }
        guard let credentials = try? KeychainManager().getNightscoutCredentials(), !credentials.apiSecret.isEmpty else {
            return defaults.aiDoseHistorySummary
        }
        let start = now.addingTimeInterval(-.hours(24 * Double(days)))
        let milliseconds = Int(start.timeIntervalSince1970 * 1000)
        let iso = ISO8601DateFormatter().string(from: start)
        let secretHash = Insecure.SHA1.hash(data: Data(credentials.apiSecret.utf8)).map { String(format: "%02x", $0) }.joined()

        func get(_ path: String, _ query: [URLQueryItem]) async throws -> Data {
            var components = URLComponents(url: credentials.siteURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
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

        do {
            async let glucoseData = get("api/v1/entries/sgv.json", [
                URLQueryItem(name: "find[date][$gte]", value: String(milliseconds)),
                URLQueryItem(name: "count", value: String(days * 300)),
            ])
            async let treatmentData = get("api/v1/treatments.json", [
                URLQueryItem(name: "find[created_at][$gte]", value: iso),
                URLQueryItem(name: "count", value: "10000"),
            ])
            let summary = summarize(glucose: parseGlucose(try await glucoseData), treatments: parseTreatments(try await treatmentData), days: days, now: now)
            defaults.aiDoseHistorySummary = summary
            return summary
        } catch {
            // An older summary is better than none.
            return defaults.aiDoseHistorySummary
        }
    }
}

// MARK: - Storage

extension UserDefaults {
    private enum AIDoseAdviceKey: String {
        case settings = "com.loopkit.Loop.aiDoseAdviceSettings"
        case records = "com.loopkit.Loop.aiDoseAdviceRecords"
        case historySummary = "com.loopkit.Loop.aiDoseHistorySummary"
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

    var aiDoseHistorySummary: NightscoutHistorySummary? {
        get { aiDoseDecoded(forKey: AIDoseAdviceKey.historySummary.rawValue) }
        set { set(try? JSONEncoder().encode(newValue), forKey: AIDoseAdviceKey.historySummary.rawValue) }
    }

    private func aiDoseDecoded<T: Decodable>(forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
