//
//  SplitBolus.swift
//  Loop
//
//  Splits a meal's bolus in two: part when it is eaten, the rest a couple of hours later for the
//  late rise fat brings (evening milk). Turned on per meal on the carb entry screen; off unless
//  turned on.
//

import Foundation
import HealthKit
import LoopKit
import UserNotifications
import os.log

/// How a split starts out before anything is learned. Stored on the phone and changed from its
/// settings screen.
struct SplitBolusSettings: Codable, Equatable {
    /// Share of the meal's carbs dosed for when it is eaten.
    var nowShare = 0.55
    /// Time from the meal to the rest.
    var delay: TimeInterval = .hours(2)

    static let standard = SplitBolusSettings()

    init() {}

    /// Every field may be missing, so settings saved by an older build keep what they had.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = SplitBolusSettings()
        nowShare = try container.decodeIfPresent(Double.self, forKey: .nowShare) ?? standard.nowShare
        delay = try container.decodeIfPresent(TimeInterval.self, forKey: .delay) ?? standard.delay
    }

    static let nowShareRange: ClosedRange<Double> = 0.4...0.8
    /// No real upper limit: the rise after fat can come many hours later (milk at seven, high
    /// at eleven). Twelve hours only keeps the stepper finite.
    static let delayRange: ClosedRange<TimeInterval> = .minutes(90) ... .hours(12)
    /// Extra on the rest, on top of its carbs, learned from evenings that still went high.
    static let extraRange: ClosedRange<Double> = 0...0.5
    static let nowShareStep = 0.05
    static let delayStep: TimeInterval = .minutes(15)
    static let extraStep = 0.1

    /// The part eaten now is absorbed like milk sugar; the rest stands for the slow rise after it.
    static let nowAbsorptionTime: TimeInterval = .hours(2)
    static let laterAbsorptionTime: TimeInterval = .hours(3)
}

/// What the split has learned from the evenings after it.
struct SplitBolusCalibration: Codable, Equatable {
    /// `nil` until learned: the settings' start value applies.
    var nowShare: Double?
    /// `nil` until learned: the start value, or what the history suggests, applies.
    var delay: TimeInterval?
    var extra = 0.0
    /// The latest outcomes, newest first.
    var outcomes: [SplitBolusOutcome] = []

    static let keptOutcomes = 20
}

/// How one split went, and what it changed for the next one.
struct SplitBolusOutcome: Codable, Equatable {
    var mealName: String
    var mealDate: Date
    /// False when the rest was skipped or never logged.
    var restWasGiven: Bool
    /// Lowest glucose from the meal until the rest (or two hours, without a rest).
    var lowestBeforeRestMgdl: Double
    /// Lowest glucose in the three hours after the rest.
    var lowestAfterRestMgdl: Double?
    /// Minutes above 10 mmol/L from two to six hours after the meal.
    var minutesHigh: Double
    /// Glucose had already risen 2 mmol/L when the rest was logged: from its low point, or from
    /// where it started if it dipped below that.
    var roseBeforeRest: Bool
    var nowShareBefore: Double
    var nowShareAfter: Double
    var delayBefore: TimeInterval
    var delayAfter: TimeInterval
    var extraBefore: Double
    var extraAfter: Double

    var changed: Bool {
        nowShareBefore != nowShareAfter || delayBefore != delayAfter || extraBefore != extraAfter
    }
}

/// What earlier servings of the same food did, read from the weeks of Nightscout on the phone.
struct SplitBolusHistoryBasis: Equatable {
    /// Servings with glucose covering the six hours after them.
    var count: Int
    /// Median time from eating to the rise: glucose 1.5 mmol/L over its low point after eating.
    var medianRiseStart: TimeInterval?
    /// Median time from eating to the highest glucose two to six hours after.
    var medianPeak: TimeInterval?
    /// Servings followed by glucose below 4 mmol/L within two hours.
    var earlyLows: Int

    /// Fewer servings than this say too little to go by.
    static let minimumCount = 5
}

/// What the split would do for a meal being logged, for the carb entry and bolus screens.
struct SplitBolusSuggestion: Equatable {
    var mealName: String
    var foodType: String?
    var mealDate: Date
    var totalCarbs: Double
    var nowShare: Double
    var delay: TimeInterval
    var extra: Double
    var nowCarbs: Double
    /// The rest of the carbs, with `extra` on top.
    var laterCarbs: Double
    /// Rough insulin for each part from the carb ratio, `nil` without one.
    var nowUnits: Double?
    var laterUnits: Double?
    var basis: SplitBolusHistoryBasis?
    /// Where the delay came from.
    var delaySource: DelaySource

    enum DelaySource: Equatable {
        case learned
        case history
        case standard
        /// Changed by hand for this meal.
        case chosen
    }

    var due: Date { mealDate.addingTimeInterval(delay) }
}

