//
//  EveningWatchManager.swift
//  Loop
//
//  Runs the evening watch after every loop: gives the dose in automatic mode, or puts the
//  suggestion on the home screen, in a notification and in Nightscout for LoopFollow, where it
//  stays until it is given, declined here or in LoopFollow, or no longer needed.
//

import CryptoKit
import Foundation
import LoopKit
import UserNotifications
import os.log

@MainActor
final class EveningWatchManager: ObservableObject {
    static let shared = EveningWatchManager()

    nonisolated static let notificationPrefix = "eveningWatch."
    nonisolated static let notificationCategory = "eveningWatchSuggestion"
    nonisolated static let reviewAction = "eveningWatch.review"
    nonisolated static let declineAction = "eveningWatch.decline"
    nonisolated static let actionIDUserInfoKey = "EveningWatchActionID"

    @Published private(set) var settings: EveningWatchSettings
    @Published private(set) var state: EveningWatchState
    /// A suggestion to open the bolus screen for, set from a notification before the home screen
    /// may be there to take it.
    @Published var pendingReviewID: String?

    struct Environment {
        /// What the loop knows now; nil while it cannot tell.
        var input: (Date) async -> EveningWatch.Input?
        /// Gives a bolus through the pump.
        var deliver: (Double) async throws -> Void
    }

    nonisolated static func requestReview(_ actionID: String) {
        Task { @MainActor in shared.pendingReviewID = actionID }
    }

