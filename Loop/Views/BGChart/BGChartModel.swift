//
//  BGChartModel.swift
//  Loop
//
//  Data model behind the interactive glucose chart, ported from LoopFollow
//  (LoopFollow/Charts/BGChartModel.swift). The mark/series types and the
//  treatment-decluttering logic are unchanged. LoopFollow's `performRebuild()`,
//  which pulled from its own view controller's Nightscout arrays, is replaced
//  by `BGChartModel+Loop.swift`, which fills the same properties from Loop's
//  stores.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import SwiftUI

/// Interaction state shared between the main chart (which owns the gestures)
/// and the small overview chart (which shows a viewport box and navigates on
/// tap). Kept separate from BGChartModel so high-frequency pan/zoom writes
/// don't invalidate views that only observe the data.
final class BGChartInteraction: ObservableObject {
    /// Date at the leading (left) edge of the main chart's visible window.
    @Published var scrollPosition: Date
    /// Length of the visible x-axis window in seconds.
    @Published var visibleSeconds: TimeInterval
    /// True while the main chart should keep auto-scrolling to "now"; cleared
    /// when the user pans back into history, re-armed when they return to the edge.
    @Published var followLatest: Bool = true

    init() {
        let seconds = Self.clampedVisibleSeconds(BGChartSettings.shared.visibleHours * 3600)
        visibleSeconds = seconds
        scrollPosition = Date().addingTimeInterval(-seconds * 0.7)
    }

    /// Clamps a visible-window length to the zoom range the chart supports.
    static func clampedVisibleSeconds(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds > 0 else { return 6 * 3600 }
        return min(max(seconds, 15 * 60), 24 * 3600)
    }

    /// Persists the current zoom so it survives relaunches.
    func persistZoom() {
        BGChartSettings.shared.visibleHours = visibleSeconds / 3600
    }
}

final class BGChartModel: ObservableObject {
    struct BGPoint: Identifiable {
        let date: Date
        let value: Double
        let color: Color
        var id: Double { date.timeIntervalSince1970 }
    }

    /// Vertical band a treatment symbol is drawn in, relative to the glucose
    /// curve it hangs off. Carbs ride above the curve and insulin below it —
    /// the reading Nightscout and LoopFollow use — and pump events get a band
    /// of their own further out, so treatments logged in the same minute never
    /// land on the same pixel and hide one another.
    ///
    /// The offset is a fraction of the y-domain rather than a fixed mg/dL
    /// amount, so a lane keeps the same on-screen distance from the curve
    /// however far the y-axis is scaled.
    enum TreatmentLane {
        /// Drawn exactly on the curve. For marks that *are* a glucose value.
        case onCurve
        case carbs
        case insulin
        case pumpEvent
        case note

        var offsetFraction: Double {
            switch self {
            case .onCurve: return 0
            case .carbs: return 0.05
            case .insulin: return -0.05
            case .pumpEvent: return -0.13
            case .note: return 0.13
            }
        }
    }

    struct TreatmentPoint: Identifiable {
        let date: Date
        let value: Double
        let sgv: Double
        let label: String
        let pillText: String
        /// Which vertical band the symbol is drawn in; see `TreatmentLane`.
        let lane: TreatmentLane
        /// The carb entry this mark stands for, when it is one the user may edit. The
        /// chart offers a way into the carb editor for marks that have it.
        let carbEntryID: String?
        /// Where the symbol is drawn. Equals `date` unless `spread` nudged it
        /// left to keep a crowded run of treatments from stacking up.
        var drawnDate: Date
        var id: Double { date.timeIntervalSince1970 }

        init(date: Date, value: Double, sgv: Double, label: String, pillText: String, lane: TreatmentLane = .onCurve, carbEntryID: String? = nil) {
            self.date = date
            self.value = value
            self.sgv = sgv
            self.label = label
            self.pillText = pillText
            self.lane = lane
            self.carbEntryID = carbEntryID
            drawnDate = date
        }
    }

    struct BasalStep: Identifiable {
        let start: Date
        let end: Date
        let rate: Double
        var id: TimeInterval { start.timeIntervalSince1970 }
    }

