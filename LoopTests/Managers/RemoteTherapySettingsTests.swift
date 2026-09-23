//
//  RemoteTherapySettingsTests.swift
//  LoopTests
//
//  Carb ratio and insulin sensitivity schedules replaced from a caregiver's phone.
//

import XCTest
import HealthKit
import LoopKit
import LoopCore
@testable import Loop

final class RemoteTherapySettingsTests: XCTestCase {

    private let oslo = TimeZone(identifier: "Europe/Oslo")!

    private var current: LoopSettings {
        LoopSettings(
            insulinSensitivitySchedule: InsulinSensitivitySchedule(unit: .millimolesPerLiter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: 12)], timeZone: oslo),
            carbRatioSchedule: CarbRatioSchedule(unit: .gram(), dailyItems: [RepeatingScheduleValue(startTime: 0, value: 20)], timeZone: oslo)
        )
    }

    func testCarbRatioChange_ReplacesTimesAndKeepsTimeZone() throws {
        let change = try RemoteTherapySettingsChange(
            carbRatioItems: [RepeatingScheduleValue(startTime: 0, value: 18), RepeatingScheduleValue(startTime: .hours(6), value: 14.5)],
            insulinSensitivityItems: nil,
            insulinSensitivityUnit: nil
        )

        let (carbRatio, sensitivity) = try ServicesManager.schedules(for: change, replacing: current)

        XCTAssertNil(sensitivity)
        XCTAssertEqual(carbRatio?.items, change.carbRatioItems)
        XCTAssertEqual(carbRatio?.timeZone, oslo)
        XCTAssertEqual(carbRatio?.unit, .gram())
    }

    func testSensitivityInOtherUnit_IsStoredInCurrentUnit() throws {
        let change = try RemoteTherapySettingsChange(
            carbRatioItems: nil,
            insulinSensitivityItems: [RepeatingScheduleValue(startTime: 0, value: 180)],
            insulinSensitivityUnit: .milligramsPerDeciliter
        )

        let (_, sensitivity) = try ServicesManager.schedules(for: change, replacing: current)

        XCTAssertEqual(sensitivity?.unit, .millimolesPerLiter)
        XCTAssertEqual(sensitivity?.items.first?.value ?? 0, 10.0, accuracy: 0.05)
        XCTAssertEqual(sensitivity?.timeZone, oslo)
    }

    func testSensitivityInSameUnit_IsKeptExactly() throws {
        let change = try RemoteTherapySettingsChange(
            carbRatioItems: nil,
            insulinSensitivityItems: [RepeatingScheduleValue(startTime: 0, value: 13.3), RepeatingScheduleValue(startTime: .minutes(90), value: 11.7)],
            insulinSensitivityUnit: .millimolesPerLiter
        )

        let (_, sensitivity) = try ServicesManager.schedules(for: change, replacing: current)

        XCTAssertEqual(sensitivity?.items, change.insulinSensitivityItems)
    }

    func testCarbRatioOutsideGuardrail_IsRejected() throws {
        let change = try RemoteTherapySettingsChange(
            carbRatioItems: [RepeatingScheduleValue(startTime: 0, value: 20), RepeatingScheduleValue(startTime: .hours(12), value: 151)],
            insulinSensitivityItems: nil,
            insulinSensitivityUnit: nil
        )

        XCTAssertThrowsError(try ServicesManager.schedules(for: change, replacing: current)) { error in
            XCTAssertEqual(error as? ServicesManager.TherapySettingsActionError, .carbRatioOutOfRange(151))
        }
    }

    func testSensitivityOutsideGuardrail_IsRejected() throws {
        // 0.4 mmol/L/U ≈ 7 mg/dL/U, below Loop's 9.1 mg/dL/U minimum.
        let change = try RemoteTherapySettingsChange(
            carbRatioItems: nil,
            insulinSensitivityItems: [RepeatingScheduleValue(startTime: 0, value: 0.4)],
            insulinSensitivityUnit: .millimolesPerLiter
        )

        XCTAssertThrowsError(try ServicesManager.schedules(for: change, replacing: current))
    }
}
