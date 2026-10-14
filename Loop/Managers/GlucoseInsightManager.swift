//
//  GlucoseInsightManager.swift
//  Loop
//
//  Keeps the glucose insight up to date through the day, so the AI dose advice can read it
//  instead of working through weeks of history while someone waits at the bolus screen.
//
//  After a loop, at most every half hour: what is new in Nightscout is read and the numbers are
//  worked out again — no AI — and the result is put back in Nightscout for LoopFollow. With AI dose advice turned on, the model also writes what the numbers
//  mean: the deep model once a night about the weeks behind, and the fast model through the day
//  when a meal is over or after a low. Each has a daily ceiling, so a fault can't run up the bill.
//

import Foundation
import HealthKit
import LoopCore
import LoopKit
import UIKit
import os.log

@MainActor
final class GlucoseInsightManager: ObservableObject {
    static let shared = GlucoseInsightManager()

    @Published private(set) var status: GlucoseInsightStatus
    @Published private(set) var isUpdating = false

    private let log = OSLog(category: "GlucoseInsightManager")
    private let store: NightscoutHistoryStore
    private let defaults: UserDefaults
    private let fileURL: URL
    private var settings: () -> LoopSettings? = { nil }
    private var observer: NSObjectProtocol?
    private var lastDataAttempt: Date?
    private let uploader = GlucoseInsightUploader()

