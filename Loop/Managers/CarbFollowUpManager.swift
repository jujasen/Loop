//
//  CarbFollowUpManager.swift
//  Loop
//
//  Adds a meal's late "second wave" of carbs by itself, a while after the meal.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore
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
    /// A favorite food's fixed amount, set by hand.
    case favorite
    /// Worked out from the fat and protein the meal estimate found.
    case ai
    /// Set by hand for this one meal.
    case manual
}

/// The fat and protein in an amount of food that has `carbGrams` of carbs.
///
/// Kept per amount of carbs, so a smaller or larger serving of the same food scales with it.
struct MealNutrition: Codable, Equatable {
    var fatGrams: Double
    var proteinGrams: Double
    /// The carbs of the amount the fat and protein were estimated for.
    var carbGrams: Double
    /// Whether the meal estimate expects this food to raise glucose again hours after it is eaten.
    /// Only a food judged so can give a meal later carbs; `nil` (not judged, or judged by a build
    /// that did not ask) counts as no.
    var delayedRise: Bool? = nil

    /// Fat-protein units: 100 kcal from fat and protein each.
    var fatProteinUnits: Double {
        (fatGrams * 9 + proteinGrams * 4) / 100
    }

    /// The same food at another amount of carbs. Held within a factor of four either way, so a
    /// mistyped amount cannot turn a glass of milk into a pot of cream.
    func scaled(toCarbs carbs: Double) -> MealNutrition {
        guard carbGrams > 0, carbs > 0 else { return self }
        let factor = min(max(carbs / carbGrams, 0.25), 4)
        return MealNutrition(fatGrams: fatGrams * factor, proteinGrams: proteinGrams * factor, carbGrams: carbs, delayedRise: delayedRise)
    }

    static func + (lhs: MealNutrition, rhs: MealNutrition) -> MealNutrition {
        MealNutrition(
            fatGrams: lhs.fatGrams + rhs.fatGrams,
            proteinGrams: lhs.proteinGrams + rhs.proteinGrams,
            carbGrams: lhs.carbGrams + rhs.carbGrams,
            delayedRise: lhs.delayedRise == true || rhs.delayedRise == true
        )
    }

    static let zero = MealNutrition(fatGrams: 0, proteinGrams: 0, carbGrams: 0, delayedRise: false)
}

/// What was decided for one meal on this phone, kept by the meal's carb entry. It wins over what
/// would otherwise be worked out, so a meal can be given other amounts or none at all.
struct MealCarbFollowUp: Codable, Equatable {
    /// `nil` when the later carbs were turned down for this meal.
    var rule: CarbFollowUpRule?
    var source: CarbFollowUpSource
    /// How the amount came about, shown under it.
    var reason: String?
    var date: Date = Date()

    static func == (lhs: MealCarbFollowUp, rhs: MealCarbFollowUp) -> Bool {
        lhs.rule == rhs.rule && lhs.source == rhs.source && lhs.reason == rhs.reason
    }
}

/// What the meal estimate found in a favorite food, so each food is looked at once and again only
/// after it is edited.
struct FavoriteCarbFollowUpAssessment: Codable, Equatable {
    /// `FavoriteCarbFollowUpAssessment.contentKey(for:)` of the food as it was assessed.
    var contentKey: String
    /// Fat and protein of the food's first serving size, or `nil` from an assessment made before
    /// later carbs were worked out from them.
    var nutrition: MealNutrition?
    /// The amount earlier builds suggested. Read only to retire rules they wrote.
    var suggestion: CarbFollowUpRule?
    var reason: String?
    /// True once the food's fixed amount was set or turned off by hand.
    var userChanged: Bool = false

    static func contentKey(for food: StoredFavoriteFood) -> String {
        let portions = food.portions.map { "\($0.name)=\($0.carbsQuantity.doubleValue(for: .gram()))" }.joined(separator: ",")
        return [food.name, food.foodType, String(food.absorptionTime), portions].joined(separator: "|")
    }
}

