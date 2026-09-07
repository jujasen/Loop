//
//  StatsDisplayModel.swift
//  Loop
//
//  Ported from LoopFollow (LoopFollow/Controllers/StatsDisplayModel.swift).
//  Filled by `GlucoseStats.swift`.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

class StatsDisplayModel: ObservableObject {
    @Published var lowPercent: String = ""
    @Published var inRangePercent: String = ""
    @Published var highPercent: String = ""
    @Published var avgBG: String = ""
    @Published var estA1C: String = ""
    @Published var estA1CTitle: String = "Est A1C:"
    @Published var stdDev: String = ""
    @Published var stdDevTitle: String = "Std Dev:"
    @Published var pieLow: Double = 0
    @Published var pieRange: Double = 0
    @Published var pieHigh: Double = 0
}
