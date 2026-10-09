//
//  SettingsManager.swift
//  Loop
//
//  Created by Pete Schwamb on 2/27/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit
import UserNotifications
import UIKit
import HealthKit
import Combine
import LoopCore
import LoopKitUI
import os.log


protocol DeviceStatusProvider {
    var pumpManagerStatus: PumpManagerStatus? { get }
    var cgmManagerStatus: CGMManagerStatus? { get }
}

class SettingsManager {

    let settingsStore: SettingsStore

    var remoteDataServicesManager: RemoteDataServicesManager?

    var deviceStatusProvider: DeviceStatusProvider?

    var alertMuter: AlertMuter

    var displayGlucosePreference: DisplayGlucosePreference?

    public var latestSettings: StoredSettings

    private var remoteNotificationRegistrationResult: Swift.Result<Data,Error>?

    private var cancellables: Set<AnyCancellable> = []

    private let log = OSLog(category: "SettingsManager")

    init(cacheStore: PersistenceController, expireAfter: TimeInterval, alertMuter: AlertMuter)
    {
        settingsStore = SettingsStore(store: cacheStore, expireAfter: expireAfter)
        self.alertMuter = alertMuter

        if let storedSettings = settingsStore.latestSettings {
            latestSettings = storedSettings
        } else {
            log.default("SettingsStore has no latestSettings: initializing empty StoredSettings.")
            latestSettings = StoredSettings()
        }

        settingsStore.delegate = self

        // Migrate old settings from UserDefaults
        if var legacyLoopSettings = UserDefaults.appGroup?.legacyLoopSettings {
            log.default("Migrating settings from UserDefaults")
            legacyLoopSettings.insulinSensitivitySchedule = UserDefaults.appGroup?.legacyInsulinSensitivitySchedule
            legacyLoopSettings.basalRateSchedule = UserDefaults.appGroup?.legacyBasalRateSchedule
            legacyLoopSettings.carbRatioSchedule = UserDefaults.appGroup?.legacyCarbRatioSchedule
            legacyLoopSettings.defaultRapidActingModel = .rapidActingAdult

            storeSettings(newLoopSettings: legacyLoopSettings)

            UserDefaults.appGroup?.removeLegacyLoopSettings()
        }

        NotificationCenter.default
            .publisher(for: .LoopDataUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                let context = note.userInfo?[LoopDataManager.LoopUpdateContextKey] as! LoopDataManager.LoopUpdateContext.RawValue
                if case .preferences = LoopDataManager.LoopUpdateContext(rawValue: context), let loopDataManager = note.object as? LoopDataManager {
                    self?.storeSettings(newLoopSettings: loopDataManager.settings)
                }
            }
            .store(in: &cancellables)

        // The app's own settings live in UserDefaults; any write there may have changed one.
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, LoopAppSettings.json() != self.latestSettings.appSettings else { return }
                self.storeSettings()
            }
            .store(in: &cancellables)

