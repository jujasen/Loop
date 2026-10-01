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

    // MARK: - v2 settings

    /// Omnipod-like: 0–30 U/h and 0.05–30 U in 0.05 steps, 24 basal entries.
    private let pod = RemoteTherapySettingsPumpIncrements(
        basalRates: (0...600).map { Double($0) / 20 },
        maximumBolusVolumes: (1...600).map { Double($0) / 20 },
        maximumBasalScheduleEntryCount: 24
    )

    private let sickID = UUID()

    /// Walter-like settings in mmol/L.
    private var full: LoopSettings {
        LoopSettings(
            dosingEnabled: true,
            glucoseTargetRangeSchedule: GlucoseRangeSchedule(unit: .millimolesPerLiter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 5.5, maxValue: 6.5))], timeZone: oslo),
            insulinSensitivitySchedule: InsulinSensitivitySchedule(unit: .millimolesPerLiter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: 12)], timeZone: oslo),
            basalRateSchedule: BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: 0.3)], timeZone: oslo),
            carbRatioSchedule: CarbRatioSchedule(unit: .gram(), dailyItems: [RepeatingScheduleValue(startTime: 0, value: 20)], timeZone: oslo),
            preMealTargetRange: DoubleRange(minValue: 5, maxValue: 5.5).quantityRange(for: .millimolesPerLiter),
            legacyWorkoutTargetRange: DoubleRange(minValue: 7, maxValue: 8).quantityRange(for: .millimolesPerLiter),
            overridePresets: [TemporaryScheduleOverridePreset(id: sickID, symbol: "🤒", name: "Sick", settings: TemporaryScheduleOverrideSettings(targetRange: nil, insulinNeedsScaleFactor: 1.2), duration: .indefinite)],
            maximumBasalRatePerHour: 1.0,
            maximumBolus: 2.0,
            suspendThreshold: GlucoseThreshold(unit: .millimolesPerLiter, value: 4.0),
            automaticDosingStrategy: .tempBasalOnly,
            defaultRapidActingModel: .rapidActingAdult
        )
    }

    private func update(_ change: RemoteTherapySettingsChange, current: LoopSettings? = nil, pump: RemoteTherapySettingsPumpIncrements?? = nil) throws -> ServicesManager.RemoteTherapySettingsUpdate {
        return try ServicesManager.therapySettingsUpdate(for: change, replacing: current ?? full, pump: pump ?? pod)
    }

    private func assertRejected(_ change: RemoteTherapySettingsChange, current: LoopSettings? = nil, pump: RemoteTherapySettingsPumpIncrements?? = nil, with expected: ServicesManager.TherapySettingsActionError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try update(change, current: current, pump: pump), file: file, line: line) { error in
            XCTAssertEqual(error as? ServicesManager.TherapySettingsActionError, expected, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line)
        }
    }

    func testEverySetting_IsApplied() throws {
        let change = try RemoteTherapySettingsChange(
            glucoseUnit: .millimolesPerLiter,
            basalRateItems: [RepeatingScheduleValue(startTime: 0, value: 0.35), RepeatingScheduleValue(startTime: .minutes(30), value: 0.4)],
            correctionRangeItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 5.8, maxValue: 6.6))],
            preMealTargetRange: DoubleRange(minValue: 4.8, maxValue: 5.2),
            workoutTargetRange: DoubleRange(minValue: 8, maxValue: 9),
            suspendThreshold: 4.2,
            maximumBasalRatePerHour: 1.5,
            maximumBolus: 2.5,
            insulinModel: .rapidActingChild,
            dosingStrategy: .automaticBolus,
            closedLoop: false,
            overridePresets: [],
            glucoseBasedPartialApplication: true
        )

        let settings = try update(change).settings

        XCTAssertEqual(settings.basalRateSchedule?.items, change.basalRateItems)
        XCTAssertEqual(settings.basalRateSchedule?.timeZone, oslo)
        XCTAssertEqual(settings.glucoseTargetRangeSchedule?.items, change.correctionRangeItems)
        XCTAssertEqual(settings.glucoseTargetRangeSchedule?.unit, .millimolesPerLiter)
        XCTAssertEqual(settings.glucoseTargetRangeSchedule?.timeZone, oslo)
        XCTAssertEqual(settings.preMealTargetRange, DoubleRange(minValue: 4.8, maxValue: 5.2).quantityRange(for: .millimolesPerLiter))
        XCTAssertEqual(settings.legacyWorkoutTargetRange, DoubleRange(minValue: 8, maxValue: 9).quantityRange(for: .millimolesPerLiter))
        XCTAssertEqual(settings.suspendThreshold, GlucoseThreshold(unit: .millimolesPerLiter, value: 4.2))
        XCTAssertEqual(settings.maximumBasalRatePerHour, 1.5)
        XCTAssertEqual(settings.maximumBolus, 2.5)
        XCTAssertEqual(settings.defaultRapidActingModel, .rapidActingChild)
        XCTAssertEqual(settings.automaticDosingStrategy, .automaticBolus)
        XCTAssertFalse(settings.dosingEnabled)
        XCTAssertEqual(settings.overridePresets, [])
        // Untouched.
        XCTAssertEqual(settings.carbRatioSchedule, full.carbRatioSchedule)
        XCTAssertEqual(settings.insulinSensitivitySchedule, full.insulinSensitivitySchedule)
    }

    func testApply_CopiesOnlyChangedSettings() throws {
        let change = try RemoteTherapySettingsChange(basalRateItems: [RepeatingScheduleValue(startTime: 0, value: 0.5)])
        let result = try update(change)

        var target = full
        target.carbRatioSchedule = CarbRatioSchedule(unit: .gram(), dailyItems: [RepeatingScheduleValue(startTime: 0, value: 25)], timeZone: oslo)
        target.maximumBolus = 3
        result.apply(to: &target)

        XCTAssertEqual(target.basalRateSchedule?.items, [RepeatingScheduleValue(startTime: 0, value: 0.5)])
        XCTAssertEqual(target.carbRatioSchedule?.items.first?.value, 25)
        XCTAssertEqual(target.maximumBolus, 3)
        XCTAssertFalse(result.changesDeliveryLimits)
    }

    func testDeliveryLimits_AreSentTogether() throws {
        let change = try RemoteTherapySettingsChange(maximumBolus: 3)
        let result = try update(change)
        XCTAssertTrue(result.changesDeliveryLimits)
        XCTAssertEqual(result.deliveryLimits.maximumBolus, HKQuantity(unit: .internationalUnit(), doubleValue: 3))
        XCTAssertEqual(result.deliveryLimits.maximumBasalRate, HKQuantity(unit: .internationalUnitsPerHour, doubleValue: 1.0))
    }

    // MARK: Basal rates

    func testBasalAboveNewMaximumBasal_IsRejected() throws {
        let change = try RemoteTherapySettingsChange(basalRateItems: [RepeatingScheduleValue(startTime: 0, value: 1.2)], maximumBasalRatePerHour: 1.0)
        assertRejected(change, with: .basalRateOutOfRange(1.2, 0...1.0))
    }

    func testBasalAboveCurrentMaximumBasal_IsRejected() throws {
        let change = try RemoteTherapySettingsChange(basalRateItems: [RepeatingScheduleValue(startTime: 0, value: 0.3), RepeatingScheduleValue(startTime: .hours(8), value: 1.05)])
        assertRejected(change, with: .basalRateOutOfRange(1.05, 0...1.0))
    }

    func testBasalAndMaximumBasalRaisedTogether_AreAccepted() throws {
        let change = try RemoteTherapySettingsChange(basalRateItems: [RepeatingScheduleValue(startTime: 0, value: 1.2)], maximumBasalRatePerHour: 2.0)
        let settings = try update(change).settings
        XCTAssertEqual(settings.basalRateSchedule?.items.first?.value, 1.2)
        XCTAssertEqual(settings.maximumBasalRatePerHour, 2.0)
    }

    func testBasalNotAPumpIncrement_IsRejected() throws {
        let change = try RemoteTherapySettingsChange(basalRateItems: [RepeatingScheduleValue(startTime: 0, value: 0.33)])
        assertRejected(change, with: .basalRateNotSupported(0.33))
    }

    func testBasalWithFloatingPointNoise_IsStoredAsPumpIncrement() throws {
        let change = try RemoteTherapySettingsChange(basalRateItems: [RepeatingScheduleValue(startTime: 0, value: 0.1 + 0.2)])
        XCTAssertEqual(try update(change).settings.basalRateSchedule?.items.first?.value, 6.0 / 20)
    }

    func testMoreBasalRatesThanThePumpHolds_IsRejected() throws {
        let items = (0..<25).map { RepeatingScheduleValue(startTime: .minutes(30 * Double($0)), value: 0.3) }
        let change = try RemoteTherapySettingsChange(basalRateItems: items)
        assertRejected(change, with: .tooManyBasalRates(25, 24))
    }

    func testBasalWithoutPump_IsRejected() throws {
        let change = try RemoteTherapySettingsChange(basalRateItems: [RepeatingScheduleValue(startTime: 0, value: 0.3)])
        assertRejected(change, pump: .some(nil), with: .noPump)
    }

    func testCarbRatioWithoutPump_IsAccepted() throws {
        let change = try RemoteTherapySettingsChange(carbRatioItems: [RepeatingScheduleValue(startTime: 0, value: 18)])
        XCTAssertNoThrow(try update(change, pump: .some(nil)))
    }

    // MARK: Delivery limits

    func testMaximumBasalBelowScheduledBasal_IsRejected() throws {
        let change = try RemoteTherapySettingsChange(maximumBasalRatePerHour: 0.25)
        assertRejected(change, with: .maximumBasalRateOutOfRange(0.25, 0.3...3.5))
    }

    func testMaximumBasalLimitFollowsNewCarbRatio() throws {
        // 70 / lowest carb ratio: 3.5 U/h with today's 20 g/U, 7 U/h with a new 10 g/U.
        assertRejected(try RemoteTherapySettingsChange(maximumBasalRatePerHour: 7.0), with: .maximumBasalRateOutOfRange(7.0, 0.3...3.5))
        let change = try RemoteTherapySettingsChange(carbRatioItems: [RepeatingScheduleValue(startTime: 0, value: 10)], maximumBasalRatePerHour: 7.0)
        XCTAssertEqual(try update(change).settings.maximumBasalRatePerHour, 7.0)
        assertRejected(try RemoteTherapySettingsChange(carbRatioItems: [RepeatingScheduleValue(startTime: 0, value: 10)], maximumBasalRatePerHour: 7.05),
                       with: .maximumBasalRateOutOfRange(7.05, 0.3...7.0))
    }

    func testMaximumBasalNotAPumpIncrement_IsRejected() throws {
        assertRejected(try RemoteTherapySettingsChange(maximumBasalRatePerHour: 1.23), with: .maximumBasalRateNotSupported(1.23))
    }

    func testMaximumBolusOutsideGuardrail_IsRejected() throws {
        assertRejected(try RemoteTherapySettingsChange(maximumBolus: 30.05), with: .maximumBolusOutOfRange(30.05, 0.05...30))
        assertRejected(try RemoteTherapySettingsChange(maximumBolus: 0), with: .maximumBolusOutOfRange(0, 0.05...30))
    }

    func testMaximumBolusNotAPumpIncrement_IsRejected() throws {
        assertRejected(try RemoteTherapySettingsChange(maximumBolus: 2.33), with: .maximumBolusNotSupported(2.33))
    }

    // MARK: Glucose settings

    func testSuspendThresholdAbovePreMealLow_IsRejected() throws {
        // The lowest of correction 5.5, pre-meal 5.0 and workout 7.0 caps the safety limit at 5.0.
        let change = try RemoteTherapySettingsChange(glucoseUnit: .millimolesPerLiter, suspendThreshold: 5.2)
        assertRejected(change, with: .suspendThresholdOutOfRange(5.2, 3.7...5.0, .millimolesPerLiter))
    }

    func testSuspendThresholdAboveNewCorrectionLow_IsRejected() throws {
        let change = try RemoteTherapySettingsChange(
            glucoseUnit: .millimolesPerLiter,
            correctionRangeItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 4.9, maxValue: 6))],
            suspendThreshold: 4.95
        )
        assertRejected(change, with: .suspendThresholdOutOfRange(4.95, 3.7...4.9, .millimolesPerLiter))
    }

    func testSuspendThresholdOutsideAbsoluteGuardrail_IsRejected() throws {
        let change = try RemoteTherapySettingsChange(glucoseUnit: .milligramsPerDeciliter, suspendThreshold: 65)
        assertRejected(change, with: .suspendThresholdOutOfRange(65, 67...90, .milligramsPerDeciliter))
    }

    func testSuspendThresholdRaisedWithRanges_IsAccepted() throws {
        let change = try RemoteTherapySettingsChange(
            glucoseUnit: .millimolesPerLiter,
            correctionRangeItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 6, maxValue: 7))],
            preMealTargetRange: DoubleRange(minValue: 5.5, maxValue: 6),
            suspendThreshold: 5.5
        )
        XCTAssertEqual(try update(change).settings.suspendThreshold?.value, 5.5)
    }

    func testCorrectionLowBelowSuspendThreshold_IsRejected() throws {
        var current = full
        current.suspendThreshold = GlucoseThreshold(unit: .millimolesPerLiter, value: 5.0)
        let change = try RemoteTherapySettingsChange(
            glucoseUnit: .millimolesPerLiter,
            correctionRangeItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 5.5, maxValue: 6)), RepeatingScheduleValue(startTime: .hours(22), value: DoubleRange(minValue: 4.9, maxValue: 6))]
        )
        assertRejected(change, current: current, with: .glucoseRangeOutOfRange(.correctionRange, DoubleRange(minValue: 4.9, maxValue: 6), 5.0...10.0, .millimolesPerLiter))
    }

    func testCorrectionAboveAbsoluteGuardrail_IsRejected() throws {
        let change = try RemoteTherapySettingsChange(glucoseUnit: .milligramsPerDeciliter, correctionRangeItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 181))])
        assertRejected(change, with: .glucoseRangeOutOfRange(.correctionRange, DoubleRange(minValue: 100, maxValue: 181), 87...180, .milligramsPerDeciliter))
    }

    func testInvertedCorrectionRange_IsRejected() throws {
        let change = try RemoteTherapySettingsChange(glucoseUnit: .millimolesPerLiter, correctionRangeItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 7, maxValue: 6))])
        assertRejected(change, with: .invertedGlucoseRange(.correctionRange, DoubleRange(minValue: 7, maxValue: 6), .millimolesPerLiter))
    }

    func testCorrectionInOtherUnit_IsStoredInCurrentUnit() throws {
        let change = try RemoteTherapySettingsChange(glucoseUnit: .milligramsPerDeciliter, correctionRangeItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 110))])
        let schedule = try update(change).settings.glucoseTargetRangeSchedule
        XCTAssertEqual(schedule?.unit, .millimolesPerLiter)
        XCTAssertEqual(schedule?.items.first?.value.minValue ?? 0, 5.6, accuracy: 0.05)
        XCTAssertEqual(schedule?.items.first?.value.maxValue ?? 0, 6.1, accuracy: 0.05)
        XCTAssertEqual(schedule?.timeZone, oslo)
    }

    func testPreMealBelowSuspendThreshold_IsRejected() throws {
        let change = try RemoteTherapySettingsChange(glucoseUnit: .millimolesPerLiter, preMealTargetRange: DoubleRange(minValue: 3.9, maxValue: 4.5))
        assertRejected(change, with: .glucoseRangeOutOfRange(.preMealRange, DoubleRange(minValue: 3.9, maxValue: 4.5), 4.0...7.2, .millimolesPerLiter))
    }

    func testPreMealAboveMaximum_IsRejected() throws {
        let change = try RemoteTherapySettingsChange(glucoseUnit: .milligramsPerDeciliter, preMealTargetRange: DoubleRange(minValue: 100, maxValue: 131))
        assertRejected(change, with: .glucoseRangeOutOfRange(.preMealRange, DoubleRange(minValue: 100, maxValue: 131), 73...130, .milligramsPerDeciliter))
    }

    func testWorkoutAboveMaximum_IsRejected() throws {
        let change = try RemoteTherapySettingsChange(glucoseUnit: .milligramsPerDeciliter, workoutTargetRange: DoubleRange(minValue: 140, maxValue: 251))
        assertRejected(change, with: .glucoseRangeOutOfRange(.workoutRange, DoubleRange(minValue: 140, maxValue: 251), 87...250, .milligramsPerDeciliter))
    }

    func testWorkoutWithHighCorrectionRange_DoesNotTrap() throws {
        // Loop's workout guardrail builds recommended bounds that trap above a 180 mg/dL correction high.
        let change = try RemoteTherapySettingsChange(
            glucoseUnit: .millimolesPerLiter,
            correctionRangeItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 6, maxValue: 10))],
            workoutTargetRange: DoubleRange(minValue: 10, maxValue: 11)
        )
        XCTAssertNoThrow(try update(change))
    }

    // MARK: Override presets

    func testOverridePresets_KeepIdByNameAndConvertSettings() throws {
        let change = try RemoteTherapySettingsChange(glucoseUnit: .millimolesPerLiter, overridePresets: [
            .init(name: "Sick", symbol: "🤢", duration: 0, insulinNeedsScaleFactor: 1.3, targetRange: DoubleRange(minValue: 6, maxValue: 7)),
            .init(name: "Nap", symbol: "😴", duration: .hours(2))
        ])

        let presets = try update(change).settings.overridePresets

        XCTAssertEqual(presets.count, 2)
        XCTAssertEqual(presets[0].id, sickID)
        XCTAssertEqual(presets[0].symbol, "🤢")
        XCTAssertEqual(presets[0].duration, .indefinite)
        XCTAssertEqual(presets[0].settings.insulinNeedsScaleFactor, 1.3)
        XCTAssertEqual(presets[0].settings.targetRange?.lowerBound.doubleValue(for: .millimolesPerLiter) ?? 0, 6, accuracy: 0.001)
        XCTAssertEqual(presets[0].settings.targetRange?.upperBound.doubleValue(for: .millimolesPerLiter) ?? 0, 7, accuracy: 0.001)
        XCTAssertNotEqual(presets[1].id, sickID)
        XCTAssertEqual(presets[1].duration, .finite(.hours(2)))
        XCTAssertNil(presets[1].settings.insulinNeedsScaleFactor)
        XCTAssertNil(presets[1].settings.targetRange)
    }

    func testOverridePresetRenamed_GetsNewId() throws {
        let change = try RemoteTherapySettingsChange(overridePresets: [.init(name: "Ill", symbol: "🤒", duration: 0, insulinNeedsScaleFactor: 1.2)])
        XCTAssertNotEqual(try update(change).settings.overridePresets.first?.id, sickID)
    }

    func testOverridePresetsInvalid_AreRejected() throws {
        assertRejected(try RemoteTherapySettingsChange(overridePresets: [.init(name: " ", symbol: "🤒", duration: 0)]), with: .overridePresetNameMissing)
        assertRejected(try RemoteTherapySettingsChange(overridePresets: [.init(name: "Sick", symbol: "🤒", duration: 0), .init(name: "Sick", symbol: "😷", duration: 0)]),
                       with: .overridePresetNameDuplicated("Sick"))
        assertRejected(try RemoteTherapySettingsChange(overridePresets: [.init(name: "Sick", symbol: "", duration: 0)]), with: .overridePresetSymbolMissing("Sick"))
        assertRejected(try RemoteTherapySettingsChange(overridePresets: [.init(name: "Sick", symbol: "🤒", duration: -60)]), with: .overridePresetDurationOutOfRange("Sick", -60))
        assertRejected(try RemoteTherapySettingsChange(overridePresets: [.init(name: "Sick", symbol: "🤒", duration: .hours(25))]), with: .overridePresetDurationOutOfRange("Sick", .hours(25)))
        assertRejected(try RemoteTherapySettingsChange(overridePresets: [.init(name: "Sick", symbol: "🤒", duration: 0, insulinNeedsScaleFactor: 2.5)]), with: .overridePresetInsulinNeedsOutOfRange("Sick", 2.5))
        assertRejected(try RemoteTherapySettingsChange(overridePresets: [.init(name: "Sick", symbol: "🤒", duration: 0, insulinNeedsScaleFactor: 0.05)]), with: .overridePresetInsulinNeedsOutOfRange("Sick", 0.05))
        assertRejected(try RemoteTherapySettingsChange(glucoseUnit: .millimolesPerLiter, overridePresets: [.init(name: "Sick", symbol: "🤒", duration: 0, targetRange: DoubleRange(minValue: 3, maxValue: 4))]),
                       with: .glucoseRangeOutOfRange(.overridePreset("Sick"), DoubleRange(minValue: 3, maxValue: 4), 3.7...13.8, .millimolesPerLiter))
        assertRejected(try RemoteTherapySettingsChange(glucoseUnit: .millimolesPerLiter, overridePresets: [.init(name: "Sick", symbol: "🤒", duration: 0, targetRange: DoubleRange(minValue: 8, maxValue: 7))]),
                       with: .invertedGlucoseRange(.overridePreset("Sick"), DoubleRange(minValue: 8, maxValue: 7), .millimolesPerLiter))
    }

    func testOneBadValue_RejectsWholeChange() throws {
        // A valid carb ratio and basal rate do not get through with a bad maximum bolus.
        let change = try RemoteTherapySettingsChange(
            carbRatioItems: [RepeatingScheduleValue(startTime: 0, value: 18)],
            basalRateItems: [RepeatingScheduleValue(startTime: 0, value: 0.4)],
            maximumBolus: 40
        )
        assertRejected(change, with: .maximumBolusOutOfRange(40, 0.05...30))
    }

    // MARK: Notifications

    func testNotificationTitle_KeepsV1TitlesAndGeneralizes() throws {
        let carbRatio = try RemoteTherapySettingsChange(carbRatioItems: [RepeatingScheduleValue(startTime: 0, value: 18)], insulinSensitivityItems: nil, insulinSensitivityUnit: nil)
        XCTAssertEqual(NotificationManager.remoteTherapySettingsNotificationTitle(for: carbRatio), "Remote Change: Carb Ratios")
        let basal = try RemoteTherapySettingsChange(carbRatioItems: [RepeatingScheduleValue(startTime: 0, value: 18)], basalRateItems: [RepeatingScheduleValue(startTime: 0, value: 0.4)])
        XCTAssertEqual(NotificationManager.remoteTherapySettingsNotificationTitle(for: basal), "Remote Change: Therapy Settings")
    }
}
