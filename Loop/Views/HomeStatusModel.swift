//
//  HomeStatusModel.swift
//  Loop
//
//  What the cards at the top of the status screen show: the loop ring, the glucose with
//  trend and delta, the sensor and pod tiles and the four numbers. Laid out like
//  LoopFollow's Home (LoopFollow/Home/*.swift); filled by `StatusTableViewController`
//  from Loop's own managers instead of from Nightscout.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI
import LoopCore

final class HomeStatusModel: ObservableObject {

    // MARK: Loop

    @Published var lastLoopCompleted: Date?
    @Published var isClosedLoop = false
    @Published var loopInProgress = false

    // MARK: Glucose

    struct Glucose: Equatable {
        /// The number, or LOW/HIGH outside the sensor's range.
        var valueText: String
        var valueMGDL: Double
        /// Colour the CGM gave the reading (below/above its range), if any.
        var rangeColor: UIColor?
        var trendSymbol: String?
        var deltaText: String?
        var date: Date
        /// Entered by hand (a fingerstick), which has no trend.
        var isManual: Bool
    }

    @Published var glucose: Glucose?
    /// The unit the glucose is shown in, e.g. "mmol/L".
    @Published var glucoseUnitText = ""

    // MARK: Numbers

    @Published var insulinOnBoardText: String?
    @Published var carbsOnBoardText: String?
    @Published var basalRateText: String?
    @Published var eventualGlucoseText: String?

    // MARK: Devices

    struct Highlight: Equatable {
        var message: String
        var image: UIImage?
        var color: UIColor
    }

    struct Badge: Equatable {
        var image: UIImage?
        var color: UIColor
    }

    struct Device: Equatable {
        var title: String
        var image: UIImage?
        var symbolName: String
        var lifecycle: DeviceLifecycle?
        /// What the device manager itself says about its progress, when it says anything.
        var managerProgress: Double?
        var managerProgressColor: UIColor?
        var highlight: Highlight?
        var badge: Badge?
    }

    @Published var sensor = Device(title: "", image: nil, symbolName: "sensor.tag.radiowaves.forward.fill")
    @Published var pump = Device(title: "", image: nil, symbolName: "cross.vial.fill")
    /// The pump manager's own HUD view (the reservoir on an Omnipod), shown on the pod tile.
    @Published var pumpHUDView: BaseHUDView?

    // MARK: Actions

    var onLoopTapped: (() -> Void)?
    var onGlucoseTapped: (() -> Void)?
    var onSensorTapped: (() -> Void)?
    var onPumpTapped: (() -> Void)?
    var onInsulinTapped: (() -> Void)?
    var onCarbsTapped: (() -> Void)?
    var onForecastTapped: (() -> Void)?
}

// MARK: - Glucose formatting

extension HomeStatusModel {
    /// Readings older than this show as dashes, as Loop's HUD did.
    static let staleGlucoseAge = LoopCoreConstants.inputDataRecencyInterval

    /// "+0,3", "−0,3", "±0,0": the change since the reading about five minutes before.
    static func deltaText(latestDate: Date, latestMGDL: Double, samples: [StoredGlucoseSample]) -> String? {
        // The reading closest to five minutes before, within 4–11 minutes.
        let earlier = samples
            .filter {
                let gap = latestDate.timeIntervalSince($0.startDate)
                return gap >= 4 * 60 && gap <= 11 * 60
            }
            .min { abs(latestDate.timeIntervalSince($0.startDate) - 300) < abs(latestDate.timeIntervalSince($1.startDate) - 300) }
        guard let earlier else { return nil }
        let deltaMGDL = latestMGDL - earlier.quantity.doubleValue(for: .milligramsPerDeciliter)
        let text = BGChartGlucoseDisplay.string(fromMGDL: abs(deltaMGDL))
        // Zero once rounded to what is shown: no digit other than 0 in the text.
        if !text.contains(where: { $0.isNumber && $0 != "0" }) {
            return "±" + text
        }
        return (deltaMGDL > 0 ? "+" : "−") + text
    }