        self.alertMuter.$configuration
            .sink { [weak self] alertMuterConfiguration in
                guard var notificationSettings = self?.latestSettings.notificationSettings else { return }
                let newTemporaryMuteAlertsSetting = NotificationSettings.TemporaryMuteAlertSetting(enabled: alertMuterConfiguration.shouldMute, duration: alertMuterConfiguration.duration)
                if notificationSettings.temporaryMuteAlertsSetting != newTemporaryMuteAlertsSetting {
                    notificationSettings.temporaryMuteAlertsSetting = newTemporaryMuteAlertsSetting
                    self?.storeSettings(notificationSettings: notificationSettings)
                }
            }
            .store(in: &cancellables)
    }

    var loopSettings: LoopSettings {
        get {
            return LoopSettings(
                dosingEnabled: latestSettings.dosingEnabled,
                glucoseTargetRangeSchedule: latestSettings.glucoseTargetRangeSchedule,
                insulinSensitivitySchedule: latestSettings.insulinSensitivitySchedule,
                basalRateSchedule: latestSettings.basalRateSchedule,
                carbRatioSchedule: latestSettings.carbRatioSchedule,
                preMealTargetRange: latestSettings.preMealTargetRange,
                legacyWorkoutTargetRange: latestSettings.workoutTargetRange,
                overridePresets: latestSettings.overridePresets,
                scheduleOverride: latestSettings.scheduleOverride,
                preMealOverride: latestSettings.preMealOverride,
                maximumBasalRatePerHour: latestSettings.maximumBasalRatePerHour,
                maximumBolus: latestSettings.maximumBolus,
                suspendThreshold: latestSettings.suspendThreshold,
                automaticDosingStrategy: latestSettings.automaticDosingStrategy,
                defaultRapidActingModel: latestSettings.defaultRapidActingModel?.presetForRapidActingInsulin)
        }
    }

    private func mergeSettings(newLoopSettings: LoopSettings? = nil, notificationSettings: NotificationSettings? = nil, deviceToken: String? = nil) -> StoredSettings
    {
        let newLoopSettings = newLoopSettings ?? loopSettings
        let newNotificationSettings = notificationSettings ?? settingsStore.latestSettings?.notificationSettings

        return StoredSettings(date: Date(),
                              dosingEnabled: newLoopSettings.dosingEnabled,
                              glucoseTargetRangeSchedule: newLoopSettings.glucoseTargetRangeSchedule,
                              preMealTargetRange: newLoopSettings.preMealTargetRange,
                              workoutTargetRange: newLoopSettings.legacyWorkoutTargetRange,
                              overridePresets: newLoopSettings.overridePresets,
                              scheduleOverride: newLoopSettings.scheduleOverride,
                              preMealOverride: newLoopSettings.preMealOverride,
                              maximumBasalRatePerHour: newLoopSettings.maximumBasalRatePerHour,
                              maximumBolus: newLoopSettings.maximumBolus,
                              suspendThreshold: newLoopSettings.suspendThreshold,
                              deviceToken: deviceToken,
                              insulinType: deviceStatusProvider?.pumpManagerStatus?.insulinType,
                              defaultRapidActingModel: newLoopSettings.defaultRapidActingModel.map(StoredInsulinModel.init),
                              basalRateSchedule: newLoopSettings.basalRateSchedule,
                              insulinSensitivitySchedule: newLoopSettings.insulinSensitivitySchedule,
                              carbRatioSchedule: newLoopSettings.carbRatioSchedule,
                              notificationSettings: newNotificationSettings,
                              controllerDevice: UIDevice.current.controllerDevice,
                              cgmDevice: deviceStatusProvider?.cgmManagerStatus?.device,
                              pumpDevice: deviceStatusProvider?.pumpManagerStatus?.device,
                              bloodGlucoseUnit: displayGlucosePreference?.unit,
                              automaticDosingStrategy: newLoopSettings.automaticDosingStrategy,
                              appSettings: LoopAppSettings.json())
    }

    func storeSettings(newLoopSettings: LoopSettings? = nil, notificationSettings: NotificationSettings? = nil) {

        var deviceTokenStr: String?

        if case .success(let deviceToken) = remoteNotificationRegistrationResult {
            deviceTokenStr = deviceToken.hexadecimalString
        }

        let mergedSettings = mergeSettings(newLoopSettings: newLoopSettings, notificationSettings: notificationSettings, deviceToken: deviceTokenStr)

        if latestSettings == mergedSettings {
            // Skipping unchanged settings store
            return
        }

        latestSettings = mergedSettings

        if remoteNotificationRegistrationResult == nil && FeatureFlags.remoteCommandsEnabled {
            // remote notification registration not finished
            return
        }

        if latestSettings.insulinSensitivitySchedule == nil {
            log.default("Saving settings with no ISF schedule.")
        }

        settingsStore.storeSettings(latestSettings) { error in
            if let error = error {
                self.log.error("Error storing settings: %{public}@", error.localizedDescription)
            }
        }
    }

    func storeSettingsCheckingNotificationPermissions() {
        UNUserNotificationCenter.current().getNotificationSettings() { notificationSettings in
            DispatchQueue.main.async {
                guard let latestSettings = self.settingsStore.latestSettings else {
                    return
                }

                let temporaryMuteAlertSetting = NotificationSettings.TemporaryMuteAlertSetting(enabled: self.alertMuter.configuration.shouldMute, duration: self.alertMuter.configuration.duration)
                let notificationSettings = NotificationSettings(notificationSettings, temporaryMuteAlertsSetting: temporaryMuteAlertSetting)

                if notificationSettings != latestSettings.notificationSettings
                {
                    self.storeSettings(notificationSettings: notificationSettings)
                }
            }
        }
    }

    func didBecomeActive () {
        storeSettingsCheckingNotificationPermissions()
    }

    func remoteNotificationRegistrationDidFinish(_ result: Swift.Result<Data,Error>) {
        self.remoteNotificationRegistrationResult = result
        storeSettings()
    }

    func purgeHistoricalSettingsObjects(completion: @escaping (Error?) -> Void) {
        settingsStore.purgeHistoricalSettingsObjects(completion: completion)
    }
}

// MARK: - SettingsStoreDelegate
extension SettingsManager: SettingsStoreDelegate {
    func settingsStoreHasUpdatedSettingsData(_ settingsStore: SettingsStore) {
        remoteDataServicesManager?.triggerUpload(for: .settings)
    }
}

private extension NotificationSettings {