    struct ScheduledBasalPoint: Identifiable {
        let date: Date
        let rate: Double
        var id: TimeInterval { date.timeIntervalSince1970 }
    }

    struct BandRect: Identifiable {
        let start: Date
        let end: Date
        let yBottom: Double
        let yTop: Double
        let label: String
        let pillText: String
        var id: String { "\(start.timeIntervalSince1970)-\(end.timeIntervalSince1970)" }
    }

    struct ConePoint: Identifiable {
        let date: Date
        let yMin: Double
        let yMax: Double
        var id: Double { date.timeIntervalSince1970 }
    }

    /// A maximal stretch of consecutive BG readings sharing one range color.
    /// Each run renders as a single LineMark series; runs share their boundary
    /// point so the line stays visually continuous across color changes.
    /// (One series per run — tens per day — instead of one per segment, which
    /// was a Swift Charts layout hotspot at hundreds of series.)
    struct BGRun: Identifiable {
        let id: Int
        let color: Color
        let points: [BGPoint]
    }

    @Published var bg: [BGPoint] = []
    @Published var bgRuns: [BGRun] = []
    @Published var yesterday: [BGPoint] = []
    @Published var prediction: [BGPoint] = []
    @Published var ztPrediction: [BGPoint] = []
    @Published var iobPrediction: [BGPoint] = []
    @Published var cobPrediction: [BGPoint] = []
    @Published var uamPrediction: [BGPoint] = []

    /// Prediction cone band (min/max envelope). Set by updateOpenAPSPredictionDisplay;
    /// preserved across rebuild() since it has no source array on the view controller.
    /// The didSet keeps the canvas generation in sync for call sites that assign the
    /// cone directly without triggering a rebuild.
    @Published var cone: [ConePoint] = [] {
        didSet { generation &+= 1 }
    }

    @Published var basal: [BasalStep] = []
    @Published var basalScheduled: [ScheduledBasalPoint] = []

    @Published var boluses: [TreatmentPoint] = []
    @Published var carbs: [TreatmentPoint] = []
    /// Boluses Loop gave on its own. Drawn as a downward triangle rather than a dot,
    /// the way LoopFollow separates a dose the algorithm gave from one a person did.
    @Published var automaticBoluses: [TreatmentPoint] = []
    @Published var bgChecks: [TreatmentPoint] = []
    @Published var suspends: [TreatmentPoint] = []
    @Published var resumes: [TreatmentPoint] = []
    @Published var sensorStarts: [TreatmentPoint] = []
    @Published var notes: [TreatmentPoint] = []

    @Published var overrides: [BandRect] = []
    @Published var tempTargets: [BandRect] = []

    /// The correction-range schedule drawn as a band behind everything else.
    /// LoopFollow has no equivalent (Nightscout followers don't see the target
    /// schedule); it is here so the target range Loop's own chart draws is not
    /// lost in the port.
    @Published var targetRanges: [BandRect] = []

    // Backend-aware band colors: Loop draws overrides green / temp targets purple,
    // Trio (and other OpenAPS backends) use the inverse. Mirrors TreatmentGraphColors.
    @Published var overrideColor: Color = .green
    @Published var tempTargetColor: Color = .purple

    @Published var maxBG: Double = 250
    @Published var maxBasal: Double = 5
    @Published var lowLine: Double = 70
    @Published var highLine: Double = 180
    @Published var domainStart: Date = .init(timeIntervalSince1970: 0)
    @Published var domainEnd: Date = .init(timeIntervalSince1970: 0)

    @Published var now: Date = .init()
    @Published var diaMarkers: [Date] = []
    @Published var midnightMarkers: [Date] = []
    @Published var thirtyMinMark: Date? = nil
    @Published var ninetyMinMark: Date? = nil

    /// Shared pan/zoom/follow state (see BGChartInteraction). A separate object so
    /// per-frame gesture writes don't invalidate views that only observe the data.
    let interaction = BGChartInteraction()

