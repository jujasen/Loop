//
//  CarbFollowUpManager.swift
//  Loop
//
//  Adds a meal's late "second wave" of carbs by itself, a while after the meal.
//

import Foundation
import HealthKit
import LoopKit
import os.log

/// Later carbs: a small, slow carb entry added some time after a meal, to cover the rise that fat
/// and protein cause hours later (milk, porridge, pizza).
///
/// The later carbs are deliberately not logged together with the meal. Loop counts carbs with a
/// future start date the moment they are entered and doses for them straight away, which deepens
/// the dip that follows the meal. Kept back until they are due, they only add insulin once the dip
/// is over — and only if glucose is actually on its way up.
struct CarbFollowUpRule: Codable, Equatable {
    var carbGrams: Double
    var absorptionTime: TimeInterval
    /// Time from the start of the meal's carb entry to when the later carbs are first considered.
    var delay: TimeInterval

    static let standard = CarbFollowUpRule(carbGrams: 6, absorptionTime: .minutes(240), delay: .minutes(90))

    static let carbRange: ClosedRange<Double> = 1...30
    static let delayRange: ClosedRange<TimeInterval> = .minutes(30) ... .hours(4)
    static let absorptionRange: ClosedRange<TimeInterval> = .hours(2) ... .hours(8)
}

/// Who decided a meal's later carbs.
enum CarbFollowUpSource: String, Codable {
    /// The favorite food's own rule, set by hand.
    case favorite
    /// Suggested by the meal estimate, for the meal or for the favorite food.
    case ai
    /// Added by hand to this one meal.
    case manual
}

/// What was decided for one meal on this phone, kept by the meal's carb entry. It wins over the
/// favorite food's rule, so a meal can be given other amounts or none at all.
struct MealCarbFollowUp: Codable, Equatable {
    /// `nil` when the later carbs were turned down for this meal.
    var rule: CarbFollowUpRule?
    var source: CarbFollowUpSource
    var reason: String?
    var date: Date = Date()

    static func == (lhs: MealCarbFollowUp, rhs: MealCarbFollowUp) -> Bool {
        lhs.rule == rhs.rule && lhs.source == rhs.source && lhs.reason == rhs.reason
    }
}

/// What the meal estimate made of a favorite food, so each food is looked at once and again only
/// after it is edited.
struct FavoriteCarbFollowUpAssessment: Codable, Equatable {
    /// `FavoriteCarbFollowUpAssessment.contentKey(for:)` of the food as it was assessed.
    var contentKey: String
    /// The suggestion, or `nil` when no late rise is expected.
    var suggestion: CarbFollowUpRule?
    var reason: String?
    /// True once the rule on the food was changed or turned off by hand, which the next
    /// assessment then leaves alone.
    var userChanged: Bool = false

    static func contentKey(for food: StoredFavoriteFood) -> String {
        let portions = food.portions.map { "\($0.name)=\($0.carbsQuantity.doubleValue(for: .gram()))" }.joined(separator: ",")
        return [food.name, food.foodType, String(food.absorptionTime), portions].joined(separator: "|")
    }
}

/// Later carbs waiting for their meal's dip to end.
struct PlannedCarbFollowUp: Equatable {
    /// `syncIdentifier` of the meal's carb entry.
    var triggerID: String
    /// The favorite food the meal was logged as, if any.
    var favoriteID: String?
    /// The meal's name — the favorite's or the estimate's — or empty for a meal without one.
    var mealName: String
    var emoji: String
    var mealStart: Date
    var rule: CarbFollowUpRule
    var source: CarbFollowUpSource
    var reason: String?
    /// Earliest time the later carbs are added.
    var dueDate: Date
    /// Past this, later carbs still waiting are dropped instead.
    var expiryDate: Date

    /// The meal as a person would name it: its name, or its time when it has none.
    var mealDescription: String {
        mealName.isEmpty
            ? String(format: NSLocalizedString("the meal at %@", comment: "Stand-in for the name of a meal without one (1: time of the meal)"), DateFormatter.localizedString(from: mealStart, dateStyle: .none, timeStyle: .short))
            : mealName
    }

