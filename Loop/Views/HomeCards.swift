//
//  HomeCards.swift
//  Loop
//
//  The cards of the status screen, laid out like LoopFollow's Home (LoopFollow/Home/*.swift
//  and DeviceStatus/DeviceStatusViews.swift): the loop ring with a large glucose, trend and
//  delta; the sensor and pod tiles; four numbers; the chart with a 3/6/12/24 h control; and
//  today's time in range. Each sits on a rounded card on the grouped background.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import LoopKit
import LoopKitUI
import LoopCore

// MARK: - Card style

/// The rounded card every block on the status screen sits on: a raised surface on the
/// grouped background, light and dark.
struct HomeCard: ViewModifier {
    var padding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HomeLayout.cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }
}

extension View {
    func homeCard(padding: CGFloat = 12) -> some View {
        modifier(HomeCard(padding: padding))
    }
}

enum HomeLayout {
    static let cornerRadius: CGFloat = 14
    /// Space between the cards and the screen edge.
    static let horizontalMargin: CGFloat = 12
    /// Space above and below each card, so two cards are twice this apart.
    static let verticalMargin: CGFloat = 4
}

/// Tints for labels and icons. The system colours are too light to read as text on
/// white, so light mode gets a darker shade of the same hue.
enum HomePalette {
    static let insulin = adaptive(light: UIColor(red: 0.70, green: 0.31, blue: 0.00, alpha: 1), dark: .systemOrange)
    static let carbs = adaptive(light: UIColor(red: 0.11, green: 0.50, blue: 0.22, alpha: 1), dark: .systemGreen)
    static let basal = adaptive(light: UIColor(red: 0.12, green: 0.37, blue: 0.82, alpha: 1), dark: UIColor(red: 0.39, green: 0.62, blue: 1.00, alpha: 1))
    static let prediction = adaptive(light: UIColor(red: 0.43, green: 0.25, blue: 0.85, alpha: 1), dark: UIColor(red: 0.69, green: 0.55, blue: 1.00, alpha: 1))
    /// The chosen segment of a segmented control, as UIKit draws it.
    static let selectedSegment = adaptive(light: .white, dark: .systemGray3)
    /// Yellow darkened so a high glucose can be read on white.
    static let highGlucose = adaptive(light: UIColor(red: 0.72, green: 0.53, blue: 0.00, alpha: 1), dark: .systemYellow)

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// Loop's status ring: a thick circle coloured by how fresh the last loop is. An open
/// loop leaves a gap at the top, as Loop's own loop icon does.
struct LoopRingView: View {
    let freshness: LoopCompletionFreshness
    var isOpenLoop: Bool = false
    var isRunning: Bool = false
    var lineWidth: CGFloat = 6

    @State private var pulse = false

    var body: some View {
        Circle()
            .trim(from: isOpenLoop ? 0.08 : 0, to: isOpenLoop ? 0.92 : 1)
            .rotation(.degrees(-90))
            .stroke(Color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .padding(lineWidth / 2)
            .opacity(isRunning && pulse ? 0.35 : 1)
            .animation(isRunning ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = isRunning }
            .onChange(of: isRunning) { running in pulse = running }
    }

    private var color: UIColor {
        switch freshness {
        case .fresh: return .freshColor
        case .aging: return .agingColor
        case .stale: return .staleColor
        }
    }
}

// MARK: - Top of the screen

/// Everything above the chart: the loop and glucose card, the sensor and pod tiles and the
/// four numbers. One table row, so the table keeps its sections as they were.
struct HomeHeaderView: View {
    @ObservedObject var model: HomeStatusModel
    /// Only measured, never shown: leaves the pump manager's view (a single UIView) to the
    /// header on screen, which would otherwise lose it to this copy.
    var isForMeasuring = false