    private let log = OSLog(category: "EveningWatchManager")
    private let defaults: UserDefaults
    private var environment: Environment?
    private var observer: NSObjectProtocol?
    private var isChecking = false
    private var lastLogUpload: Date?
    /// The card as the home screen last read it, and a timer for when the window closes.
    private var publishedCard: EveningWatchCardContent?
    private var cardTimer: Timer?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.eveningWatchSettings
        state = defaults.eveningWatchState
        publishedCard = EveningWatchCardContent(settings: settings, state: state, now: Date())
    }

    func start(_ environment: Environment) {
        self.environment = environment
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .LoopCompleted, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        refreshCard()
    }

    /// The card depends on the time as well as on the state: when the window closes with nothing
    /// open it must go, though nothing has changed. Tells the home screen when it is different.
    func refreshCard(now: Date = Date()) {
        let card = EveningWatchCardContent(settings: settings, state: state, now: now)
        if card != publishedCard {
            publishedCard = card
            objectWillChange.send()
        }
        cardTimer?.invalidate()
        cardTimer = nil
        guard let card, !card.isSuggestion, card.windowEnd > now else { return }
        let timer = Timer(fire: card.windowEnd.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshCard() }
        }
        RunLoop.main.add(timer, forMode: .common)
        cardTimer = timer
    }

    /// The card on the home screen: an open suggestion, or what the watch has done tonight while
    /// it is on.
    var card: EveningWatchCardContent? {
        EveningWatchCardContent(settings: settings, state: state, now: Date())
    }

    func action(withID id: String) -> EveningWatchAction? {
        state.actions.first { $0.id == id }
    }

    // MARK: Changes

    func update(_ settings: EveningWatchSettings) {
        let settings = settings.clamped
        guard settings != self.settings else { return }
        self.settings = settings
        defaults.eveningWatchSettings = settings
        Task { await check() }
    }

    /// Back to the dose it started with.
    func forgetLearnedDose() {
        var state = self.state
        state.learnedUnits = nil
        save(state)
    }

    func decline(_ actionID: String) {
        guard markDeclined(actionID) else { return }
        Task { await syncNightscout(now: Date()) }
    }

    @discardableResult
    private func markDeclined(_ actionID: String) -> Bool {
        var state = self.state
        guard let index = state.actions.firstIndex(where: { $0.id == actionID && $0.state == .open }) else { return false }
        state.actions[index].state = .declined
        state.actions[index].closedAt = Date()
        save(state)
        removeNotification(actionID)
        return true
    }

    // MARK: Checking

    func check(now: Date = Date()) async {
        defer { refreshCard() }
        guard !isChecking, let environment, needsCheck(now: now) else { return }
        isChecking = true
        defer { isChecking = false }

        guard let input = await environment.input(now) else { return }
        let before = state
        let (state, effect) = EveningWatch.tick(before, input: input, settings: settings, now: now)
        save(state)

        switch effect {
        case .none:
            break
        case .suggest(let action):
            notifySuggestion(action)
        case .dose(let action):
            await deliver(action, with: environment)
        case .stop:
            stopAutomatic()
        }
        for action in state.actions where action.state != .open && before.actions.contains(where: { $0.id == action.id && $0.state == .open }) {
            removeNotification(action.id)
        }
        await syncNightscout(now: now)
    }

    /// Off, with nothing open, nothing given in the last hours to learn from and no suggestion left
    /// in Nightscout: nothing to do.
    private func needsCheck(now: Date) -> Bool {
        guard settings.mode == .off else { return true }
        return state.actions.contains { action in
            action.state == .open || action.state == .delivering
                || (action.state == .given && action.outcome == nil && now.timeIntervalSince(action.date) < EveningWatch.Rule.outcomeAfter + 3600)
        } || !defaults.eveningWatchUploads.suggestions.isEmpty
    }

    private func deliver(_ action: EveningWatchAction, with environment: Environment) async {
        log.default("Evening watch gives %{public}@ U", String(action.units))
        do {
            try await environment.deliver(action.units)
            change(action.id) {
                $0.state = .given
                $0.givenUnits = action.units
                $0.closedAt = Date()
            }
            notifyDose(action)
        } catch {
            log.error("Evening watch dose failed: %{public}@", String(describing: error))
            change(action.id) {
                $0.state = .failed
                $0.closedAt = Date()
            }
        }
    }

    /// After a low following an automatic dose: back to suggesting until turned on again.
    private func stopAutomatic() {
        var settings = self.settings
        settings.mode = .suggest
        self.settings = settings
        defaults.eveningWatchSettings = settings
        guard let stop = state.stop else { return }
        let content = UNMutableNotificationContent()
        content.title = EveningWatchText.stoppedTitle
        content.body = EveningWatchText.stopped(stop, actions: state.actions)
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notificationPrefix + "stop", content: content, trigger: nil))
    }

    // MARK: Notifying

    /// Without sound: the phone is by the child at night. LoopFollow's alarm is what wakes a parent.
    private func notifySuggestion(_ action: EveningWatchAction) {
        let content = UNMutableNotificationContent()
        content.title = EveningWatchText.suggestionTitle(action)
        content.body = EveningWatchText.reason(action)
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = [Self.actionIDUserInfoKey: action.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notificationPrefix + action.id, content: content, trigger: nil))
    }

    /// Quiet: it is the middle of the night where the phone is.
    private func notifyDose(_ action: EveningWatchAction) {
        let content = UNMutableNotificationContent()
        content.title = EveningWatchText.doseTitle(action)
        content.body = EveningWatchText.reason(action)
        content.interruptionLevel = .passive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notificationPrefix + action.id, content: content, trigger: nil))
    }

    private func removeNotification(_ actionID: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationPrefix + actionID])
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

    // MARK: Nightscout

    /// Open suggestions as treatments LoopFollow shows (one deleted there counts as declined), a
    /// note for each automatic dose, and tonight's log.
    private func syncNightscout(now: Date) async {
        guard let api = SuggestionNightscoutAPI.fromKeychain() else { return }
        var uploads = defaults.eveningWatchUploads
        do {
            for (id, nsID) in uploads.suggestions {
                guard let action = action(withID: id), action.state == .open else {
                    try await api.delete(nsID)
                    uploads.suggestions[id] = nil
                    continue
                }
                guard now.timeIntervalSince(action.date) > 60 else { continue }
                let exists = try await api.exists(nsID)
                if !exists {
                    log.default("Evening watch suggestion %{public}@ declined in LoopFollow", id)
                    uploads.suggestions[id] = nil
                    markDeclined(id)
                }
            }
            for action in state.actions where action.state == .open && uploads.suggestions[action.id] == nil {
                if let nsID = try await api.create(EveningWatchTreatment.suggestion(action)) {
                    uploads.suggestions[action.id] = nsID
                }
            }
            for action in state.actions where action.kind == .automatic && (action.state == .given || action.state == .failed) && !uploads.notes.contains(action.id) {
                _ = try await api.create(EveningWatchTreatment.note(action))
                uploads.notes.insert(action.id)
            }
            uploads.notes.formIntersection(state.actions.map(\.id))

            let start = EveningWatch.windowStart(before: now, settings: settings, calendar: .current)
            let document = EveningWatchTreatment.log(state: state, settings: settings, since: start)
            let changed = uploads.logHash != document.hash
            let actionChanged = uploads.logActions != document.actions
            if settings.mode != .off, changed, actionChanged || now.timeIntervalSince(lastLogUpload ?? .distantPast) >= 15 * 60 {
                if let nsID = uploads.logID {
                    try await api.delete(nsID)
                    uploads.logID = nil
                }
                uploads.logID = try await api.create(document.body)
                uploads.logHash = document.hash
                uploads.logActions = document.actions
                lastLogUpload = now
            }
        } catch {
            log.error("Evening watch Nightscout sync failed: %{public}@", String(describing: error))
        }
        defaults.eveningWatchUploads = uploads
    }

    // MARK: Storage

    private func change(_ actionID: String, _ update: (inout EveningWatchAction) -> Void) {
        var state = self.state
        guard let index = state.actions.firstIndex(where: { $0.id == actionID }) else { return }
        update(&state.actions[index])
        save(state)
    }

    private func save(_ state: EveningWatchState) {
        guard state != self.state else { return }
        self.state = state
        defaults.eveningWatchState = state
        publishedCard = card
    }
}

