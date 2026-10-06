//
//  FatProteinBoost.swift
//  Loop
//
//  Raises insulin needs for a while after a meal heavy in fat and protein, once glucose turns up.
//

import Foundation
import HealthKit
import LoopKit
import os.log

/// The fat and protein in an amount of food that has `carbGrams` of carbs.
///
/// Kept per amount of carbs, so a smaller or larger serving of the same food scales with it.
struct MealNutrition: Codable, Equatable {
    var fatGrams: Double
    var proteinGrams: Double
    /// The carbs of the amount the fat and protein were estimated for.
    var carbGrams: Double

    /// Fat-protein units: 100 kcal from fat and protein each.
    var fatProteinUnits: Double {
        (fatGrams * 9 + proteinGrams * 4) / 100
    }

    /// The same food at another amount of carbs. Held within a factor of four either way, so a
    /// mistyped amount cannot turn a glass of milk into a pot of cream.
    func scaled(toCarbs carbs: Double) -> MealNutrition {
        guard carbGrams > 0, carbs > 0 else { return self }
        let factor = min(max(carbs / carbGrams, 0.25), 4)
        return MealNutrition(fatGrams: fatGrams * factor, proteinGrams: proteinGrams * factor, carbGrams: carbs)
    }

    static func + (lhs: MealNutrition, rhs: MealNutrition) -> MealNutrition {
        MealNutrition(fatGrams: lhs.fatGrams + rhs.fatGrams, proteinGrams: lhs.proteinGrams + rhs.proteinGrams, carbGrams: lhs.carbGrams + rhs.carbGrams)
    }

    static let zero = MealNutrition(fatGrams: 0, proteinGrams: 0, carbGrams: 0)
}

/// What the meal estimate found in a favorite food, so each food is looked at once and again only
/// after it is edited.
struct FavoriteNutritionAssessment: Codable, Equatable {
    /// `FavoriteNutritionAssessment.contentKey(for:)` of the food as it was assessed.
    var contentKey: String
    /// Fat and protein of the food's first serving size.
    var nutrition: MealNutrition?
    /// True once the fat and protein were typed in by hand; the estimate never replaces them.
    var isUserSet: Bool? = nil

    static func contentKey(for food: StoredFavoriteFood) -> String {
        let portions = food.portions.map { "\($0.name)=\($0.carbsQuantity.doubleValue(for: .gram()))" }.joined(separator: ",")
        return [food.name, food.foodType, String(food.absorptionTime), portions].joined(separator: "|")
    }
}

/// How the boost behaves. Stored on the phone and changed from its settings screen.
struct FatProteinBoostSettings: Codable, Equatable {
    var isEnabled = true
    /// Meals below this many fat-protein units get no boost.
    var minimumUnits = 1.0
    /// Time from the last part of the meal to when the boost may first start.
    var delay: TimeInterval = .minutes(90)
    /// The boost starts only with glucose at or above this.
    var startGlucoseMgdl = 144.0 // 8.0 mmol/L
    /// A running boost ends once glucose is below this.
    var stopGlucoseMgdl = 126.0 // 7.0 mmol/L
    /// Extra insulin needs per fat-protein unit, before the learned factor: 0.15 is 15 %.
    var strengthPerUnit = 0.15
    /// The most the boost raises insulin needs to, whatever the meal and the learned factor.
    var maximumStrength = 1.5

    static let standard = FatProteinBoostSettings()

    init() {}

    /// Every field may be missing, so settings saved by an older build keep what they had.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = FatProteinBoostSettings()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? standard.isEnabled
        minimumUnits = try container.decodeIfPresent(Double.self, forKey: .minimumUnits) ?? standard.minimumUnits
        delay = try container.decodeIfPresent(TimeInterval.self, forKey: .delay) ?? standard.delay
        startGlucoseMgdl = try container.decodeIfPresent(Double.self, forKey: .startGlucoseMgdl) ?? standard.startGlucoseMgdl
        stopGlucoseMgdl = try container.decodeIfPresent(Double.self, forKey: .stopGlucoseMgdl) ?? standard.stopGlucoseMgdl
        strengthPerUnit = try container.decodeIfPresent(Double.self, forKey: .strengthPerUnit) ?? standard.strengthPerUnit
        maximumStrength = try container.decodeIfPresent(Double.self, forKey: .maximumStrength) ?? standard.maximumStrength
    }

    static let minimumStrength = 1.1
    /// The settings screen never lets the maximum past this.
    static let strengthLimit = 2.0
    static let startGlucoseRange: ClosedRange<Double> = 108...216 // 6–12 mmol/L
    static let stopGlucoseRange: ClosedRange<Double> = 99...162 // 5.5–9 mmol/L
    static let strengthPerUnitRange: ClosedRange<Double> = 0.05...0.4
    static let maximumStrengthRange: ClosedRange<Double> = 1.1...strengthLimit
    static let delayRange: ClosedRange<TimeInterval> = .minutes(30) ... .hours(4)
    static let minimumUnitsRange: ClosedRange<Double> = 0.5...3
}

/// What the boost has learned from the nights after it, as one factor on its strength.
struct FatProteinBoostCalibration: Codable, Equatable {
    /// Multiplies `strengthPerUnit`. Starts at 1, rises after nights that stayed high, falls
    /// after nights that went low.
    var factor = 1.0
    /// The latest outcomes, newest first.
    var outcomes: [FatProteinBoostOutcome] = []

