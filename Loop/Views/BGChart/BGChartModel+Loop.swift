//
//  BGChartModel+Loop.swift
//  Loop
//
//  Fills the ported LoopFollow chart model from Loop's own stores.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import SwiftUI

/// One snapshot of everything the glucose chart draws. Assembled on the status
/// screen's reload pass — which already fetches most of it for the existing
/// charts — and handed to `BGChartModel.update(with:)` in one go, so the chart
/// re-lays out once per refresh rather than once per array.
struct BGChartData {
    var glucoseSamples: [StoredGlucoseSample] = []
    /// Yesterday's readings in mg/dL, already shifted forward 24 h, for the
    /// comparison overlay. Empty unless `BGChartSettings.showYesterdayLine` is
    /// on.
    var yesterdayGlucose: [(date: Date, valueMGDL: Double)] = []
    var predictedGlucose: [GlucoseValue] = []
    var doseEntries: [DoseEntry] = []
    var carbEntries: [StoredCarbEntry] = []
    var basalSchedule: BasalRateSchedule?
    var targetRangeSchedule: GlucoseRangeSchedule?
    /// Overrides overlapping the chart window, including the active one.
    var overrides: [TemporaryScheduleOverride] = []
    /// How far the prediction reaches; the domain ends here.
    var predictionEnd: Date?
}