/// What the home screen card shows.
struct EveningWatchCardContent: Equatable {
    var open: EveningWatchAction?
    /// Tonight's suggestions given and automatic doses, oldest first.
    var tonight: [EveningWatchAction]
    var mode: EveningWatchSettings.Mode
    var windowEnd: Date
    var stop: EveningWatchState.Stop?

    /// Nil when there is nothing to show: no open suggestion, and outside the window or off.
    init?(settings: EveningWatchSettings, state: EveningWatchState, now: Date, calendar: Calendar = .current) {
        open = state.open
        let inWindow = settings.mode != .off && EveningWatch.isInWindow(now, settings: settings, calendar: calendar)
        guard open != nil || inWindow else { return nil }
        let start = EveningWatch.windowStart(before: now, settings: settings, calendar: calendar)
        tonight = state.actions.filter { $0.date >= start && ($0.state == .given || $0.state == .delivering || $0.state == .failed) }
        mode = settings.mode
        windowEnd = EveningWatch.windowEnd(after: now, settings: settings, calendar: calendar)
        stop = settings.mode == .automatic ? nil : state.stop.flatMap { $0.date >= start ? $0 : nil }
    }

    var isSuggestion: Bool { open != nil }
}

// MARK: - Nightscout documents

/// The evening watch in Nightscout, for LoopFollow. Contract with LoopFollow
/// (`Remote/AISuggestion/AIBolusSuggestion.swift`, `Alarm/EveningWatch`); change both apps together.
///
/// - An open suggestion is an "AI Bolus Suggestion", with
///   `source: "eveningWatch"`, `trigger` ("rising"/"high") and `mealName` "🌙 …". Deleting it in
///   Nightscout declines it here.
/// - An automatic dose is a "Note" with `source: "eveningWatch"`, `actionID`, `units`, `glucose`
///   and `state` ("given"/"failed"). The bolus itself is uploaded like any other.
/// - Tonight's log is one "Evening Watch Log" treatment dated at the window's start, replaced as
///   it grows: `mode`, `learnedUnits`, `actions` and `entries`.
///
/// None has an `insulin` or `carbs` field, so none counts as either.
enum EveningWatchTreatment {
    static let logEventType = "Evening Watch Log"
    static let source = "eveningWatch"