    static let factorRange: ClosedRange<Double> = 0.5...2.0
    static let keptOutcomes = 20
}

/// How one boost went, and what it did to the learned factor.
struct FatProteinBoostOutcome: Codable, Equatable {
    enum Verdict: String, Codable {
        /// Glucose went below 4 mmol/L: much less next time.
        case low
        /// Glucose went below 4.5 mmol/L: a little less next time.
        case lowish
        /// Still at 13 mmol/L or more an hour into the boost: much more next time.
        case high
        /// Still at 11 mmol/L or more an hour into the boost: a little more next time.
        case highish
        /// Neither: the same next time.
        case good
    }

    var mealName: String
    var start: Date
    var end: Date
    var units: Double
    var strength: Double
    var peakMgdl: Double
    var lowestMgdl: Double
    var verdict: Verdict
    var factorBefore: Double
    var factorAfter: Double
}

/// A boost waiting for its meal's rise.
struct FatProteinBoostPlan: Equatable {
    /// `syncIdentifier` of the meal's last carb entry; the boost is timed from it.
    var triggerID: String
    /// The meal's name — its foods' names joined — or empty for a meal without any.
    var mealName: String
    /// When the meal's last part was eaten.
    var mealEnd: Date
    var nutrition: MealNutrition
    /// Insulin needs while the boost runs: 1.3 is 130 %.
    var strength: Double
    var duration: TimeInterval
    /// "8 g fat + 11 g protein = 1.2 fat-protein units → 130 % for 3 hr"
    var explanation: String
    /// Earliest time the boost starts.
    var earliestStart: Date
    /// Past this, a boost that never started is skipped.
    var latestStart: Date

    var units: Double { nutrition.fatProteinUnits }

    /// The meal as a person would name it: its name, or its time when it has none.
    var mealDescription: String {
        FatProteinBoostPlanner.mealDescription(name: mealName, date: mealEnd)
    }
}

/// What became of a meal's boost. Kept so the same meal is never boosted twice, and so a running
/// boost can be told apart from an override someone else started.
struct FatProteinBoostRecord: Codable, Equatable {
    enum State: String, Codable {
        /// Its override is running.
        case active
        /// Glucose never turned up in time, so it never started.
        case skipped
        /// It ran to its end, or was ended early because glucose came down.
        case ended
        /// It was taken over by a later meal's boost, which carries on from it.
        case merged
        /// Someone ended it or started another override.
        case cancelled
        /// Turned off for this meal on the carb entry screen.
        case declined
    }

    var state: State
    var mealName: String
    var units: Double
    var strength: Double
    var overrideID: UUID?
    var start: Date?
    /// When the boost was set to end.
    var plannedEnd: Date?
    /// When it actually ended.
    var end: Date?
    /// True once its outcome was learned from, or when there is none to learn from.
    var isEvaluated = false
    var date: Date
}

/// What the boost would do for a meal being logged, for the carb entry screen.
struct FatProteinBoostPreview: Equatable {
    /// Fat and protein of the whole meal, earlier parts included.
    var mealTotal: MealNutrition
    /// Fat and protein of the entry being logged, `nil` when nothing is known about it.
    var entry: MealNutrition?
    /// Where the entry's fat and protein came from.
    var source: Source
    /// `nil` below the limit.
    var strength: Double?
    var duration: TimeInterval?
    var earliestStart: Date
    var explanation: String

    enum Source: Equatable {
        /// Typed in, or found by the meal estimate, for this meal.
        case meal
        /// The favorite food it was logged as.
        case favorite
        /// Not known.
        case none
    }

    var units: Double { mealTotal.fatProteinUnits }
}

/// Where glucose stands against the start conditions, for the screens.
struct FatProteinBoostConditions: Equatable {
    var latestGlucose: HKQuantity?
    /// Change over roughly the last 15 minutes, `nil` without a reading to compare with.
    var recentChange: HKQuantity?
    var isHighEnough: Bool
    var isNotFalling: Bool
}

/// The rules the boost runs on, apart from storage and timing, so they can be tested.
enum FatProteinBoostPlanner {
    /// Entries this close to the one before belong to the same meal: porridge, then milk.
    static let mealGap = TimeInterval.minutes(60)
    /// How long after its earliest start a boost may still start.
    static let startWindow = TimeInterval.hours(3)
    /// A boost never runs past this long after the meal.
    static let longestReach = TimeInterval.hours(7)
    /// Glucose older than this says nothing about where it is heading now.
    static let maximumGlucoseAge = TimeInterval.minutes(15)
    /// The trend compares the latest reading with one roughly this long before it.
    static let trendSpan = TimeInterval.minutes(15)
    /// Readings this little lower than 15 minutes earlier still count as level, not falling.
    static let levelTolerance = 5.0 // mg/dL
    /// Carbs logged with glucose below this treat a low, and their fat is not boosted: a smoothie
    /// after a low is not part of dinner.
    static let rescueGlucoseMgdl = 90.0 // 5.0 mmol/L
    /// The outcome is read until this long after the boost ended.
    static let outcomeTail = TimeInterval.hours(2)
    /// Peak glucose is read from this long into the boost, once the extra insulin had time to act.
    static let outcomeLead = TimeInterval.hours(1)

    enum Decision: Equatable {
        case wait
        case start
        case skip
    }