    /// Green in range, yellow high, red low: the colours the chart uses for its dots.
    static func color(forMGDL value: Double) -> Color {
        let settings = BGChartSettings.shared
        if value >= settings.inRangeHighMGDL { return HomePalette.highGlucose }
        if value <= settings.inRangeLowMGDL { return .red }
        return .green
    }
}

// MARK: - Device lifecycle

/// Where a CGM sensor or a pod is in its life, worked out from when it was started.
/// Ported from LoopFollow (DeviceStatus/DeviceLifecycle.swift): warmup, the nominal
/// lifetime, then a grace period.
struct DeviceLifecycle: Equatable {
    enum Phase: Equatable {
        case warmup
        case active
        case grace
        case expired
    }

    enum Level: Equatable {
        case normal
        case warning
        case critical
    }

    let start: Date
    var warmup: TimeInterval = 0
    let lifetime: TimeInterval
    var grace: TimeInterval = 0
    /// Remaining lifetime at which the bar turns from normal to warning.
    var warningThreshold: TimeInterval = 24 * 3600

    var warmupEnd: Date { start.addingTimeInterval(warmup) }
    var expiration: Date { start.addingTimeInterval(lifetime) }
    var graceEnd: Date { expiration.addingTimeInterval(grace) }

    func phase(at now: Date) -> Phase {
        if now < warmupEnd { return .warmup }
        if now < expiration { return .active }
        if now < graceEnd { return .grace }
        return .expired
    }

    /// Time left of the current phase; nil once the device is past its grace period.
    func remaining(at now: Date) -> TimeInterval? {
        switch phase(at: now) {
        case .warmup: return warmupEnd.timeIntervalSince(now)
        case .active: return expiration.timeIntervalSince(now)
        case .grace: return graceEnd.timeIntervalSince(now)
        case .expired: return nil
        }
    }

    /// How full the bar is: warmup fills up to its end, the lifetime fills as it is
    /// used up, and anything past expiry shows a full bar.
    func progress(at now: Date) -> Double {
        let fraction: Double
        switch phase(at: now) {
        case .warmup:
            fraction = now.timeIntervalSince(start) / warmup
        case .active:
            fraction = now.timeIntervalSince(start) / lifetime
        case .grace, .expired:
            fraction = 1
        }
        return min(1, max(0, fraction))
    }

    func level(at now: Date) -> Level {
        switch phase(at: now) {
        case .warmup:
            return .normal
        case .active:
            return expiration.timeIntervalSince(now) <= warningThreshold ? .warning : .normal
        case .grace, .expired:
            return .critical
        }
    }

    /// A sensor's life, by the CGM manager that reads it.
    static func sensor(cgmPluginIdentifier identifier: String?, startedAt start: Date) -> DeviceLifecycle {
        let identifier = (identifier ?? "").lowercased()
        if identifier.contains("g7") {
            // G7SensorKit: 10 days, 27 min warmup, 12 h grace period.
            return DeviceLifecycle(start: start, warmup: 27 * 60, lifetime: 10 * 86400, grace: 12 * 3600)
        }
        if identifier.contains("g6") || identifier.contains("g5") || identifier.contains("dex") {
            return DeviceLifecycle(start: start, warmup: 2 * 3600, lifetime: 10 * 86400)
        }
        if identifier.contains("libre") {
            return DeviceLifecycle(start: start, warmup: 3600, lifetime: 14 * 86400)
        }
        return DeviceLifecycle(start: start, lifetime: 10 * 86400)
    }

    /// A pod's (or an infusion set's) life, by the pump manager that runs it.
    static func pump(isOmnipod: Bool, startedAt start: Date) -> DeviceLifecycle {
        if isOmnipod {
            // OmnipodKit: 72 h nominal life; the pod stops delivering at 80 h.
            return DeviceLifecycle(start: start, lifetime: 72 * 3600, grace: 8 * 3600)
        }
        return DeviceLifecycle(start: start, lifetime: 72 * 3600)
    }
}