    /// `foodType` of the entry the later carbs add. Its name differs from the meal's, so the later
    /// carbs never count as the meal itself.
    var foodType: String? {
        CarbFoodLabel(emoji: emoji, name: String(format: NSLocalizedString("%@ (later carbs)", comment: "Name of the carb entry that later carbs add (1: name of the meal)"), mealDescription)).foodType
    }
}

/// What became of a meal's later carbs. Kept so the same meal is never followed up twice.
struct CarbFollowUpRecord: Codable, Equatable {
    enum Outcome: String, Codable {
        case added
        case dropped
        case cancelled
    }

    var favoriteID: String?
    var outcome: Outcome
    var date: Date
}

/// Where glucose stands against the two conditions, for the detail screen.
struct CarbFollowUpConditions: Equatable {
    var latestGlucose: HKQuantity?
    /// Change over roughly the last 15 minutes, `nil` without a reading to compare with.
    var recentChange: HKQuantity?
    var isHighEnough: Bool
    var isNotFalling: Bool
}

/// The rules the later carbs run on, apart from storage and timing, so they can be tested.
enum CarbFollowUpPlanner {
    /// The later carbs wait while glucose is below this.
    static let minimumGlucose = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 108) // 6.0 mmol/L

    /// How long after the meal later carbs not added yet are given up on. Never less than an hour
    /// past their due time.
    static let window = TimeInterval.hours(3)

    /// An expired plan stays this long, so that a loop gets to drop it (and say so) rather than it
    /// disappearing without a word.
    static let dropGrace = TimeInterval.hours(1)

    /// Glucose older than this says nothing about where it is heading now.
    static let maximumGlucoseAge = TimeInterval.minutes(15)

    /// The trend compares the latest reading with one roughly this long before it.
    static let trendSpan = TimeInterval.minutes(15)

    /// Suggestions are capped at this many grams, and at half of the meal's own carbs.
    static let maximumSuggestion = 15.0
    static let maximumSuggestionShareOfMeal = 0.5
    /// Below this, a suggestion is not worth the noise.
    static let minimumSuggestion = 3.0

    enum Decision: Equatable {
        case wait
        case add
        case drop
    }

    static func expiryDate(start: Date, rule: CarbFollowUpRule) -> Date {
        start.addingTimeInterval(max(window, rule.delay + .hours(1)))
    }

    /// How far back a meal can be and still have later carbs to add or drop.
    static func lookback(rules: [CarbFollowUpRule]) -> TimeInterval {
        (rules.map { max(window, $0.delay + .hours(1)) }.max() ?? window) + dropGrace
    }

    /// Turns the meal estimate's late-rise guess into a rule: rounded, kept within the steppers'
    /// ranges and capped, or `nil` when it is too small to matter.
    static func suggestion(grams: Double, delayMinutes: Double, absorptionHours: Double, mealCarbs: Double) -> CarbFollowUpRule? {
        guard grams.isFinite, delayMinutes.isFinite, absorptionHours.isFinite else { return nil }
        let capped = min(grams, maximumSuggestion, mealCarbs * maximumSuggestionShareOfMeal).rounded()
        guard capped >= minimumSuggestion else { return nil }

        let delay = (delayMinutes / 15).rounded() * 15 * 60
        let absorption = (absorptionHours * 2).rounded() / 2 * 3600
        return CarbFollowUpRule(
            carbGrams: capped,
            absorptionTime: min(max(absorption, CarbFollowUpRule.absorptionRange.lowerBound), CarbFollowUpRule.absorptionRange.upperBound),
            delay: min(max(delay, CarbFollowUpRule.delayRange.lowerBound), CarbFollowUpRule.delayRange.upperBound)
        )
    }

    /// The later carbs not yet added, dropped or cancelled.
    ///
    /// A meal has later carbs when this phone decided them for that meal, or else when it was
    /// logged as a favorite food with a rule — which covers meals logged by the caregiver app or
    /// the watch. Meals of the same favorite share one: the most recent, unless one of them was
    /// already followed up. Includes plans that have just expired, for `decide` to drop.
    static func planned(
        entries: [StoredCarbEntry],
        favorites: [StoredFavoriteFood],
        rules: [String: CarbFollowUpRule],
        assessments: [String: FavoriteCarbFollowUpAssessment] = [:],
        mealPlans: [String: MealCarbFollowUp] = [:],
        records: [String: CarbFollowUpRecord],
        now: Date
    ) -> [PlannedCarbFollowUp] {
        struct Candidate {
            var groupKey: String
            var followUp: PlannedCarbFollowUp
        }

        var candidates: [Candidate] = []
        var handledGroups = Set<String>()

        for entry in entries {
            guard let id = entry.syncIdentifier, entry.startDate <= now else { continue }
            let label = CarbFoodLabel(foodType: entry.foodType)
            let favorite = label.name.isEmpty ? nil : favorites.first {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(label.name) == .orderedSame
            }
            let groupKey = favorite?.id ?? id

            if records[id] != nil {
                handledGroups.insert(groupKey)
                continue
            }

            let rule: CarbFollowUpRule
            let source: CarbFollowUpSource
            let reason: String?
            if let plan = mealPlans[id] {
                guard let planned = plan.rule else { continue }
                (rule, source, reason) = (planned, plan.source, plan.reason)
            } else if let favorite, let favoriteRule = rules[favorite.id] {
                let assessment = assessments[favorite.id]
                let suggested = assessment?.userChanged == false && assessment?.suggestion == favoriteRule
                (rule, source, reason) = (favoriteRule, suggested ? .ai : .favorite, suggested ? assessment?.reason : nil)
            } else {
                continue
            }

            guard rule.carbGrams > 0,
                  now < expiryDate(start: entry.startDate, rule: rule) + dropGrace else { continue }

            candidates.append(Candidate(groupKey: groupKey, followUp: PlannedCarbFollowUp(
                triggerID: id,
                favoriteID: favorite?.id,
                mealName: favorite?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? label.name,
                emoji: label.emoji,
                mealStart: entry.startDate,
                rule: rule,
                source: source,
                reason: reason,
                dueDate: entry.startDate.addingTimeInterval(rule.delay),
                expiryDate: expiryDate(start: entry.startDate, rule: rule)
            )))
        }

        // A second glass of the same milk is still the same evening's second wave.
        var latestByGroup: [String: PlannedCarbFollowUp] = [:]
        for candidate in candidates where !handledGroups.contains(candidate.groupKey) {
            if let current = latestByGroup[candidate.groupKey], current.mealStart >= candidate.followUp.mealStart { continue }
            latestByGroup[candidate.groupKey] = candidate.followUp
        }

        return latestByGroup.values.sorted { $0.dueDate < $1.dueDate }
    }

    /// Where glucose stands against the conditions: at least 6 mmol/L, and no lower than about
    /// 15 minutes earlier.
    static func conditions(glucose: [GlucoseValue], now: Date) -> CarbFollowUpConditions {
        let samples = glucose.sorted { $0.startDate < $1.startDate }
        guard let latest = samples.last, now.timeIntervalSince(latest.startDate) <= maximumGlucoseAge else {
            return CarbFollowUpConditions(latestGlucose: nil, recentChange: nil, isHighEnough: false, isNotFalling: false)
        }

        let unit = HKUnit.milligramsPerDeciliter
        let latestValue = latest.quantity.doubleValue(for: unit)

        // The reading closest to `trendSpan` before the latest one, within five minutes either way.
        let target = latest.startDate.addingTimeInterval(-trendSpan)
        let earlier = samples
            .filter { abs($0.startDate.timeIntervalSince(target)) <= .minutes(5) }
            .min { abs($0.startDate.timeIntervalSince(target)) < abs($1.startDate.timeIntervalSince(target)) }
        let change = earlier.map { latestValue - $0.quantity.doubleValue(for: unit) }

        return CarbFollowUpConditions(
            latestGlucose: latest.quantity,
            recentChange: change.map { HKQuantity(unit: unit, doubleValue: $0) },
            isHighEnough: latestValue >= minimumGlucose.doubleValue(for: unit),
            isNotFalling: change.map { $0 >= 0 } ?? false
        )
    }

    /// Whether later carbs are added now: once due, when both conditions hold. Until then they
    /// wait, and past their expiry they are dropped.
    static func decide(_ followUp: PlannedCarbFollowUp, glucose: [GlucoseValue], now: Date) -> Decision {
        if now >= followUp.expiryDate {
            return .drop
        }
        guard now >= followUp.dueDate else {
            return .wait
        }
        let conditions = conditions(glucose: glucose, now: now)
        return conditions.isHighEnough && conditions.isNotFalling ? .add : .wait
    }

    /// Records and meal plans older than a day can no longer match a meal in the window.
    static func pruned<Value>(_ values: [String: Value], now: Date, date: (Value) -> Date) -> [String: Value] {
        values.filter { now.timeIntervalSince(date($0.value)) < .hours(24) }
    }

    static func pruned(_ records: [String: CarbFollowUpRecord], now: Date) -> [String: CarbFollowUpRecord] {
        pruned(records, now: now, date: \.date)
    }
}