    enum ActiveDecision: Equatable {
        /// Leave it running.
        case keep
        /// Glucose came down: end it now.
        case endNow
        /// It already finished by itself.
        case finished
        /// Its override is gone or was replaced by someone else's.
        case cancelled
    }

    // MARK: Working out the boost

    /// How much a meal of this many units raises insulin needs, rounded to 5 %.
    static func strength(units: Double, settings: FatProteinBoostSettings, factor: Double) -> Double {
        let raw = 1 + settings.strengthPerUnit * units * factor
        let capped = min(max(raw, FatProteinBoostSettings.minimumStrength), min(settings.maximumStrength, FatProteinBoostSettings.strengthLimit))
        return (capped * 20).rounded() / 20
    }

    /// Bigger meals keep raising glucose for longer.
    static func duration(units: Double) -> TimeInterval {
        units < 2 ? .hours(3) : units < 3 ? .hours(4) : .hours(5)
    }

    static func percent(_ strength: Double) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: (strength * 100).rounded()), number: .decimal) + " %"
    }

    static func hours(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .short
        return formatter.string(from: interval) ?? ""
    }

    static func time(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }

    static func mealDescription(name: String, date: Date) -> String {
        name.isEmpty
            ? String(format: NSLocalizedString("the meal at %@", comment: "Stand-in for the name of a meal without one (1: time of the meal)"), time(date))
            : name
    }

    /// "8 g fat + 11 g protein = 1.2 fat-protein units → 130 % for 3 hr", or with a meal below the
    /// limit, why it gets none.
    static func explanation(for nutrition: MealNutrition, foods: [String] = [], settings: FatProteinBoostSettings, factor: Double) -> String {
        let number: (Double) -> String = { NumberFormatter.localizedString(from: NSNumber(value: ($0 * 10).rounded() / 10), number: .decimal) }
        let whole: (Double) -> String = { NumberFormatter.localizedString(from: NSNumber(value: $0.rounded()), number: .decimal) }
        let units = nutrition.fatProteinUnits
        var text = String(format: NSLocalizedString("%1$@ g fat + %2$@ g protein = %3$@ fat-protein units", comment: "How the fat and protein boost is worked out (1: grams of fat)(2: grams of protein)(3: units)"), whole(nutrition.fatGrams), whole(nutrition.proteinGrams), number(units))
        if units >= settings.minimumUnits {
            text += String(format: NSLocalizedString(" → %1$@ for %2$@", comment: "Result of the fat and protein boost calculation, appended to it (1: insulin needs in percent)(2: duration)"), percent(strength(units: units, settings: settings, factor: factor)), hours(duration(units: units)))
        } else {
            text += String(format: NSLocalizedString(", below %@: no boost", comment: "Appended to the fat and protein calculation when the meal is below the limit (1: the limit in units)"), number(settings.minimumUnits))
        }
        let names = foods.filter { !$0.isEmpty }
        if names.count > 1 {
            text = String(format: NSLocalizedString("%1$@ together: %2$@", comment: "Fat and protein calculation for several foods eaten together (1: the foods)(2: the calculation)"), names.joined(separator: " + "), text)
        }
        return text
    }

    /// Fat and protein in one carb entry: what was found for this meal, or else what was found for
    /// the favorite food it was logged as, scaled to the entry's carbs.
    static func nutrition(of entry: StoredCarbEntry, favorite: StoredFavoriteFood?, assessments: [String: FavoriteNutritionAssessment], mealNutrition: [String: MealNutrition]) -> MealNutrition? {
        let carbs = entry.quantity.doubleValue(for: .gram())
        if let id = entry.syncIdentifier, let found = mealNutrition[id] {
            return found.scaled(toCarbs: carbs)
        }
        if let favorite, let found = assessments[favorite.id]?.nutrition {
            return found.scaled(toCarbs: carbs)
        }
        return nil
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

    /// The reading nearest to `date`, within ten minutes either way.
    static func glucose(near date: Date, in glucose: [GlucoseValue]) -> Double? {
        glucose
            .filter { abs($0.startDate.timeIntervalSince(date)) <= .minutes(10) }
            .min { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }?
            .quantity.doubleValue(for: .milligramsPerDeciliter)
    }

    /// True for carbs that treated a low: logged with glucose below 5 mmol/L.
    static func isRescue(_ entry: StoredCarbEntry, glucose: [GlucoseValue]) -> Bool {
        guard let value = Self.glucose(near: entry.startDate, in: glucose) else { return false }
        return value < rescueGlucoseMgdl
    }

    /// The fat and protein of a whole meal, and the names of its foods, leaving out carbs that
    /// treated a low.
    static func mealContents(
        _ meal: [StoredCarbEntry],
        favorites: [StoredFavoriteFood],
        assessments: [String: FavoriteNutritionAssessment],
        mealNutrition: [String: MealNutrition],
        glucose: [GlucoseValue]
    ) -> (nutrition: MealNutrition, foods: [String]) {
        let counted = meal.filter { !isRescue($0, glucose: glucose) }
        let foods = counted.map { CarbFoodLabel(foodType: $0.foodType).name }
        let total = zip(counted, foods)
            .compactMap { entry, name in nutrition(of: entry, favorite: favorite(named: name, in: favorites), assessments: assessments, mealNutrition: mealNutrition) }
            .reduce(.zero, +)
        let names = unique(foods.map { name in favorite(named: name, in: favorites)?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? name })
        return (total, names)
    }

    /// The boosts waiting to start, one per meal at most, soonest first. A meal with any record —
    /// started, skipped, declined — is never planned again, even if more of it was logged later.
    static func planned(
        entries: [StoredCarbEntry],
        glucose: [GlucoseValue],
        favorites: [StoredFavoriteFood],
        assessments: [String: FavoriteNutritionAssessment],
        mealNutrition: [String: MealNutrition],
        declined: [String: Date],
        records: [String: FatProteinBoostRecord],
        settings: FatProteinBoostSettings,
        factor: Double,
        now: Date
    ) -> [FatProteinBoostPlan] {
        guard settings.isEnabled else { return [] }

        var planned: [FatProteinBoostPlan] = []
        for meal in meals(entries.filter { $0.syncIdentifier != nil && $0.startDate <= now }) {
            guard let last = meal.last, let triggerID = last.syncIdentifier,
                  !meal.contains(where: { records[$0.syncIdentifier!] != nil || declined[$0.syncIdentifier!] != nil })
            else { continue }

            let earliestStart = last.startDate.addingTimeInterval(settings.delay)
            let latestStart = earliestStart.addingTimeInterval(startWindow)
            // Kept until a little past its window, so a loop gets to skip it rather than it
            // disappearing without a word.
            guard now < latestStart.addingTimeInterval(.hours(1)) else { continue }

            let (nutrition, foods) = mealContents(meal, favorites: favorites, assessments: assessments, mealNutrition: mealNutrition, glucose: glucose)
            let units = nutrition.fatProteinUnits
            guard units.isFinite, units >= settings.minimumUnits else { continue }

            planned.append(FatProteinBoostPlan(
                triggerID: triggerID,
                mealName: foods.joined(separator: " + "),
                mealEnd: last.startDate,
                nutrition: nutrition,
                strength: strength(units: units, settings: settings, factor: factor),
                duration: duration(units: units),
                explanation: explanation(for: nutrition, foods: foods, settings: settings, factor: factor),
                earliestStart: earliestStart,
                latestStart: latestStart
            ))
        }
        return planned.sorted { $0.earliestStart < $1.earliestStart }
    }

    /// What the boost would do for `entry`, counted together with the entries logged up to an hour
    /// before it. `entry` is not saved yet; its fat and protein, if any, are under its own id.
    static func preview(
        entry: StoredCarbEntry,
        earlier: [StoredCarbEntry],
        favorites: [StoredFavoriteFood],
        assessments: [String: FavoriteNutritionAssessment],
        mealNutrition: [String: MealNutrition],
        settings: FatProteinBoostSettings,
        factor: Double
    ) -> FatProteinBoostPreview {
        let meal = meals(earlier + [entry]).first { $0.contains { $0.syncIdentifier == entry.syncIdentifier } } ?? [entry]
        let (total, foods) = mealContents(meal, favorites: favorites, assessments: assessments, mealNutrition: mealNutrition, glucose: [])

        let name = CarbFoodLabel(foodType: entry.foodType).name
        let ownFavorite = favorite(named: name, in: favorites)
        let own = nutrition(of: entry, favorite: ownFavorite, assessments: assessments, mealNutrition: mealNutrition)
        let source: FatProteinBoostPreview.Source = entry.syncIdentifier.flatMap { mealNutrition[$0] } != nil ? .meal : own != nil ? .favorite : .none

        let units = total.fatProteinUnits
        let isBoosted = settings.isEnabled && units.isFinite && units >= settings.minimumUnits
        return FatProteinBoostPreview(
            mealTotal: total,
            entry: own,
            source: source,
            strength: isBoosted ? strength(units: units, settings: settings, factor: factor) : nil,
            duration: isBoosted ? duration(units: units) : nil,
            earliestStart: (meal.last?.startDate ?? entry.startDate).addingTimeInterval(settings.delay),
            explanation: explanation(for: total, foods: foods, settings: settings, factor: factor)
        )
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    // MARK: Starting and ending

    /// Where glucose stands against the start conditions.
    static func conditions(glucose: [GlucoseValue], settings: FatProteinBoostSettings, now: Date) -> FatProteinBoostConditions {
        let samples = glucose.sorted { $0.startDate < $1.startDate }
        guard let latest = samples.last, now.timeIntervalSince(latest.startDate) <= maximumGlucoseAge else {
            return FatProteinBoostConditions(latestGlucose: nil, recentChange: nil, isHighEnough: false, isNotFalling: false)
        }

        let unit = HKUnit.milligramsPerDeciliter
        let latestValue = latest.quantity.doubleValue(for: unit)

        // The reading closest to `trendSpan` before the latest one, within five minutes either way.
        let target = latest.startDate.addingTimeInterval(-trendSpan)
        let earlier = samples
            .filter { abs($0.startDate.timeIntervalSince(target)) <= .minutes(5) }
            .min { abs($0.startDate.timeIntervalSince(target)) < abs($1.startDate.timeIntervalSince(target)) }
        let change = earlier.map { latestValue - $0.quantity.doubleValue(for: unit) }

        return FatProteinBoostConditions(
            latestGlucose: latest.quantity,
            recentChange: change.map { HKQuantity(unit: unit, doubleValue: $0) },
            isHighEnough: latestValue >= settings.startGlucoseMgdl,
            isNotFalling: change.map { $0 >= -levelTolerance } ?? false
        )
    }

    /// Whether a waiting boost starts now: once due, with glucose high and not falling. Until then
    /// it waits, and past its window it is skipped. It also waits while someone else's override
    /// runs, so it never replaces a choice made by hand.
    static func decide(_ plan: FatProteinBoostPlan, glucose: [GlucoseValue], otherOverrideIsActive: Bool, settings: FatProteinBoostSettings, now: Date) -> Decision {
        if now >= plan.latestStart {
            return .skip
        }
        guard now >= plan.earliestStart, !otherOverrideIsActive else {
            return .wait
        }
        let conditions = conditions(glucose: glucose, settings: settings, now: now)
        return conditions.isHighEnough && conditions.isNotFalling ? .start : .wait
    }

    /// What to do with a boost that was started: the override running now is compared with the
    /// one the boost started.
    static func decideActive(_ record: FatProteinBoostRecord, current: TemporaryScheduleOverride?, glucose: [GlucoseValue], settings: FatProteinBoostSettings, now: Date) -> ActiveDecision {
        guard let current, current.syncIdentifier == record.overrideID else {
            if let plannedEnd = record.plannedEnd, now >= plannedEnd.addingTimeInterval(-.minutes(1)) {
                return .finished
            }
            return .cancelled
        }
        if current.hasFinished(relativeTo: now) {
            return .finished
        }
        let samples = glucose.sorted { $0.startDate < $1.startDate }
        if let latest = samples.last, now.timeIntervalSince(latest.startDate) <= maximumGlucoseAge,
           latest.quantity.doubleValue(for: .milligramsPerDeciliter) < settings.stopGlucoseMgdl {
            return .endNow
        }
        return .keep
    }

    /// The override a boost runs as: a preset of its own, so Loop, Nightscout and LoopFollow all
    /// show it by name. The correction range is left as scheduled.
    static func override(strength: Double, duration: TimeInterval, start: Date, id: UUID = UUID()) -> TemporaryScheduleOverride {
        let settings = TemporaryScheduleOverrideSettings(targetRange: nil, insulinNeedsScaleFactor: strength)
        let preset = TemporaryScheduleOverridePreset(
            symbol: "🧈",
            name: NSLocalizedString("Fat and Protein", comment: "Name of the override that raises insulin needs after a meal heavy in fat and protein"),
            settings: settings,
            duration: .finite(duration)
        )
        return TemporaryScheduleOverride(context: .preset(preset), settings: settings, startDate: start, duration: .finite(duration), enactTrigger: .local, syncIdentifier: id)
    }

    /// The boost that takes over when another meal's boost is due while one already runs: the
    /// stronger of the two, until the later of their ends, but never past either meal's reach.
    static func merged(active: FatProteinBoostRecord, with plan: FatProteinBoostPlan, now: Date) -> (strength: Double, end: Date) {
        let strength = max(active.strength, plan.strength)
        let end = max(active.plannedEnd ?? now, min(now.addingTimeInterval(plan.duration), plan.mealEnd.addingTimeInterval(longestReach)))
        return (strength, end)
    }

    // MARK: Learning

    /// How a boost went, once the two hours after it are over: `nil` before then, or when too few
    /// readings cover it to tell.
    static func outcome(of record: FatProteinBoostRecord, glucose: [GlucoseValue], factor: Double, now: Date) -> FatProteinBoostOutcome? {
        guard let start = record.start, let end = record.end ?? record.plannedEnd else { return nil }
        let tailEnd = end.addingTimeInterval(outcomeTail)
        guard now >= tailEnd else { return nil }

        let unit = HKUnit.milligramsPerDeciliter
        let window = glucose.filter { $0.startDate >= start && $0.startDate <= tailEnd }
        let expected = tailEnd.timeIntervalSince(start) / .minutes(5)
        guard expected > 0, Double(window.count) >= expected * 0.7 else { return nil }

        let peakStart = start.addingTimeInterval(outcomeLead)
        let peakWindow = window.filter { $0.startDate >= peakStart && $0.startDate <= max(end, peakStart) }
        let peak = (peakWindow.isEmpty ? window : peakWindow).map { $0.quantity.doubleValue(for: unit) }.max() ?? 0
        let lowest = window.map { $0.quantity.doubleValue(for: unit) }.min() ?? 0

        let verdict: FatProteinBoostOutcome.Verdict
        let change: Double
        // A low weighs more than a high: it is the one that cannot wait until morning.
        if lowest < 72 {
            (verdict, change) = (.low, 0.8)
        } else if lowest < 81 {
            (verdict, change) = (.lowish, 0.9)
        } else if peak >= 234 {
            (verdict, change) = (.high, 1.15)
        } else if peak >= 198 {
            (verdict, change) = (.highish, 1.08)
        } else {
            (verdict, change) = (.good, 1)
        }
        let range = FatProteinBoostCalibration.factorRange
        let after = min(max(factor * change, range.lowerBound), range.upperBound)

        return FatProteinBoostOutcome(
            mealName: record.mealName, start: start, end: end, units: record.units, strength: record.strength,
            peakMgdl: peak, lowestMgdl: lowest, verdict: verdict, factorBefore: factor, factorAfter: after
        )
    }

    /// Records older than two days can no longer match a meal or be learned from.
    static func pruned(_ records: [String: FatProteinBoostRecord], now: Date) -> [String: FatProteinBoostRecord] {
        records.filter { now.timeIntervalSince($0.value.date) < .hours(48) || $0.value.state == .active }
    }
}

extension Notification.Name {
    /// Posted on the main queue when waiting or running boosts change.
    static let fatProteinBoostDidChange = Notification.Name("com.loopkit.Loop.fatProteinBoostDidChange")

    /// Posted when fat and protein, a declined meal or the settings change.
    static let fatProteinBoostInputsDidChange = Notification.Name("com.loopkit.Loop.fatProteinBoostInputsDidChange")
}

/// Runs the boost: checked right before every loop, so a boost that starts or ends is dosed for in
/// the same loop, whether the meal was logged on this phone, by the caregiver app, or on the watch.
final class FatProteinBoostManager {
    /// The one the app runs, for the settings screen.
    static weak var current: FatProteinBoostManager?

    private let log = OSLog(category: "FatProteinBoostManager")

    typealias CarbEntriesFetcher = (_ start: Date, _ completion: @escaping (Swift.Result<[StoredCarbEntry], Error>) -> Void) -> Void
    typealias GlucoseFetcher = (_ start: Date, _ completion: @escaping (Swift.Result<[StoredGlucoseSample], Error>) -> Void) -> Void

    private let fetchCarbEntries: CarbEntriesFetcher
    private let fetchGlucose: GlucoseFetcher
    private let currentOverride: () -> TemporaryScheduleOverride?
    private let enactOverride: (TemporaryScheduleOverride?) -> Void
    private let glucoseUnit: () -> HKUnit
    private let defaults: UserDefaults
    private let now: () -> Date

    private let lock = UnfairLock()
    /// Held for a whole pass, apart from `lock`: enacting an override sets off observers that may
    /// read `planned`, and `lock` is not reentrant.
    private let runLock = NSLock()
    private var _planned: [FatProteinBoostPlan] = []
    private var _glucose: [GlucoseValue] = []

    /// Boosts waiting for their meal's rise, soonest first.
    var planned: [FatProteinBoostPlan] {
        lock.withLock { _planned }
    }

    /// The boost running now, if any.
    var active: FatProteinBoostRecord? {
        defaults.fatProteinBoostRecords.values.first { $0.state == .active }
    }

    /// Where glucose stood against the start conditions at the last check.
    var conditions: FatProteinBoostConditions {
        let glucose = lock.withLock { _glucose }
        return FatProteinBoostPlanner.conditions(glucose: glucose, settings: defaults.fatProteinBoostSettings, now: now())
    }

    private var observers: [NSObjectProtocol] = []

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        fetchCarbEntries: @escaping CarbEntriesFetcher,
        fetchGlucose: @escaping GlucoseFetcher,
        currentOverride: @escaping () -> TemporaryScheduleOverride?,
        enactOverride: @escaping (TemporaryScheduleOverride?) -> Void,
        glucoseUnit: @escaping () -> HKUnit = { .millimolesPerLiter }
    ) {
        self.glucoseUnit = glucoseUnit
        self.defaults = defaults
        self.now = now
        self.fetchCarbEntries = fetchCarbEntries
        self.fetchGlucose = fetchGlucose
        self.currentOverride = currentOverride
        self.enactOverride = enactOverride

        // A meal logged or deleted, or its fat and protein changed, shows up without waiting for a loop.
        for name in [CarbStore.carbEntriesDidChange, .fatProteinBoostInputsDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.refresh()
            })
        }
        refresh()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Long enough back for the meals that may still start, and for the outcome of a boost that
    /// ran up to the meal's reach.
    private static let glucoseLookback = FatProteinBoostSettings.delayRange.upperBound + FatProteinBoostPlanner.startWindow + FatProteinBoostPlanner.longestReach

    private var carbLookback: TimeInterval {
        defaults.fatProteinBoostSettings.delay + FatProteinBoostPlanner.startWindow + .hours(1) + FatProteinBoostPlanner.mealGap * 2
    }

    // MARK: - Running

    /// Looks after the running boost, learns from finished ones, and starts or skips waiting ones,
    /// then calls `completion`.
    func runDue(completion: @escaping () -> Void) {
        let now = self.now()
        fetchRecentGlucose(now: now) { glucose in
            self.fetchEntries(now: now) { entries in
                self.runLock.lock()
                self.run(entries: entries, glucose: glucose, now: now)
                self.runLock.unlock()
                self.publish(self.plans(entries: entries, glucose: glucose, now: now).filter { now < $0.latestStart })
                completion()
            }
        }
    }

    func refresh() {
        let now = self.now()
        fetchRecentGlucose(now: now) { glucose in
            self.fetchEntries(now: now) { entries in
                self.publish(self.plans(entries: entries, glucose: glucose, now: now).filter { now < $0.latestStart })
            }
        }
    }

    /// Ends the running boost straight away — the caregiver's call. Nothing is learned from it.
    func endActive() {
        runLock.lock()
        var records = defaults.fatProteinBoostRecords
        if let (id, record) = records.first(where: { $0.value.state == .active }) {
            if currentOverride()?.syncIdentifier == record.overrideID {
                enactOverride(nil)
            }
            records[id]?.state = .cancelled
            records[id]?.end = now()
            records[id]?.isEvaluated = true
            defaults.fatProteinBoostRecords = records
        }
        runLock.unlock()
        refresh()
    }

    private func plans(entries: [StoredCarbEntry], glucose: [GlucoseValue], now: Date) -> [FatProteinBoostPlan] {
        FatProteinBoostPlanner.planned(
            entries: entries,
            glucose: glucose,
            favorites: defaults.favoriteFoods,
            assessments: defaults.favoriteNutritionAssessments,
            mealNutrition: defaults.mealNutrition,
            declined: defaults.fatProteinBoostDeclined,
            records: defaults.fatProteinBoostRecords,
            settings: defaults.fatProteinBoostSettings,
            factor: defaults.fatProteinBoostCalibration.factor,
            now: now
        )
    }

    /// One pass, under `runLock`, so two loops close together never start the same boost twice.
    private func run(entries: [StoredCarbEntry], glucose: [GlucoseValue], now: Date) {
        let settings = defaults.fatProteinBoostSettings
        var records = FatProteinBoostPlanner.pruned(defaults.fatProteinBoostRecords, now: now)
        defer { defaults.fatProteinBoostRecords = records }

        // 1. The running boost.
        if let (id, record) = records.first(where: { $0.value.state == .active }) {
            switch FatProteinBoostPlanner.decideActive(record, current: currentOverride(), glucose: glucose, settings: settings, now: now) {
            case .keep:
                break
            case .endNow:
                log.default("Ending the fat and protein boost for %{public}@: glucose is down", record.mealName)
                enactOverride(nil)
                records[id]?.state = .ended
                records[id]?.end = now
            case .finished:
                records[id]?.state = .ended
                records[id]?.end = min(record.plannedEnd ?? now, now)
            case .cancelled:
                log.default("The fat and protein boost for %{public}@ was ended by someone else", record.mealName)
                records[id]?.state = .cancelled
                records[id]?.end = now
                records[id]?.isEvaluated = true
            }
        }

        // 2. Learn from boosts that are over.
        var calibration = defaults.fatProteinBoostCalibration
        for (id, record) in records where record.state == .ended && !record.isEvaluated {
            if let outcome = FatProteinBoostPlanner.outcome(of: record, glucose: glucose, factor: calibration.factor, now: now) {
                log.default("Fat and protein boost for %{public}@ was %{public}@; factor %.2f → %.2f", record.mealName, outcome.verdict.rawValue, outcome.factorBefore, outcome.factorAfter)
                calibration.factor = outcome.factorAfter
                calibration.outcomes = Array(([outcome] + calibration.outcomes).prefix(FatProteinBoostCalibration.keptOutcomes))
                records[id]?.isEvaluated = true
            } else if let end = record.end ?? record.plannedEnd, now > end.addingTimeInterval(FatProteinBoostPlanner.outcomeTail + .hours(1)) {
                // The readings never covered it well enough to tell.
                records[id]?.isEvaluated = true
            }
        }
        if calibration != defaults.fatProteinBoostCalibration {
            defaults.fatProteinBoostCalibration = calibration
        }

        // 3. Start or skip the waiting ones.
        let planned = FatProteinBoostPlanner.planned(
            entries: entries, glucose: glucose,
            favorites: defaults.favoriteFoods,
            assessments: defaults.favoriteNutritionAssessments,
            mealNutrition: defaults.mealNutrition,
            declined: defaults.fatProteinBoostDeclined,
            records: records, settings: settings, factor: calibration.factor, now: now
        )
        for plan in planned {
            let activeEntry = records.first(where: { $0.value.state == .active })
            let current = currentOverride()
            let otherIsActive = current.map { !$0.hasFinished(relativeTo: now) && $0.syncIdentifier != activeEntry?.value.overrideID } ?? false

            switch FatProteinBoostPlanner.decide(plan, glucose: glucose, otherOverrideIsActive: otherIsActive, settings: settings, now: now) {
            case .wait:
                continue
            case .skip:
                log.default("Skipping the fat and protein boost for %{public}@: glucose never turned up", plan.mealDescription)
                records[plan.triggerID] = FatProteinBoostRecord(state: .skipped, mealName: plan.mealDescription, units: plan.units, strength: plan.strength, isEvaluated: true, date: now)
            case .start:
                var strength = plan.strength
                var end = min(now.addingTimeInterval(plan.duration), plan.mealEnd.addingTimeInterval(FatProteinBoostPlanner.longestReach))
                var name = plan.mealDescription
                if let (activeID, active) = activeEntry {
                    (strength, end) = FatProteinBoostPlanner.merged(active: active, with: plan, now: now)
                    name = active.mealName + " + " + name
                    records[activeID]?.state = .merged
                    records[activeID]?.end = now
                    records[activeID]?.isEvaluated = true
                }
                let duration = end.timeIntervalSince(now)
                guard duration >= .minutes(30) else {
                    records[plan.triggerID] = FatProteinBoostRecord(state: .skipped, mealName: name, units: plan.units, strength: strength, isEvaluated: true, date: now)
                    continue
                }

                let override = FatProteinBoostPlanner.override(strength: strength, duration: duration, start: now)
                // Recorded before enacting, so a crash in between can never start it twice.
                records[plan.triggerID] = FatProteinBoostRecord(state: .active, mealName: name, units: plan.units, strength: strength, overrideID: override.syncIdentifier, start: now, plannedEnd: end, date: now)
                defaults.fatProteinBoostRecords = records
                enactOverride(override)
                log.default("Started the fat and protein boost for %{public}@: %.2f until %{public}@", name, strength, String(describing: end))

                let glucoseNow = FatProteinBoostPlanner.conditions(glucose: glucose, settings: settings, now: now).latestGlucose
                let unit = glucoseUnit()
                let glucoseText = glucoseNow.flatMap { QuantityFormatter(for: unit).string(from: $0) }
                NotificationManager.sendFatProteinBoostStartedNotification(name: name, strength: strength, end: end, glucose: glucoseText)
            }
        }
    }

    private func fetchRecentGlucose(now: Date, completion: @escaping ([GlucoseValue]) -> Void) {
        fetchGlucose(now.addingTimeInterval(-Self.glucoseLookback)) { result in
            let glucose: [GlucoseValue]
            switch result {
            case .success(let samples):
                glucose = samples
            case .failure(let error):
                self.log.error("Could not read glucose for the fat and protein boost: %{public}@", String(describing: error))
                glucose = []
            }
            self.lock.withLock { self._glucose = glucose }
            completion(glucose)
        }
    }

    private func fetchEntries(now: Date, completion: @escaping ([StoredCarbEntry]) -> Void) {
        fetchCarbEntries(now.addingTimeInterval(-carbLookback)) { result in
            switch result {
            case .success(let entries):
                completion(entries)
            case .failure(let error):
                self.log.error("Could not read carb entries for the fat and protein boost: %{public}@", String(describing: error))
                completion([])
            }
        }
    }

    private func publish(_ planned: [FatProteinBoostPlan]) {
        lock.withLock { _planned = planned }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .fatProteinBoostDidChange, object: self)
        }
    }
}