/// A split waiting for, or done with, its rest.
struct SplitBolusPlan: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        /// Not due yet.
        case waiting
        /// Due, and the notification went out.
        case notified
        /// Glucose was low or falling when due: waiting another half hour, once.
        case postponed
        /// The rest was logged.
        case given
        /// Glucose was still low or falling after the half hour: no rest.
        case skipped
        /// Nobody logged the rest in time.
        case expired
        /// Called off by hand.
        case cancelled
    }

    var id: String
    var mealName: String
    var foodType: String?
    var mealDate: Date
    var totalCarbs: Double
    var nowCarbs: Double
    var laterCarbs: Double
    var nowShare: Double
    var delay: TimeInterval
    var extra: Double
    /// Rough insulin for the rest from the carb ratio at the time it is due.
    var laterUnits: Double?
    /// `syncIdentifier` of the part logged with the meal.
    var nowEntryID: String?
    var due: Date
    var state: State
    var stateDate: Date
    /// `syncIdentifier` of the rest once logged.
    var laterEntryID: String?
    var givenAt: Date?
    /// True once its outcome was learned from, or when there is none to learn from.
    var isEvaluated = false

    var isOpen: Bool { [.waiting, .notified, .postponed].contains(state) }

    /// The meal as a person would name it: its name, or its time when it has none.
    var mealDescription: String {
        FatProteinBoostPlanner.mealDescription(name: mealName, date: mealDate)
    }

    /// The rest's own name, so it is never taken for another serving: "🥛🍼 Melk (resten)".
    /// LoopFollow logs the rest with exactly this, read from Nightscout (`SplitBolusTreatment`).
    var restFoodType: String? {
        let label = CarbFoodLabel(foodType: foodType)
        let name = label.name.isEmpty
            ? NSLocalizedString("Rest", comment: "Name of the rest of a split bolus for a meal without a name")
            : label.name + " " + SplitBolusPlanner.restSuffix
        return CarbFoodLabel(emoji: label.emoji.isEmpty ? "✂️" : label.emoji, name: name).foodType
    }

    /// The rest as a carb entry.
    func laterEntry(at date: Date) -> NewCarbEntry {
        NewCarbEntry(
            date: date,
            quantity: HKQuantity(unit: .gram(), doubleValue: laterCarbs),
            startDate: date,
            foodType: restFoodType,
            absorptionTime: SplitBolusSettings.laterAbsorptionTime
        )
    }
}

/// The rules the split runs on, apart from storage and timing, so they can be tested.
enum SplitBolusPlanner {
    /// The rest waits this long the one time glucose is low or falling when it is due.
    static let postponement = TimeInterval.minutes(30)
    /// A rest nobody logged is let go this long after it was due, so a rest given late in the
    /// evening, well after its reminder, still counts.
    static let restWindow = TimeInterval.hours(6)
    /// No rest with glucose below this.
    static let lowGlucoseMgdl = 90.0 // 5.0 mmol/L
    /// No rest with glucose falling more than this over 15 minutes: 0.1 mmol/L a minute.
    static let fallingMgdlPer15Minutes = -27.0
    static let maximumGlucoseAge = TimeInterval.minutes(15)
    /// Outcomes are read until at least this long after the meal, and three hours after a late rest.
    static let outcomeSpan = TimeInterval.hours(6)
    /// Glucose is read this long after the rest to see what it did.
    static let afterRestSpan = TimeInterval.hours(3)
    /// Glucose this far over its low point after eating counts as the rise.
    static let riseMgdl = 27.0 // 1.5 mmol/L
    /// Risen this far over its low point when the rest was logged: the rest came too late.
    static let lateRiseMgdl = 36.0 // 2 mmol/L
    static let lowMgdl = 72.0 // 4 mmol/L
    static let highMgdl = 180.0 // 10 mmol/L
    /// Time above 10 mmol/L past which the rest was too small.
    static let tooLongHigh = TimeInterval.hours(1)
    /// The rest is aimed this long before the rise, so the insulin is working when it comes.
    static let leadBeforeRise = TimeInterval.minutes(30)
    /// Earlier servings count when eaten within this of the same time of day.
    static let timeOfDayWindow = TimeInterval.hours(3)
    /// Ends the name of the rest's carb entry: "Milk (rest)".
    static let restSuffix = NSLocalizedString("(rest)", comment: "Marks the rest of a split bolus after the food's name")

    // MARK: Working out the split

    /// Whole grams, as carbs are shown everywhere else.
    static func rounded(carbs: Double) -> Double {
        carbs.rounded()
    }

    static func clampedShare(_ share: Double) -> Double {
        let range = SplitBolusSettings.nowShareRange
        return (min(max(share, range.lowerBound), range.upperBound) * 100).rounded() / 100
    }

    static func clampedDelay(_ delay: TimeInterval) -> TimeInterval {
        let range = SplitBolusSettings.delayRange
        let step = SplitBolusSettings.delayStep
        return min(max((delay / step).rounded() * step, range.lowerBound), range.upperBound)
    }

    static func clampedExtra(_ extra: Double) -> Double {
        let range = SplitBolusSettings.extraRange
        return (min(max(extra, range.lowerBound), range.upperBound) * 100).rounded() / 100
    }

    /// The delay the history points to: the rise, less the lead the insulin needs.
    static func delay(from basis: SplitBolusHistoryBasis?) -> TimeInterval? {
        guard let basis, basis.count >= SplitBolusHistoryBasis.minimumCount, let rise = basis.medianRiseStart else { return nil }
        return clampedDelay(rise - leadBeforeRise)
    }

