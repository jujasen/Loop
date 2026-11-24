//
//  LowWatchManager.swift
//  Loop
//
//  Runs the low watch after every loop: puts a suggestion of fast carbs on the home screen, in a
//  notification and in Nightscout for LoopFollow, where it stays until carbs are entered, it is
//  declined here or in LoopFollow, or glucose comes back up.
//

import Foundation
import HealthKit
import LoopKit
import UserNotifications
import os.log

@MainActor
final class LowWatchManager: ObservableObject {
    static let shared = LowWatchManager()

    nonisolated static let notificationPrefix = "lowWatch."
    nonisolated static let notificationCategory = "lowWatchSuggestion"
    nonisolated static let enterAction = "lowWatch.enter"
    nonisolated static let declineAction = "lowWatch.decline"
    nonisolated static let actionIDUserInfoKey = "LowWatchActionID"

    @Published private(set) var settings: LowWatchSettings
    @Published private(set) var state: LowWatchState
    /// A suggestion to open the carb screen for, set from a notification before the home screen
    /// may be there to take it.
    @Published var pendingEntryID: String?

    private let log = OSLog(category: "LowWatchManager")
    private let defaults: UserDefaults
    private var input: ((Date) async -> LowWatch.Input?)?
    private var observer: NSObjectProtocol?
    private var isChecking = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.lowWatchSettings
        state = defaults.lowWatchState
    }

    nonisolated static func requestEntry(_ actionID: String) {
        Task { @MainActor in shared.pendingEntryID = actionID }
    }

    func start(input: @escaping (Date) async -> LowWatch.Input?) {
        self.input = input
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .LoopCompleted, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    /// The open suggestion, for the home screen card.
    var open: LowWatchAction? { state.open }

    func action(withID id: String) -> LowWatchAction? {
        state.actions.first { $0.id == id }
    }

    func update(_ settings: LowWatchSettings) {
        guard settings != self.settings else { return }
        self.settings = settings
        defaults.lowWatchSettings = settings
        Task { await check() }
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
        guard !isChecking, let input else { return }
        guard settings.isOn || state.open != nil || !defaults.lowWatchUploads.isEmpty else { return }
        isChecking = true
        defer { isChecking = false }

        guard let values = await input(now) else { return }
        let before = state
        let (state, effect) = LowWatch.tick(before, input: values, settings: settings, now: now)
        save(state)
        if case .suggest(let action) = effect {
            log.default("Low watch suggests %{public}@ g at %{public}@", String(action.grams), String(action.glucose))
            notify(action, now: now)
        }
        for action in state.actions where action.state != .open && before.actions.contains(where: { $0.id == action.id && $0.state == .open }) {
            removeNotification(action.id)
        }
        await syncNightscout(now: now)
    }

    // MARK: Notifying

    /// Time sensitive, with a sound by day: whoever is with the child has to act. Silent at night
    /// unless chosen, as the phone is by the child then.
    private func notify(_ action: LowWatchAction, now: Date) {
        let content = UNMutableNotificationContent()
        content.title = LowWatchText.title(action)
        content.body = LowWatchText.reason(action)
        content.interruptionLevel = .timeSensitive
        if settings.soundAtNight || !LowWatch.isNight(now) {
            content.sound = .default
        }
        content.categoryIdentifier = Self.notificationCategory
        content.userInfo = [Self.actionIDUserInfoKey: action.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notificationPrefix + action.id, content: content, trigger: nil))
    }

    private func removeNotification(_ actionID: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationPrefix + actionID])
    }

    nonisolated static var notificationCategoryDefinition: UNNotificationCategory {
        UNNotificationCategory(
            identifier: notificationCategory,
            actions: [
                UNNotificationAction(identifier: enterAction, title: NSLocalizedString("Enter Carbs", comment: "Low watch notification action opening the carb screen with the suggested grams"), options: .foreground),
                UNNotificationAction(identifier: declineAction, title: NSLocalizedString("Decline", comment: "Meal watch notification action declining the suggestion"), options: .destructive),
            ],
            intentIdentifiers: [],
            options: []
        )
    }

    // MARK: Nightscout

    /// The open suggestion as a treatment LoopFollow shows; deleted there, it counts as declined.
    private func syncNightscout(now: Date) async {
        guard let api = SuggestionNightscoutAPI.fromKeychain() else { return }
        var uploads = defaults.lowWatchUploads
        do {
            for (id, nsID) in uploads {
                guard let action = action(withID: id), action.state == .open else {
                    try await api.delete(nsID)
                    uploads[id] = nil
                    continue
                }
                guard now.timeIntervalSince(action.date) > 60 else { continue }
                if try await !api.exists(nsID) {
                    log.default("Low watch suggestion %{public}@ declined in LoopFollow", id)
                    uploads[id] = nil
                    markDeclined(id)
                }
            }
            for action in state.actions where action.state == .open && uploads[action.id] == nil {
                if let nsID = try await api.create(LowWatchTreatment.suggestion(action)) {
                    uploads[action.id] = nsID
                }
            }
        } catch {
            log.error("Low watch Nightscout sync failed: %{public}@", String(describing: error))
        }
        defaults.lowWatchUploads = uploads
    }

    private func save(_ state: LowWatchState) {
        guard state != self.state else { return }
        self.state = state
        defaults.lowWatchState = state
    }
}

// MARK: - Nightscout document

