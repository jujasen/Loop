//
//  BGChartDeviceChangeTests.swift
//  LoopTests
//
//  Which pump and sensor changes the chart marks.
//

import XCTest
@testable import Loop

final class BGChartDeviceChangeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_385_820)

    private func hours(_ value: Double) -> Date {
        now.addingTimeInterval(value * 3600)
    }

    func testPumpAndSensorChangesAreListedOldestFirst() {
        let changes = BGChartModel.DeviceChange.list(pump: [hours(-2)], sensor: [hours(-5)], since: hours(-24))
        XCTAssertEqual(changes.map(\.kind), [.sensor, .pump])
        XCTAssertEqual(changes.map(\.date), [hours(-5), hours(-2)])
    }

    func testAChangeThePumpReportsTwiceIsMarkedOnce() {
        // Pairing, then priming a few minutes later.
        let changes = BGChartModel.DeviceChange.list(pump: [hours(-2), hours(-2).addingTimeInterval(4 * 60)], sensor: [], since: hours(-24))
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.date, hours(-2))
    }

    func testTwoPumpChangesTheSameDayAreBothMarked() {
        let changes = BGChartModel.DeviceChange.list(pump: [hours(-9), hours(-1)], sensor: [], since: hours(-24))
        XCTAssertEqual(changes.count, 2)
    }

    func testPumpAndSensorChangedTogetherAreBothMarkedAtDifferentHeights() {
        let changes = BGChartModel.DeviceChange.list(pump: [hours(-2)], sensor: [hours(-2).addingTimeInterval(60)], since: hours(-24))
        XCTAssertEqual(changes.count, 2)
        XCTAssertNotEqual(changes[0].labelFraction, changes[1].labelFraction)
        XCTAssertNotEqual(changes[0].id, changes[1].id)
    }

    func testChangesBeforeTheChartStartsAreLeftOut() {
        let changes = BGChartModel.DeviceChange.list(pump: [hours(-30)], sensor: [hours(-25)], since: hours(-24))
        XCTAssertTrue(changes.isEmpty)
    }
}