    /// The split for `carbs` of a food eaten at `mealDate`. A share or delay chosen by hand for
    /// this meal wins over what was learned, which wins over the history and the start values.
    static func suggestion(
        carbs: Double,
        foodType: String?,
        mealDate: Date,
        settings: SplitBolusSettings,
        calibration: SplitBolusCalibration,
        basis: SplitBolusHistoryBasis?,
        carbRatio: Double?,
        chosenShare: Double? = nil,
        chosenDelay: TimeInterval? = nil
    ) -> SplitBolusSuggestion? {
        guard carbs > 0, carbs.isFinite else { return nil }

        let share = clampedShare(chosenShare ?? calibration.nowShare ?? settings.nowShare)
        let delay: TimeInterval
        let source: SplitBolusSuggestion.DelaySource
        if let chosenDelay {
            (delay, source) = (clampedDelay(chosenDelay), .chosen)
        } else if let learned = calibration.delay {
            (delay, source) = (clampedDelay(learned), .learned)
        } else if let fromHistory = Self.delay(from: basis) {
            (delay, source) = (fromHistory, .history)
        } else {
            (delay, source) = (clampedDelay(settings.delay), .standard)
        }
        let extra = clampedExtra(calibration.extra)

        let nowCarbs = min(max(rounded(carbs: carbs * share), 1), carbs)
        let laterCarbs = rounded(carbs: (carbs - nowCarbs) * (1 + extra))
        let ratio = carbRatio.flatMap { $0 > 0 ? $0 : nil }

        return SplitBolusSuggestion(
            mealName: CarbFoodLabel(foodType: foodType).name,
            foodType: foodType,
            mealDate: mealDate,
            totalCarbs: carbs,
            nowShare: share,
            delay: delay,
            extra: extra,
            nowCarbs: nowCarbs,
            laterCarbs: laterCarbs,
            nowUnits: ratio.map { nowCarbs / $0 },
            laterUnits: ratio.map { laterCarbs / $0 },
            basis: basis,
            delaySource: source
        )
    }

    static func plan(from suggestion: SplitBolusSuggestion, nowEntryID: String?, laterCarbRatio: Double?, id: String = UUID().uuidString, now: Date) -> SplitBolusPlan {
        let ratio = laterCarbRatio.flatMap { $0 > 0 ? $0 : nil }
        return SplitBolusPlan(
            id: id,
            mealName: suggestion.mealName,
            foodType: suggestion.foodType,
            mealDate: suggestion.mealDate,
            totalCarbs: suggestion.totalCarbs,
            nowCarbs: suggestion.nowCarbs,
            laterCarbs: suggestion.laterCarbs,
            nowShare: suggestion.nowShare,
            delay: suggestion.delay,
            extra: suggestion.extra,
            laterUnits: ratio.map { suggestion.laterCarbs / $0 } ?? suggestion.laterUnits,
            nowEntryID: nowEntryID,
            due: suggestion.due,
            state: .waiting,
            stateDate: now
        )
    }

    // MARK: History

    /// True when a logged food is the same food as `foodType`: the same name, or with neither
    /// named, the same emoji. Rests of earlier splits are never the same food.
    static func isSameFood(_ logged: String?, as foodType: String?) -> Bool {
        let a = CarbFoodLabel(foodType: logged), b = CarbFoodLabel(foodType: foodType)
        if a.name.hasSuffix(restSuffix) || a.name.hasSuffix("(rest)") { return false }
        if !b.name.isEmpty {
            return a.name.caseInsensitiveCompare(b.name) == .orderedSame
                || (a.name.isEmpty && !a.emoji.isEmpty && a.emoji == b.emoji)
        }
        return !b.emoji.isEmpty && a.emoji == b.emoji
    }

