//
//  MealWatch.swift
//  Loop
//
//  The meal watch: turned on for one meal on the carb entry screen (the evening milk, say), it
//  looks at glucose every quarter of an hour for as long as the meal works, together with how
//  the same meal went on earlier days, and suggests an extra dose when one is needed — when
//  glucose starts to rise, or just before it usually does. The suggestion is a notification and
//  a card on the home screen (and in LoopFollow, through Nightscout) that opens the bolus
//  screen filled in, to change or decline. It never gives insulin itself.
//
//  Most quarters end in code, without asking the AI: no suggestion while glucose is low,
//  falling or forecast low, while one is waiting or right after one, or when nothing is
//  happening and the history says nothing is about to. The dose the AI comes back with is held
//  to Loop's own recommendation plus the AI dose advice's margin, and to the maximum bolus.
//

import CryptoKit
import Foundation
import HealthKit
import LoopCore
import LoopKit
import UserNotifications
import os.log

// MARK: - Model

struct MealWatchSuggestion: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        case open
        /// A bolus was given while it was open.
        case given
        case declined
        case expired
    }

    var id: String
    var date: Date
    var units: Double
    var reason: String
    var glucoseMmol: Double?
    var loopUnits: Double?
    var expiresAt: Date
    var state: State
}

struct MealWatch: Codable, Equatable, Identifiable {
    var id: String
    /// The carb entry's sync identifier.
    var entryID: String?
    var mealDate: Date
    var carbs: Double
    var foodType: String?
    /// The watch ends at this time.
    var until: Date
    var lastCheck: Date?
    var suggestions: [MealWatchSuggestion] = []
    var isStopped = false

    var openSuggestion: MealWatchSuggestion? {
        suggestions.last { $0.state == .open }
    }

    var mealDescription: String {
        let name = CarbFoodLabel(foodType: foodType).name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? NumberFormatter.localizedString(from: NSNumber(value: carbs), number: .decimal) + " g" : name
    }

    /// The food's name, lowercased, for remembering the meal watch per food.
    static func foodKey(_ foodType: String?) -> String? {
        let name = CarbFoodLabel(foodType: foodType).name.trimmingCharacters(in: .whitespaces).lowercased()
        return name.isEmpty ? nil : name
    }

    func isActive(at date: Date) -> Bool {
        !isStopped && date < until
    }
}

/// An earlier meal like this one: glucose every half hour from the meal for five hours, and the
/// insulin given after it.
struct MealWatchHistoryMeal: Codable, Equatable {
    var date: Date
    var carbs: Double
    var foods: [String]
    var mealBolusUnits: Double
    /// Manual boluses from 30 minutes to 5 hours after the meal: minutes after, units.
    var laterBoluses: [Later]
    /// mmol/L at 0, 30, … 300 minutes; nil where there was no reading.
    var curve: [Double?]
    /// The first half hour, from 30 minutes on, at which glucose was 1.5 mmol/L over the start.
    var riseStartMinutes: Int?

    struct Later: Codable, Equatable {
        var minutes: Int
        var units: Double
    }
}

// MARK: - Deciding when to ask

enum MealWatchGate {
    static let checkInterval: TimeInterval = .minutes(15)
    /// The first look is this long after the meal: earlier, Loop has the meal bolus to work with.
    static let firstCheckAfter: TimeInterval = .minutes(30)
    static let suggestionLifetime: TimeInterval = .minutes(20)
    /// After a suggestion, given or not, the next waits this long.
    static let cooldown: TimeInterval = .minutes(45)
    static let maximumSuggestionsPerMeal = 2
    /// How long a watch lasts: the meal's absorption time and an hour more, within these.
    static let watchLength: ClosedRange<TimeInterval> = .hours(3)...(.hours(7))

    static let minimumGlucose = 6.0
    static let minimumForecast = 4.5

    enum Decision: Equatable {
        case wait
        case skip(String)
        case ask
    }