    init(_ notificationSettings: UNNotificationSettings, temporaryMuteAlertsSetting: TemporaryMuteAlertSetting) {
        let timeSensitiveSetting: NotificationSettings.NotificationSetting
        let scheduledDeliverySetting: NotificationSettings.NotificationSetting

        if #available(iOS 15.0, *) {
            timeSensitiveSetting = NotificationSettings.NotificationSetting(notificationSettings.timeSensitiveSetting)
            scheduledDeliverySetting = NotificationSettings.NotificationSetting(notificationSettings.scheduledDeliverySetting)
        } else {
            timeSensitiveSetting = .unknown
            scheduledDeliverySetting = .unknown
        }

        self.init(authorizationStatus: NotificationSettings.AuthorizationStatus(notificationSettings.authorizationStatus),
                  soundSetting: NotificationSettings.NotificationSetting(notificationSettings.soundSetting),
                  badgeSetting: NotificationSettings.NotificationSetting(notificationSettings.badgeSetting),
                  alertSetting: NotificationSettings.NotificationSetting(notificationSettings.alertSetting),
                  notificationCenterSetting: NotificationSettings.NotificationSetting(notificationSettings.notificationCenterSetting),
                  lockScreenSetting: NotificationSettings.NotificationSetting(notificationSettings.lockScreenSetting),
                  carPlaySetting: NotificationSettings.NotificationSetting(notificationSettings.carPlaySetting),
                  alertStyle: NotificationSettings.AlertStyle(notificationSettings.alertStyle),
                  showPreviewsSetting: NotificationSettings.ShowPreviewsSetting(notificationSettings.showPreviewsSetting),
                  criticalAlertSetting: NotificationSettings.NotificationSetting(notificationSettings.criticalAlertSetting),
                  providesAppNotificationSettings: notificationSettings.providesAppNotificationSettings,
                  announcementSetting: NotificationSettings.NotificationSetting(notificationSettings.announcementSetting),
                  timeSensitiveSetting: timeSensitiveSetting,
                  scheduledDeliverySetting: scheduledDeliverySetting,
                  temporaryMuteAlertsSetting: temporaryMuteAlertsSetting
        )
    }
}

/// The settings Loop keeps outside `LoopSettings`, as one JSON object that Nightscout gets in
/// loopSettings next to the therapy settings, so someone reading the data there sees all of them.
enum LoopAppSettings {
    static func json(defaults: UserDefaults = .standard) -> Data? {
        let boost = defaults.fatProteinBoostSettings
        let calibration = defaults.fatProteinBoostCalibration
        let object: [String: Any] = [
            // With the automatic bolus dosing strategy, the share of the recommended dose given each loop.
            "bolusPartialApplicationFactor": LoopConstants.bolusPartialApplicationFactor,
            // When enabled, the share instead slides with glucose across this range.
            "glucoseBasedApplicationFactorEnabled": defaults.glucoseBasedApplicationFactorEnabled,
            "glucoseBasedApplicationFactorRange": [
                GlucoseBasedApplicationFactorStrategy.minPartialApplicationFactor,
                GlucoseBasedApplicationFactorStrategy.maxPartialApplicationFactor
            ],
            "integralRetrospectiveCorrectionEnabled": defaults.integralRetrospectiveCorrectionEnabled,
            "fatProteinBoost": [
                "enabled": boost.isEnabled,
                "minimumUnits": boost.minimumUnits,
                "delayMinutes": boost.delay / 60,
                "startGlucoseMgdl": boost.startGlucoseMgdl,
                "startGlucoseMmol": mmol(boost.startGlucoseMgdl),
                "stopGlucoseMgdl": boost.stopGlucoseMgdl,
                "stopGlucoseMmol": mmol(boost.stopGlucoseMgdl),
                "strengthPerUnit": boost.strengthPerUnit,
                "maximumStrength": boost.maximumStrength,
                "learnedFactor": calibration.factor,
                "recentOutcomes": calibration.outcomes.prefix(5).map { outcome in
                    [
                        "meal": outcome.mealName,
                        "start": ISO8601DateFormatter().string(from: outcome.start),
                        "end": ISO8601DateFormatter().string(from: outcome.end),
                        "units": outcome.units,
                        "strength": outcome.strength,
                        "peakMgdl": outcome.peakMgdl,
                        "lowestMgdl": outcome.lowestMgdl,
                        "verdict": outcome.verdict.rawValue,
                        "factorBefore": outcome.factorBefore,
                        "factorAfter": outcome.factorAfter
                    ] as [String: Any]
                }
            ] as [String: Any]
        ]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func mmol(_ mgdl: Double) -> Double {
        (mgdl / 18.0182 * 10).rounded() / 10
    }
}