    init(store: NightscoutHistoryStore = .shared, defaults: UserDefaults = .standard, fileURL: URL? = nil) {
        self.store = store
        self.defaults = defaults
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlucoseInsight", isDirectory: true)
            .appendingPathComponent("Status.json")
        try? FileManager.default.createDirectory(at: self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        status = (try? Data(contentsOf: self.fileURL)).flatMap { try? JSONDecoder().decode(GlucoseInsightStatus.self, from: $0) } ?? GlucoseInsightStatus()
    }

    /// Starts following the loop. `settings` gives the therapy settings the model is told about.
    func start(settings: @escaping () -> LoopSettings?) {
        self.settings = settings
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .LoopCompleted, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateIfDue() }
        }
    }

    private var aiEnabled: Bool {
        defaults.aiDoseAdviceSettings.isEnabled && OpenAIChat.shared != nil
    }

    // MARK: Updating

    /// Does what is due. With `force` (the insight tab is open), reads Nightscout now, and has
    /// today's text written again when it is over half an hour old — within the daily ceiling.
    func updateIfDue(force: Bool = false) {
        guard !isUpdating else { return }
        let now = Date()
        var due = GlucoseInsightSchedule.dueWork(status: status, attempts: defaults.glucoseInsightAttempts, aiEnabled: aiEnabled, lastDataAttempt: lastDataAttempt, now: now)
        if force, now.timeIntervalSince(status.dataUpdatedAt ?? .distantPast) >= .minutes(5) {
            due.data = true
        }
        let attempts = defaults.glucoseInsightAttempts.on(now)
        let forceToday = force && aiEnabled
            && now.timeIntervalSince(status.todayText?.createdAt ?? .distantPast) >= .minutes(30)
            && attempts.fast < GlucoseInsightSchedule.maximumFastCallsPerDay
            && GlucoseInsightSchedule.todayHours.contains(Calendar.current.component(.hour, from: now))
        guard due.data || due.longTermText || due.todayText || forceToday else { return }

        isUpdating = true
        let background = UIApplication.shared.beginBackgroundTask(withName: "GlucoseInsight")
        Task {
            await self.run(due, forceToday: forceToday, now: now)
            self.isUpdating = false
            UIApplication.shared.endBackgroundTask(background)
        }
    }

    private func run(_ due: GlucoseInsightSchedule.DueWork, forceToday: Bool, now: Date) async {
        var status = self.status
        if due.data {
            lastDataAttempt = now
            do {
                let days = defaults.aiDoseAdviceSettings.historyDays
                let history = try await store.refresh(days: days, now: now)
                status.longTerm = GlucoseInsight.longTerm(history: history, advice: defaults.aiDoseAdviceRecords, days: days, now: now)
                status.today = GlucoseInsight.today(history: history, now: now)
                status.dataUpdatedAt = now
                status.lastError = nil
            } catch {
                log.error("Reading Nightscout failed: %{public}@", String(describing: error))
                status.lastError = error.localizedDescription
            }
            publish(status)
        }

        // The numbers may just have arrived, so what is due is looked at again.
        let aiDue = GlucoseInsightSchedule.dueWork(status: status, attempts: defaults.glucoseInsightAttempts, aiEnabled: aiEnabled, lastDataAttempt: lastDataAttempt, now: now)
        guard let chat = OpenAIChat.shared else { return }
        let writer = GlucoseInsightWriter(chat: chat)
        let profile = defaults.aiDoseAdviceSettings.childProfile
        let therapy = GlucoseInsightTherapy.dayparts(settings(), on: now)

        if aiDue.longTermText, let longTerm = status.longTerm {
            defaults.glucoseInsightAttempts.record(.deep, at: now)
            do {
                status.longTermText = try await writer.longTerm(longTerm, today: status.today, therapy: therapy, childProfile: profile, now: now)
                status.lastError = nil
            } catch {
                log.error("Long-term insight failed: %{public}@", String(describing: error))
                status.lastError = error.localizedDescription
            }
            publish(status)
        }

        if aiDue.todayText || forceToday, let today = status.today {
            defaults.glucoseInsightAttempts.record(.fast, at: now)
            do {
                status.todayText = try await writer.today(today, longTerm: status.longTerm, longTermText: status.longTermText, therapy: therapy, childProfile: profile, now: now)
                status.lastError = nil
            } catch {
                log.error("Today's insight failed: %{public}@", String(describing: error))
                status.lastError = error.localizedDescription
            }
            publish(status)
        }
    }

    private func publish(_ status: GlucoseInsightStatus) {
        self.status = status
        if let data = try? JSONEncoder().encode(status) {
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        // LoopFollow reads it from Nightscout.
        uploader.upload(status, aiEnabled: aiEnabled, usage: defaults.openAIUsage(on: Date()))
    }

#if DEBUG
    /// For looking at the insight tab with made-up numbers.
    func setStatusForPreview(_ status: GlucoseInsightStatus) {
        self.status = status
    }
#endif

    // MARK: For the dose advice

    /// What the AI dose advice is told about the child: the texts, the numbers for this part of
    /// the day and today, and the meals most like this one.
    func doseContext(carbs: Double?, foodType: String?, at date: Date) -> AIDoseStatusContext? {
        guard status.longTerm != nil || status.today != nil else { return nil }
        let longTerm = status.longTerm
        let daypart = GlucoseInsight.daypartName(date, calendar: .current)
        return AIDoseStatusContext(
            dataAgeMinutes: status.dataUpdatedAt.map { Int(date.timeIntervalSince($0) / 60) },
            longTermSummary: status.longTermText?.summary,
            longTermPoints: status.longTermText?.points ?? [],
            longTermDoseHints: status.longTermText?.doseHints ?? [],
            todaySummary: status.todayText.flatMap { Calendar.current.isDate($0.createdAt, inSameDayAs: date) ? $0.summary : nil },
            todayDoseHints: status.todayText.flatMap { Calendar.current.isDate($0.createdAt, inSameDayAs: date) ? $0.doseHints : nil } ?? [],
            daypartNow: longTerm?.dayparts.first { $0.name == daypart },
            today: status.today.flatMap { Calendar.current.isDate($0.computedAt, inSameDayAs: date) ? $0 : nil },
            similarMeals: carbs.map { GlucoseInsight.similarMeals(to: $0, foodType: foodType, at: date, in: longTerm?.meals ?? []) } ?? [],
            earlierAdvice: Array((longTerm?.advice ?? []).suffix(10))
        )
    }
}

/// When the numbers are read and the texts written. Kept apart from the manager so it can be
/// worked out anywhere.
enum GlucoseInsightSchedule {

    /// Nightscout is read again after this long.
    static let dataInterval: TimeInterval = .minutes(30)
    /// The longest a day's text is kept before something new happens.
    static let todayTextInterval: TimeInterval = .minutes(45)
    /// The night's look at the weeks behind is written after this hour.
    static let nightlyHour = 4
    /// The fast model writes about today between these hours.
    static let todayHours = 6..<23
    /// The most calls a day for the insight; the dose advice is not counted here.
    static let maximumDeepCallsPerDay = 2
    static let maximumFastCallsPerDay = 8
    /// After a failed call, the next try waits this long.
    static let retryInterval: TimeInterval = .minutes(30)