    /// Minutes from midnight apart, the shorter way round.
    static func timeOfDayDistance(_ a: Date, _ b: Date, calendar: Calendar = .current) -> TimeInterval {
        func seconds(_ date: Date) -> TimeInterval {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return TimeInterval((parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60)
        }
        let difference = abs(seconds(a) - seconds(b))
        return min(difference, 24 * 3600 - difference)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// What earlier servings of the food did: when glucose rose, when it peaked and how often it
    /// went low early. Only servings eaten around the same time of day count.
    static func historyBasis(
        foodType: String?,
        mealDate: Date,
        treatments: [NightscoutTreatment],
        glucose: [NightscoutGlucoseReading],
        calendar: Calendar = .current
    ) -> SplitBolusHistoryBasis? {
        guard !CarbFoodLabel(foodType: foodType).name.isEmpty || !CarbFoodLabel(foodType: foodType).emoji.isEmpty else { return nil }

        let servings = treatments.filter {
            ($0.carbs ?? 0) > 0 && $0.date < mealDate.addingTimeInterval(-outcomeSpan)
                && isSameFood($0.foodType, as: foodType)
                && timeOfDayDistance($0.date, mealDate, calendar: calendar) <= timeOfDayWindow
        }
        guard !servings.isEmpty else { return nil }

        let readings = glucose.sorted { $0.date < $1.date }
        var rises: [Double] = [], peaks: [Double] = [], lows = 0, count = 0
        var lastServing: Date?
        for serving in servings.sorted(by: { $0.date < $1.date }) {
            // A second serving within the hour is the same meal.
            if let lastServing, serving.date.timeIntervalSince(lastServing) < .hours(1) { continue }
            lastServing = serving.date

            let window = readings.filter { $0.date >= serving.date && $0.date <= serving.date.addingTimeInterval(outcomeSpan) }
            guard Double(window.count) >= outcomeSpan / .minutes(5) * 0.7 else { continue }
            count += 1

            let early = window.filter { $0.date <= serving.date.addingTimeInterval(.hours(2)) }
            if early.contains(where: { $0.mgdl < lowMgdl }) { lows += 1 }

            // The rise: the first reading, from an hour on, 1.5 mmol/L over the lowest one before
            // it and above where glucose started, so coming back from a dip is not taken for it.
            let start = window[0].mgdl
            var lowest = Double.infinity
            for reading in window {
                lowest = min(lowest, reading.mgdl)
                if reading.date >= serving.date.addingTimeInterval(.hours(1)), reading.mgdl >= lowest + riseMgdl, reading.mgdl > start {
                    rises.append(reading.date.timeIntervalSince(serving.date))
                    break
                }
            }
            let late = window.filter { $0.date >= serving.date.addingTimeInterval(.hours(2)) }
            if let peak = late.max(by: { $0.mgdl < $1.mgdl }) {
                peaks.append(peak.date.timeIntervalSince(serving.date))
            }
        }
        guard count > 0 else { return nil }
        return SplitBolusHistoryBasis(count: count, medianRiseStart: median(rises), medianPeak: median(peaks), earlyLows: lows)
    }

    // MARK: A rest logged elsewhere

    /// A carb entry as the split looks at it.
    struct LoggedCarb: Equatable {
        var id: String?
        var foodType: String?
        var date: Date
    }

    /// True when `foodType` names the rest of `plan`: exactly what the split logs it with, or,
    /// typed in another language, the meal's name with "(rest)" after it.
    static func isRest(_ foodType: String?, of plan: SplitBolusPlan) -> Bool {
        guard let foodType, !foodType.isEmpty else { return false }
        if foodType == plan.restFoodType { return true }
        let name = CarbFoodLabel(foodType: foodType).name
        let meal = CarbFoodLabel(foodType: plan.foodType).name
        guard !meal.isEmpty else { return false }
        for suffix in Set([restSuffix, "(rest)"]) where name.hasSuffix(suffix) {
            let base = name.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
            if base.caseInsensitiveCompare(meal) == .orderedSame { return true }
        }
        return false
    }

    /// The rest of an open split when it was logged without the split knowing: sent from
    /// LoopFollow as a remote carb entry, or typed in by hand. It counts from the meal until the
    /// rest is let go, and an entry already taken for another split's rest never counts again.
    static func loggedRest(for plan: SplitBolusPlan, in entries: [LoggedCarb], claimed: Set<String>) -> LoggedCarb? {
        guard plan.isOpen else { return nil }
        let end = plan.due.addingTimeInterval(restWindow)
        return entries
            .filter { entry in
                entry.date >= plan.mealDate && entry.date <= end
                    && (entry.id.map { $0 != plan.nowEntryID && !claimed.contains($0) } ?? true)
                    && isRest(entry.foodType, of: plan)
            }
            .min { $0.date < $1.date }
    }

    // MARK: When it is due

    enum DueDecision: Equatable {
        /// Not due, or already notified and waiting for someone.
        case wait
        /// Due with glucose fit for it: tell someone.
        case notify
        /// Low or falling when due the first time: wait half an hour.
        case postpone
        /// Still low or falling: no rest this time.
        case skip
        /// Notified long ago and never logged.
        case expire
    }

    struct GlucoseCheck: Equatable {
        var latestMgdl: Double?
        /// Change over roughly the last 15 minutes.
        var changeMgdl: Double?

        var isLowOrFalling: Bool {
            guard let latestMgdl else { return false }
            return latestMgdl < lowGlucoseMgdl || (changeMgdl ?? 0) < fallingMgdlPer15Minutes
        }
    }

    static func glucoseCheck(_ glucose: [GlucoseValue], now: Date) -> GlucoseCheck {
        let samples = glucose.sorted { $0.startDate < $1.startDate }
        guard let latest = samples.last, now.timeIntervalSince(latest.startDate) <= maximumGlucoseAge else {
            return GlucoseCheck(latestMgdl: nil, changeMgdl: nil)
        }
        let value = latest.quantity.doubleValue(for: .milligramsPerDeciliter)
        let target = latest.startDate.addingTimeInterval(-.minutes(15))
        let earlier = samples
            .filter { abs($0.startDate.timeIntervalSince(target)) <= .minutes(5) }
            .min { abs($0.startDate.timeIntervalSince(target)) < abs($1.startDate.timeIntervalSince(target)) }
        return GlucoseCheck(latestMgdl: value, changeMgdl: earlier.map { value - $0.quantity.doubleValue(for: .milligramsPerDeciliter) })
    }

    /// Without fresh glucose the rest is still offered: the person logging it sees the meter.
    static func decide(_ plan: SplitBolusPlan, glucose: [GlucoseValue], now: Date) -> DueDecision {
        switch plan.state {
        case .waiting, .postponed:
            guard now >= plan.due else { return .wait }
            if now >= plan.due.addingTimeInterval(restWindow) { return .expire }
            guard glucoseCheck(glucose, now: now).isLowOrFalling else { return .notify }
            return plan.state == .waiting ? .postpone : .skip
        case .notified:
            return now >= plan.due.addingTimeInterval(restWindow) ? .expire : .wait
        case .given, .skipped, .expired, .cancelled:
            return .wait
        }
    }

    // MARK: Learning

    /// How a split went, once six hours have passed since the meal: `nil` before then, for a
    /// split called off by hand, or when too few readings cover it.
    static func outcome(of plan: SplitBolusPlan, glucose: [GlucoseValue], calibration: SplitBolusCalibration, settings: SplitBolusSettings, now: Date) -> SplitBolusOutcome? {
        guard [.given, .skipped, .expired].contains(plan.state) else { return nil }
        let end = outcomeEnd(of: plan)
        guard now >= end else { return nil }
        let span = end.timeIntervalSince(plan.mealDate)

        let unit = HKUnit.milligramsPerDeciliter
        let window = glucose
            .filter { $0.startDate >= plan.mealDate && $0.startDate <= end }
            .sorted { $0.startDate < $1.startDate }
            .map { (date: $0.startDate, mgdl: $0.quantity.doubleValue(for: unit)) }
        guard Double(window.count) >= span / .minutes(5) * 0.7 else { return nil }

        let restDate = plan.state == .given ? (plan.givenAt ?? plan.due) : nil
        let earlyEnd = restDate ?? plan.mealDate.addingTimeInterval(.hours(2))
        let early = window.filter { $0.date <= earlyEnd }
        let lowestBefore = early.map(\.mgdl).min() ?? window[0].mgdl

        var lowestAfter: Double?
        var roseBeforeRest = false
        if let restDate {
            lowestAfter = window.filter { $0.date >= restDate && $0.date <= restDate.addingTimeInterval(afterRestSpan) }.map(\.mgdl).min()
            if let atRest = window.min(by: { abs($0.date.timeIntervalSince(restDate)) < abs($1.date.timeIntervalSince(restDate)) }),
               abs(atRest.date.timeIntervalSince(restDate)) <= .minutes(10) {
                // Measured from where glucose started when it dipped below that, so coming back
                // up from an early low is not taken for the rise.
                roseBeforeRest = atRest.mgdl - max(lowestBefore, window[0].mgdl) >= lateRiseMgdl
            }
        }
        let late = window.filter { $0.date >= plan.mealDate.addingTimeInterval(.hours(2)) }
        let minutesHigh = Double(late.filter { $0.mgdl > highMgdl }.count * 5)

        let shareBefore = calibration.nowShare ?? plan.nowShare
        let delayBefore = calibration.delay ?? plan.delay
        let extraBefore = calibration.extra
        var share = shareBefore, delay = delayBefore, extra = extraBefore

        let earlyLow = lowestBefore < lowMgdl
        let lateLow = (lowestAfter ?? .infinity) < lowMgdl
        if earlyLow {
            share -= SplitBolusSettings.nowShareStep
        }
        if restDate != nil {
            if lateLow {
                if extra > 0 {
                    extra -= SplitBolusSettings.extraStep
                } else {
                    delay += SplitBolusSettings.delayStep
                }
            } else {
                if minutesHigh * 60 > tooLongHigh, !earlyLow {
                    extra += SplitBolusSettings.extraStep
                }
                if roseBeforeRest {
                    delay -= SplitBolusSettings.delayStep
                }
            }
        }

        return SplitBolusOutcome(
            mealName: plan.mealDescription,
            mealDate: plan.mealDate,
            restWasGiven: restDate != nil,
            lowestBeforeRestMgdl: lowestBefore,
            lowestAfterRestMgdl: lowestAfter,
            minutesHigh: minutesHigh,
            roseBeforeRest: roseBeforeRest,
            nowShareBefore: shareBefore,
            nowShareAfter: clampedShare(share),
            delayBefore: delayBefore,
            delayAfter: clampedDelay(delay),
            extraBefore: extraBefore,
            extraAfter: clampedExtra(extra)
        )
    }

    /// When a split's evening is over: six hours after the meal, or three after a late rest.
    static func outcomeEnd(of plan: SplitBolusPlan) -> Date {
        let rest = plan.state == .given ? (plan.givenAt ?? plan.due) : plan.due
        return max(plan.mealDate.addingTimeInterval(outcomeSpan), rest.addingTimeInterval(afterRestSpan))
    }

    /// Applies an outcome. Share and delay are only kept as learned once they move, so a change
    /// to the start values still reaches meals until then.
    static func applying(_ outcome: SplitBolusOutcome, to calibration: SplitBolusCalibration) -> SplitBolusCalibration {
        var calibration = calibration
        if calibration.nowShare != nil || outcome.nowShareAfter != outcome.nowShareBefore {
            calibration.nowShare = outcome.nowShareAfter
        }
        if calibration.delay != nil || outcome.delayAfter != outcome.delayBefore {
            calibration.delay = outcome.delayAfter
        }
        calibration.extra = outcome.extraAfter
        calibration.outcomes = Array(([outcome] + calibration.outcomes).prefix(SplitBolusCalibration.keptOutcomes))
        return calibration
    }

    /// Plans older than two days can no longer be due or learned from.
    static func pruned(_ plans: [SplitBolusPlan], now: Date) -> [SplitBolusPlan] {
        plans.filter { now.timeIntervalSince($0.mealDate) < .hours(48) }
    }

    // MARK: Formatting

    static func grams(_ grams: Double) -> String {
        "\(NumberFormatter.localizedString(from: NSNumber(value: (grams * 2).rounded() / 2), number: .decimal)) g"
    }

    static func units(_ units: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return (formatter.string(from: NSNumber(value: (units * 20).rounded() / 20)) ?? "") + " " + NSLocalizedString("U", comment: "Short unit for insulin units")
    }

    static func percent(_ share: Double) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: (share * 100).rounded()), number: .decimal) + " %"
    }

    /// "8 g now · 6.5 g at 21:40"
    static func summary(_ suggestion: SplitBolusSuggestion) -> String {
        String(format: NSLocalizedString("%1$@ now · %2$@ at %3$@", comment: "Short summary of a split bolus (1: carbs now)(2: carbs later)(3: time of the rest)"), grams(suggestion.nowCarbs), grams(suggestion.laterCarbs), FatProteinBoostPlanner.time(suggestion.due))
    }

    /// "10 earlier servings: rise after about 2 hr 10 min, peak about 4 hr; low within 2 hr 3 times"
    static func basisText(_ basis: SplitBolusHistoryBasis) -> String {
        var parts: [String] = []
        if let rise = basis.medianRiseStart {
            parts.append(String(format: NSLocalizedString("rise after about %@", comment: "Part of what earlier servings did (1: time from eating)"), FatProteinBoostPlanner.hours(rise)))
        }
        if let peak = basis.medianPeak {
            parts.append(String(format: NSLocalizedString("highest after about %@", comment: "Part of what earlier servings did (1: time from eating)"), FatProteinBoostPlanner.hours(peak)))
        }
        parts.append(String(format: NSLocalizedString("low within 2 hr %1$d of %2$d times", comment: "Part of what earlier servings did (1: times low)(2: servings)"), basis.earlyLows, basis.count))
        return String(format: NSLocalizedString("%1$d earlier servings: %2$@", comment: "What earlier servings of the same food did (1: number of servings)(2: what they did)"), basis.count, parts.joined(separator: ", "))
    }
}