extension Notification.Name {
    /// Posted on the main queue when the planned later carbs change.
    static let carbFollowUpsDidChange = Notification.Name("com.loopkit.Loop.carbFollowUpsDidChange")

    /// Posted when a favorite food's rule or a meal's plan is added, changed or removed.
    static let carbFollowUpRulesDidChange = Notification.Name("com.loopkit.Loop.carbFollowUpRulesDidChange")
}

/// Runs the later carbs: checked right before every loop, so later carbs that are added are dosed
/// for in the same loop, whether the meal was logged on this phone, by the caregiver app, or on
/// the watch.
final class CarbFollowUpManager {
    private let log = OSLog(category: "CarbFollowUpManager")

    typealias CarbEntriesFetcher = (_ start: Date, _ completion: @escaping (Swift.Result<[StoredCarbEntry], Error>) -> Void) -> Void
    typealias GlucoseFetcher = (_ start: Date, _ completion: @escaping (Swift.Result<[StoredGlucoseSample], Error>) -> Void) -> Void
    typealias CarbEntryAdder = (_ entry: NewCarbEntry, _ completion: @escaping (Swift.Result<StoredCarbEntry, Error>) -> Void) -> Void

    private let fetchCarbEntries: CarbEntriesFetcher
    private let fetchGlucose: GlucoseFetcher
    private let addCarbEntry: CarbEntryAdder
    private let defaults: UserDefaults
    private let now: () -> Date