    /// Whether this quarter is worth asking the AI about.
    static func decide(_ watch: MealWatch, now loop: LoopNow?, history: [MealWatchHistoryMeal], at date: Date) -> Decision {
        guard watch.isActive(at: date) else { return .skip("ended") }
        guard date.timeIntervalSince(watch.mealDate) >= firstCheckAfter else { return .wait }
        if let last = watch.lastCheck, date.timeIntervalSince(last) < checkInterval - .minutes(1) { return .wait }
        guard watch.openSuggestion == nil else { return .skip("a suggestion is open") }
        if let last = watch.suggestions.last, date.timeIntervalSince(last.date) < cooldown { return .skip("cooldown") }
        guard watch.suggestions.count < maximumSuggestionsPerMeal else { return .skip("enough suggestions for this meal") }

        guard let loop, let glucose = loop.glucoseMmol, let age = loop.glucoseMinutesAgo, age <= 10 else { return .skip("no fresh glucose") }
        guard glucose >= minimumGlucose else { return .skip("glucose under \(minimumGlucose)") }
        if let change = loop.change15MinMmol, change < -0.2 { return .skip("falling") }
        guard let lowest = loop.lowestForecastMmol, lowest >= minimumForecast else { return .skip("forecast low") }

        let rising = (loop.change15MinMmol ?? 0) >= 0.5
        let forecastHigh = loop.forecast.contains { $0.minutes >= 90 && $0.mmol >= 10 }
        let loopWantsMore = (loop.loopRecommendedBolusUnits ?? 0) >= 0.1
        let minutes = Int(date.timeIntervalSince(watch.mealDate) / 60)
        let riseDue = typicalRiseStart(history).map { abs(minutes - $0) <= 30 } ?? false
        guard rising || forecastHigh || loopWantsMore || riseDue else { return .skip("nothing happening") }
        return .ask
    }

    /// The median time earlier meals like this one started to rise, with at least three of them.
    static func typicalRiseStart(_ history: [MealWatchHistoryMeal]) -> Int? {
        let starts = history.compactMap(\.riseStartMinutes).sorted()
        guard starts.count >= 3 else { return nil }
        return starts[starts.count / 2]
    }

    /// The most the suggestion may be: Loop's recommendation plus the AI dose advice's margin,
    /// and never over the maximum bolus.
    static func allowedUnits(loopUnits: Double?, maximumAboveLoop: Double, maximumBolus: Double?) -> Double {
        var allowed = max(loopUnits ?? 0, 0) + maximumAboveLoop
        if let maximumBolus {
            allowed = min(allowed, maximumBolus)
        }
        return max(allowed, 0)
    }

    /// The AI's dose held to what is allowed and rounded down to 0.05 U; nil when nothing is left.
    static func clamp(_ units: Double, allowed: Double) -> Double? {
        guard units.isFinite, units > 0 else { return nil }
        let held = (min(units, allowed) * 20).rounded(.down) / 20
        return held >= 0.05 ? held : nil
    }

    // MARK: History

    static func historyMeals(like carbs: Double, foodType: String?, at date: Date, meals: [GlucoseInsightMeal], history: NightscoutHistory, calendar: Calendar = .current) -> [MealWatchHistoryMeal] {
        let similar = GlucoseInsight.similarMeals(to: carbs, foodType: foodType, at: date, in: meals, count: 6, calendar: calendar)
        return similar.map { meal in
            let curve: [Double?] = stride(from: 0, through: 300, by: 30).map { minutes in
                GlucoseInsight.reading(near: meal.date.addingTimeInterval(.minutes(Double(minutes))), in: history.glucose).map(GlucoseInsight.mmol)
            }
            let start = curve.first ?? nil
            var riseStart: Int?
            if let start {
                for (index, value) in curve.enumerated() where index >= 1 {
                    if let value, value - start >= 1.5 {
                        riseStart = index * 30
                        break
                    }
                }
            }
            let later = history.treatments
                .filter { !$0.isAutomatic && ($0.insulin ?? 0) > 0 && $0.date >= meal.date.addingTimeInterval(.minutes(30)) && $0.date <= meal.date.addingTimeInterval(.hours(5)) }
                .map { MealWatchHistoryMeal.Later(minutes: Int($0.date.timeIntervalSince(meal.date) / 60), units: (($0.insulin ?? 0) * 100).rounded() / 100) }
            return MealWatchHistoryMeal(date: meal.date, carbs: meal.carbsGrams, foods: meal.foods, mealBolusUnits: meal.bolusUnits, laterBoluses: later, curve: curve, riseStartMinutes: riseStart)
        }
    }
}

