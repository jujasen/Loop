//
//  BGChartTableViewCells.swift
//  Loop
//
//  Table cells that host the SwiftUI glucose chart and statistics summary
//  inside the status screen's table view.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import UIKit

/// Hosts the interactive glucose chart — the tall main chart or the small
/// overview strip, depending on `config`.
///
/// `UIHostingConfiguration` updates the existing hosting view in place when the
/// same cell is reconfigured, so the chart's pan/zoom state survives a reload.
/// The state that must outlive even a cell rebuild (scroll position, zoom,
/// follow mode) lives on the model's `BGChartInteraction` rather than in the
/// view.
@available(iOS 17.0, *)
final class BGChartTableViewCell: UITableViewCell {
    func configure(model: BGChartModel, config: BGChartView.Config) {
        selectionStyle = .none
        backgroundColor = .secondarySystemBackground
        contentConfiguration = UIHostingConfiguration {
            BGChartView(model: model, config: config)
        }
        .margins(.all, 0)
    }
}

/// Hosts the time-in-range summary.
@available(iOS 17.0, *)
final class GlucoseStatsTableViewCell: UITableViewCell {
    func configure(model: StatsDisplayModel) {
        selectionStyle = .none
        backgroundColor = .secondarySystemBackground
        contentConfiguration = UIHostingConfiguration {
            StatsDisplayView(model: model)
        }
        .margins(.all, 0)
    }
}