    /// Monotonic data version. Bumped whenever chart data changes; the chart
    /// canvases use it (instead of comparing arrays) to decide whether a
    /// re-layout is needed, so panning — which changes none of the data — can
    /// provably skip their bodies.
    private(set) var generation: Int = 0

    @Published var showLines: Bool = true
    @Published var showDots: Bool = true
    @Published var showDIA: Bool = true
    @Published var show30Min: Bool = false
    @Published var show90Min: Bool = false
    @Published var showMidnight: Bool = false
    @Published var smallGraphTreatments: Bool = true

    private static let doseFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.locale = .current
        nf.numberStyle = .decimal
        nf.usesGroupingSeparator = false
        nf.minimumIntegerDigits = 0
        nf.minimumFractionDigits = 0
        nf.maximumFractionDigits = 2
        return nf
    }()

    private func formatDose(_ value: Double) -> String {
        Self.doseFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Formatter for the time line at the bottom of every selection pill.
    /// Recreated on each rebuild so 12/24-hour and graph-time-zone settings apply.
    private var pillTimeFormatter = BGChartModel.makePillTimeFormatter()

    private static func makePillTimeFormatter() -> DateFormatter {
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .short
        if let tz = BGChartSettings.shared.axisTimeZone {
            df.timeZone = tz
        }
        return df
    }

    /// The pill's time line for a given point in time.
    func pillTimeString(for date: Date) -> String {
        pillTimeFormatter.string(from: date)
    }

    /// Nightscout remote-command error notes embed a JSON payload after
    /// the human-readable message ("Error text {\"bolus-entry\": 1.5, ...}").
    /// Returns the message plus a compact summary of the payload, or nil when
    /// the note contains no JSON.
    private static func extractMessage(from note: String) -> String? {
        guard let jsonStartIndex = note.range(of: "{\"")?.lowerBound else {
            return nil
        }

        let errorMessage = String(note[..<jsonStartIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var actionContext = ""
        if let jsonData = String(note[jsonStartIndex...]).data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        {
            var actionParts: [String] = []
            if let bolusAmount = json["bolus-entry"] as? Double {
                actionParts.append("Bolus: \(bolusAmount) U")
            }
            if let carbsAmount = json["carbs-entry"] as? Double {
                actionParts.append("Carbs: \(carbsAmount) g")
            }
            if let absorptionTime = json["absorption-time"] as? Double {
                actionParts.append("Absorption: \(absorptionTime) hrs")
            }
            if let otp = json["otp"] as? String {
                actionParts.append("OTP: \(otp)")
            }
            if let enteredBy = json["entered-by"] as? String {
                actionParts.append("From: \(enteredBy)")
            }
            if !actionParts.isEmpty {
                actionContext = " [" + actionParts.joined(separator: ", ") + "]"
            }
        }

        let finalMessage = errorMessage + actionContext
        return finalMessage.isEmpty ? nil : finalMessage
    }

    private func colorFor(_ sgv: Int, thresholds: (low: Double, high: Double)) -> Color {
        if Double(sgv) >= thresholds.high {
            return .yellow
        } else if Double(sgv) <= thresholds.low {
            return .red
        } else {
            return .green
        }
    }

    /// Groups consecutive same-colored readings into line runs (see BGRun).
    /// The segment between two points takes the color of the earlier point.
    static func makeRuns(_ points: [BGPoint]) -> [BGRun] {
        guard let first = points.first else { return [] }
        var runs: [BGRun] = []
        var runColor = first.color
        var runPoints: [BGPoint] = [first]
        for pt in points.dropFirst() {
            runPoints.append(pt)
            if pt.color != runColor {
                runs.append(BGRun(id: runs.count, color: runColor, points: runPoints))
                runPoints = [pt]
                runColor = pt.color
            }
        }
        if runPoints.count > 1 {
            runs.append(BGRun(id: runs.count, color: runColor, points: runPoints))
        }
        return runs
    }

    /// Minimum drawn spacing between two treatments of the same population, and
    /// the furthest a treatment may be moved from its true time to reach it.
    /// Only treatments sharing a lane can collide, so each lane is decluttered
    /// on its own: manual and automatic boluses share the insulin lane and its
    /// symbol footprint, while carbs carry a wider "30 3h" label, so they need —
    /// and are allowed — more room in theirs.
    enum Spread {
        static let bolusGap: TimeInterval = 240
        static let bolusShift: TimeInterval = 240
        static let carbGap: TimeInterval = 250
        static let carbShift: TimeInterval = 250
    }

    /// Nudges crowded treatments left so their symbols don't stack. The newest
    /// point in a run keeps its true time and earlier ones give way, never by
    /// more than `maxShift` — so a treatment is at most `maxShift` from where it
    /// really happened, and an isolated one never moves at all.
    static func spread(_ points: [TreatmentPoint], minGap: TimeInterval, maxShift: TimeInterval) -> [TreatmentPoint] {
        var out = points.sorted { $0.date < $1.date }
        spreadSorted(&out, minGap: minGap, maxShift: maxShift)
        return out
    }

    /// Spreads two treatment kinds as a single population — a bolus dot and an
    /// automatic-bolus triangle drawn at the same minute overlap just like two dots
    /// would — then hands each kind back its own points.
    static func spreadTogether(_ first: [TreatmentPoint], _ second: [TreatmentPoint], minGap: TimeInterval, maxShift: TimeInterval) -> ([TreatmentPoint], [TreatmentPoint]) {
        let tagged = (first.map { (isFirst: true, point: $0) } + second.map { (isFirst: false, point: $0) })
            .sorted { $0.point.date < $1.point.date }
        var points = tagged.map(\.point)
        spreadSorted(&points, minGap: minGap, maxShift: maxShift)
        var outFirst: [TreatmentPoint] = []
        var outSecond: [TreatmentPoint] = []
        for (tag, point) in zip(tagged, points) {
            if tag.isFirst {
                outFirst.append(point)
            } else {
                outSecond.append(point)
            }
        }
        return (outFirst, outSecond)
    }

    /// `points` must be sorted ascending by `date`.
    private static func spreadSorted(_ out: inout [TreatmentPoint], minGap: TimeInterval, maxShift: TimeInterval) {
        guard out.count > 1 else { return }

        // Walking left from the newest point, each point yields to its right
        // neighbor until it hits its own left bound (`date - maxShift`).
        var clamped = [Bool](repeating: false, count: out.count)
        for i in stride(from: out.count - 2, through: 0, by: -1) {
            let wanted = out[i + 1].drawnDate.addingTimeInterval(-minGap)
            guard out[i].drawnDate > wanted else { continue }
            let leftBound = out[i].date.addingTimeInterval(-maxShift)
            if wanted <= leftBound {
                out[i].drawnDate = leftBound
                clamped[i] = true
            } else {
                out[i].drawnDate = wanted
            }
        }

        // A chain of clamped points was squeezed against its left bound and may
        // have piled up there (several same-time treatments all land at
        // date - maxShift). Re-space each chain evenly between that bound and
        // the first point to its right that still had room.
        var i = 0
        while i < out.count - 1 {
            guard clamped[i] else {
                i += 1
                continue
            }
            var last = i
            while clamped[last + 1] {
                last += 1
            }
            let anchorIndex = last + 1
            let anchor = out[anchorIndex].drawnDate
            let leftBound = out[i].date.addingTimeInterval(-maxShift)
            let spacing = anchor.timeIntervalSince(leftBound) / Double(anchorIndex - i)
            for k in i ... last {
                let ideal = anchor.addingTimeInterval(-spacing * Double(anchorIndex - k))
                let boundK = out[k].date.addingTimeInterval(-maxShift)
                out[k].drawnDate = min(max(ideal, boundK), out[k].date)
            }
            i = anchorIndex + 1
        }
    }

    /// Marks the end of a batch of data assignments. Bumps the generation the
    /// chart canvases compare against, so one re-layout covers the whole batch.
    /// `BGChartModel+Loop.swift` calls this; nothing else should need to.
    func didUpdateData() {
        pillTimeFormatter = Self.makePillTimeFormatter()
        generation &+= 1
    }
}
