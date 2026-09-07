//
//  GlucoseStats.swift
//  Loop
//
//  Time-in-range statistics for the status screen, matching the summary
//  LoopFollow shows under its chart.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit

/// Time-in-range and variability over a set of glucose readings.
///
/// All arithmetic is done in mg/dL — the unit the readings are compared in —
/// and converted to the display unit only by `StatsDisplayModel`.
struct GlucoseStats {
    let readingCount: Int
    let percentLow: Double
    let percentInRange: Double
    let percentHigh: Double
    /// Mean glucose, mg/dL.
    let averageMGDL: Double
    /// Population standard deviation, mg/dL.
    let standardDeviationMGDL: Double
    /// Standard deviation as a percentage of the mean.
    let coefficientOfVariation: Double

    /// - Parameters:
    ///   - samples: readings to summarise. Manually entered values are included;
    ///     they are as real as CGM readings for time in range.
    ///   - low: below this (mg/dL) counts as low.
    ///   - high: above this (mg/dL) counts as high.
    init(samples: [StoredGlucoseSample], low: Double, high: Double) {
        let values = samples.map { $0.quantity.doubleValue(for: .milligramsPerDeciliter) }
        self.init(values: values, low: low, high: high)
    }

    init(values: [Double], low: Double, high: Double) {
        readingCount = values.count
        guard !values.isEmpty else {
            percentLow = 0
            percentInRange = 0
            percentHigh = 0
            averageMGDL = 0
            standardDeviationMGDL = 0
            coefficientOfVariation = 0
            return
        }

        var countLow = 0
        var countHigh = 0
        var total = 0.0
        for value in values {
            if value < low {
                countLow += 1
            } else if value > high {
                countHigh += 1
            }
            total += value
        }
        let count = Double(values.count)
        percentLow = Double(countLow) / count * 100
        percentHigh = Double(countHigh) / count * 100
        percentInRange = 100 - percentLow - percentHigh

        let mean = total / count
        averageMGDL = mean

        let sumOfSquares = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        let sigma = (sumOfSquares / count).squareRoot()
        standardDeviationMGDL = sigma
        coefficientOfVariation = mean > 0 ? sigma / mean * 100 : 0
    }

    /// Estimated HbA1c (%), from the Nathan et al. regression on mean glucose.
    var estimatedA1C: Double {
        (averageMGDL + 46.7) / 28.7
    }

    /// Glucose Management Indicator (%), from Bergenstal et al.
    var glucoseManagementIndicator: Double {
        3.31 + 0.02392 * averageMGDL
    }
}

extension StatsDisplayModel {
    /// Renders a `GlucoseStats` into the strings the summary row displays.
    func update(with stats: GlucoseStats, useGMI: Bool, useCoefficientOfVariation: Bool) {
        guard stats.readingCount > 0 else {
            lowPercent = "—"
            inRangePercent = "—"
            highPercent = "—"
            avgBG = "—"
            estA1C = "—"
            stdDev = "—"
            pieLow = 0
            pieRange = 0
            pieHigh = 0
            return
        }

        lowPercent = String(format: "%.1f%%", stats.percentLow)
        inRangePercent = String(format: "%.1f%%", stats.percentInRange)
        highPercent = String(format: "%.1f%%", stats.percentHigh)
        avgBG = BGChartGlucoseDisplay.string(fromMGDL: stats.averageMGDL)

        estA1CTitle = useGMI
            ? NSLocalizedString("GMI:", comment: "Title of the glucose management indicator statistic")
            : NSLocalizedString("Est. A1C:", comment: "Title of the estimated A1C statistic")
        estA1C = String(format: "%.1f%%", useGMI ? stats.glucoseManagementIndicator : stats.estimatedA1C)

        if useCoefficientOfVariation {
            stdDevTitle = NSLocalizedString("CV:", comment: "Title of the coefficient of variation statistic")
            stdDev = String(format: "%.1f%%", stats.coefficientOfVariation)
        } else {
            stdDevTitle = NSLocalizedString("Std Dev:", comment: "Title of the standard deviation statistic")
            stdDev = BGChartGlucoseDisplay.string(fromMGDL: stats.standardDeviationMGDL)
        }

        pieLow = stats.percentLow
        pieRange = stats.percentInRange
        pieHigh = stats.percentHigh
    }
}