extension BGChartModel {
    /// Replaces every series from a single snapshot of Loop's data.
    func update(with data: BGChartData, now: Date = Date()) {
        applyDisplaySettings()

        let settings = BGChartSettings.shared
        let domainStart = now.addingTimeInterval(-settings.historyHours * 3600)
        // Always leave at least 15 minutes of room to the right so follow mode
        // has somewhere to put "now"; otherwise the domain ends where the
        // prediction does.
        let domainEnd = max(data.predictionEnd ?? now, now.addingTimeInterval(15 * 60))

        // The shaded range, the reading colours and the statistics all come from the
        // in-range thresholds — not from the correction range, which is a much narrower
        // window and is drawn separately. See `BGChartSettings.inRangeLowMGDL`.
        let thresholds = (low: settings.inRangeLowMGDL, high: settings.inRangeHighMGDL)
        lowLine = thresholds.low
        highLine = thresholds.high

        // Manual fingersticks are drawn as their own marker, the way LoopFollow
        // separates Nightscout's BG checks from CGM readings.
        var readings: [BGPoint] = []
        var checks: [TreatmentPoint] = []
        for sample in data.glucoseSamples where sample.startDate >= domainStart {
            let mgdl = sample.quantity.doubleValue(for: .milligramsPerDeciliter)
            if sample.wasUserEntered {
                checks.append(TreatmentPoint(
                    date: sample.startDate,
                    value: mgdl,
                    sgv: mgdl,
                    label: "",
                    pillText: "BG Check\n\(BGChartGlucoseDisplay.string(fromMGDL: mgdl))\n\(pillTimeString(for: sample.startDate))",
                    lane: .onCurve
                ))
            } else {
                readings.append(BGPoint(
                    date: sample.startDate,
                    value: mgdl,
                    color: Self.color(forMGDL: mgdl, thresholds: thresholds)
                ))
            }
        }
        readings.sort { $0.date < $1.date }
        bg = readings
        bgRuns = Self.makeRuns(readings)
        bgChecks = checks

        yesterday = data.yesterdayGlucose.map {
            BGPoint(date: $0.date, value: $0.valueMGDL, color: Color(.systemGray).opacity(0.4))
        }

        // Loop forecasts as a single line; the ZT/IOB/COB/UAM series and the
        // cone are OpenAPS concepts with no Loop equivalent.
        prediction = data.predictedGlucose.map {
            BGPoint(
                date: $0.startDate,
                value: $0.quantity.doubleValue(for: .milligramsPerDeciliter),
                color: .purple
            )
        }
        ztPrediction = []
        iobPrediction = []
        cobPrediction = []
        uamPrediction = []
        cone = []
        // Loop has no super-micro-bolus concept.
        smbs = []
        // Nightscout notes and sensor-start records have no local equivalent.
        notes = []
        sensorStarts = []

        // Treatments hang off the glucose curve, so they need a y value; the
        // reading either side of the treatment gives it. The lane each kind is
        // given then lifts or drops the symbol clear of the curve — and of the
        // other kinds — so a carb entry and a bolus logged in the same minute
        // are both readable instead of one hiding the other.
        let interpolator = GlucoseInterpolator(points: readings, fallback: thresholds.low)

        boluses = Self.spread(data.doseEntries.compactMap { dose -> TreatmentPoint? in
            guard dose.type == .bolus else { return nil }
            let units = dose.deliveredUnits ?? dose.programmedUnits
            guard units > 0 else { return nil }
            let label = Self.doseString(units)
            return TreatmentPoint(
                date: dose.startDate,
                value: units,
                sgv: interpolator.value(at: dose.startDate),
                label: label,
                pillText: "Bolus\n\(label)U\n\(pillTimeString(for: dose.startDate))",
                lane: .insulin
            )
        }, minGap: Spread.bolusGap, maxShift: Spread.bolusShift)

        carbs = Self.spread(data.carbEntries.compactMap { entry -> TreatmentPoint? in
            guard entry.startDate >= domainStart else { return nil }
            let grams = Int(entry.quantity.doubleValue(for: .gram()).rounded())
            var label = "\(grams)"
            if settings.showAbsorption, let absorption = entry.absorptionTime, absorption > 0 {
                label += " \(Int((absorption / 3600).rounded()))h"
            }
            return TreatmentPoint(
                date: entry.startDate,
                value: Double(grams),
                sgv: interpolator.value(at: entry.startDate),
                label: label,
                pillText: "Carbs\n\(grams)g\n\(pillTimeString(for: entry.startDate))",
                lane: .carbs
            )
        }, minGap: Spread.carbGap, maxShift: Spread.carbShift)

        suspends = data.doseEntries.filter { $0.type == .suspend }.map { dose in
            TreatmentPoint(
                date: dose.startDate,
                value: 0,
                sgv: interpolator.value(at: dose.startDate),
                label: "",
                pillText: "Suspend\n\(pillTimeString(for: dose.startDate))",
                lane: .pumpEvent
            )
        }
        resumes = data.doseEntries.filter { $0.type == .resume }.map { dose in
            TreatmentPoint(
                date: dose.startDate,
                value: 0,
                sgv: interpolator.value(at: dose.startDate),
                label: "",
                pillText: "Resume\n\(pillTimeString(for: dose.startDate))",
                lane: .pumpEvent
            )
        }

        // Delivered basal: temp basals plus the scheduled basal Loop records as
        // `.basal` doses. Suspends read as a zero rate for their duration.
        basal = data.doseEntries.compactMap { dose -> BasalStep? in
            let rate: Double
            switch dose.type {
            case .tempBasal, .basal:
                rate = dose.unitsPerHour
            case .suspend:
                rate = 0
            case .bolus, .resume:
                return nil
            }
            let end = dose.type == .suspend ? min(dose.endDate, now) : dose.endDate
            guard end > dose.startDate else { return nil }
            return BasalStep(start: dose.startDate, end: end, rate: rate)
        }.sorted { $0.start < $1.start }

        basalScheduled = Self.scheduledBasalPoints(
            from: data.basalSchedule,
            start: domainStart,
            end: domainEnd
        )
        maxBasal = max(
            basal.map(\.rate).max() ?? 0,
            basalScheduled.map(\.rate).max() ?? 0,
            settings.minBasalScale
        )

        // The y-domain has to be known before the bands can be placed, since
        // overrides live in a strip just under the top of the chart.
        let highestPlotted = max(
            readings.map(\.value).max() ?? 0,
            prediction.map(\.value).max() ?? 0,
            yesterday.map(\.value).max() ?? 0,
            checks.map(\.sgv).max() ?? 0
        )
        maxBG = max(highestPlotted + 20, settings.minBGScale)

        targetRanges = Self.targetRangeBands(
            from: data.targetRangeSchedule,
            start: domainStart,
            end: domainEnd
        )

        let overrideStripTop = maxBG - 5
        let overrideStripBottom = maxBG - 25
        var overrideBands: [BandRect] = []
        var targetBands: [BandRect] = []
        for override in data.overrides {
            let start = override.startDate
            // An indefinite override ends at `.distantFuture`; clamp it to the
            // domain so the band doesn't stretch the x-scale.
            let end = min(override.actualEndDate, domainEnd)
            guard end > domainStart, start < domainEnd else { continue }
            let name = Self.name(for: override)
            overrideBands.append(BandRect(
                start: start,
                end: end,
                yBottom: overrideStripBottom,
                yTop: overrideStripTop,
                label: name,
                pillText: "Override\n\(name)\n\(pillTimeString(for: start))"
            ))

            // An override that moves the correction range is Loop's version of
            // a temp target, and draws at the glucose level it targets.
            if let range = override.settings.targetRange {
                let lower = range.lowerBound.doubleValue(for: .milligramsPerDeciliter)
                let upper = range.upperBound.doubleValue(for: .milligramsPerDeciliter)
                let label = lower == upper
                    ? BGChartGlucoseDisplay.string(fromMGDL: lower)
                    : "\(BGChartGlucoseDisplay.string(fromMGDL: lower))–\(BGChartGlucoseDisplay.string(fromMGDL: upper))"
                targetBands.append(BandRect(
                    start: start,
                    end: end,
                    yBottom: min(lower, upper) - 2,
                    yTop: max(upper, lower) + 2,
                    label: "Target",
                    pillText: "Target\n\(label)\n\(pillTimeString(for: start))"
                ))
            }
        }
        overrides = overrideBands
        tempTargets = targetBands
        // Loop's own status chart draws overrides green and correction-range
        // changes purple; keep that reading.
        overrideColor = .green
        tempTargetColor = .purple

        self.now = now
        self.domainStart = domainStart
        self.domainEnd = domainEnd

        thirtyMinMark = now.addingTimeInterval(-1800)
        ninetyMinMark = now.addingTimeInterval(-5400)
        diaMarkers = (1 ... 6).map { now.addingTimeInterval(TimeInterval(-$0 * 3600)) }
        midnightMarkers = Self.midnights(from: domainStart, to: domainEnd)

        didUpdateData()
    }