// MARK: - Storage

extension UserDefaults {
    private enum FatProteinBoostKey: String {
        // The first two keep the names later carbs gave them, so a phone that ran those builds
        // keeps the fat and protein already found in its favorites and meals.
        case assessments = "com.loopkit.Loop.carbFollowUpAssessments"
        case mealNutrition = "com.loopkit.Loop.carbFollowUpMealNutrition"
        case declined = "com.loopkit.Loop.fatProteinBoostDeclined"
        case records = "com.loopkit.Loop.fatProteinBoostRecords"
        case settings = "com.loopkit.Loop.fatProteinBoostSettings"
        case calibration = "com.loopkit.Loop.fatProteinBoostCalibration"
    }

    /// What the meal estimate made of each favorite food, by favorite food `id`.
    var favoriteNutritionAssessments: [String: FavoriteNutritionAssessment] {
        get { decoded(forKey: FatProteinBoostKey.assessments.rawValue) ?? [:] }
        set {
            set(try? JSONEncoder().encode(newValue), forKey: FatProteinBoostKey.assessments.rawValue)
            NotificationCenter.default.post(name: .fatProteinBoostInputsDidChange, object: nil)
        }
    }

    /// Fat and protein found for, or typed in for, one meal, by its carb entry `syncIdentifier`.
    var mealNutrition: [String: MealNutrition] {
        get { decoded(forKey: FatProteinBoostKey.mealNutrition.rawValue) ?? [:] }
        set {
            set(try? JSONEncoder().encode(newValue), forKey: FatProteinBoostKey.mealNutrition.rawValue)
            NotificationCenter.default.post(name: .fatProteinBoostInputsDidChange, object: nil)
        }
    }