extension Notification.Name {
    /// Posted on the main queue when splits are added, become due or end.
    static let splitBolusDidChange = Notification.Name("com.loopkit.Loop.splitBolusDidChange")
}

/// Runs the splits: checked right before every loop, so a rest is offered within five minutes of
/// being due, and only when glucose is fit for it.
final class SplitBolusManager {
    /// The one the app runs, for the screens.
    static weak var current: SplitBolusManager?

    static let notificationPrefix = "splitBolus."
    static let planIDUserInfoKey = "SplitBolusPlanID"

    private let log = OSLog(category: "SplitBolusManager")

    typealias GlucoseFetcher = (_ start: Date, _ completion: @escaping (Swift.Result<[StoredGlucoseSample], Error>) -> Void) -> Void
    typealias CarbFetcher = (_ start: Date, _ completion: @escaping (Swift.Result<[SplitBolusPlanner.LoggedCarb], Error>) -> Void) -> Void

    private let fetchGlucose: GlucoseFetcher
    private let fetchCarbs: CarbFetcher
    private let carbRatio: (Date) -> Double?
    private let glucoseUnit: () -> HKUnit
    private let defaults: UserDefaults
    private let now: () -> Date
    private let notify: (UNNotificationRequest) -> Void
    private let removeNotifications: ([String]) -> Void
    private let history: () async -> NightscoutHistory
    /// What earlier servings did, by food and half hour of the day, so a stepper tap does not
    /// work through weeks of readings again.
    private let basisCache = UnfairLock()
    private var _basisCache: [String: (basis: SplitBolusHistoryBasis?, date: Date)] = [:]

