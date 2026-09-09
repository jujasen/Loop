//
//  StatsDisplayView.swift
//  Loop
//
//  The time-in-range summary under the glucose chart, ported from LoopFollow
//  (LoopFollow/Controllers/StatsDisplayView.swift).
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Charts
import SwiftUI

@available(iOS 17.0, *)
struct StatsDisplayView: View {
    @ObservedObject var model: StatsDisplayModel
    var onTap: (() -> Void)?

    /// Grows with the text beside it, so the pie does not shrink into a dot on a large
    /// text setting. The row itself is measured the same way — see
    /// `StatusTableViewController.fixedChartRowHeight`.
    @ScaledMetric(relativeTo: .subheadline) private var pieDiameter: CGFloat = 80

    var body: some View {
        HStack {
            StatsPieChartView(
                pieLow: model.pieLow,
                pieRange: model.pieRange,
                pieHigh: model.pieHigh
            )
            .frame(width: pieDiameter, height: pieDiameter)
            .padding(.leading, 8)

            VStack(spacing: 10) {
                HStack {
                    // Localized here rather than as a literal in `statColumn`: the titles
                    // arrive as `String`, and `Text(String)` does not look anything up.
                    statColumn(
                        title: String(localized: "Low:", comment: "Statistics label for the share of readings below range"),
                        value: model.lowPercent
                    )
                    statColumn(
                        title: String(localized: "In Range:", comment: "Statistics label for the share of readings in range"),
                        value: model.inRangePercent
                    )
                    statColumn(
                        title: String(localized: "High:", comment: "Statistics label for the share of readings above range"),
                        value: model.highPercent
                    )
                }
                HStack {
                    statColumn(
                        title: String(localized: "Avg BG:", comment: "Statistics label for average glucose"),
                        value: model.avgBG
                    )
                    statColumn(title: model.estA1CTitle, value: model.estA1C)
                    statColumn(title: model.stdDevTitle, value: model.stdDev)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }

    private func statColumn(title: String, value: String) -> some View {
        VStack {
            Text(title)
            Text(value)
        }
        .font(.subheadline)
        // Six columns of numbers have to stay side by side; at the largest text
        // settings they shrink a little rather than wrapping into each other.
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity)
    }
}

@available(iOS 17.0, *)
struct StatsPieChartView: View {
    var pieLow: Double
    var pieRange: Double
    var pieHigh: Double

    private struct Slice: Identifiable {
        let id: String
        let value: Double
        let color: Color
    }

    private var slices: [Slice] {
        [
            Slice(id: "low", value: max(pieLow, 0.1), color: .red),
            Slice(id: "range", value: max(pieRange, 0.1), color: .green),
            Slice(id: "high", value: max(pieHigh, 0.1), color: .yellow),
        ]
    }

    var body: some View {
        Chart(slices) { slice in
            SectorMark(angle: .value("share", slice.value))
                .foregroundStyle(slice.color)
        }
        .chartLegend(.hidden)
        .allowsHitTesting(false)
    }
}