    func setMealNutrition(_ nutrition: MealNutrition?, forEntry id: String) {
        // Only meals still in the window matter, so an overgrown list can simply start over.
        var all = mealNutrition
        if all.count > 200 { all = [:] }
        all[id] = nutrition
        mealNutrition = all
    }

    /// Meals whose boost was turned off on the carb entry screen, by carb entry `syncIdentifier`.
    var fatProteinBoostDeclined: [String: Date] {
        get { decoded(forKey: FatProteinBoostKey.declined.rawValue) ?? [:] }
        set {
            set(try? JSONEncoder().encode(newValue), forKey: FatProteinBoostKey.declined.rawValue)
            NotificationCenter.default.post(name: .fatProteinBoostInputsDidChange, object: nil)
        }
    }

    func setFatProteinBoostDeclined(_ declined: Bool, forEntry id: String, now: Date = Date()) {
        var all = fatProteinBoostDeclined.filter { now.timeIntervalSince($0.value) < .hours(48) }
        all[id] = declined ? now : nil
        fatProteinBoostDeclined = all
    }

    var fatProteinBoostRecords: [String: FatProteinBoostRecord] {
        get { decoded(forKey: FatProteinBoostKey.records.rawValue) ?? [:] }
        set { set(try? JSONEncoder().encode(newValue), forKey: FatProteinBoostKey.records.rawValue) }
    }

    var fatProteinBoostSettings: FatProteinBoostSettings {
        get { decoded(forKey: FatProteinBoostKey.settings.rawValue) ?? .standard }
        set {
            set(try? JSONEncoder().encode(newValue), forKey: FatProteinBoostKey.settings.rawValue)
            NotificationCenter.default.post(name: .fatProteinBoostInputsDidChange, object: nil)
        }
    }

    var fatProteinBoostCalibration: FatProteinBoostCalibration {
        get { decoded(forKey: FatProteinBoostKey.calibration.rawValue) ?? FatProteinBoostCalibration() }
        set { set(try? JSONEncoder().encode(newValue), forKey: FatProteinBoostKey.calibration.rawValue) }
    }

    private func decoded<T: Decodable>(forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
