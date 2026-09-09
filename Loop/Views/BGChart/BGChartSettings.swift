//
//  BGChartSettings.swift
//  Loop
//
//  Display settings for the interactive glucose chart.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import SwiftUI

/// Display and behaviour settings for the interactive glucose chart.
///
/// The chart was ported from LoopFollow, where these live in its `Storage`
/// singleton. Loop has no equivalent settings screen, so they are kept here
/// with defaults that match LoopFollow's, persisted in `UserDefaults` so the
/// zoom level survives relaunches. Everything is main-actor only, matching the
/// chart itself.
final class BGChartSettings {
    static let shared = BGChartSettings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let visibleHours = "BGChart.visibleHours"
        static let showLines = "BGChart.showLines"
        static let showDots = "BGChart.showDots"
        static let showValues = "BGChart.showValues"
        static let showAbsorption = "BGChart.showAbsorption"
        static let showDIALines = "BGChart.showDIALines"
        static let show30MinLine = "BGChart.show30MinLine"
        static let show90MinLine = "BGChart.show90MinLine"
        static let showMidnightLines = "BGChart.showMidnightLines"
        static let showYesterdayLine = "BGChart.showYesterdayLine"
        static let smallGraphTreatments = "BGChart.smallGraphTreatments"
        static let showSmallGraph = "BGChart.showSmallGraph"
        static let showStats = "BGChart.showStats"
        static let historyHours = "BGChart.historyHours"
        static let useGMI = "BGChart.useGMI"
        static let useCoefficientOfVariation = "BGChart.useCoefficientOfVariation"
    }

    private init() {
        defaults.register(defaults: [
            Key.visibleHours: 6.0,
            Key.showLines: true,
            Key.showDots: true,
            Key.showValues: true,
            Key.showAbsorption: true,
            Key.showDIALines: false,
            Key.show30MinLine: false,
            Key.show90MinLine: false,
            Key.showMidnightLines: false,
            Key.showYesterdayLine: false,
            Key.smallGraphTreatments: true,
            Key.showSmallGraph: true,
            Key.showStats: true,
            Key.historyHours: 24.0,
            Key.useGMI: false,
            Key.useCoefficientOfVariation: false,
        ])
    }

    private func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }
    private func double(_ key: String) -> Double { defaults.double(forKey: key) }

    /// Width of the visible x-axis window, in hours. Written back by the chart
    /// whenever the user pinches or double-taps to a new zoom level.
    var visibleHours: Double {
        get { double(Key.visibleHours) }
        set { defaults.set(newValue, forKey: Key.visibleHours) }
    }

    /// How far back the chart's scale domain reaches. The stores may hold less
    /// than this; the domain simply ends up sparse on the left.
    var historyHours: Double {
        get { double(Key.historyHours) }
        set { defaults.set(newValue, forKey: Key.historyHours) }
    }

    var showLines: Bool {
        get { bool(Key.showLines) }
        set { defaults.set(newValue, forKey: Key.showLines) }
    }

    var showDots: Bool {
        get { bool(Key.showDots) }
        set { defaults.set(newValue, forKey: Key.showDots) }
    }

    /// Draw the numeric label above bolus / carb / SMB markers.
    var showValues: Bool {
        get { bool(Key.showValues) }
        set { defaults.set(newValue, forKey: Key.showValues) }
    }

    /// Append the absorption time to carb labels ("30 3h").
    var showAbsorption: Bool {
        get { bool(Key.showAbsorption) }
        set { defaults.set(newValue, forKey: Key.showAbsorption) }
    }

    var showDIALines: Bool {
        get { bool(Key.showDIALines) }
        set { defaults.set(newValue, forKey: Key.showDIALines) }
    }

    var show30MinLine: Bool {
        get { bool(Key.show30MinLine) }
        set { defaults.set(newValue, forKey: Key.show30MinLine) }
    }

    var show90MinLine: Bool {
        get { bool(Key.show90MinLine) }
        set { defaults.set(newValue, forKey: Key.show90MinLine) }
    }

    var showMidnightLines: Bool {
        get { bool(Key.showMidnightLines) }
        set { defaults.set(newValue, forKey: Key.showMidnightLines) }
    }

    /// Overlay yesterday's glucose, shifted forward 24 h, as a dim gray line.
    var showYesterdayLine: Bool {
        get { bool(Key.showYesterdayLine) }
        set { defaults.set(newValue, forKey: Key.showYesterdayLine) }
    }

    var smallGraphTreatments: Bool {
        get { bool(Key.smallGraphTreatments) }
        set { defaults.set(newValue, forKey: Key.smallGraphTreatments) }
    }

    var showSmallGraph: Bool {
        get { bool(Key.showSmallGraph) }
        set { defaults.set(newValue, forKey: Key.showSmallGraph) }
    }

    var showStats: Bool {
        get { bool(Key.showStats) }
        set { defaults.set(newValue, forKey: Key.showStats) }
    }

    /// Report GMI instead of estimated A1C in the statistics row.
    var useGMI: Bool {
        get { bool(Key.useGMI) }
        set { defaults.set(newValue, forKey: Key.useGMI) }
    }

    /// Report coefficient of variation instead of standard deviation.
    var useCoefficientOfVariation: Bool {
        get { bool(Key.useCoefficientOfVariation) }
        set { defaults.set(newValue, forKey: Key.useCoefficientOfVariation) }
    }

    /// Time zone for the x-axis and midnight markers. Loop has no time-zone
    /// override setting, so the axis always follows the device.
    var axisTimeZone: TimeZone? { nil }

    /// Floor for the chart's y-axis top, in mg/dL, so a flat-low day still
    /// renders on a sensible scale.
    var minBGScale: Double { 250 }

    /// Floor for the basal axis, in U/hr. Matches LoopFollow's default, and
    /// keeps a normal basal rate as a low band rather than a wall of colour.
    var minBasalScale: Double { 5 }
}

