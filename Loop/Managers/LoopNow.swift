//
//  LoopNow.swift
//  Loop
//
//  What Loop knows right now — glucose and its trend, insulin and carbs on board, its forecast and
//  the bolus it would recommend — for the AI text that looks at the moment, the insight's "now".
//  Read from the loop's own state, not from Nightscout, so it is never older
//  than the last loop.
//

import Foundation
import HealthKit
import LoopKit

struct LoopNow: Codable, Equatable {
    struct Point: Codable, Equatable {
        /// Minutes from now: negative in the past, positive in the forecast.
        var minutes: Int
        var mmol: Double
    }

    var date: Date
    var glucoseMmol: Double?
    var glucoseMinutesAgo: Int?
    var change15MinMmol: Double?
    /// Every 15 minutes over the last hour, oldest first.
    var lastHour: [Point]
    var insulinOnBoardUnits: Double?
    var carbsOnBoardGrams: Double?
    /// Loop's forecast 30, 60, 90, 120 and 180 minutes on.
    var forecast: [Point]
    /// The lowest Loop expects within three hours.
    var lowestForecastMmol: Double?
    /// What Loop would recommend if a bolus were asked for now.
    var loopRecommendedBolusUnits: Double?
    var activeOverride: String?

    /// Set once the loop is running (see DeviceDataManager).
    static var provider: (() async -> LoopNow?)?

    static func current() async -> LoopNow? {
        await provider?()
    }

    static func mmol(_ quantity: HKQuantity) -> Double {
        (quantity.doubleValue(for: .millimolesPerLiter) * 10).rounded() / 10
    }

    /// Builds the snapshot from the loop's values.
    static func make(
        now: Date,
        glucose: [GlucoseValue],
        insulinOnBoard: Double?,
        carbsOnBoard: Double?,
        forecast: [GlucoseValue],
        recommendedBolus: Double?,
        activeOverride: String?
    ) -> LoopNow {
        let sorted = glucose.sorted { $0.startDate < $1.startDate }
        let latest = sorted.last
        func reading(near date: Date) -> GlucoseValue? {
            sorted.min { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }
                .flatMap { abs($0.startDate.timeIntervalSince(date)) <= .minutes(4) ? $0 : nil }
        }
        let change = latest.flatMap { last in
            reading(near: last.startDate.addingTimeInterval(.minutes(-15))).map { ((mmol(last.quantity) - mmol($0.quantity)) * 10).rounded() / 10 }
        }
        let lastHour = stride(from: -60, through: 0, by: 15).compactMap { minutes -> Point? in
            reading(near: now.addingTimeInterval(.minutes(Double(minutes)))).map { Point(minutes: minutes, mmol: mmol($0.quantity)) }
        }
        let future = forecast.filter { $0.startDate > now && $0.startDate <= now.addingTimeInterval(.hours(3)) }
        let points = [30, 60, 90, 120, 180].compactMap { minutes -> Point? in
            let date = now.addingTimeInterval(.minutes(Double(minutes)))
            return future.min { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }
                .flatMap { abs($0.startDate.timeIntervalSince(date)) <= .minutes(5) ? Point(minutes: minutes, mmol: mmol($0.quantity)) : nil }
        }
        return LoopNow(
            date: now,
            glucoseMmol: latest.map { mmol($0.quantity) },
            glucoseMinutesAgo: latest.map { Int(now.timeIntervalSince($0.startDate) / 60) },
            change15MinMmol: change,
            lastHour: lastHour,
            insulinOnBoardUnits: insulinOnBoard.map { ($0 * 100).rounded() / 100 },
            carbsOnBoardGrams: carbsOnBoard.map { $0.rounded() },
            forecast: points,
            lowestForecastMmol: future.map { mmol($0.quantity) }.min(),
            loopRecommendedBolusUnits: recommendedBolus.map { ($0 * 100).rounded() / 100 },
            activeOverride: activeOverride
        )
    }
}