/// The low watch in Nightscout, for LoopFollow (`Alarm/LowWatch`); change both apps together.
/// An open suggestion is a "Low Watch Suggestion" treatment with `source: "lowWatch"`,
/// `suggestionID`, `grams`, `glucose`, `trigger` ("forecast"/"low"), `lowestForecast` and
/// `reason`. It has no `carbs` field, so it never counts as carbs. Deleting it in Nightscout
/// declines it here.
enum LowWatchTreatment {
    static let eventType = "Low Watch Suggestion"
    static let source = "lowWatch"

    static func suggestion(_ action: LowWatchAction) -> [String: Any] {
        var document: [String: Any] = [
            "eventType": eventType,
            "source": source,
            "trigger": action.trigger.rawValue,
            "created_at": BolusSuggestionTreatment.iso8601(action.date),
            "timestamp": BolusSuggestionTreatment.iso8601(action.date),
            "expiresAt": BolusSuggestionTreatment.iso8601(action.date.addingTimeInterval(LowWatch.Rule.lifetime)),
            "suggestionID": action.id,
            "grams": action.grams,
            "glucose": action.glucose,
            "reason": LowWatchText.reason(action),
            "enteredBy": "Loop",
            "notes": LowWatchText.title(action) + " " + LowWatchText.reason(action),
        ]
        if let forecast = action.lowestForecast { document["lowestForecast"] = forecast }
        return document
    }
}

// MARK: - Words

enum LowWatchText {
    static let symbol = "🍭"

    static var name: String {
        NSLocalizedString("Low Watch", comment: "Name of the low watch, which suggests fast carbs when a low is coming")
    }

    /// "🍭 Lavvakt: 4 g raske karbo?"
    static func title(_ action: LowWatchAction) -> String {
        String(format: NSLocalizedString("🍭 Low watch: %@ g fast carbs?", comment: "Low watch suggestion title (1: grams)"), grams(action.grams))
    }

    static func grams(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    /// "Hvorfor: 5,2 og Loop spår 3,6 innen 20 min." / "Hvorfor: 4,1 og faller 0,6 siste kvarter."
    static func reason(_ action: LowWatchAction) -> String {
        switch action.trigger {
        case .forecast:
            return String(format: NSLocalizedString("Why: %1$@ and Loop forecasts %2$@ within 20 minutes.", comment: "Low watch: why, Loop's forecast (1: glucose)(2: lowest forecast)"), EveningWatchText.glucose(action.glucose), EveningWatchText.glucose(action.lowestForecast ?? action.nadir))
        case .low:
            return String(format: NSLocalizedString("Why: %1$@ and down %2$@ over the last quarter of an hour.", comment: "Low watch: why, glucose low and falling (1: glucose)(2: fall over 15 minutes)"), EveningWatchText.glucose(action.glucose), EveningWatchText.glucose(abs(action.change15 ?? 0)))
        }
    }

    static func enter(_ action: LowWatchAction) -> String {
        String(format: NSLocalizedString("Enter %@ g", comment: "Low watch button opening the carb screen with the grams (1: grams)"), grams(action.grams))
    }

    static func state(_ action: LowWatchAction) -> String {
        switch action.state {
        case .open:
            return NSLocalizedString("Waiting", comment: "State of an evening watch suggestion")
        case .eaten:
            return String(format: NSLocalizedString("%@ g entered", comment: "State of a low watch suggestion answered with carbs (1: grams)"), grams(action.eatenGrams ?? action.grams))
        case .declined:
            return NSLocalizedString("Declined", comment: "State of an evening watch suggestion")
        case .lapsed:
            return NSLocalizedString("No longer needed", comment: "State of an evening watch suggestion")
        }
    }
}

extension UserDefaults {
    private enum LowWatchKey: String {
        case settings = "com.loopkit.Loop.lowWatchSettings"
        case state = "com.loopkit.Loop.lowWatchState"
        case uploads = "com.loopkit.Loop.lowWatchUploads"
    }

    var lowWatchSettings: LowWatchSettings {
        get { data(forKey: LowWatchKey.settings.rawValue).flatMap { try? JSONDecoder().decode(LowWatchSettings.self, from: $0) } ?? LowWatchSettings() }
        set { set(try? JSONEncoder().encode(newValue), forKey: LowWatchKey.settings.rawValue) }
    }

    var lowWatchState: LowWatchState {
        get { data(forKey: LowWatchKey.state.rawValue).flatMap { try? JSONDecoder().decode(LowWatchState.self, from: $0) } ?? LowWatchState() }
        set { set(try? JSONEncoder().encode(newValue), forKey: LowWatchKey.state.rawValue) }
    }

    /// Nightscout `_id` per open suggestion.
    var lowWatchUploads: [String: String] {
        get { dictionary(forKey: LowWatchKey.uploads.rawValue) as? [String: String] ?? [:] }
        set { set(newValue, forKey: LowWatchKey.uploads.rawValue) }
    }
}

extension NSUserActivity {
    /// The carb screen with the low watch's grams, eaten now, absorbed in half an hour (how
    /// Julia entered the carbs she gave for a low).
    static func forLowWatch(_ action: LowWatchAction, now: Date = Date()) -> NSUserActivity {
        let activity = NSUserActivity.forNewCarbEntry()
        activity.update(from: NewCarbEntry(
            quantity: HKQuantity(unit: .gram(), doubleValue: action.grams),
            startDate: now,
            foodType: LowWatchText.symbol,
            absorptionTime: .minutes(30)
        ))
        return activity
    }
}