// MARK: - Asking the AI

struct MealWatchAdvisor {
    let chat: AIChat

    struct Answer: Decodable, Equatable {
        var suggest: Bool
        var units: Double
        var reason: String
    }

    struct Input: Encodable {
        var localTime: String
        var childProfile: String
        var minutesSinceMeal: Int
        var meal: Meal
        var now: LoopNow
        var therapy: AIDoseSituation.Therapy
        var maximumUnits: Double
        var earlierSuggestionsForThisMeal: [Earlier]
        var similarMeals: [MealWatchHistoryMeal]
        var typicalRiseStartMinutes: Int?

        struct Meal: Encodable {
            var carbsGrams: Double
            var foodType: String?
        }

        struct Earlier: Encodable {
            var minutesSinceMeal: Int
            var units: Double
            var outcome: String
        }
    }

    func advise(_ input: Input) async throws -> Answer {
        let json = String(data: try GlucoseInsightWriter.encoder().encode(input), encoding: .utf8) ?? "{}"
        let body: [String: Any] = [
            "reasoning_effort": "medium",
            "messages": [
                ["role": "system", "content": Self.prompt],
                ["role": "user", "content": json],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "meal_watch", "strict": true, "schema": Self.schema] as [String: Any],
            ] as [String: Any],
        ]
        return try Self.parse(try await chat.send(body, timeout: 90, tier: .fast))
    }

    static func parse(_ data: Data) throws -> Answer {
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
        guard let message = (try? JSONDecoder().decode(Completion.self, from: data))?.choices.first?.message else {
            throw AIDoseAdvisor.AdviceError.unreadableResponse
        }
        if let refusal = message.refusal, !refusal.isEmpty {
            throw AIChat.ChatError.server(refusal)
        }
        guard let content = message.content?.data(using: .utf8), let answer = try? JSONDecoder().decode(Answer.self, from: content) else {
            throw AIDoseAdvisor.AdviceError.unreadableResponse
        }
        return answer
    }

    static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["suggest", "units", "reason"],
        "properties": [
            "suggest": ["type": "boolean"],
            "units": ["type": "number"],
            "reason": ["type": "string"],
        ] as [String: Any],
    ]

    static let prompt = """
        Du følger med på blodsukkeret etter et måltid for et lite barn med type 1-diabetes som bruker Loop (automatisk insulin, Omnipod DASH). Omsorgspersonen har bedt om at du sier fra når en ekstra dose bør gis, for eksempel når fett i måltidet gir en sen stigning. Du gir aldri insulin selv: et forslag går til omsorgspersonen, som godtar, endrer eller avslår.

        Du får situasjonen nå fra Loop (blodsukker og endring siste 15 min, insulin og karbo om bord, Loops prognose og hva Loop selv ville anbefalt), måltidet, terapiinnstillingene, tidligere forslag for dette måltidet og hvordan lignende måltider gikk tidligere (blodsukker hver halvtime i fem timer fra måltidet, og insulin gitt senere). typical_rise_start_minutes er når de pleier å begynne å stige.

        Regler:
        - Foreslå bare når det er tydelig at barnet trenger mer insulin nå: blodsukkeret stiger og vil havne over 10, eller lignende måltider viser at stigningen kommer om kort tid og Loop ikke har tatt høyde for den.
        - Aldri når blodsukkeret er under 6, faller, eller Loop spår under 4,5. Et lite barn er svært følsomt; føling er farligere enn et forbigående høyt blodsukker.
        - Ta hensyn til insulin om bord: Loop gir selv mer via basal når den kan. Dosen er det som trengs i tillegg.
        - units: høyst maximum_units, gjerne mindre. 0 når du ikke foreslår noe.
        - reason: én kort setning på norsk til omsorgspersonen, med det viktigste tallet (for eksempel «8,4 og stiger 0,6 per kvarter – melka pleier å gi topp rundt 13 om en time.»).
        - Er du i tvil, foreslå ingenting; du ser igjen om et kvarter.
        """
}

// MARK: - Nightscout, for LoopFollow

