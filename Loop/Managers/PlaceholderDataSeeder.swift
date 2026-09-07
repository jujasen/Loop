//
//  PlaceholderDataSeeder.swift
//  Loop
//
//  Fills a simulator with a plausible day of data so the status screen can be
//  looked at without waiting for a CGM to produce readings.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

#if DEBUG && targetEnvironment(simulator)

import Foundation
import HealthKit
import LoopKit
import LoopKitUI
import LoopTestingKit
import os.log

/// Development-only seeding of a day of glucose, carbs and insulin.
///
/// Runs **only** in a simulator, in a DEBUG build, and only when the app is
/// launched with `LOOP_SEED_PLACEHOLDER_DATA=1` in its environment:
///
///     SIMCTL_CHILD_LOOP_SEED_PLACEHOLDER_DATA=1 \
///         xcrun simctl launch booted com..loopkit.Loop
///
/// Seeding is destructive — it applies the mock therapy settings, installs the
/// Pump and CGM simulators and adds a day of data — which is why every one of
/// those conditions has to hold before anything happens.
enum PlaceholderDataSeeder {
    private static let log = OSLog(category: "PlaceholderDataSeeder")

    private static let environmentKey = "LOOP_SEED_PLACEHOLDER_DATA"

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    /// Applies therapy settings and installs the simulated devices. Must run
    /// before `OnboardingManager` is created, since that decides at init time
    /// whether onboarding is still needed.
    static func prepareIfRequested(deviceManager: DeviceDataManager, userDefaults: UserDefaults?) {
        guard isRequested else { return }

        let therapySettings = TherapySettings.mockTherapySettings
        // The mock settings aim at 100–115 mg/dL with a temporary 80–90
        // override, which would read as "high all day" against any plausible
        // placeholder curve. A flat, ordinary correction range makes the
        // statistics say something.
        let correctionRange = GlucoseRangeSchedule(
            unit: .milligramsPerDeciliter,
            dailyItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 95, maxValue: 125))]
        )
        deviceManager.loopManager.mutateSettings { settings in
            settings.glucoseTargetRangeSchedule = correctionRange ?? therapySettings.glucoseTargetRangeSchedule
            settings.preMealTargetRange = therapySettings.correctionRangeOverrides?.preMeal
            settings.legacyWorkoutTargetRange = therapySettings.correctionRangeOverrides?.workout
            settings.suspendThreshold = therapySettings.suspendThreshold
            settings.maximumBolus = therapySettings.maximumBolus
            settings.maximumBasalRatePerHour = therapySettings.maximumBasalRatePerHour
            settings.insulinSensitivitySchedule = therapySettings.insulinSensitivitySchedule
            settings.carbRatioSchedule = therapySettings.carbRatioSchedule
            settings.basalRateSchedule = therapySettings.basalRateSchedule
            settings.defaultRapidActingModel = therapySettings.defaultRapidActingModel
        }

        // Onboarding is otherwise the first thing the app puts on screen.
        userDefaults?.set(true, forKey: "com.loopkit.Loop.OnboardingManager.IsComplete")
        userDefaults?.set(false, forKey: "com.loopkit.Loop.OnboardingManager.IsSuspended")

        if deviceManager.pumpManager == nil,
           let maximumBasalRate = therapySettings.maximumBasalRatePerHour,
           let maximumBolus = therapySettings.maximumBolus,
           let basalSchedule = therapySettings.basalRateSchedule
        {
            let result = deviceManager.setupPumpManager(
                withIdentifier: "MockPumpManager",
                initialSettings: PumpManagerSetupSettings(
                    maxBasalRateUnitsPerHour: maximumBasalRate,
                    maxBolusUnits: maximumBolus,
                    basalSchedule: basalSchedule
                ),
                prefersToSkipUserInteraction: true
            )
            if case .failure(let error) = result {
                log.error("Could not install the pump simulator: %{public}@", String(describing: error))
            }
        }

        if deviceManager.cgmManager == nil {
            let result = deviceManager.setupCGMManager(withIdentifier: "MockCGMManager", prefersToSkipUserInteraction: true)
            if case .failure(let error) = result {
                log.error("Could not install the CGM simulator: %{public}@", String(describing: error))
            }
        }
    }

    /// Injects the placeholder day into the simulated devices and the carb
    /// store. Goes through the same `TestingPumpManager` / `TestingCGMManager`
    /// hooks Loop's own test scenarios use, so the data lands in the stores the
    /// way real device data would.
    static func injectDataIfRequested(deviceManager: DeviceDataManager) {
        guard isRequested else { return }

        guard let pumpManager = deviceManager.pumpManager as? TestingPumpManager,
              let cgmManager = deviceManager.cgmManager as? TestingCGMManager
        else {
            log.error("Simulated pump and CGM are not both installed; no data injected")
            return
        }

        let now = Date()

        deviceManager.carbStore.addCarbEntries(carbEntries(relativeTo: now)) { result in
            if case .failure(let error) = result {
                log.error("Could not add placeholder carb entries: %{public}@", String(describing: error))
            }

            pumpManager.reservoirFillFraction = 0.72
            pumpManager.injectPumpEvents(pumpEvents(relativeTo: now))

            let samples = glucoseSamples(relativeTo: now)
            cgmManager.injectGlucoseSamples(
                samples.filter { $0.date <= now },
                futureSamples: samples.filter { $0.date > now }
            )

            log.default("Injected placeholder data")
        }
    }

    // MARK: - The placeholder day

    /// Three meals on a gentle overnight drift, sampled every five minutes for
    /// the last 24 hours plus half an hour ahead so the chart's leading edge
    /// isn't bare.
    private static func glucoseSamples(relativeTo referenceDate: Date) -> [NewGlucoseSample] {
        let meals: [(offsetHours: Double, rise: Double, spreadHours: Double)] = [
            (-19, 75, 1.6),
            (-12, 95, 1.8),
            (-4, 60, 1.4),
        ]

        return stride(from: -288, through: 6, by: 1).map { step -> NewGlucoseSample in
            let offset = Double(step) * 5 * 60
            let hours = offset / 3600

            // Slow baseline drift, lowest in the small hours.
            var mgdl = 108 + 16 * sin(2 * .pi * hours / 9)

            for meal in meals {
                let since = hours - meal.offsetHours
                // Nothing before the meal, a skewed bump after it.
                guard since > -0.25 else { continue }
                mgdl += meal.rise * exp(-pow(since - meal.spreadHours, 2) / (2 * pow(meal.spreadHours, 2)))
            }

            // A mild low mid-afternoon, so the summary has something in every
            // one of its three buckets.
            mgdl -= 42 * exp(-pow(hours + 8.5, 2) / (2 * pow(0.9, 2)))

            // A deterministic wobble, so the line reads like a sensor trace
            // rather than a formula but the screenshot stays reproducible.
            mgdl += 4 * sin(Double(step) * 1.7)

            return NewGlucoseSample(
                date: referenceDate.addingTimeInterval(offset),
                quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: max(55, min(320, mgdl))),
                condition: nil,
                trend: nil,
                trendRate: nil,
                isDisplayOnly: false,
                wasUserEntered: false,
                syncIdentifier: "placeholder-glucose-\(step)"
            )
        }
    }

    /// Half-hourly temp basals across the window plus the day's boluses, in
    /// the chronological order the dose store expects.
    private static func pumpEvents(relativeTo referenceDate: Date) -> [NewPumpEvent] {
        let rates: [Double] = [0.85, 0.9, 1.0, 1.15, 1.3, 1.2, 1.0, 0.8, 0.65, 0.55, 0.7, 0.95]

        var events: [NewPumpEvent] = (0 ..< 48).map { step in
            let start = referenceDate.addingTimeInterval(Double(step - 48) * 30 * 60)
            let dose = DoseEntry(
                type: .tempBasal,
                startDate: start,
                endDate: start.addingTimeInterval(30 * 60),
                value: rates[step % rates.count],
                unit: .unitsPerHour
            )
            return NewPumpEvent(date: dose.startDate, dose: dose, raw: identifier("basal-\(step)"), title: "Temp Basal", type: .tempBasal)
        }

        let boluses: [(units: Double, offset: TimeInterval, duration: TimeInterval)] = [
            (4.5, -19 * 3600 + 300, 120),
            (6.2, -12 * 3600 + 300, 150),
            (1.1, -8 * 3600, 60),
            // Same minute as the third meal's carb entry, the way a meal bolus
            // usually is — the case where the two symbols must not collide.
            (3.4, -4 * 3600, 120),
            (0.9, -70 * 60, 60),
        ]

        events += boluses.enumerated().map { index, bolus in
            let start = referenceDate.addingTimeInterval(bolus.offset)
            let dose = DoseEntry(
                type: .bolus,
                startDate: start,
                endDate: start.addingTimeInterval(bolus.duration),
                value: bolus.units,
                unit: .units
            )
            return NewPumpEvent(date: dose.startDate, dose: dose, raw: identifier("bolus-\(index)"), title: "Bolus", type: .bolus)
        }

        return events.sorted { $0.date < $1.date }
    }

    private static func carbEntries(relativeTo referenceDate: Date) -> [NewCarbEntry] {
        let meals: [(grams: Double, offsetHours: Double, absorptionHours: Double)] = [
            (45, -19, 3),
            (62, -12, 3),
            (35, -4, 2),
        ]

        return meals.map { meal in
            NewCarbEntry(
                quantity: HKQuantity(unit: .gram(), doubleValue: meal.grams),
                startDate: referenceDate.addingTimeInterval(meal.offsetHours * 3600),
                foodType: nil,
                absorptionTime: meal.absorptionHours * 3600
            )
        }
    }

    private static func identifier(_ suffix: String) -> Data {
        Data("placeholder-\(suffix)".utf8)
    }
}

/// Adds entries one at a time, since `CarbStore` takes them singly.
private extension CarbStore {
    func addCarbEntries(_ entries: [NewCarbEntry], completion: @escaping (CarbStoreResult<[StoredCarbEntry]>) -> Void) {
        guard let entry = entries.first else {
            completion(.success([]))
            return
        }

        addCarbEntry(entry) { result in
            switch result {
            case .success(let stored):
                self.addCarbEntries(Array(entries.dropFirst())) { rest in
                    switch rest {
                    case .success(let storedRest):
                        completion(.success([stored] + storedRest))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
}

#endif