    struct DueWork: Equatable {
        var data = false
        var longTermText = false
        var todayText = false
    }

    /// What is due at `now`. `aiEnabled` is false while AI dose advice is off or the app has no key.
    static func dueWork(status: GlucoseInsightStatus, attempts: GlucoseInsightAttempts, aiEnabled: Bool, lastDataAttempt: Date?, now: Date, calendar: Calendar = .current) -> DueWork {
        var due = DueWork()
        let dataAge = status.dataUpdatedAt.map { now.timeIntervalSince($0) } ?? .infinity
        let lastTry = lastDataAttempt.map { now.timeIntervalSince($0) } ?? .infinity
        due.data = dataAge >= dataInterval && lastTry >= .minutes(10)

        guard aiEnabled else { return due }
        let attempts = attempts.on(now, calendar: calendar)

        // The long-term text: once after the night hour each day.
        var nightly = calendar.date(bySettingHour: nightlyHour, minute: 0, second: 0, of: now) ?? now
        if nightly > now {
            nightly = calendar.date(byAdding: .day, value: -1, to: nightly) ?? nightly
        }
        if status.longTerm != nil,
           (status.longTermText?.createdAt ?? .distantPast) < nightly,
           attempts.deep < maximumDeepCallsPerDay,
           now.timeIntervalSince(attempts.lastDeep ?? .distantPast) >= retryInterval {
            due.longTermText = true
        }

        // Today's text: first thing in the morning, and when a meal is over or after a low.
        if let today = status.today,
           todayHours.contains(calendar.component(.hour, from: now)),
           attempts.fast < maximumFastCallsPerDay,
           now.timeIntervalSince(attempts.lastFast ?? .distantPast) >= retryInterval {
            let written = status.todayText?.createdAt ?? .distantPast
            if written < calendar.startOfDay(for: now) {
                due.todayText = true
            } else if now.timeIntervalSince(written) >= todayTextInterval {
                let mealOver = today.meals.contains { meal in
                    let over = meal.date.addingTimeInterval(.hours(3))
                    return over > written && over <= now
                }
                let low = today.lowEpisodeStarts.contains { $0 > written }
                due.todayText = mealOver || low
            }
        }
        return due
    }
}

/// What the dose advice is told from the insight.
struct AIDoseStatusContext: Encodable {
    var dataAgeMinutes: Int?
    var longTermSummary: String?
    var longTermPoints: [String]
    var longTermDoseHints: [String]
    var todaySummary: String?
    var todayDoseHints: [String]
    var daypartNow: GlucoseInsightDaypart?
    var today: GlucoseInsightToday?
    var similarMeals: [GlucoseInsightMeal]
    var earlierAdvice: [GlucoseInsightAdvice]
}

/// The therapy settings at the middle of each part of the day.
struct GlucoseInsightTherapy: Encodable, Equatable {
    var daypart: String
    var carbRatioGramsPerUnit: Double?
    var insulinSensitivityMmolPerUnit: Double?
    var targetMmol: [Double]?

    static func dayparts(_ settings: LoopSettings?, on date: Date, calendar: Calendar = .current) -> [GlucoseInsightTherapy] {
        guard let settings else { return [] }
        let startOfDay = calendar.startOfDay(for: date)
        return GlucoseInsight.dayparts.map { part in
            let middle = startOfDay.addingTimeInterval(.hours(Double(part.hours.lowerBound + part.hours.upperBound) / 2))
            let target = settings.glucoseTargetRangeSchedule?.quantityRange(at: middle)
            return GlucoseInsightTherapy(
                daypart: part.name,
                carbRatioGramsPerUnit: settings.carbRatioSchedule?.value(at: middle),
                insulinSensitivityMmolPerUnit: settings.insulinSensitivitySchedule.map { GlucoseInsight.round1($0.quantity(at: middle).doubleValue(for: .millimolesPerLiter)) },
                targetMmol: target.map { [GlucoseInsight.round1($0.lowerBound.doubleValue(for: .millimolesPerLiter)), GlucoseInsight.round1($0.upperBound.doubleValue(for: .millimolesPerLiter))] }
            )
        }
    }
}

/// Calls made today, for the daily ceilings.
struct GlucoseInsightAttempts: Codable, Equatable {
    var day = ""
    var deep = 0
    var fast = 0
    var lastDeep: Date?
    var lastFast: Date?