    private let lock = UnfairLock()
    private var _planned: [PlannedCarbFollowUp] = []
    private var _glucose: [GlucoseValue] = []

    /// Later carbs still waiting, soonest first.
    var planned: [PlannedCarbFollowUp] {
        lock.withLock { _planned }
    }

    /// Where glucose stood against the conditions at the last check.
    var conditions: CarbFollowUpConditions {
        let glucose = lock.withLock { _glucose }
        return CarbFollowUpPlanner.conditions(glucose: glucose, now: now())
    }

    private var observers: [NSObjectProtocol] = []

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        fetchCarbEntries: @escaping CarbEntriesFetcher,
        fetchGlucose: @escaping GlucoseFetcher,
        addCarbEntry: @escaping CarbEntryAdder
    ) {
        self.defaults = defaults
        self.now = now
        self.fetchCarbEntries = fetchCarbEntries
        self.fetchGlucose = fetchGlucose
        self.addCarbEntry = addCarbEntry

        // A meal logged or deleted, or a rule changed, shows up as planned without waiting for a loop.
        for name in [CarbStore.carbEntriesDidChange, .carbFollowUpRulesDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.refresh()
            })
        }
        refresh()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Running

    /// Adds every plan that is due and drops the expired ones, then calls `completion`.
    func runDue(completion: @escaping () -> Void) {
        let now = self.now()
        fetchPlanned(now: now) { planned in
            guard !planned.isEmpty else {
                self.publish(planned)
                completion()
                return
            }

            self.fetchRecentGlucose(now: now) { glucose in
                let group = DispatchGroup()
                var stillPlanned: [PlannedCarbFollowUp] = []

                for followUp in planned {
                    switch CarbFollowUpPlanner.decide(followUp, glucose: glucose, now: now) {
                    case .wait:
                        stillPlanned.append(followUp)
                    case .drop:
                        self.log.default("Dropping later carbs for %{public}@: glucose never turned", followUp.mealDescription)
                        self.record(followUp, outcome: .dropped, date: now)
                        NotificationManager.sendCarbFollowUpDroppedNotification(name: followUp.mealDescription)
                    case .add:
                        group.enter()
                        self.add(followUp, at: now) { group.leave() }
                    }
                }

                group.notify(queue: .global()) {
                    self.publish(stillPlanned)
                    completion()
                }
            }
        }
    }

    /// Adds waiting later carbs straight away, whatever glucose is doing — the caregiver's call.
    func addNow(_ followUp: PlannedCarbFollowUp, completion: (() -> Void)? = nil) {
        add(followUp, at: now()) {
            self.publish(self.planned.filter { $0.triggerID != followUp.triggerID })
            completion?()
        }
    }

    /// Cancels waiting later carbs for good.
    func cancel(_ followUp: PlannedCarbFollowUp) {
        record(followUp, outcome: .cancelled, date: now())
        publish(planned.filter { $0.triggerID != followUp.triggerID })
    }

    /// Gives one meal other later carbs than its favorite food's, or none.
    func setPlan(_ plan: MealCarbFollowUp, forMeal triggerID: String) {
        defaults.setCarbFollowUpMealPlan(plan, forMeal: triggerID, now: now())
    }

    func refresh() {
        let now = self.now()
        fetchPlanned(now: now) { planned in
            guard !planned.isEmpty else {
                self.publish([])
                return
            }
            self.fetchRecentGlucose(now: now) { _ in
                // An expired plan is only waiting to be dropped, so it is no longer shown as planned.
                self.publish(planned.filter { now < $0.expiryDate })
            }
        }
    }

    private func add(_ followUp: PlannedCarbFollowUp, at date: Date, completion: @escaping () -> Void) {
        // Recorded before adding, so a crash in between can never add it twice.
        record(followUp, outcome: .added, date: date)
        let entry = NewCarbEntry(
            quantity: HKQuantity(unit: .gram(), doubleValue: followUp.rule.carbGrams),
            startDate: date,
            foodType: followUp.foodType,
            absorptionTime: followUp.rule.absorptionTime
        )
        addCarbEntry(entry) { result in
            switch result {
            case .success:
                self.log.default("Added %{public}@ g later carbs for %{public}@", String(describing: followUp.rule.carbGrams), followUp.mealDescription)
                NotificationManager.sendCarbFollowUpAddedNotification(name: followUp.mealDescription, grams: followUp.rule.carbGrams)
            case .failure(let error):
                self.log.error("Could not add later carbs for %{public}@: %{public}@", followUp.mealDescription, String(describing: error))
            }
            completion()
        }
    }

    private func fetchRecentGlucose(now: Date, completion: @escaping ([GlucoseValue]) -> Void) {
        fetchGlucose(now.addingTimeInterval(-.minutes(40))) { result in
            let glucose: [GlucoseValue]
            switch result {
            case .success(let samples):
                glucose = samples
            case .failure(let error):
                self.log.error("Could not read glucose for later carbs: %{public}@", String(describing: error))
                glucose = []
            }
            self.lock.withLock { self._glucose = glucose }
            completion(glucose)
        }
    }

    private func fetchPlanned(now: Date, completion: @escaping ([PlannedCarbFollowUp]) -> Void) {
        let rules = defaults.carbFollowUpRules
        let mealPlans = defaults.carbFollowUpMealPlans
        guard !rules.isEmpty || mealPlans.contains(where: { $0.value.rule != nil }) else {
            completion([])
            return
        }

        let lookback = CarbFollowUpPlanner.lookback(rules: Array(rules.values) + mealPlans.values.compactMap(\.rule))
        fetchCarbEntries(now.addingTimeInterval(-lookback)) { result in
            switch result {
            case .success(let entries):
                completion(CarbFollowUpPlanner.planned(
                    entries: entries,
                    favorites: self.defaults.favoriteFoods,
                    rules: rules,
                    assessments: self.defaults.carbFollowUpAssessments,
                    mealPlans: mealPlans,
                    records: self.defaults.carbFollowUpRecords,
                    now: now
                ))
            case .failure(let error):
                self.log.error("Could not read carb entries for later carbs: %{public}@", String(describing: error))
                completion(self.planned)
            }
        }
    }

    private func record(_ followUp: PlannedCarbFollowUp, outcome: CarbFollowUpRecord.Outcome, date: Date) {
        lock.withLock {
            var records = CarbFollowUpPlanner.pruned(defaults.carbFollowUpRecords, now: date)
            records[followUp.triggerID] = CarbFollowUpRecord(favoriteID: followUp.favoriteID, outcome: outcome, date: date)
            defaults.carbFollowUpRecords = records
        }
    }

    private func publish(_ planned: [PlannedCarbFollowUp]) {
        let changed: Bool = lock.withLock {
            defer { _planned = planned }
            return _planned != planned
        }
        if changed {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .carbFollowUpsDidChange, object: self)
            }
        }
    }
}