    var body: some View {
        VStack(spacing: HomeLayout.verticalMargin * 2) {
            HomeGlucoseCard(model: model)
            HomeDeviceTiles(model: model)
            HomeNumbersCard(model: model)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

/// The loop ring with its age, and the glucose with trend, delta and age in large type.
struct HomeGlucoseCard: View {
    @ObservedObject var model: HomeStatusModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            HStack(alignment: .center, spacing: 12) {
                loopColumn(now: context.date)
                glucoseColumn(now: context.date)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: HomeLayout.cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    // MARK: Loop ring

    private func loopColumn(now: Date) -> some View {
        let lastLoop = model.lastLoopCompleted
        let freshness = LoopCompletionFreshness(age: lastLoop.map { max(0, now.timeIntervalSince($0)) })
        return Button {
            model.onLoopTapped?()
        } label: {
            VStack(spacing: 4) {
                LoopRingView(freshness: freshness, isOpenLoop: !model.isClosedLoop, isRunning: model.loopInProgress)
                    .frame(width: 38, height: 38)
                Text(HomeFormat.loopAge(lastLoop: lastLoop, now: now))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(freshness == .stale ? Color.red : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loopAccessibilityLabel(lastLoop: lastLoop, now: now))
        .accessibilityHint(NSLocalizedString("Shows last loop error", comment: "Loop Completion HUD accessibility hint"))
        .accessibilityAddTraits(.isButton)
    }

    private func loopAccessibilityLabel(lastLoop: Date?, now: Date) -> String {
        guard lastLoop != nil else {
            return NSLocalizedString("Waiting for first run", comment: "Accessibility label of the loop ring before Loop has run")
        }
        return String(format: NSLocalizedString("Loop ran %@ ago", comment: "Accessibility label of the loop ring (1: e.g. 2 min)"), HomeFormat.loopAge(lastLoop: lastLoop, now: now))
    }

    // MARK: Glucose

    private func glucoseColumn(now: Date) -> some View {
        let glucose = model.glucose
        let isCurrent = glucose.map { now.timeIntervalSince($0.date) <= HomeStatusModel.staleGlucoseAge } ?? false
        let valueText = isCurrent ? glucose!.valueText : "– – –"
        let valueColor: Color = {
            guard isCurrent, let glucose else { return .secondary }
            if let rangeColor = glucose.rangeColor { return Color(rangeColor) }
            return HomeStatusModel.color(forMGDL: glucose.valueMGDL)
        }()
        let trend = isCurrent && glucose?.isManual == false ? glucose?.trendSymbol : nil
        let delta = isCurrent && glucose?.isManual == false ? glucose?.deltaText : nil

        return Button {
            model.onGlucoseTapped?()
        } label: {
            // The big number's line has room under the digits; the age sits up against them.
            VStack(alignment: .center, spacing: -3) {
                HStack(alignment: .center, spacing: 10) {
                    Text(valueText)
                        // No current reading: dashes, as Loop's HUD showed, in a size that
                        // does not read as a value.
                        .font(.system(size: isCurrent ? 84 : 60, weight: isCurrent ? .black : .semibold))
                        .monospacedDigit()
                        .foregroundStyle(valueColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .layoutPriority(1)
                    if trend != nil || delta != nil {
                        VStack(alignment: .leading, spacing: -4) {
                            if let trend {
                                Text(trend)
                                    .font(.system(size: 50, weight: .black))
                            }
                            if let delta {
                                Text(delta)
                                    .font(.system(size: 30, weight: .bold))
                                    .monospacedDigit()
                            }
                        }
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    }
                }
                // Counts every second, as LoopFollow's.
                TimelineView(.periodic(from: .now, by: 1)) { second in
                    let detail = [model.glucoseUnitText, glucose.map { Self.ageText(of: $0.date, now: second.date) } ?? ""]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.subheadline.weight(.medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// "1 min ago" under the glucose.
    private static func ageText(of date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        let duration = "\(seconds / 60):" + String(format: "%02d", seconds % 60)
        return String(format: NSLocalizedString("%@ min ago", comment: "How long ago the glucose shown was measured, under the glucose value, e.g. 2:15 min ago (1: minutes:seconds)"), duration)
    }
}

// MARK: - Sensor and pod

/// Two tiles under the glucose — sensor and pod — each on its own card with the time left
/// and a lifecycle bar. A status from the device (signal loss, pod expired…) takes the
/// place of the time left, in its colour. Tapping opens what tapping the HUD opened.
struct HomeDeviceTiles: View {
    @ObservedObject var model: HomeStatusModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 10) {
                Button { model.onSensorTapped?() } label: {
                    HomeDeviceTile(device: model.sensor, tint: .teal, now: context.date)
                }
                Button { model.onPumpTapped?() } label: {
                    HomeDeviceTile(device: model.pump, tint: .blue, now: context.date)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

struct HomeDeviceTile: View {
    let device: HomeStatusModel.Device
    let tint: Color
    let now: Date

    var body: some View {
        let level = device.lifecycle?.level(at: now) ?? .normal
        // As LoopFollow: the time since the change decides; the manager's own progress only
        // when the change is not known.
        let progress = device.lifecycle?.progress(at: now) ?? device.managerProgress
        let barColor: Color = {
            if device.lifecycle == nil, let managerColor = device.managerProgressColor { return Color(managerColor) }
            return device.lifecycle == nil ? .secondary : level.color(normal: tint)
        }()

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                icon
                    .frame(width: 24, height: 24)
                    .overlay(alignment: .topTrailing) {
                        if let badge = device.badge {
                            Image(uiImage: badge.image ?? UIImage())
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 12, height: 12)
                                .foregroundStyle(Color(badge.color))
                                .offset(x: 5, y: -5)
                        }
                    }
                VStack(alignment: .leading, spacing: 0) {
                    Text(device.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let highlight = device.highlight {
                        HStack(spacing: 3) {
                            if let image = highlight.image {
                                Image(uiImage: image.withRenderingMode(.alwaysTemplate))
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 14, height: 14)
                            }
                            Text(highlight.message.replacingOccurrences(of: "\n", with: " "))
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(Color(highlight.color))
                    } else {
                        Text(remainingText)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(level == .normal ? Color.primary : barColor)
                    }
                }
                Spacer(minLength: 2)
                if let reservoir = device.reservoir {
                    HStack(spacing: 4) {
                        ReservoirGauge(fill: reservoir.fill, color: reservoir.level.color(normal: tint))
                            .frame(width: 12, height: 16)
                        Text(reservoir.text)
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle(reservoir.level.color(normal: .primary))
                    }
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            LifecycleBar(progress: progress ?? 0, color: barColor)
                .frame(height: 4)
                .opacity(progress == nil ? 0.5 : 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeLayout.cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .contentShape(RoundedRectangle(cornerRadius: HomeLayout.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var icon: some View {
        if let assetName = device.assetName {
            Image(assetName)
                .resizable()
                .scaledToFit()
        } else if let image = device.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: device.symbolName)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
        }
    }

    private var remainingText: String {
        guard let lifecycle = device.lifecycle else { return "—" }
        switch lifecycle.phase(at: now) {
        case .warmup:
            return "⏳ " + HomeFormat.short(lifecycle.remaining(at: now) ?? 0)
        case .active, .grace:
            return HomeFormat.short(lifecycle.remaining(at: now) ?? 0)
        case .expired:
            return NSLocalizedString("Expired", comment: "Tile text when a sensor or pod is past its end")
        }
    }
}

/// A thicker lifecycle bar than ProgressView draws, so it reads at a glance.
private struct LifecycleBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.systemFill))
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
    }
}

/// The pod reservoir drawing from OmnipodKit, filled to the level left (as LoopFollow's).
struct ReservoirGauge: View {
    let fill: Double
    let color: Color

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let offset = geometry.size.height * 0.05
                let fillHeight = geometry.size.height * 0.81
                Rectangle()
                    .fill(color)
                    .mask(Image("pod_reservoir_mask_swiftui").resizable().scaledToFit())
                    .mask(
                        Rectangle().path(in: CGRect(x: 0,
                                                    y: offset + fillHeight - fillHeight * fill,
                                                    width: geometry.size.width,
                                                    height: fillHeight * fill))
                    )
            }
            Image("pod_reservoir_swiftui")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(color)
        }
    }
}

// MARK: - The four numbers

/// Insulin on board, carbs on board, the basal rate running now and where Loop expects
/// the glucose to end up. Each opens the screen behind it, as the charts below do.
struct HomeNumbersCard: View {
    @ObservedObject var model: HomeStatusModel

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            number(label: NSLocalizedString("Active Insulin", comment: "The title of the Insulin On-Board graph"),
                   value: model.insulinOnBoardText, tint: HomePalette.insulin, action: model.onInsulinTapped)
            number(label: NSLocalizedString("Active carbs", comment: "Status screen: carbs on board, above the number"),
                   value: model.carbsOnBoardText, tint: HomePalette.carbs, action: model.onCarbsTapped)
            number(label: NSLocalizedString("Basal", comment: "Status screen: the basal rate running now, above the number"),
                   value: model.basalRateText, tint: HomePalette.basal, action: model.onInsulinTapped)
            number(label: NSLocalizedString("Forecast", comment: "Status screen: where Loop expects the glucose to end up, above the number"),
                   value: model.eventualGlucoseText, tint: HomePalette.prediction, action: model.onForecastTapped)
        }
        .fixedSize(horizontal: false, vertical: true)
        .homeCard(padding: 10)
    }

    private func number(label: String, value: String?, tint: Color, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(value ?? "—")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Chart

/// The glucose chart in a card, with a 3/6/12/24 h control above it and the small overview
/// chart under it. The chart itself is unchanged: pinch, pan, scrub and taps work as before.
@available(iOS 17.0, *)
struct HomeChartCard: View {
    let chartModel: BGChartModel
    var showsSmallGraph: Bool
    var smallGraphHeight: CGFloat
    var onEditCarbEntry: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(NSLocalizedString("Glucose", comment: "The title of the glucose and prediction graph"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                ChartSpanControl(model: chartModel, interaction: chartModel.interaction)
            }
            .padding(.horizontal, 4)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)

            BGChartView(model: chartModel, config: .main, onEditCarbEntry: onEditCarbEntry)

            if showsSmallGraph {
                BGChartView(model: chartModel, config: .small)
                    .frame(height: smallGraphHeight)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: HomeLayout.cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

/// A compact segmented control for the chart's span. No segment is chosen when a pinch has
/// left the chart between two of them.
@available(iOS 17.0, *)
struct ChartSpanControl: View {
    let model: BGChartModel
    @ObservedObject var interaction: BGChartInteraction

    var body: some View {
        let selected = ChartSpan.matching(visibleSeconds: interaction.visibleSeconds)
        HStack(spacing: 2) {
            ForEach(ChartSpan.allCases) { span in
                let isSelected = span == selected
                Button {
                    interaction.show(seconds: span.rawValue, model: model)
                } label: {
                    Text(span.label)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(HomePalette.selectedSegment)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityLabel(String(format: NSLocalizedString("%lld hours", comment: "Chart span, for VoiceOver (1: number of hours)"), span.hours))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(.tertiarySystemFill)))
    }
}

// MARK: - Today's time in range

/// Statistics in plain words: how much of today was in range, a bar with low / in range /
/// high, and how long each lasted. "More" opens the full statistics (average, A1C, SD).
struct HomeStatsCard: View {
    @ObservedObject var model: TimeInRangeModel
    var onMore: (() -> Void)?

    private static let lowColor = Color.red
    private static let inRangeColor = Color.green
    private static let highColor = Color.yellow

    var body: some View {
        let summary = model.summary
        Button {
            onMore?()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(summary.headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    HStack(spacing: 3) {
                        Text(NSLocalizedString("More", comment: "Opens the full statistics from the time-in-range card"))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                }

                DistributionBar(segments: segments(summary))
                    .frame(height: 8)

                HStack(alignment: .top, spacing: 8) {
                    legend(NSLocalizedString("Low", comment: "Time-in-range card: below range"), summary.low, summary.hasData, Self.lowColor, alignment: .leading)
                    legend(NSLocalizedString("In range", comment: "Time-in-range card: in range"), summary.inRange, summary.hasData, Self.inRangeColor, alignment: .center)
                    legend(NSLocalizedString("High", comment: "Time-in-range card: above range"), summary.high, summary.hasData, Self.highColor, alignment: .trailing)
                }
            }
            .homeCard(padding: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func segments(_ summary: TimeInRangeSummary) -> [(color: Color, fraction: CGFloat)] {
        guard summary.hasData else { return [(Color.secondary.opacity(0.3), 1)] }
        return [
            (Self.lowColor, CGFloat(summary.low.percent / 100)),
            (Self.inRangeColor, CGFloat(summary.inRange.percent / 100)),
            (Self.highColor, CGFloat(summary.high.percent / 100)),
        ]
    }

    private func legend(_ name: String, _ band: TimeInRangeSummary.Band, _ hasData: Bool, _ color: Color, alignment: HorizontalAlignment) -> some View {
        let frameAlignment: Alignment = alignment == .leading ? .leading : alignment == .trailing ? .trailing : .center
        return VStack(alignment: alignment, spacing: 1) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name + " " + (hasData ? HomeFormat.percent(band.percent) : "–"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
            Text(TimeInRangeSummary.durationText(band, hasData: hasData))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }
}

/// Horizontal bar of capsules, one per non-empty segment, sized by share. Every non-empty
/// segment is at least `minSegmentWidth` wide so a single reading stays visible.
struct DistributionBar: View {
    let segments: [(color: Color, fraction: CGFloat)]

    private let spacing: CGFloat = 2
    private let minSegmentWidth: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let shown = segments.filter { $0.fraction > 0 }
            let available = max(geo.size.width - spacing * CGFloat(max(shown.count - 1, 0)), 0)
            let widths = segmentWidths(shown.map(\.fraction), available: available)
            HStack(spacing: spacing) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, segment in
                    Capsule()
                        .fill(segment.color)
                        .frame(width: widths[index])
                }
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    private func segmentWidths(_ fractions: [CGFloat], available: CGFloat) -> [CGFloat] {
        var widths = fractions.map { max($0 * available, minSegmentWidth) }
        let excess = widths.reduce(0, +) - available
        if excess > 0, let widest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[widest] = max(widths[widest] - excess, minSegmentWidth)
        }
        return widths
    }
}

/// The full statistics for the last 24 hours, opened from "More" on the time-in-range card:
/// the pie, average, A1C and spread that used to sit under the chart.
@available(iOS 17.0, *)
struct HomeFullStatsView: View {
    @ObservedObject var model: StatsDisplayModel
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("Last 24 hours", comment: "Period of the full statistics opened from the status screen"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                StatsDisplayView(model: model)
                    .frame(height: 110)
                    .homeCard(padding: 8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HomeLayout.horizontalMargin)
            .padding(.top, 8)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(NSLocalizedString("Statistics", comment: "Title of the full statistics opened from the status screen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("Done", comment: "Button that closes the full statistics")) { onDone() }
                }
            }
        }
    }
}

// MARK: - Table cells

/// The loop and glucose card, the sensor and pod tiles and the four numbers, in place of
/// the HUD at the top of the status screen.
final class HomeHeaderTableViewCell: UITableViewCell {
    func configure(model: HomeStatusModel) {
        selectionStyle = .none
        backgroundColor = .clear
        contentConfiguration = UIHostingConfiguration {
            HomeHeaderView(model: model)
        }
        .margins(.horizontal, HomeLayout.horizontalMargin)
        .margins(.vertical, HomeLayout.verticalMargin)
    }
}

/// The glucose chart card.
@available(iOS 17.0, *)
final class HomeChartCardTableViewCell: UITableViewCell {
    func configure(model: BGChartModel, showsSmallGraph: Bool, smallGraphHeight: CGFloat, onEditCarbEntry: ((String) -> Void)?) {
        selectionStyle = .none
        backgroundColor = .clear
        // `UIHostingConfiguration` updates the hosting view in place when the same cell is
        // reconfigured, so the chart's pan/zoom state survives a reload.
        contentConfiguration = UIHostingConfiguration {
            HomeChartCard(chartModel: model, showsSmallGraph: showsSmallGraph, smallGraphHeight: smallGraphHeight, onEditCarbEntry: onEditCarbEntry)
        }
        .margins(.horizontal, HomeLayout.horizontalMargin)
        .margins(.vertical, HomeLayout.verticalMargin)
    }
}

/// Today's time in range.
final class HomeStatsTableViewCell: UITableViewCell {
    func configure(model: TimeInRangeModel, onMore: @escaping () -> Void) {
        selectionStyle = .none
        backgroundColor = .clear
        contentConfiguration = UIHostingConfiguration {
            HomeStatsCard(model: model, onMore: onMore)
        }
        .margins(.horizontal, HomeLayout.horizontalMargin)
        .margins(.vertical, HomeLayout.verticalMargin)
    }
}

extension UITableViewCell {
    /// Puts a UIKit row on the same rounded card as the SwiftUI cards around it.
    func applyHomeCardBackground() {
        var background = UIBackgroundConfiguration.listPlainCell()
        background.backgroundColor = .secondarySystemGroupedBackground
        background.cornerRadius = HomeLayout.cornerRadius
        background.backgroundInsets = NSDirectionalEdgeInsets(top: HomeLayout.verticalMargin, leading: HomeLayout.horizontalMargin, bottom: HomeLayout.verticalMargin, trailing: HomeLayout.horizontalMargin)
        backgroundConfiguration = background
        // Keeps the row's text inside the card.
        preservesSuperviewLayoutMargins = false
        contentView.preservesSuperviewLayoutMargins = false
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: HomeLayout.horizontalMargin * 2, bottom: 0, trailing: HomeLayout.horizontalMargin * 2)
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: HomeLayout.horizontalMargin * 2, bottom: 8, trailing: HomeLayout.horizontalMargin * 2)
        separatorInset = UIEdgeInsets(top: 0, left: 10_000, bottom: 0, right: 0)
    }
}