    /// The counts for `date`'s day: zero on a new day.
    func on(_ date: Date, calendar: Calendar = .current) -> GlucoseInsightAttempts {
        let key = OpenAIDailyUsage.dayKey(date, calendar: calendar)
        return day == key ? self : GlucoseInsightAttempts(day: key, lastDeep: lastDeep, lastFast: lastFast)
    }

    mutating func record(_ tier: OpenAIChat.Tier, at date: Date, calendar: Calendar = .current) {
        self = on(date, calendar: calendar)
        switch tier {
        case .deep:
            deep += 1
            lastDeep = date
        case .fast:
            fast += 1
            lastFast = date
        }
    }
}

extension UserDefaults {
    private static let glucoseInsightAttemptsKey = "com.loopkit.Loop.glucoseInsightAttempts"

    var glucoseInsightAttempts: GlucoseInsightAttempts {
        get {
            guard let data = data(forKey: Self.glucoseInsightAttemptsKey) else { return GlucoseInsightAttempts() }
            return (try? JSONDecoder().decode(GlucoseInsightAttempts.self, from: data)) ?? GlucoseInsightAttempts()
        }
        set { set(try? JSONEncoder().encode(newValue), forKey: Self.glucoseInsightAttemptsKey) }
    }
}

// MARK: - Writing the texts

/// Asks the model what the numbers mean.
struct GlucoseInsightWriter {
    let chat: OpenAIChat

    func longTerm(_ longTerm: GlucoseInsightLongTerm, today: GlucoseInsightToday?, therapy: [GlucoseInsightTherapy], childProfile: String, now: Date) async throws -> GlucoseInsightText {
        struct Input: Encodable {
            var localTime: String
            var childProfile: String
            var therapy: [GlucoseInsightTherapy]
            var longTerm: GlucoseInsightLongTerm
            var today: GlucoseInsightToday?
        }
        let input = Input(localTime: Self.localTime(now), childProfile: childProfile, therapy: therapy, longTerm: longTerm, today: today)
        let body = try Self.requestBody(system: Self.longTermPrompt, input: input, reasoning: "high")
        return try Self.parse(try await chat.send(body, timeout: 300, tier: .deep), now: now)
    }

    func today(_ today: GlucoseInsightToday, longTerm: GlucoseInsightLongTerm?, longTermText: GlucoseInsightText?, therapy: [GlucoseInsightTherapy], childProfile: String, now: Date) async throws -> GlucoseInsightText {
        struct Input: Encodable {
            var localTime: String
            var childProfile: String
            var therapy: [GlucoseInsightTherapy]
            var longTermSummary: String?
            var longTermPoints: [String]
            var longTermDoseHints: [String]
            var dayparts: [GlucoseInsightDaypart]
            var today: GlucoseInsightToday
        }
        let input = Input(
            localTime: Self.localTime(now),
            childProfile: childProfile,
            therapy: therapy,
            longTermSummary: longTermText?.summary,
            longTermPoints: longTermText?.points ?? [],
            longTermDoseHints: longTermText?.doseHints ?? [],
            dayparts: longTerm?.dayparts ?? [],
            today: today
        )
        let body = try Self.requestBody(system: Self.todayPrompt, input: input, reasoning: "medium")
        return try Self.parse(try await chat.send(body, timeout: 120, tier: .fast), now: now)
    }