// MARK: - Storage

extension UserDefaults {
    private enum CarbFollowUpKey: String {
        case rules = "com.loopkit.Loop.carbFollowUpRules"
        case records = "com.loopkit.Loop.carbFollowUpRecords"
        case mealPlans = "com.loopkit.Loop.carbFollowUpMealPlans"
        case assessments = "com.loopkit.Loop.carbFollowUpAssessments"
    }

    /// Later-carb rules by favorite food `id`. Kept apart from the favorites themselves, so the
    /// favorites shared with the caregiver app through Nightscout are unchanged by them.
    var carbFollowUpRules: [String: CarbFollowUpRule] {
        get { decoded(forKey: CarbFollowUpKey.rules.rawValue) ?? [:] }
        set {
            set(try? JSONEncoder().encode(newValue), forKey: CarbFollowUpKey.rules.rawValue)
            NotificationCenter.default.post(name: .carbFollowUpRulesDidChange, object: nil)
        }
    }

    /// What the meal estimate made of each favorite food, by favorite food `id`.
    var carbFollowUpAssessments: [String: FavoriteCarbFollowUpAssessment] {
        get { decoded(forKey: CarbFollowUpKey.assessments.rawValue) ?? [:] }
        set { set(try? JSONEncoder().encode(newValue), forKey: CarbFollowUpKey.assessments.rawValue) }
    }

    /// Later carbs decided for one meal, by the meal's carb entry `syncIdentifier`.
    var carbFollowUpMealPlans: [String: MealCarbFollowUp] {
        get { decoded(forKey: CarbFollowUpKey.mealPlans.rawValue) ?? [:] }
        set {
            set(try? JSONEncoder().encode(newValue), forKey: CarbFollowUpKey.mealPlans.rawValue)
            NotificationCenter.default.post(name: .carbFollowUpRulesDidChange, object: nil)
        }
    }

    func setCarbFollowUpMealPlan(_ plan: MealCarbFollowUp?, forMeal triggerID: String, now: Date = Date()) {
        var plans = CarbFollowUpPlanner.pruned(carbFollowUpMealPlans, now: now, date: \.date)
        plans[triggerID] = plan
        carbFollowUpMealPlans = plans
    }

    /// What became of each meal's later carbs, by the meal's carb entry `syncIdentifier`.
    var carbFollowUpRecords: [String: CarbFollowUpRecord] {
        get { decoded(forKey: CarbFollowUpKey.records.rawValue) ?? [:] }
        set { set(try? JSONEncoder().encode(newValue), forKey: CarbFollowUpKey.records.rawValue) }
    }

    private func decoded<T: Decodable>(forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