    private let runLock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        fetchGlucose: @escaping GlucoseFetcher,
        fetchCarbs: @escaping CarbFetcher = { _, completion in completion(.success([])) },
        carbRatio: @escaping (Date) -> Double?,
        glucoseUnit: @escaping () -> HKUnit = { .millimolesPerLiter },
        history: @escaping () async -> NightscoutHistory = { await NightscoutHistoryStore.shared.history() },
        notify: @escaping (UNNotificationRequest) -> Void = { UNUserNotificationCenter.current().add($0) },
        removeNotifications: @escaping ([String]) -> Void = {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: $0)
        }
    ) {
        self.defaults = defaults
        self.now = now
        self.fetchGlucose = fetchGlucose
        self.fetchCarbs = fetchCarbs
        self.carbRatio = carbRatio
        self.glucoseUnit = glucoseUnit
        self.history = history
        self.notify = notify
        self.removeNotifications = removeNotifications
    }

    // MARK: For the screens

    var plans: [SplitBolusPlan] { defaults.splitBolusPlans }

    /// The rest that is due now and not logged yet, the earliest first.
    var dueRest: SplitBolusPlan? {
        plans.filter { $0.state == .notified }.min { $0.due < $1.due }
    }

    /// The rest to offer first: one that is due, or else the next one ahead.
    var nextRest: SplitBolusPlan? {
        dueRest ?? openPlans.first
    }

    /// Splits whose rest is still ahead or due.
    var openPlans: [SplitBolusPlan] {
        plans.filter(\.isOpen).sorted { $0.due < $1.due }
    }

    func plan(withID id: String) -> SplitBolusPlan? {
        plans.first { $0.id == id }
    }

    func carbRatio(at date: Date) -> Double? {
        carbRatio(date)
    }

    /// The split for a meal being logged.
    func suggestion(carbs: Double, foodType: String?, mealDate: Date, chosenShare: Double? = nil, chosenDelay: TimeInterval? = nil) async -> SplitBolusSuggestion? {
        let basis = await historyBasis(foodType: foodType, mealDate: mealDate)
        return SplitBolusPlanner.suggestion(
            carbs: carbs, foodType: foodType, mealDate: mealDate,
            settings: defaults.splitBolusSettings, calibration: defaults.splitBolusCalibration,
            basis: basis, carbRatio: carbRatio(mealDate),
            chosenShare: chosenShare, chosenDelay: chosenDelay
        )
    }

    private func historyBasis(foodType: String?, mealDate: Date) async -> SplitBolusHistoryBasis? {
        let halfHour = Int(mealDate.timeIntervalSince(Calendar.current.startOfDay(for: mealDate)) / .minutes(30))
        let key = "\(foodType ?? "")|\(halfHour)"
        let date = now()
        if let cached = basisCache.withLock({ _basisCache[key] }), date.timeIntervalSince(cached.date) < .minutes(10) {
            return cached.basis
        }
        let history = await self.history()
        let basis = SplitBolusPlanner.historyBasis(foodType: foodType, mealDate: mealDate, treatments: history.treatments, glucose: history.glucose)
        basisCache.withLock { _basisCache[key] = (basis, date) }
        return basis
    }

    /// Keeps a split once its first part is saved.
    func add(_ suggestion: SplitBolusSuggestion, nowEntryID: String?) {
        let date = now()
        let plan = SplitBolusPlanner.plan(from: suggestion, nowEntryID: nowEntryID, laterCarbRatio: carbRatio(suggestion.due), now: date)
        update { plans in
            plans = SplitBolusPlanner.pruned(plans, now: date) + [plan]
        }
        log.default("Split bolus for %{public}@: %.1f g now, %.1f g at %{public}@", plan.mealDescription, plan.nowCarbs, plan.laterCarbs, String(describing: plan.due))
    }

    /// The rest was logged.
    func markGiven(planID: String, entryID: String?) {
        let date = now()
        update { plans in
            guard let index = plans.firstIndex(where: { $0.id == planID }) else { return }
            Self.markGiven(&plans[index], entryID: entryID, at: date, now: date)
        }
        removeNotifications([Self.notificationPrefix + planID])
    }

    private static func markGiven(_ plan: inout SplitBolusPlan, entryID: String?, at date: Date, now: Date) {
        plan.state = .given
        plan.stateDate = now
        plan.givenAt = date
        plan.laterEntryID = entryID
    }

    /// Calls a split off by hand. Nothing is learned from it.
    func cancel(planID: String) {
        let date = now()
        update { plans in
            guard let index = plans.firstIndex(where: { $0.id == planID }), plans[index].isOpen else { return }
            plans[index].state = .cancelled
            plans[index].stateDate = date
            plans[index].isEvaluated = true
        }
        removeNotifications([Self.notificationPrefix + planID])
    }

    // MARK: Running

    /// Takes rests logged elsewhere as given, offers the rests that are due, skips the ones
    /// glucose speaks against, and learns from evenings that are over, then calls `completion`.
    func runDue(completion: @escaping () -> Void) {
        let date = now()
        let current = plans
        guard current.contains(where: { $0.isOpen || ($0.state != .cancelled && !$0.isEvaluated) }) else {
            completion()
            return
        }
        let carbStart = current.filter(\.isOpen).map(\.mealDate).min()
        // Back to the oldest meal still to learn from, which with a late rest can be many hours ago.
        let glucoseStart = current.filter { !$0.isEvaluated }.map(\.mealDate).min() ?? date
        fetchGlucose(min(glucoseStart, date.addingTimeInterval(-(SplitBolusPlanner.outcomeSpan + .hours(2))))) { result in
            let glucose: [GlucoseValue]
            switch result {
            case .success(let samples):
                glucose = samples
            case .failure(let error):
                self.log.error("Could not read glucose for the split bolus: %{public}@", String(describing: error))
                glucose = []
            }
            self.fetchLoggedCarbs(from: carbStart) { carbs in
                self.runLock.lock()
                self.run(glucose: glucose, carbs: carbs, now: date)
                self.runLock.unlock()
                completion()
            }
        }
    }

    private func fetchLoggedCarbs(from start: Date?, completion: @escaping ([SplitBolusPlanner.LoggedCarb]) -> Void) {
        guard let start else {
            completion([])
            return
        }
        fetchCarbs(start) { result in
            switch result {
            case .success(let entries):
                completion(entries)
            case .failure(let error):
                self.log.error("Could not read carbs for the split bolus: %{public}@", String(describing: error))
                completion([])
            }
        }
    }

    private func run(glucose: [GlucoseValue], carbs: [SplitBolusPlanner.LoggedCarb], now: Date) {
        var plans = SplitBolusPlanner.pruned(defaults.splitBolusPlans, now: now)
        var calibration = defaults.splitBolusCalibration
        let settings = defaults.splitBolusSettings
        let check = SplitBolusPlanner.glucoseCheck(glucose, now: now)

        // A rest sent from LoopFollow arrives as a plain carb entry: it is the rest, given.
        var claimed = Set(plans.compactMap(\.laterEntryID))
        for index in plans.indices {
            guard let entry = SplitBolusPlanner.loggedRest(for: plans[index], in: carbs, claimed: claimed) else { continue }
            Self.markGiven(&plans[index], entryID: entry.id, at: entry.date, now: now)
            entry.id.map { claimed.insert($0) }
            removeNotifications([Self.notificationPrefix + plans[index].id])
            log.default("Rest of the split bolus for %{public}@ was logged elsewhere", plans[index].mealDescription)
        }

        for index in plans.indices {
            let plan = plans[index]
            switch SplitBolusPlanner.decide(plan, glucose: glucose, now: now) {
            case .wait:
                break
            case .notify:
                plans[index].state = .notified
                plans[index].stateDate = now
                sendRestNotification(plans[index], check: check)
                log.default("Rest of the split bolus for %{public}@ is due", plan.mealDescription)
            case .postpone:
                plans[index].state = .postponed
                plans[index].due = now.addingTimeInterval(SplitBolusPlanner.postponement)
                plans[index].stateDate = now
                sendWaitNotification(plans[index], check: check)
                log.default("Rest of the split bolus for %{public}@ waits: glucose low or falling", plan.mealDescription)
            case .skip:
                plans[index].state = .skipped
                plans[index].stateDate = now
                sendSkipNotification(plans[index], check: check)
                log.default("Rest of the split bolus for %{public}@ skipped: glucose still low or falling", plan.mealDescription)
            case .expire:
                plans[index].state = .expired
                plans[index].stateDate = now
                removeNotifications([Self.notificationPrefix + plan.id])
                log.default("Rest of the split bolus for %{public}@ was never logged", plan.mealDescription)
            }
        }

        for index in plans.indices where !plans[index].isEvaluated && !plans[index].isOpen {
            let plan = plans[index]
            if let outcome = SplitBolusPlanner.outcome(of: plan, glucose: glucose, calibration: calibration, settings: settings, now: now) {
                calibration = SplitBolusPlanner.applying(outcome, to: calibration)
                plans[index].isEvaluated = true
                log.default("Split bolus for %{public}@ learned: share %.2f → %.2f, delay %.0f → %.0f min, extra %.2f → %.2f",
                            plan.mealDescription, outcome.nowShareBefore, outcome.nowShareAfter,
                            outcome.delayBefore / 60, outcome.delayAfter / 60, outcome.extraBefore, outcome.extraAfter)
            } else if plan.state == .cancelled || now > SplitBolusPlanner.outcomeEnd(of: plan).addingTimeInterval(.hours(2)) {
                // Called off, or the readings never covered it well enough to tell.
                plans[index].isEvaluated = true
            }
        }

        if calibration != defaults.splitBolusCalibration {
            defaults.splitBolusCalibration = calibration
        }
        if plans != defaults.splitBolusPlans {
            defaults.splitBolusPlans = plans
            postChange()
        }
    }

    private func update(_ change: (inout [SplitBolusPlan]) -> Void) {
        runLock.lock()
        var plans = defaults.splitBolusPlans
        change(&plans)
        defaults.splitBolusPlans = plans
        runLock.unlock()
        postChange()
    }

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .splitBolusDidChange, object: self)
        }
    }

    // MARK: Notifications

    private func glucoseText(_ check: SplitBolusPlanner.GlucoseCheck) -> String? {
        guard let mgdl = check.latestMgdl else { return nil }
        let unit = glucoseUnit()
        let quantity = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl)
        guard var text = QuantityFormatter(for: unit).string(from: quantity) else { return nil }
        if let change = check.changeMgdl {
            text += change > 9 ? " ↗︎" : change < -9 ? " ↘︎" : " →"
        }
        return text
    }

    private func send(_ plan: SplitBolusPlan, title: String, body: String, isOffer: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if isOffer {
            content.userInfo = [Self.planIDUserInfoKey: plan.id]
            content.interruptionLevel = .timeSensitive
        }
        notify(UNNotificationRequest(identifier: Self.notificationPrefix + plan.id, content: content, trigger: nil))
    }

    private func sendRestNotification(_ plan: SplitBolusPlan, check: SplitBolusPlanner.GlucoseCheck) {
        let title = String(format: NSLocalizedString("✂️ Rest of the bolus: %@", comment: "Notification title when the rest of a split bolus is due (1: name of the meal)"), plan.mealDescription)
        var body = String(format: NSLocalizedString("%1$@ carbs, about %2$@. Tap to log it and bolus.", comment: "Notification body when the rest of a split bolus is due (1: carbs)(2: insulin)"), SplitBolusPlanner.grams(plan.laterCarbs), plan.laterUnits.map(SplitBolusPlanner.units) ?? "–")
        if let glucose = glucoseText(check) {
            body += " " + String(format: NSLocalizedString("Glucose %@.", comment: "Glucose appended to a split bolus notification (1: glucose and trend)"), glucose)
        }
        send(plan, title: title, body: body, isOffer: true)
    }

    private func sendWaitNotification(_ plan: SplitBolusPlan, check: SplitBolusPlanner.GlucoseCheck) {
        let title = String(format: NSLocalizedString("✂️ Rest of the bolus waits: %@", comment: "Notification title when the rest of a split bolus waits for glucose (1: name of the meal)"), plan.mealDescription)
        let body = String(format: NSLocalizedString("Glucose %1$@ is low or falling. Checking again at %2$@.", comment: "Notification body when the rest of a split bolus waits (1: glucose)(2: time of the next check)"), glucoseText(check) ?? "–", FatProteinBoostPlanner.time(plan.due))
        send(plan, title: title, body: body, isOffer: false)
    }

    private func sendSkipNotification(_ plan: SplitBolusPlan, check: SplitBolusPlanner.GlucoseCheck) {
        let title = String(format: NSLocalizedString("✂️ No rest of the bolus: %@", comment: "Notification title when the rest of a split bolus is skipped (1: name of the meal)"), plan.mealDescription)
        let body = String(format: NSLocalizedString("Glucose %@ is still low or falling, so the rest is skipped this time.", comment: "Notification body when the rest of a split bolus is skipped (1: glucose)"), glucoseText(check) ?? "–")
        send(plan, title: title, body: body, isOffer: false)
    }
}

// MARK: - Storage

extension UserDefaults {
    private enum SplitBolusKey: String {
        case plans = "com.loopkit.Loop.splitBolusPlans"
        case settings = "com.loopkit.Loop.splitBolusSettings"
        case calibration = "com.loopkit.Loop.splitBolusCalibration"
    }

    var splitBolusPlans: [SplitBolusPlan] {
        get { splitBolusDecoded(forKey: SplitBolusKey.plans.rawValue) ?? [] }
        set { set(try? JSONEncoder().encode(newValue), forKey: SplitBolusKey.plans.rawValue) }
    }

    var splitBolusSettings: SplitBolusSettings {
        get { splitBolusDecoded(forKey: SplitBolusKey.settings.rawValue) ?? .standard }
        set { set(try? JSONEncoder().encode(newValue), forKey: SplitBolusKey.settings.rawValue) }
    }

    var splitBolusCalibration: SplitBolusCalibration {
        get { splitBolusDecoded(forKey: SplitBolusKey.calibration.rawValue) ?? SplitBolusCalibration() }
        set { set(try? JSONEncoder().encode(newValue), forKey: SplitBolusKey.calibration.rawValue) }
    }

    private func splitBolusDecoded<T: Decodable>(forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