    // MARK: - Settings

    private func applyDisplaySettings() {
        let settings = BGChartSettings.shared
        showLines = settings.showLines
        showDots = settings.showDots
        showDIA = settings.showDIALines
        show30Min = settings.show30MinLine
        show90Min = settings.show90MinLine
        showMidnight = settings.showMidnightLines
        smallGraphTreatments = settings.smallGraphTreatments
    }

    // MARK: - Derivations

    private static func color(forMGDL value: Double, thresholds: (low: Double, high: Double)) -> Color {
        if value >= thresholds.high { return .yellow }
        if value <= thresholds.low { return .red }
        return .green
    }

    private static func name(for override: TemporaryScheduleOverride) -> String {
        switch override.context {
        case .preMeal:
            return NSLocalizedString("Pre-Meal", comment: "Chart band label for the pre-meal preset")
        case .legacyWorkout:
            return NSLocalizedString("Workout", comment: "Chart band label for the workout preset")
        case .preset(let preset):
            return "\(preset.symbol) \(preset.name)"
        case .custom:
            return NSLocalizedString("Custom", comment: "Chart band label for a custom preset")
        }
    }

    private static let doseFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumIntegerDigits = 0
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static func doseString(_ units: Double) -> String {
        doseFormatter.string(from: NSNumber(value: units)) ?? String(units)
    }

    /// Steps the scheduled basal rate across the window. Two points per segment
    /// (its start, and a hair before its end) turn the plain line mark into a
    /// staircase.
    private static func scheduledBasalPoints(from schedule: BasalRateSchedule?, start: Date, end: Date) -> [ScheduledBasalPoint] {
        guard let schedule, end > start else { return [] }
        var points: [ScheduledBasalPoint] = []
        for segment in schedule.between(start: start, end: end) {
            let segmentStart = max(segment.startDate, start)
            let segmentEnd = min(segment.endDate, end)
            guard segmentEnd > segmentStart else { continue }
            points.append(ScheduledBasalPoint(date: segmentStart, rate: segment.value))
            points.append(ScheduledBasalPoint(date: segmentEnd.addingTimeInterval(-1), rate: segment.value))
        }
        return points
    }

    private static func targetRangeBands(from schedule: GlucoseRangeSchedule?, start: Date, end: Date) -> [BandRect] {
        guard let schedule, end > start else { return [] }
        return schedule.quantityBetween(start: start, end: end).compactMap { segment in
            let segmentStart = max(segment.startDate, start)
            let segmentEnd = min(segment.endDate, end)
            guard segmentEnd > segmentStart else { return nil }
            return BandRect(
                start: segmentStart,
                end: segmentEnd,
                yBottom: segment.value.lowerBound.doubleValue(for: .milligramsPerDeciliter),
                yTop: segment.value.upperBound.doubleValue(for: .milligramsPerDeciliter),
                label: "",
                pillText: ""
            )
        }
    }

    private static func midnights(from start: Date, to end: Date) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        if let timeZone = BGChartSettings.shared.axisTimeZone {
            calendar.timeZone = timeZone
        }
        var marks: [Date] = []
        var cursor = calendar.startOfDay(for: start)
        while cursor <= end {
            if cursor >= start {
                marks.append(cursor)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return marks
    }
}

/// Reads a glucose value off the plotted curve at an arbitrary time, so
/// treatments can be drawn where the line was when they happened. Linear
/// between the readings either side; the nearest reading outside the series'
/// range; `fallback` when there are no readings at all.
private struct GlucoseInterpolator {
    private let points: [BGChartModel.BGPoint]
    private let fallback: Double

    init(points: [BGChartModel.BGPoint], fallback: Double) {
        self.points = points
        self.fallback = fallback
    }

    func value(at date: Date) -> Double {
        guard let first = points.first, let last = points.last else { return fallback }
        if date <= first.date { return first.value }
        if date >= last.date { return last.value }

        // Binary search for the first reading at or after `date`.
        var low = 0
        var high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].date < date {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let after = points[low]
        guard low > 0 else { return after.value }
        let before = points[low - 1]
        let span = after.date.timeIntervalSince(before.date)
        guard span > 0 else { return after.value }
        let fraction = date.timeIntervalSince(before.date) / span
        return before.value + (after.value - before.value) * fraction
    }
}