    static func suggestion(_ action: EveningWatchAction) -> [String: Any] {
        [
            "eventType": BolusSuggestionTreatment.eventType,
            "source": source,
            "trigger": action.trigger.rawValue,
            "created_at": BolusSuggestionTreatment.iso8601(action.date),
            "timestamp": BolusSuggestionTreatment.iso8601(action.date),
            "expiresAt": BolusSuggestionTreatment.iso8601(action.date.addingTimeInterval(EveningWatch.Rule.lifetime)),
            "suggestionID": action.id,
            "units": action.units,
            "reason": EveningWatchText.reason(action),
            "glucose": action.glucose,
            "mealName": "🌙 " + EveningWatchText.name,
            "enteredBy": "Loop",
            "notes": EveningWatchText.suggestionTitle(action) + " " + EveningWatchText.reason(action),
        ]
    }

    static func note(_ action: EveningWatchAction) -> [String: Any] {
        [
            "eventType": "Note",
            "source": source,
            "actionID": action.id,
            "created_at": BolusSuggestionTreatment.iso8601(action.date),
            "timestamp": BolusSuggestionTreatment.iso8601(action.date),
            "units": action.givenUnits ?? action.units,
            "glucose": action.glucose,
            "state": action.state.rawValue,
            "enteredBy": "Loop",
            "notes": (action.state == .given ? EveningWatchText.doseTitle(action) : EveningWatchText.failedTitle(action)) + ": " + EveningWatchText.reason(action),
        ]
    }

    struct Log {
        var body: [String: Any]
        var hash: String
        /// The actions' ids and states, so a new or settled one is uploaded at once.
        var actions: [String]
    }

    static func log(state: EveningWatchState, settings: EveningWatchSettings, since start: Date) -> Log {
        let actions = state.actions.filter { $0.date >= start }
        // One entry per change of finding, so the log stays short.
        var entries: [EveningWatchDecision] = []
        for decision in state.decisions where decision.date >= start {
            if let last = entries.last, last.kind == decision.kind, decision.kind != .suggested, decision.kind != .dosed {
                continue
            }
            entries.append(decision)
        }
        let actionList: [[String: Any]] = actions.map { action in
            var item: [String: Any] = [
                "id": action.id,
                "kind": action.kind.rawValue,
                "trigger": action.trigger.rawValue,
                "date": BolusSuggestionTreatment.iso8601(action.date),
                "glucose": action.glucose,
                "units": action.units,
                "state": action.state.rawValue,
            ]
            if let given = action.givenUnits { item["givenUnits"] = given }
            if let iob = action.iob { item["iob"] = iob }
            if let change30 = action.change30 { item["change30"] = change30 }
            return item
        }
        let entryList: [[String: Any]] = entries.suffix(60).map { entry in
            var item: [String: Any] = ["date": BolusSuggestionTreatment.iso8601(entry.date), "kind": entry.kind.rawValue]
            if let glucose = entry.glucose { item["glucose"] = glucose }
            if let until = entry.until { item["until"] = BolusSuggestionTreatment.iso8601(until) }
            if let value = entry.value { item["value"] = value }
            return item
        }
        var body: [String: Any] = [
            "eventType": logEventType,
            "source": source,
            "created_at": BolusSuggestionTreatment.iso8601(start),
            "timestamp": BolusSuggestionTreatment.iso8601(start),
            "enteredBy": "Loop",
            "mode": settings.mode.rawValue,
            "actions": actionList,
            "entries": entryList,
        ]
        if let learned = state.learnedUnits { body["learnedUnits"] = learned }
        if let stop = state.stop, stop.date >= start {
            body["stop"] = ["date": BolusSuggestionTreatment.iso8601(stop.date), "lowest": stop.lowest]
        }
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Log(body: body, hash: hash, actions: actions.map { "\($0.id):\($0.state.rawValue)" })
    }
}

// MARK: - Words