/// The Nightscout treatment that stands for an open suggestion, so a parent can see it and
/// give it from LoopFollow while the phone is with the child.
///
/// Contract with LoopFollow (`Treatments/MealWatchSuggestion.swift`); change both apps together:
/// - `eventType`: "AI Bolus Suggestion"
/// - `created_at`, `timestamp`: when it was made (UTC); `expiresAt`: when it lapses (UTC)
/// - `suggestionID`: stable id; `units`: suggested insulin; `reason`: one sentence
/// - `glucose` (mmol/L), `loopUnits`, `foodType`, `mealName`, `mealDate`, `mealCarbs`
///
/// No `insulin` or `carbs` field, so it never counts as either. It is deleted when the
/// suggestion is given, declined or lapses.
enum MealWatchTreatment {
    static let eventType = "AI Bolus Suggestion"

    static func document(for suggestion: MealWatchSuggestion, in watch: MealWatch) -> [String: Any] {
        var document: [String: Any] = [
            "eventType": eventType,
            "created_at": iso8601(suggestion.date),
            "timestamp": iso8601(suggestion.date),
            "expiresAt": iso8601(suggestion.expiresAt),
            "suggestionID": suggestion.id,
            "units": suggestion.units,
            "reason": suggestion.reason,
            "mealName": watch.mealDescription,
            "mealDate": iso8601(watch.mealDate),
            "mealCarbs": watch.carbs,
            "enteredBy": "Loop",
            "notes": String(format: NSLocalizedString("AI suggests %1$@ U: %2$@", comment: "Nightscout note for a meal watch suggestion (1: units)(2: reason)"), MealWatchManager.units(suggestion.units), suggestion.reason),
        ]
        if let glucose = suggestion.glucoseMmol { document["glucose"] = glucose }
        if let loopUnits = suggestion.loopUnits { document["loopUnits"] = loopUnits }
        if let foodType = watch.foodType { document["foodType"] = foodType }
        return document
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

/// Nightscout's v1 treatments API, with the API secret the Nightscout service holds.
struct MealWatchNightscoutAPI {
    let siteURL: URL
    let apiSecret: String

    static func fromKeychain() -> MealWatchNightscoutAPI? {
        guard let credentials = try? KeychainManager().getNightscoutCredentials(), !credentials.apiSecret.isEmpty else { return nil }
        return MealWatchNightscoutAPI(siteURL: credentials.siteURL, apiSecret: credentials.apiSecret)
    }

    private var secretHash: String {
        Insecure.SHA1.hash(data: Data(apiSecret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func request(path: String, method: String, body: Any? = nil) throws -> URLRequest {
        var request = URLRequest(url: siteURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue(secretHash, forHTTPHeaderField: "api-secret")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// Stores the treatment and returns its `_id`.
    func create(_ document: [String: Any]) async throws -> String? {
        let (data, response) = try await URLSession.shared.data(for: try request(path: "api/v1/treatments.json", method: "POST", body: [document]))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AIChat.ChatError.server("Nightscout \(http.statusCode)")
        }
        let created = try? JSONSerialization.jsonObject(with: data)
        let first = (created as? [[String: Any]])?.first ?? created as? [String: Any]
        return first?["_id"] as? String
    }

    /// Whether it is still there: gone when someone deleted it, for example from LoopFollow.
    func exists(_ nsID: String) async throws -> Bool {
        var components = URLComponents(url: siteURL.appendingPathComponent("api/v1/treatments.json"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "find[_id]", value: nsID), URLQueryItem(name: "count", value: "1")]
        guard let url = components?.url else { return true }
        var urlRequest = try request(path: "api/v1/treatments.json", method: "GET")
        urlRequest.url = url
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AIChat.ChatError.server("Nightscout \(http.statusCode)")
        }
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return true }
        return !list.isEmpty
    }

    /// Deletes it; one that is already gone is not an error.
    func delete(_ nsID: String) async throws {
        let (_, response) = try await URLSession.shared.data(for: try request(path: "api/v1/treatments/\(nsID)", method: "DELETE"))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode), http.statusCode != 404 {
            throw AIChat.ChatError.server("Nightscout \(http.statusCode)")
        }
    }
}

// MARK: - Running it

@MainActor
final class MealWatchManager: ObservableObject {
    static let shared = MealWatchManager()

    nonisolated static let notificationPrefix = "mealWatch."
    nonisolated static let notificationCategory = "mealWatchSuggestion"
    nonisolated static let reviewAction = "mealWatch.review"
    nonisolated static let declineAction = "mealWatch.decline"
    nonisolated static let suggestionIDUserInfoKey = "MealWatchSuggestionID"

    @Published private(set) var watches: [MealWatch]
    /// A suggestion to open the bolus screen for, set from a notification before the home screen
    /// may be there to take it.
    @Published var pendingReviewID: String?

    nonisolated static func requestReview(_ suggestionID: String) {
        Task { @MainActor in shared.pendingReviewID = suggestionID }
    }

    private let log = OSLog(category: "MealWatchManager")
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?
    private var isChecking = false
    private var settings: () -> LoopSettings? = { nil }
    private var manualBoluses: (Date) async -> [(date: Date, units: Double)] = { _ in [] }
    /// Nightscout `_id` per suggestion id, for deleting it again.
    private var uploaded: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        watches = defaults.mealWatches
        uploaded = defaults.mealWatchUploads
    }

    /// The AI is available and the caregiver has AI dose advice on.
    nonisolated static var isAvailable: Bool {
        AIChat.shared != nil && UserDefaults.standard.aiDoseAdviceSettings.isEnabled
    }

    func start(settings: @escaping () -> LoopSettings?, manualBoluses: @escaping (Date) async -> [(date: Date, units: Double)]) {
        self.settings = settings
        self.manualBoluses = manualBoluses
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .LoopCompleted, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    var activeWatches: [MealWatch] {
        watches.filter { $0.isActive(at: Date()) || $0.openSuggestion != nil }
    }

    func suggestion(withID id: String) -> (MealWatch, MealWatchSuggestion)? {
        for watch in watches {
            if let suggestion = watch.suggestions.first(where: { $0.id == id }) {
                return (watch, suggestion)
            }
        }
        return nil
    }

    // MARK: Changes

    func watch(entryID: String?, mealDate: Date, carbs: Double, foodType: String?, absorptionTime: TimeInterval?) {
        let length = min(max((absorptionTime ?? .hours(3)) + .hours(1), MealWatchGate.watchLength.lowerBound), MealWatchGate.watchLength.upperBound)
        var watches = self.watches.filter { $0.mealDate > Date().addingTimeInterval(-.hours(24)) }
        watches.append(MealWatch(id: UUID().uuidString, entryID: entryID, mealDate: mealDate, carbs: carbs, foodType: foodType, until: mealDate.addingTimeInterval(length)))
        save(watches)
        if let key = MealWatch.foodKey(foodType) {
            defaults.mealWatchFoods.insert(key)
        }
    }

    /// Stops watching a meal, declining any open suggestion.
    func stop(_ watchID: String) {
        update(watchID) { watch in
            watch.isStopped = true
            for index in watch.suggestions.indices where watch.suggestions[index].state == .open {
                watch.suggestions[index].state = .declined
            }
        }
        if let watch = watches.first(where: { $0.id == watchID }), let key = MealWatch.foodKey(watch.foodType) {
            defaults.mealWatchFoods.remove(key)
        }
        Task { await syncNightscout() }
    }

    func decline(_ suggestionID: String) {
        close(suggestionID, as: .declined)
    }

    private func close(_ suggestionID: String, as state: MealWatchSuggestion.State) {
        for watch in watches {
            guard let index = watch.suggestions.firstIndex(where: { $0.id == suggestionID && $0.state == .open }) else { continue }
            update(watch.id) { $0.suggestions[index].state = state }
        }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationPrefix + suggestionID])
        Task { await syncNightscout() }
    }

    /// Whether the meal watch is turned on by itself for this food: it was on the last time.
    nonisolated static func isRemembered(foodName: String?) -> Bool {
        guard let name = foodName?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return false }
        return UserDefaults.standard.mealWatchFoods.contains(name)
    }