    static func localTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nb_NO")
        formatter.dateFormat = "EEEE d. MMMM yyyy HH:mm"
        return formatter.string(from: date)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "nb_NO")
        formatter.dateFormat = "EEE d. MMM HH:mm"
        encoder.dateEncodingStrategy = .formatted(formatter)
        return encoder
    }

    static func requestBody<T: Encodable>(system: String, input: T, reasoning: String) throws -> [String: Any] {
        let json = String(data: try encoder().encode(input), encoding: .utf8) ?? "{}"
        return [
            "reasoning_effort": reasoning,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": json],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "glucose_insight",
                    "strict": true,
                    "schema": schema,
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    static func parse(_ data: Data, now: Date) throws -> GlucoseInsightText {
        struct Completion: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { var content: String? }
                var message: Message
            }
            var choices: [Choice]
        }
        struct Answer: Decodable {
            var summary: String
            var points: [String]
            var dose_hints: [String]
        }
        guard let content = (try? JSONDecoder().decode(Completion.self, from: data))?.choices.first?.message.content?.data(using: .utf8),
              let answer = try? JSONDecoder().decode(Answer.self, from: content)
        else {
            throw AIDoseAdvisor.AdviceError.unreadableResponse
        }
        return GlucoseInsightText(summary: answer.summary, points: answer.points, doseHints: answer.dose_hints, createdAt: now)
    }

    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["summary", "points", "dose_hints"],
        "properties": [
            "summary": ["type": "string"],
            "points": ["type": "array", "items": ["type": "string"]] as [String: Any],
            "dose_hints": ["type": "array", "items": ["type": "string"]] as [String: Any],
        ] as [String: Any],
    ]

    static let commonRules = """
        Tallene er regnet ut i appen og er riktige; ikke regn dem om, og ikke finn på tall som ikke står der. Blodsukker er i mmol/L, målområdet 3,9–10.
        - loop_forecast_error: faktisk minus Loops prognose (median). Positivt betyr at Loop spår for lavt der og trenger mer insulin enn den tror; negativt at den spår for høyt.
        - Måltider med flags (extra_carbs, correction, treated_low, started_low) er forstyrret og teller ikke i mønstrene; clean_meals er de rene.
        - median_grams_per_unit er karbo per enhet måltidsbolus i rene måltider; sammenlign med karboratioen i therapy.
        - Siste 7 dager veier tyngre enn de 30 når de spriker: barnet vokser, og sykdom og pod-bytter endrer ting.
        - Et lite barn er svært følsomt for insulin; føling er farligere enn et forbigående høyt blodsukker. Si fra om alt som tyder på føling.
        - Vær konkret og kort, på norsk. Ingen generelle råd om diabetes; bare det disse tallene viser. Si det når grunnlaget er tynt (få måltider eller målinger).
        """

    static let longTermPrompt = """
        Du lager en oversikt over blodsukkeret til et lite barn med type 1-diabetes som bruker Loop (automatisk insulin, Omnipod DASH). Oversikten lagres og leses senere av en annen modell som foreslår bolusdoser, og av omsorgspersonen i appen.

        Du får de siste ukene ferdig regnet ut: tid i mål per del av døgnet (siste 7 og 30 dager), hvor mye Loops prognose bommer per del av døgnet, hvordan måltidene gikk, hverdag mot helg på dagtid, hvordan AI-dosene som ble vist gikk, terapiinnstillingene og det omsorgspersonen har skrevet om barnet.

        \(commonRules)

        Svar med:
        - summary: 2–3 setninger om hvordan det går og det viktigste mønsteret.
        - points: 3–6 korte funn, hvert med tid på døgnet og tallene det bygger på (for eksempel «Kveld 19–24: Loop spår 3,8 for lavt etter 2 t; 4 av 6 rene middager over 10 etter 3 t»).
        - dose_hints: 2–5 konkrete hint for bolus per del av døgnet eller mattype, slik en som skal foreslå en dose kan bruke dem (for eksempel «Frokost: rene måltider ender ofte lavt – ikke mer enn Loop»). Ingen hint uten grunnlag i tallene.
        """

    static let todayPrompt = """
        Du skriver en kort status for i dag om blodsukkeret til et lite barn med type 1-diabetes som bruker Loop (automatisk insulin, Omnipod DASH). Den leses av omsorgspersonen i appen og av en modell som foreslår bolusdoser resten av dagen.

        Du får dagens tall (tid i mål så langt, lave perioder, timer over 10, dagens måltider og hvordan de gikk, hvor mye Loop bommer i dag mot vanlig for de samme timene), mønstrene fra de siste ukene og oversikten som ble skrevet i natt.

        \(commonRules)
        - forecast_deviation_mmol: dagens prognosefeil minus den vanlige. Over +1 betyr at barnet trenger mer insulin enn vanlig i dag (for eksempel sykdom); under −1 mindre (for eksempel mye aktivitet).

        Svar med:
        - summary: 1–2 setninger om hvordan dagen går og om den skiller seg fra vanlig.
        - points: 0–4 korte funn fra i dag.
        - dose_hints: 0–3 hint for resten av dagen (for eksempel «Mer følsom enn vanlig i dag – to lave etter lunsj; vurder litt mindre til middag»). Tom liste når dagen er som vanlig.
        """
}