enum EveningWatchText {
    static var name: String {
        NSLocalizedString("Evening Watch", comment: "Name of the evening watch")
    }

    static func units(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    static func glucose(_ mmol: Double) -> String {
        mmol.formatted(.number.precision(.fractionLength(1)))
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "🌙 Kveldsvakt: 0,35 E?"
    static func suggestionTitle(_ action: EveningWatchAction) -> String {
        String(format: NSLocalizedString("🌙 Evening watch: %@ U?", comment: "Evening watch suggestion title (1: units)"), units(action.units))
    }

    /// "🌙 Kveldsvakten ga 0,35 E"
    static func doseTitle(_ action: EveningWatchAction) -> String {
        String(format: NSLocalizedString("🌙 Evening watch gave %@ U", comment: "Evening watch automatic dose title (1: units)"), units(action.givenUnits ?? action.units))
    }

    static func failedTitle(_ action: EveningWatchAction) -> String {
        String(format: NSLocalizedString("🌙 Evening watch could not give %@ U", comment: "Evening watch automatic dose that the pump did not take (1: units)"), units(action.units))
    }

    static var stoppedTitle: String {
        NSLocalizedString("🌙 Evening watch stopped dosing", comment: "Notification title when the evening watch turns automatic mode off after a low")
    }

    static func stopped(_ stop: EveningWatchState.Stop, actions: [EveningWatchAction]) -> String {
        let dose = actions.first { $0.id == stop.actionID }
        return String(
            format: NSLocalizedString("Glucose went to %1$@ after the dose at %2$@. It suggests instead until automatic is turned on again in Settings.", comment: "Why the evening watch turned automatic mode off (1: lowest glucose)(2: time of the dose)"),
            glucose(stop.lowest), dose.map { time($0.date) } ?? "–"
        )
    }

    /// "10,8 og stiger 0,9 siste halvtime. 0,4 E om bord."
    static func reason(_ action: EveningWatchAction) -> String {
        var text: String
        switch action.trigger {
        case .rising:
            text = String(format: NSLocalizedString("%1$@ and up %2$@ over the last half hour.", comment: "Evening watch: why, glucose rising (1: glucose)(2: rise over 30 minutes)"), glucose(action.glucose), glucose(action.change30 ?? 0))
        case .high:
            text = String(format: NSLocalizedString("%@ and not falling for half an hour.", comment: "Evening watch: why, glucose high (1: glucose)"), glucose(action.glucose))
        }
        if let iob = action.iob {
            text += " " + String(format: NSLocalizedString("%@ U on board.", comment: "Evening watch: insulin on board (1: units)"), units(iob))
        }
        return text
    }

    static func decision(_ decision: EveningWatchDecision) -> String {
        let until = decision.until.map(time) ?? ""
        switch decision.kind {
        case .noFreshGlucose:
            return NSLocalizedString("No recent glucose", comment: "Evening watch log")
        case .missingReadings:
            return NSLocalizedString("Readings missing in the last half hour", comment: "Evening watch log")
        case .jump:
            return NSLocalizedString("Sensor jump", comment: "Evening watch log: two readings too far apart")
        case .belowLimit:
            return NSLocalizedString("Under the limit", comment: "Evening watch log")
        case .notRising:
            return NSLocalizedString("Not rising enough", comment: "Evening watch log")
        case .falling:
            return NSLocalizedString("Falling", comment: "Evening watch log")
        case .recentLow:
            return String(format: NSLocalizedString("Was under %@ in the last 90 min", comment: "Evening watch log (1: glucose)"), glucose(EveningWatch.Rule.lowFloor))
        case .recentCarbs:
            return String(format: NSLocalizedString("Meal, waits until %@", comment: "Evening watch log (1: time)"), until)
        case .recentBolus:
            return String(format: NSLocalizedString("Dose given, waits until %@", comment: "Evening watch log (1: time)"), until)
        case .recentAction:
            return String(format: NSLocalizedString("Waits until %@ after the last one", comment: "Evening watch log (1: time)"), until)
        case .enoughTonight:
            return NSLocalizedString("Enough for tonight", comment: "Evening watch log")
        case .noInsulinOnBoard:
            return NSLocalizedString("Insulin on board unknown", comment: "Evening watch log")
        case .highIOB:
            return String(format: NSLocalizedString("%@ U on board", comment: "Evening watch log (1: insulin on board)"), units(decision.value ?? 0))
        case .forecastLow:
            return String(format: NSLocalizedString("Loop forecasts %@", comment: "Evening watch log (1: lowest forecast glucose)"), glucose(decision.value ?? 0))
        case .reducedInsulin:
            return NSLocalizedString("Override with less insulin on", comment: "Evening watch log")
        case .cannotDose:
            return NSLocalizedString("Closed loop off or pump busy", comment: "Evening watch log")
        case .tooSmall:
            return NSLocalizedString("Dose under 0.1 U", comment: "Evening watch log")
        case .suggested:
            return String(format: NSLocalizedString("Suggested %@ U", comment: "Evening watch log (1: units)"), units(decision.value ?? 0))
        case .dosed:
            return String(format: NSLocalizedString("Gave %@ U", comment: "Evening watch log (1: units)"), units(decision.value ?? 0))
        case .open:
            return NSLocalizedString("Suggestion waiting", comment: "Evening watch log")
        case .lapsed:
            return NSLocalizedString("Suggestion no longer needed", comment: "Evening watch log")
        case .stopped:
            return String(format: NSLocalizedString("Automatic turned off after %@", comment: "Evening watch log (1: lowest glucose)"), glucose(decision.value ?? 0))
        }
    }

    static func state(_ action: EveningWatchAction) -> String {
        switch action.state {
        case .open:
            return NSLocalizedString("Waiting", comment: "State of an evening watch suggestion")
        case .delivering:
            return NSLocalizedString("Giving", comment: "State of an evening watch automatic dose being delivered")
        case .given:
            return String(format: NSLocalizedString("Given %@ U", comment: "State of an evening watch dose (1: units)"), units(action.givenUnits ?? action.units))
        case .declined:
            return NSLocalizedString("Declined", comment: "State of an evening watch suggestion")
        case .lapsed:
            return NSLocalizedString("No longer needed", comment: "State of an evening watch suggestion")
        case .failed:
            return NSLocalizedString("Not delivered", comment: "State of an evening watch automatic dose")
        }
    }
}

extension UserDefaults {
    private enum EveningWatchKey: String {
        case settings = "com.loopkit.Loop.eveningWatchSettings"
        case state = "com.loopkit.Loop.eveningWatchState"
        case uploads = "com.loopkit.Loop.eveningWatchUploads"
    }

    var eveningWatchSettings: EveningWatchSettings {
        get { data(forKey: EveningWatchKey.settings.rawValue).flatMap { try? JSONDecoder().decode(EveningWatchSettings.self, from: $0) }?.clamped ?? EveningWatchSettings() }
        set { set(try? JSONEncoder().encode(newValue), forKey: EveningWatchKey.settings.rawValue) }
    }

    var eveningWatchState: EveningWatchState {
        get { data(forKey: EveningWatchKey.state.rawValue).flatMap { try? JSONDecoder().decode(EveningWatchState.self, from: $0) } ?? EveningWatchState() }
        set { set(try? JSONEncoder().encode(newValue), forKey: EveningWatchKey.state.rawValue) }
    }

    struct EveningWatchUploads: Codable, Equatable {
        /// Nightscout `_id` per open suggestion.
        var suggestions: [String: String] = [:]
        /// Automatic doses already noted.
        var notes: Set<String> = []
        var logID: String?
        var logHash: String?
        var logActions: [String] = []
    }

    var eveningWatchUploads: EveningWatchUploads {
        get { data(forKey: EveningWatchKey.uploads.rawValue).flatMap { try? JSONDecoder().decode(EveningWatchUploads.self, from: $0) } ?? EveningWatchUploads() }
        set { set(try? JSONEncoder().encode(newValue), forKey: EveningWatchKey.uploads.rawValue) }
    }
}