/// Later carbs waiting for their meal's dip to end.
struct PlannedCarbFollowUp: Equatable {
    /// `syncIdentifier` of the meal's last carb entry; the later carbs are timed from it.
    var triggerID: String
    /// The favorite food the last entry was logged as, if any.
    var favoriteID: String?
    /// The meal's name — its foods' names joined — or empty for a meal without any.
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
        CarbFoodLabel(emoji: emoji, name: Self.laterCarbName(for: mealDescription)).foodType
    }

    static func laterCarbName(for meal: String) -> String {
        String(format: NSLocalizedString("%@ (later carbs)", comment: "Name of the carb entry that later carbs add (1: name of the meal)"), meal)
    }

    /// True for the name of an entry that later carbs added.
    static func isLaterCarbName(_ name: String) -> Bool {
        let suffix = laterCarbName(for: "")
        return !name.isEmpty && name.hasSuffix(suffix.trimmingCharacters(in: .whitespaces))
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

    /// Entries this close to the one before belong to the same meal: porridge, then milk.
    static let mealGap = TimeInterval.minutes(60)

    /// Below one fat-protein unit there is no second wave worth covering, only slower absorption.
    static let minimumUnits = 1.0
    /// Carbs per fat-protein unit: half the usual 10 g, because the full amount overestimates
    /// for a small child.
    static let gramsPerUnit = 5.0
    static let maximumGrams = 15.0
    /// When the rise from fat and protein starts, after the last part of the meal.
    static let delay = TimeInterval.minutes(90)
    /// A part of a meal logged with an absorption time this short is fast carbs — a smoothie, juice,
    /// fruit — and never gives the meal later carbs, whatever the estimate made of it.
    static let fastAbsorption = TimeInterval.hours(2)

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
        let longest = rules.map { max(window, $0.delay + .hours(1)) }.max() ?? window
        return max(longest, delay + .hours(1), window) + dropGrace + mealGap * 2
    }

    // MARK: Working out the amount

    /// Later carbs for a meal of this much fat and protein, or `nil` below one unit or when no
    /// part of it is expected to rise late. More units last longer, the way the rise from a bigger
    /// meal does.
    static func rule(for nutrition: MealNutrition) -> CarbFollowUpRule? {
        guard nutrition.delayedRise == true else { return nil }
        let units = nutrition.fatProteinUnits
        guard units.isFinite, units >= minimumUnits else { return nil }
        let grams = min((units * gramsPerUnit).rounded(), maximumGrams)
        let absorption: TimeInterval = units < 2 ? .hours(4) : units < 3 ? .hours(5) : .hours(6)
        return CarbFollowUpRule(carbGrams: grams, absorptionTime: absorption, delay: delay)
    }

    /// "9 g fat + 11 g protein = 1.3 units → 7 g", or with a meal below the limit, why it gets none.
    static func explanation(for nutrition: MealNutrition, foods: [String] = []) -> String {
        let number: (Double) -> String = { NumberFormatter.localizedString(from: NSNumber(value: ($0 * 10).rounded() / 10), number: .decimal) }
        let whole: (Double) -> String = { NumberFormatter.localizedString(from: NSNumber(value: $0.rounded()), number: .decimal) }
        var text = String(format: NSLocalizedString("%1$@ g fat + %2$@ g protein = %3$@ fat-protein units", comment: "How later carbs are worked out (1: grams of fat)(2: grams of protein)(3: units)"), whole(nutrition.fatGrams), whole(nutrition.proteinGrams), number(nutrition.fatProteinUnits))
        if let rule = rule(for: nutrition) {
            text += String(format: NSLocalizedString(" → %@ g", comment: "Result of the later carbs calculation (1: grams), appended to it"), whole(rule.carbGrams))
        } else if nutrition.delayedRise != true {
            text += NSLocalizedString(", no late rise expected: no later carbs", comment: "Appended to the later carbs calculation when the meal estimate expects no late rise from the food (a smoothie, juice, fruit)")
        } else {
            text += NSLocalizedString(", below 1: no later carbs", comment: "Appended to the later carbs calculation when the meal is below the limit")
        }
        let names = foods.filter { !$0.isEmpty }
        if names.count > 1 {
            text = String(format: NSLocalizedString("%1$@ together: %2$@", comment: "Later carbs calculation for several foods eaten together (1: the foods)(2: the calculation)"), names.joined(separator: " + "), text)
        }
        return text
    }

    /// Fat and protein in one carb entry: what was found for this meal, or else what was found for
    /// the favorite food it was logged as, scaled to the entry's carbs. An entry logged as fast
    /// carbs keeps its fat and protein but can never be the part that rises late.
    static func nutrition(of entry: StoredCarbEntry, favorite: StoredFavoriteFood?, assessments: [String: FavoriteCarbFollowUpAssessment], mealNutrition: [String: MealNutrition]) -> MealNutrition? {
        let carbs = entry.quantity.doubleValue(for: .gram())
        var found: MealNutrition?
        if let id = entry.syncIdentifier, let nutrition = mealNutrition[id] {
            found = nutrition.scaled(toCarbs: carbs)
        } else if let favorite, let nutrition = assessments[favorite.id]?.nutrition {
            found = nutrition.scaled(toCarbs: carbs)
        }
        if isFast(entry) {
            found?.delayedRise = false
        }
        return found
    }

    /// True for an entry logged with fast carbs. Without an absorption time, Loop uses the medium one.
    static func isFast(_ entry: StoredCarbEntry) -> Bool {
        (entry.absorptionTime ?? LoopCoreConstants.defaultCarbAbsorptionTimes.medium) <= fastAbsorption
    }

    static func favorite(named name: String, in favorites: [StoredFavoriteFood]) -> StoredFavoriteFood? {
        guard !name.isEmpty else { return nil }
        return favorites.first { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame }
    }

    /// One meal's worth of carb entries: each no more than `mealGap` after the one before.
    static func meals(_ entries: [StoredCarbEntry]) -> [[StoredCarbEntry]] {
        var meals: [[StoredCarbEntry]] = []
        for entry in entries.sorted(by: { $0.startDate < $1.startDate }) {
            if let last = meals.last?.last, entry.startDate.timeIntervalSince(last.startDate) <= mealGap {
                meals[meals.count - 1].append(entry)
            } else {
                meals.append([entry])
            }
        }
        return meals
    }

    /// What one meal's later carbs are, before anything was added: the latest decision made for
    /// one of its entries on this phone, else a favorite's fixed amount, else the amount worked out
    /// from the fat and protein of all its entries together. That last one needs at least one part
    /// the meal estimate expects to rise late and that was not logged as fast carbs, so a smoothie
    /// or juice never gets later carbs on its own. `nil` when it gets none.
    static func followUp(
        forMeal meal: [StoredCarbEntry],
        favorites: [StoredFavoriteFood],
        rules: [String: CarbFollowUpRule],
        assessments: [String: FavoriteCarbFollowUpAssessment],
        mealPlans: [String: MealCarbFollowUp],
        mealNutrition: [String: MealNutrition]
    ) -> MealCarbFollowUp? {
        if let decided = meal.reversed().lazy.compactMap({ $0.syncIdentifier.flatMap { mealPlans[$0] } }).first {
            return decided.rule == nil ? nil : decided
        }

        let foods = meal.map { CarbFoodLabel(foodType: $0.foodType).name }
        let matched = foods.map { favorite(named: $0, in: favorites) }

        if let fixed = matched.compactMap({ $0.flatMap { rules[$0.id] } }).max(by: { $0.carbGrams < $1.carbGrams }) {
            return MealCarbFollowUp(rule: fixed, source: .favorite)
        }

        let total = zip(meal, matched).compactMap { nutrition(of: $0, favorite: $1, assessments: assessments, mealNutrition: mealNutrition) }.reduce(.zero, +)
        guard let rule = rule(for: total) else { return nil }
        return MealCarbFollowUp(rule: rule, source: .ai, reason: explanation(for: total, foods: unique(foods)))
    }

    /// The later carbs not yet added, dropped or cancelled, one per meal at most. Includes plans
    /// that have just expired, for `decide` to drop.
    static func planned(
        entries: [StoredCarbEntry],
        favorites: [StoredFavoriteFood],
        rules: [String: CarbFollowUpRule],
        assessments: [String: FavoriteCarbFollowUpAssessment] = [:],
        mealPlans: [String: MealCarbFollowUp] = [:],
        mealNutrition: [String: MealNutrition] = [:],
        records: [String: CarbFollowUpRecord],
        now: Date
    ) -> [PlannedCarbFollowUp] {
        // Later carbs already added are not part of any meal.
        let meals = meals(entries.filter { entry in
            entry.syncIdentifier != nil && entry.startDate <= now
                && !PlannedCarbFollowUp.isLaterCarbName(CarbFoodLabel(foodType: entry.foodType).name)
        })

        var planned: [PlannedCarbFollowUp] = []
        for meal in meals {
            // A meal is followed up once, even if more of it was logged afterwards.
            guard let last = meal.last, let triggerID = last.syncIdentifier,
                  !meal.contains(where: { records[$0.syncIdentifier!] != nil }),
                  let followUp = followUp(forMeal: meal, favorites: favorites, rules: rules, assessments: assessments, mealPlans: mealPlans, mealNutrition: mealNutrition),
                  let rule = followUp.rule, rule.carbGrams > 0,
                  now < expiryDate(start: last.startDate, rule: rule) + dropGrace
            else { continue }

            let labels = meal.map { CarbFoodLabel(foodType: $0.foodType) }
            let names = unique(labels.map { label in favorite(named: label.name, in: favorites)?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? label.name })
            planned.append(PlannedCarbFollowUp(
                triggerID: triggerID,
                favoriteID: favorite(named: CarbFoodLabel(foodType: last.foodType).name, in: favorites)?.id,
                mealName: names.joined(separator: " + "),
                emoji: labels.first(where: { !$0.emoji.isEmpty })?.emoji ?? "",
                mealStart: last.startDate,
                rule: rule,
                source: followUp.source,
                reason: followUp.reason,
                dueDate: last.startDate.addingTimeInterval(rule.delay),
                expiryDate: expiryDate(start: last.startDate, rule: rule)
            ))
        }

        return planned.sorted { $0.dueDate < $1.dueDate }
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
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

    /// Gives one meal other later carbs than worked out, or none.
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
                    mealNutrition: self.defaults.carbFollowUpMealNutrition,
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
        case mealNutrition = "com.loopkit.Loop.carbFollowUpMealNutrition"
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

    /// Fat and protein the meal estimate found in a meal, by the meal's carb entry `syncIdentifier`.
    var carbFollowUpMealNutrition: [String: MealNutrition] {
        get { decoded(forKey: CarbFollowUpKey.mealNutrition.rawValue) ?? [:] }
        set {
            set(try? JSONEncoder().encode(newValue), forKey: CarbFollowUpKey.mealNutrition.rawValue)
            NotificationCenter.default.post(name: .carbFollowUpRulesDidChange, object: nil)
        }
    }

    func setCarbFollowUpMealNutrition(_ nutrition: MealNutrition?, forMeal triggerID: String) {
        // Only meals still in the window matter, so an overgrown list can simply start over.
        var all = carbFollowUpMealNutrition
        if all.count > 200 { all = [:] }
        all[triggerID] = nutrition
        carbFollowUpMealNutrition = all
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