    // MARK: Checking

    func check(now: Date = Date()) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        await closeGivenAndExpired(now: now)
        guard Self.isAvailable, let chat = AIChat.shared else { return }

        for watch in watches where watch.isActive(at: now) {
            let loop = await LoopNow.current()
            let insight = GlucoseInsightManager.shared
            let history = MealWatchGate.historyMeals(
                like: watch.carbs, foodType: watch.foodType, at: watch.mealDate,
                meals: insight.status.longTerm?.meals ?? [], history: await insight.storedHistory()
            )
            let decision = MealWatchGate.decide(watch, now: loop, history: history, at: now)
            guard decision != .wait else { continue }
            update(watch.id) { $0.lastCheck = now }
            guard decision == .ask, let loop else {
                if case .skip(let reason) = decision {
                    log.debug("Meal watch %{public}@: %{public}@", watch.id, reason)
                }
                continue
            }
            await ask(chat, about: watch, now: loop, history: history, at: now)
        }
    }

    private func ask(_ chat: AIChat, about watch: MealWatch, now loop: LoopNow, history: [MealWatchHistoryMeal], at now: Date) async {
        let settings = self.settings()
        let adviceSettings = defaults.aiDoseAdviceSettings
        let allowed = MealWatchGate.allowedUnits(loopUnits: loop.loopRecommendedBolusUnits, maximumAboveLoop: adviceSettings.maximumAboveLoop, maximumBolus: settings?.maximumBolus)
        let mmol = { (quantity: HKQuantity) in LoopNow.mmol(quantity) }
        let target = settings?.glucoseTargetRangeSchedule?.quantityRange(at: now)
        let therapy = AIDoseSituation.Therapy(
            carbRatioGramsPerUnit: settings?.carbRatioSchedule?.value(at: now),
            insulinSensitivityMmolPerUnit: settings?.insulinSensitivitySchedule.map { mmol($0.quantity(at: now)) },
            targetMmol: target.map { [mmol($0.lowerBound), mmol($0.upperBound)] },
            suspendThresholdMmol: settings?.suspendThreshold.map { mmol($0.quantity) },
            maximumBolusUnits: settings?.maximumBolus,
            activeOverride: loop.activeOverride
        )
        let input = MealWatchAdvisor.Input(
            localTime: GlucoseInsightWriter.localTime(now),
            childProfile: adviceSettings.childProfile,
            minutesSinceMeal: Int(now.timeIntervalSince(watch.mealDate) / 60),
            meal: .init(carbsGrams: watch.carbs, foodType: watch.foodType),
            now: loop,
            therapy: therapy,
            maximumUnits: allowed,
            earlierSuggestionsForThisMeal: watch.suggestions.map {
                .init(minutesSinceMeal: Int($0.date.timeIntervalSince(watch.mealDate) / 60), units: $0.units, outcome: $0.state.rawValue)
            },
            similarMeals: history,
            typicalRiseStartMinutes: MealWatchGate.typicalRiseStart(history)
        )

        let answer: MealWatchAdvisor.Answer
        do {
            answer = try await MealWatchAdvisor(chat: chat).advise(input)
        } catch {
            log.error("Meal watch advice failed: %{public}@", String(describing: error))
            return
        }
        // Glucose may have moved while the AI thought: the same checks again on what is now.
        guard answer.suggest,
              let fresh = await LoopNow.current(),
              (fresh.glucoseMmol ?? 0) >= MealWatchGate.minimumGlucose,
              (fresh.change15MinMmol ?? 0) >= -0.2,
              (fresh.lowestForecastMmol ?? 0) >= MealWatchGate.minimumForecast,
              let units = MealWatchGate.clamp(answer.units, allowed: allowed)
        else { return }

        let suggestion = MealWatchSuggestion(
            id: UUID().uuidString,
            date: now,
            units: units,
            reason: answer.reason,
            glucoseMmol: fresh.glucoseMmol,
            loopUnits: fresh.loopRecommendedBolusUnits,
            expiresAt: now.addingTimeInterval(MealWatchGate.suggestionLifetime),
            state: .open
        )
        update(watch.id) { $0.suggestions.append(suggestion) }
        notify(suggestion, for: watch)
        await syncNightscout()
    }

    /// A manual bolus since a suggestion was made closes it as given; one past its time lapses.
    private func closeGivenAndExpired(now: Date) async {
        let open = watches.flatMap { watch in watch.suggestions.filter { $0.state == .open } }
        guard !open.isEmpty else {
            await syncNightscout()
            return
        }
        let earliest = open.map(\.date).min() ?? now
        let boluses = await manualBoluses(earliest)
        for suggestion in open {
            if boluses.contains(where: { $0.date >= suggestion.date && $0.units >= 0.05 }) {
                close(suggestion.id, as: .given)
            } else if now >= suggestion.expiresAt {
                close(suggestion.id, as: .expired)
            }
        }
    }

    // MARK: Notifying

    private func notify(_ suggestion: MealWatchSuggestion, for watch: MealWatch) {
        let content = UNMutableNotificationContent()
        content.title = String(format: NSLocalizedString("✨ Suggested: %1$@ U for %2$@", comment: "Meal watch notification title (1: units)(2: name of the meal)"), Self.units(suggestion.units), watch.mealDescription)
        content.body = suggestion.reason
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = [Self.suggestionIDUserInfoKey: suggestion.id]
        let request = UNNotificationRequest(identifier: Self.notificationPrefix + suggestion.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated static var notificationCategoryDefinition: UNNotificationCategory {
        UNNotificationCategory(
            identifier: notificationCategory,
            actions: [
                UNNotificationAction(identifier: reviewAction, title: NSLocalizedString("Review", comment: "Meal watch notification action opening the bolus screen with the suggestion"), options: .foreground),
                UNNotificationAction(identifier: declineAction, title: NSLocalizedString("Decline", comment: "Meal watch notification action declining the suggestion"), options: .destructive),
            ],
            intentIdentifiers: [],
            options: []
        )
    }

    nonisolated static func units(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    // MARK: Nightscout

    private func syncNightscout() async {
        guard let api = MealWatchNightscoutAPI.fromKeychain() else { return }
        var desired: [String: (MealWatch, MealWatchSuggestion)] = [:]
        for watch in watches {
            for suggestion in watch.suggestions where suggestion.state == .open {
                desired[suggestion.id] = (watch, suggestion)
            }
        }
        do {
            for (id, nsID) in uploaded where desired[id] == nil {
                try await api.delete(nsID)
                uploaded[id] = nil
                defaults.mealWatchUploads = uploaded
            }
            for (id, pair) in desired where uploaded[id] == nil {
                if let nsID = try await api.create(MealWatchTreatment.document(for: pair.1, in: pair.0)) {
                    uploaded[id] = nsID
                    defaults.mealWatchUploads = uploaded
                }
            }
        } catch {
            log.error("Meal watch Nightscout sync failed: %{public}@", String(describing: error))
        }
    }

    // MARK: Storage

    private func update(_ watchID: String, _ change: (inout MealWatch) -> Void) {
        var watches = self.watches
        guard let index = watches.firstIndex(where: { $0.id == watchID }) else { return }
        change(&watches[index])
        save(watches)
    }

    private func save(_ watches: [MealWatch]) {
        self.watches = watches
        defaults.mealWatches = watches
    }
}

extension UserDefaults {
    private enum MealWatchKey: String {
        case watches = "com.loopkit.Loop.mealWatches"
        case uploads = "com.loopkit.Loop.mealWatchUploads"
        case foods = "com.loopkit.Loop.mealWatchFoods"
    }

    var mealWatches: [MealWatch] {
        get { data(forKey: MealWatchKey.watches.rawValue).flatMap { try? JSONDecoder().decode([MealWatch].self, from: $0) } ?? [] }
        set { set(try? JSONEncoder().encode(newValue), forKey: MealWatchKey.watches.rawValue) }
    }

    var mealWatchUploads: [String: String] {
        get { dictionary(forKey: MealWatchKey.uploads.rawValue) as? [String: String] ?? [:] }
        set { set(newValue, forKey: MealWatchKey.uploads.rawValue) }
    }

    /// Foods (lowercased names) the meal watch was on for last time, so it starts on for them.
    var mealWatchFoods: Set<String> {
        get { Set(stringArray(forKey: MealWatchKey.foods.rawValue) ?? []) }
        set { set(Array(newValue).sorted(), forKey: MealWatchKey.foods.rawValue) }
    }
}