extension DeviceLifecycle.Level {
    func color(normal: Color) -> Color {
        switch self {
        case .normal: return normal
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

enum HomeFormat {
    /// "1d 6h" — the short form used on the device tiles.
    static func short(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = interval >= 3600 ? [.day, .hour] : [.minute]
        return formatter.string(from: max(60, interval)) ?? ""
    }

    /// "18 h 43 min", "4 h", "30 min" — a time span in plain words.
    static func hoursMinutes(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int((interval / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 {
            return String(format: NSLocalizedString("%lld min", comment: "A duration in minutes, e.g. how long glucose was low today"), minutes)
        }
        if minutes == 0 {
            return String(format: NSLocalizedString("%lld h", comment: "A duration in hours, e.g. how long glucose was high today"), hours)
        }
        return String(format: NSLocalizedString("%lld h %lld min", comment: "A duration in hours and minutes, e.g. how long glucose was in range today"), hours, minutes)
    }

    /// "3 min", "1 h", "2 d" — how long ago Loop last ran, under the loop ring.
    static func loopAge(lastLoop: Date?, now: Date) -> String {
        guard let lastLoop else { return "–" }
        let minutes = max(0, Int(now.timeIntervalSince(lastLoop) / 60))
        if minutes < 60 {
            return String(format: NSLocalizedString("%lld min", comment: "A duration in minutes, e.g. how long glucose was low today"), minutes)
        }
        let hours = minutes / 60
        if hours < 24 {
            return String(format: NSLocalizedString("%lld h", comment: "A duration in hours, e.g. how long glucose was high today"), hours)
        }
        return String(format: NSLocalizedString("%lld d", comment: "Days since Loop last ran, under the loop ring"), hours / 24)
    }

    /// "78 %", "<1 %" for a small share that would otherwise read as none.
    static func percent(_ percent: Double) -> String {
        if percent > 0, percent < 0.5 {
            return "<" + (0.01).formatted(.percent.precision(.fractionLength(0)))
        }
        return (percent / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}

// MARK: - Today's time in range

/// The plain-language statistics card: how much of today was in range, and how long
/// was spent low, in range and high.
struct TimeInRangeSummary: Equatable {
    struct Band: Equatable {
        /// Share of the readings, 0–100.
        var percent: Double
        /// The same share of the day so far, as time.
        var duration: TimeInterval
    }

    var low = Band(percent: 0, duration: 0)
    var inRange = Band(percent: 0, duration: 0)
    var high = Band(percent: 0, duration: 0)
    var hasData = false

    init() {}

    /// - Parameters:
    ///   - stats: statistics over the readings since midnight.
    ///   - periodSeconds: how long it is since midnight.
    init(stats: GlucoseStats, periodSeconds: TimeInterval) {
        func band(_ percent: Double) -> Band {
            Band(percent: percent, duration: periodSeconds * percent / 100)
        }
        low = band(stats.percentLow)
        inRange = band(stats.percentInRange)
        high = band(stats.percentHigh)
        hasData = stats.readingCount > 0
    }

    /// "Today: 78 % in range".
    var headline: String {
        let percent = hasData ? HomeFormat.percent(inRange.percent) : "–"
        return String(format: NSLocalizedString("Today: %@ in range", comment: "Headline of the time-in-range card on the status screen (1: percentage)"), percent)
    }

    static func durationText(_ band: Band, hasData: Bool) -> String {
        guard hasData else { return "" }
        return HomeFormat.hoursMinutes(band.duration)
    }
}

/// Today's time in range, for the statistics card.
final class TimeInRangeModel: ObservableObject {
    @Published var summary = TimeInRangeSummary()
}