// MARK: - Glucose unit display

/// Converts the chart's internal mg/dL values into the user's display unit.
///
/// The ported chart keeps all glucose values in mg/dL — thresholds, y-domain
/// and mark positions all assume it — and converts only at the point of
/// display, which is what this provides.
enum BGChartGlucoseDisplay {
    /// The unit the chart labels values in. Set from the status screen, which
    /// owns the `DisplayGlucosePreference`.
    static var unit: HKUnit = .milligramsPerDeciliter

    private static let mgdLFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    private static let mmolLFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 1
        return formatter
    }()

    /// Values to label the glucose axis with, in mg/dL, spaced so that the numbers come
    /// out round in the *display* unit — 4, 6, 8 rather than 3.9, 5.6, 7.2 — and so the
    /// axis carries enough of them to read a level off the curve at a glance.
    ///
    /// Zero is left out: the axis starts there and a "0" reads as a glucose value that
    /// never happens.
    static func axisTicks(upToMGDL maxMGDL: Double, targetCount: Int = 7) -> [Double] {
        let inMMOLL = unit == .millimolesPerLiter
        // Steps that read as round numbers in the unit on screen.
        let steps: [Double] = inMMOLL ? [1, 2, 3, 4, 5, 10] : [20, 25, 50, 100, 200]
        let maxInUnit = inMMOLL
            ? HKQuantity(unit: .milligramsPerDeciliter, doubleValue: maxMGDL).doubleValue(for: .millimolesPerLiter)
            : maxMGDL
        guard maxInUnit > 0 else { return [] }

        // The coarsest step still gives the fewest labels, so this is the first step that
        // keeps the count reasonable.
        let step = steps.first(where: { maxInUnit / $0 <= Double(targetCount) }) ?? steps[steps.count - 1]

        var ticks: [Double] = []
        var value = step
        while value <= maxInUnit {
            ticks.append(inMMOLL
                ? HKQuantity(unit: .millimolesPerLiter, doubleValue: value).doubleValue(for: .milligramsPerDeciliter)
                : value)
            value += step
        }
        return ticks
    }

    /// Formats an mg/dL value in the display unit, without a unit suffix.
    static func string(fromMGDL value: Double) -> String {
        if unit == .millimolesPerLiter {
            let quantity = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: value)
            let converted = quantity.doubleValue(for: .millimolesPerLiter)
            return mmolLFormatter.string(from: NSNumber(value: converted)) ?? String(format: "%.1f", converted)
        }
        return mgdLFormatter.string(from: NSNumber(value: value)) ?? String(Int(value.rounded()))
    }
}
