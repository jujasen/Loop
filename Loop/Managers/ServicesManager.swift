//
//  ServicesManager.swift
//  Loop
//
//  Created by Darin Krauss on 5/22/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import os.log
import HealthKit
import LoopKit
import LoopKitUI
import LoopCore
import Combine

class ServicesManager {

    private let pluginManager: PluginManager

    private let alertManager: AlertManager

    let analyticsServicesManager: AnalyticsServicesManager

    let loggingServicesManager: LoggingServicesManager

    let remoteDataServicesManager: RemoteDataServicesManager
    
    let settingsManager: SettingsManager
    
    weak var servicesManagerDelegate: ServicesManagerDelegate?
    weak var servicesManagerDosingDelegate: ServicesManagerDosingDelegate?
    
    private var services = [Service]()

    private let servicesLock = UnfairLock()

    private let log = OSLog(category: "ServicesManager")
    
    lazy private var cancellables = Set<AnyCancellable>()

    @PersistedProperty(key: "Services")
    var rawServices: [Service.RawValue]?

    init(
        pluginManager: PluginManager,
        alertManager: AlertManager,
        analyticsServicesManager: AnalyticsServicesManager,
        loggingServicesManager: LoggingServicesManager,
        remoteDataServicesManager: RemoteDataServicesManager,
        settingsManager: SettingsManager,
        servicesManagerDelegate: ServicesManagerDelegate,
        servicesManagerDosingDelegate: ServicesManagerDosingDelegate
    ) {
        self.pluginManager = pluginManager
        self.alertManager = alertManager
        self.analyticsServicesManager = analyticsServicesManager
        self.loggingServicesManager = loggingServicesManager
        self.remoteDataServicesManager = remoteDataServicesManager
        self.settingsManager = settingsManager
        self.servicesManagerDelegate = servicesManagerDelegate
        self.servicesManagerDosingDelegate = servicesManagerDosingDelegate
        restoreState()
    }

    public var availableServices: [ServiceDescriptor] {
        return pluginManager.availableServices + availableStaticServices
    }

    func setupService(withIdentifier identifier: String) -> Swift.Result<SetupUIResult<ServiceViewController, Service>, Error> {
        switch setupServiceUI(withIdentifier: identifier) {
        case .failure(let error):
            return .failure(error)
        case .success(let success):
            switch success {
            case .userInteractionRequired(let viewController):
                return .success(.userInteractionRequired(viewController))
            case .createdAndOnboarded(let serviceUI):
                return .success(.createdAndOnboarded(serviceUI))
            }
        }
    }

    struct UnknownServiceIdentifierError: Error {}
    
    fileprivate func setupServiceUI(withIdentifier identifier: String) -> Swift.Result<SetupUIResult<ServiceViewController, ServiceUI>, Error> {
        guard let serviceUIType = serviceUITypeByIdentifier(identifier) else {
            return .failure(UnknownServiceIdentifierError())
        }

        let result = serviceUIType.setupViewController(colorPalette: .default, pluginHost: self)
        if case .createdAndOnboarded(let serviceUI) = result {
            serviceOnboarding(didCreateService: serviceUI)
            serviceOnboarding(didOnboardService: serviceUI)
        }

        return .success(result)
    }

    func serviceUITypeByIdentifier(_ identifier: String) -> ServiceUI.Type? {
        return pluginManager.getServiceTypeByIdentifier(identifier) ?? staticServicesByIdentifier[identifier] as? ServiceUI.Type
    }

    private func serviceTypeFromRawValue(_ rawValue: Service.RawStateValue) -> Service.Type? {
        guard let identifier = rawValue["serviceIdentifier"] as? String else {
            return nil
        }

        return serviceUITypeByIdentifier(identifier)
    }

    private func serviceFromRawValue(_ rawValue: Service.RawStateValue) -> Service? {
        guard let serviceType = serviceTypeFromRawValue(rawValue),
            let rawState = rawValue["state"] as? Service.RawStateValue
            else {
                return nil
        }

        return serviceType.init(rawState: rawState)
    }

    public var activeServices: [Service] {
        return servicesLock.withLock { services }
    }

    public func addActiveService(_ service: Service) {
        servicesLock.withLock {
            service.serviceDelegate = self
            service.stateDelegate = self

            services.append(service)

            if let analyticsService = service as? AnalyticsService {
                analyticsServicesManager.addService(analyticsService)
            }
            if let loggingService = service as? LoggingService {
                loggingServicesManager.addService(loggingService)
            }
            if let remoteDataService = service as? RemoteDataService {
                remoteDataServicesManager.addService(remoteDataService)
            }

            saveState()
        }
    }

    public func removeActiveService(_ service: Service) {
        servicesLock.withLock {
            if let remoteDataService = service as? RemoteDataService {
                remoteDataServicesManager.removeService(remoteDataService)
            }
            if let loggingService = service as? LoggingService {
                loggingServicesManager.removeService(loggingService)
            }
            if let analyticsService = service as? AnalyticsService {
                analyticsServicesManager.removeService(analyticsService)
            }

            services.removeAll { $0.pluginIdentifier == service.pluginIdentifier }

            service.serviceDelegate = nil
            service.stateDelegate = nil

            saveState()
        }
    }

    private func saveState() {
        rawServices = services.compactMap { $0.rawValue }
        UserDefaults.appGroup?.clearLegacyServicesState()
    }

    private func restoreState() {
        let rawServices = rawServices ?? UserDefaults.appGroup?.legacyServicesState ?? []
        rawServices.forEach { rawValue in
            if let service = serviceFromRawValue(rawValue) {
                service.serviceDelegate = self
                service.stateDelegate = self

                services.append(service)

                if let analyticsService = service as? AnalyticsService {
                    analyticsServicesManager.restoreService(analyticsService)
                }
                if let loggingService = service as? LoggingService {
                    loggingServicesManager.restoreService(loggingService)
                }
                if let remoteDataService = service as? RemoteDataService {
                    remoteDataServicesManager.restoreService(remoteDataService)
                }
            }
        }
    }
    
    func handleRemoteNotification(_ notification: [String: AnyObject]) {
        Task {
            log.default("Remote Notification: Handling notification %{public}@", notification)
            
            guard FeatureFlags.remoteCommandsEnabled else {
                log.error("Remote Notification: Remote Commands not enabled.")
                return
            }
            
            let backgroundTask = await beginBackgroundTask(name: "Handle Remote Notification")
            do {
                try await remoteDataServicesManager.remoteNotificationWasReceived(notification)
            } catch {
                log.error("Remote Notification: Error: %{public}@", String(describing: error))
            }
            
            await endBackgroundTask(backgroundTask)
            log.default("Remote Notification: Finished handling")
        }
    }
    
    private func beginBackgroundTask(name: String) async -> UIBackgroundTaskIdentifier? {
        var backgroundTask: UIBackgroundTaskIdentifier?
        backgroundTask = await UIApplication.shared.beginBackgroundTask(withName: name) {
            guard let backgroundTask = backgroundTask else {return}
            Task {
                await UIApplication.shared.endBackgroundTask(backgroundTask)
            }
            
            self.log.error("Background Task Expired: %{public}@", name)
        }
        
        return backgroundTask
    }
    
    private func endBackgroundTask(_ backgroundTask: UIBackgroundTaskIdentifier?) async {
        guard let backgroundTask else {return}
        await UIApplication.shared.endBackgroundTask(backgroundTask)
    }
}

public protocol ServicesManagerDosingDelegate: AnyObject {
    func deliverBolus(amountInUnits: Double) async throws
    /// What the current pump can deliver, or nil without a pump.
    func remoteTherapySettingsPumpIncrements() -> RemoteTherapySettingsPumpIncrements?
    /// Through the same preflight (cancelling a temp basal above a lowered maximum) and pump sync as Loop's delivery limits editor.
    func syncRemoteDeliveryLimits(_ deliveryLimits: DeliveryLimits) async throws -> DeliveryLimits
    /// Through the same pump sync as Loop's basal rate editor.
    func syncRemoteBasalRateSchedule(items: [RepeatingScheduleValue<Double>]) async throws -> BasalRateSchedule
}

/// The pump increments a remote therapy settings change is checked against.
public struct RemoteTherapySettingsPumpIncrements: Equatable {
    public let basalRates: [Double]
    public let maximumBolusVolumes: [Double]
    public let maximumBasalScheduleEntryCount: Int

    public init(basalRates: [Double], maximumBolusVolumes: [Double], maximumBasalScheduleEntryCount: Int) {
        self.basalRates = basalRates
        self.maximumBolusVolumes = maximumBolusVolumes
        self.maximumBasalScheduleEntryCount = maximumBasalScheduleEntryCount
    }
}

public protocol ServicesManagerDelegate: AnyObject {
    func enactOverride(name: String, duration: TemporaryScheduleOverride.Duration?, remoteAddress: String) async throws
    func cancelCurrentOverride() async throws
    func deliverCarbs(amountInGrams: Double, absorptionTime: TimeInterval?, foodType: String?, startDate: Date?) async throws
    func updateTherapySettings(_ changes: (_ settings: inout LoopSettings) -> Void) async
}

// MARK: - StatefulPluggableDelegate
extension ServicesManager: StatefulPluggableDelegate {
    func pluginDidUpdateState(_ plugin: StatefulPluggable) {
        saveState()
    }

    func pluginWantsDeletion(_ plugin: StatefulPluggable) {
        guard let service = plugin as? Service else { return }
        log.default("Service with identifier '%{public}@' deleted", service.pluginIdentifier)
        removeActiveService(service)
    }
}

// MARK: - ServiceDelegate

extension ServicesManager: ServiceDelegate {
    var hostIdentifier: String {
        return "com.loopkit.Loop"
    }

    var hostVersion: String {
        var semanticVersion = Bundle.main.shortVersionString

        while semanticVersion.split(separator: ".").count < 3 {
            semanticVersion += ".0"
        }

        semanticVersion += "+\(Bundle.main.version)"

        return semanticVersion
    }
    
    func enactRemoteOverride(name: String, durationTime: TimeInterval?, remoteAddress: String) async throws {
        
        var duration: TemporaryScheduleOverride.Duration? = nil
        if let durationTime = durationTime {
            
            guard durationTime <= LoopConstants.maxOverrideDurationTime else {
                throw OverrideActionError.durationExceedsMax(LoopConstants.maxOverrideDurationTime)
            }
            
            guard durationTime >= 0 else {
                throw OverrideActionError.negativeDuration
            }
            
            if durationTime == 0 {
                duration = .indefinite
            } else {
                duration = .finite(durationTime)
            }
        }
        
        try await servicesManagerDelegate?.enactOverride(name: name, duration: duration, remoteAddress: remoteAddress)
        await remoteDataServicesManager.triggerUpload(for: .overrides)
    }
    
    enum OverrideActionError: LocalizedError {
        
        case durationExceedsMax(TimeInterval)
        case negativeDuration
        
        var errorDescription: String? {
            switch self {
            case .durationExceedsMax(let maxDurationTime):
                return String(format: NSLocalizedString("Duration exceeds: %1$.1f hours", comment: "Override error description: duration exceed max (1: max duration in hours)."), maxDurationTime.hours)
            case .negativeDuration:
                return String(format: NSLocalizedString("Negative duration not allowed", comment: "Override error description: negative duration error."))
            }
        }
    }
    
    func cancelRemoteOverride() async throws {
        try await servicesManagerDelegate?.cancelCurrentOverride()
        await remoteDataServicesManager.triggerUpload(for: .overrides)
    }
    
    func deliverRemoteCarbs(amountInGrams: Double, absorptionTime: TimeInterval?, foodType: String?, startDate: Date?) async throws {
        do {
            try await servicesManagerDelegate?.deliverCarbs(amountInGrams: amountInGrams, absorptionTime: absorptionTime, foodType: foodType, startDate: startDate)
            await NotificationManager.sendRemoteCarbEntryNotification(amountInGrams: amountInGrams)
            await remoteDataServicesManager.triggerUpload(for: .carb)
            analyticsServicesManager.didAddCarbs(source: "Remote", amount: amountInGrams)
        } catch {
            await NotificationManager.sendRemoteCarbEntryFailureNotification(for: error, amountInGrams: amountInGrams)
            throw error
        }
    }
    
    func deliverRemoteBolus(amountInUnits: Double) async throws {
        do {
            
            guard amountInUnits > 0 else {
                throw BolusActionError.invalidBolus
            }
            
            guard let maxBolusAmount = settingsManager.loopSettings.maximumBolus else {
                throw BolusActionError.missingMaxBolus
            }
            
            guard amountInUnits <= maxBolusAmount else {
                throw BolusActionError.exceedsMaxBolus
            }
            
            try await servicesManagerDosingDelegate?.deliverBolus(amountInUnits: amountInUnits)
            await NotificationManager.sendRemoteBolusNotification(amount: amountInUnits)
            await remoteDataServicesManager.triggerUpload(for: .dose)
            analyticsServicesManager.didBolus(source: "Remote", units: amountInUnits)
        } catch {
            await NotificationManager.sendRemoteBolusFailureNotification(for: error, amountInUnits: amountInUnits)
            throw error
        }
    }
    
    func applyRemoteTherapySettings(_ change: RemoteTherapySettingsChange) async throws {
        do {
            let current = settingsManager.loopSettings
            var update = try Self.therapySettingsUpdate(for: change, replacing: current, pump: servicesManagerDosingDelegate?.remoteTherapySettingsPumpIncrements())
            try await syncPumpSettings(of: &update, replacing: current)
            let validatedUpdate = update
            await servicesManagerDelegate?.updateTherapySettings { settings in
                validatedUpdate.apply(to: &settings)
            }
            if let enabled = change.glucoseBasedPartialApplication {
                UserDefaults.standard.glucoseBasedApplicationFactorEnabled = enabled
            }
            if let enabled = change.integralRetrospectiveCorrection {
                UserDefaults.standard.integralRetrospectiveCorrectionEnabled = enabled
            }
            log.default("Applied remote therapy settings: %{public}@", String(describing: change))
            await NotificationManager.sendRemoteTherapySettingsNotification(for: change)
            await remoteDataServicesManager.triggerUpload(for: .settings)
        } catch {
            await NotificationManager.sendRemoteTherapySettingsFailureNotification(for: error, change: change)
            throw error
        }
    }

    /// Sends new delivery limits, then new basal rates, to the pump the same way Loop's settings editors
    /// do (a temp basal above a lowered maximum is cancelled first), and keeps what the pump reports back.
    /// If the basal rates fail after the limits went through, the old limits are sent back so that no
    /// part of the change is left behind.
    private func syncPumpSettings(of update: inout RemoteTherapySettingsUpdate, replacing current: LoopSettings) async throws {
        let changesBasalRates = update.change.basalRateItems != nil
        guard update.changesDeliveryLimits || changesBasalRates else {
            return
        }
        guard let pump = servicesManagerDosingDelegate else {
            throw TherapySettingsActionError.noPump
        }

        var didSyncDeliveryLimits = false
        if update.changesDeliveryLimits {
            let synced = try await pump.syncRemoteDeliveryLimits(update.deliveryLimits)
            update.settings.maximumBasalRatePerHour = synced.maximumBasalRate?.doubleValue(for: .internationalUnitsPerHour) ?? update.settings.maximumBasalRatePerHour
            update.settings.maximumBolus = synced.maximumBolus?.doubleValue(for: .internationalUnit()) ?? update.settings.maximumBolus
            didSyncDeliveryLimits = true
        }

        if changesBasalRates, let items = update.settings.basalRateSchedule?.items {
            do {
                update.settings.basalRateSchedule = try await pump.syncRemoteBasalRateSchedule(items: items)
            } catch {
                if didSyncDeliveryLimits {
                    let previous = DeliveryLimits(
                        maximumBasalRate: current.maximumBasalRatePerHour.map { HKQuantity(unit: .internationalUnitsPerHour, doubleValue: $0) },
                        maximumBolus: current.maximumBolus.map { HKQuantity(unit: .internationalUnit(), doubleValue: $0) }
                    )
                    do {
                        _ = try await pump.syncRemoteDeliveryLimits(previous)
                    } catch let revertError {
                        log.error("Could not restore delivery limits after a failed remote basal rate change: %{public}@", String(describing: revertError))
                    }
                }
                throw error
            }
        }
    }

    /// A remote change that has passed every guardrail, as the settings it leaves behind.
    struct RemoteTherapySettingsUpdate {
        let change: RemoteTherapySettingsChange
        /// The current settings with the change applied.
        var settings: LoopSettings

        var changesDeliveryLimits: Bool {
            return change.maximumBasalRatePerHour != nil || change.maximumBolus != nil
        }

        var deliveryLimits: DeliveryLimits {
            return DeliveryLimits(
                maximumBasalRate: settings.maximumBasalRatePerHour.map { HKQuantity(unit: .internationalUnitsPerHour, doubleValue: $0) },
                maximumBolus: settings.maximumBolus.map { HKQuantity(unit: .internationalUnit(), doubleValue: $0) }
            )
        }

        /// Copies only the settings the change touches, so that anything else that changed meanwhile
        /// (an override being enabled, say) is kept.
        func apply(to target: inout LoopSettings) {
            if change.carbRatioItems != nil {
                target.carbRatioSchedule = settings.carbRatioSchedule
            }
            if change.insulinSensitivityItems != nil {
                target.insulinSensitivitySchedule = settings.insulinSensitivitySchedule
            }
            if change.basalRateItems != nil {
                target.basalRateSchedule = settings.basalRateSchedule
            }
            if change.correctionRangeItems != nil {
                target.glucoseTargetRangeSchedule = settings.glucoseTargetRangeSchedule
            }
            if change.preMealTargetRange != nil {
                target.preMealTargetRange = settings.preMealTargetRange
            }
            if change.workoutTargetRange != nil {
                target.legacyWorkoutTargetRange = settings.legacyWorkoutTargetRange
            }
            if change.suspendThreshold != nil {
                target.suspendThreshold = settings.suspendThreshold
            }
            if changesDeliveryLimits {
                target.maximumBasalRatePerHour = settings.maximumBasalRatePerHour
                target.maximumBolus = settings.maximumBolus
            }
            if change.insulinModel != nil {
                target.defaultRapidActingModel = settings.defaultRapidActingModel
            }
            if change.dosingStrategy != nil {
                target.automaticDosingStrategy = settings.automaticDosingStrategy
            }
            if change.closedLoop != nil {
                target.dosingEnabled = settings.dosingEnabled
            }
            if change.overridePresets != nil {
                target.overridePresets = settings.overridePresets
            }
        }
    }

    /// Applies a remote change to `current` and holds every changed value to the same absolute limits as
    /// Loop's own settings editors, checked against the settings as they will be once the whole change is
    /// saved (so a new basal rate is held to a new maximum basal rate sent with it). One value outside its
    /// limits rejects the whole change.
    static func therapySettingsUpdate(for change: RemoteTherapySettingsChange, replacing current: LoopSettings, pump: RemoteTherapySettingsPumpIncrements?) throws -> RemoteTherapySettingsUpdate {
        var settings = current

        let (carbRatioSchedule, insulinSensitivitySchedule) = try schedules(for: change, replacing: current)
        if let carbRatioSchedule {
            settings.carbRatioSchedule = carbRatioSchedule
        }
        if let insulinSensitivitySchedule {
            settings.insulinSensitivitySchedule = insulinSensitivitySchedule
        }

        try applyDeliveryChanges(of: change, to: &settings, pump: pump)
        try applyGlucoseChanges(of: change, to: &settings, replacing: current)

        if let presets = change.overridePresets {
            settings.overridePresets = try overridePresets(presets, unit: change.glucoseUnit, replacing: current.overridePresets)
        }
        if let insulinModel = change.insulinModel {
            settings.defaultRapidActingModel = insulinModel
        }
        if let dosingStrategy = change.dosingStrategy {
            settings.automaticDosingStrategy = dosingStrategy
        }
        if let closedLoop = change.closedLoop {
            settings.dosingEnabled = closedLoop
        }

        return RemoteTherapySettingsUpdate(change: change, settings: settings)
    }

    /// Basal rates, maximum basal rate and maximum bolus: each must be a value the pump can deliver, within
    /// the guardrails of Loop's basal rate and delivery limits editors.
    private static func applyDeliveryChanges(of change: RemoteTherapySettingsChange, to settings: inout LoopSettings, pump: RemoteTherapySettingsPumpIncrements?) throws {
        guard change.basalRateItems != nil || change.maximumBasalRatePerHour != nil || change.maximumBolus != nil else {
            return
        }
        // The guardrails below need at least one positive basal rate and a couple of bolus volumes.
        guard let pump,
              pump.basalRates.contains(where: { $0 > 0 && $0 <= 30 }),
              pump.maximumBolusVolumes.filter({ $0 > 0 && $0 <= 30 }).count >= 2,
              pump.maximumBolusVolumes.contains(where: { $0 > 0 && $0 < 20 })
        else {
            throw TherapySettingsActionError.noPump
        }

        let resultingMaximumBasalRate = change.maximumBasalRatePerHour ?? settings.maximumBasalRatePerHour

        if let items = change.basalRateItems {
            guard items.count <= pump.maximumBasalScheduleEntryCount else {
                throw TherapySettingsActionError.tooManyBasalRates(items.count, pump.maximumBasalScheduleEntryCount)
            }
            let bounds = Guardrail.basalRate(supportedBasalRates: pump.basalRates).absoluteBounds
            let lowerBound = bounds.lowerBound.doubleValue(for: .internationalUnitsPerHour)
            let upperBound = min(bounds.upperBound.doubleValue(for: .internationalUnitsPerHour), resultingMaximumBasalRate ?? .infinity)
            let syncedItems = try items.map { item -> RepeatingScheduleValue<Double> in
                guard item.value >= lowerBound - matchingTolerance, item.value <= upperBound + matchingTolerance else {
                    throw TherapySettingsActionError.basalRateOutOfRange(item.value, lowerBound...max(lowerBound, upperBound))
                }
                guard let rate = supportedValue(matching: item.value, in: pump.basalRates) else {
                    throw TherapySettingsActionError.basalRateNotSupported(item.value)
                }
                return RepeatingScheduleValue(startTime: item.startTime, value: rate)
            }
            settings.basalRateSchedule = BasalRateSchedule(dailyItems: syncedItems, timeZone: settings.basalRateSchedule?.timeZone)
            guard settings.basalRateSchedule != nil else { throw RemoteTherapySettingsError.invalidSchedule }
        }

        if let maximumBasalRate = change.maximumBasalRatePerHour {
            let scheduledBasalRange = settings.basalRateSchedule?.valueRange()
            let lowestCarbRatio = settings.carbRatioSchedule?.lowestValue()
            let bounds = Guardrail.maximumBasalRate(supportedBasalRates: pump.basalRates, scheduledBasalRange: scheduledBasalRange, lowestCarbRatio: lowestCarbRatio).absoluteBounds
            let lowerBound = bounds.lowerBound.doubleValue(for: .internationalUnitsPerHour)
            let upperBound = bounds.upperBound.doubleValue(for: .internationalUnitsPerHour)
            guard maximumBasalRate >= lowerBound - matchingTolerance, maximumBasalRate <= upperBound + matchingTolerance else {
                throw TherapySettingsActionError.maximumBasalRateOutOfRange(maximumBasalRate, lowerBound...upperBound)
            }
            let selectable = Guardrail.selectableMaxBasalRates(supportedBasalRates: pump.basalRates, scheduledBasalRange: scheduledBasalRange, lowestCarbRatio: lowestCarbRatio)
            guard let rate = supportedValue(matching: maximumBasalRate, in: selectable) else {
                throw TherapySettingsActionError.maximumBasalRateNotSupported(maximumBasalRate)
            }
            settings.maximumBasalRatePerHour = rate
        }

        if let maximumBolus = change.maximumBolus {
            let bounds = Guardrail.maximumBolus(supportedBolusVolumes: pump.maximumBolusVolumes).absoluteBounds
            let lowerBound = bounds.lowerBound.doubleValue(for: .internationalUnit())
            let upperBound = bounds.upperBound.doubleValue(for: .internationalUnit())
            guard maximumBolus >= lowerBound - matchingTolerance, maximumBolus <= upperBound + matchingTolerance else {
                throw TherapySettingsActionError.maximumBolusOutOfRange(maximumBolus, lowerBound...upperBound)
            }
            guard let volume = supportedValue(matching: maximumBolus, in: Guardrail.selectableBolusVolumes(supportedBolusVolumes: pump.maximumBolusVolumes)) else {
                throw TherapySettingsActionError.maximumBolusNotSupported(maximumBolus)
            }
            settings.maximumBolus = volume
        }
    }

    /// Correction range, pre-meal and workout ranges and the glucose safety limit (suspend threshold), held
    /// to the guardrails of Loop's editors and to each other: the safety limit may not be above the lowest
    /// of the ranges, and no range may start below the safety limit.
    ///
    /// Values are checked exactly as sent; they are then stored in the unit of the setting they replace,
    /// like Loop's editors do.
    private static func applyGlucoseChanges(of change: RemoteTherapySettingsChange, to settings: inout LoopSettings, replacing current: LoopSettings) throws {
        guard change.correctionRangeItems != nil || change.preMealTargetRange != nil || change.workoutTargetRange != nil || change.suspendThreshold != nil else {
            return
        }
        guard let unit = change.glucoseUnit else {
            throw RemoteTherapySettingsError.unsupportedGlucoseUnit
        }

        // A range with its ends swapped can't even be expressed as a ClosedRange.
        for item in change.correctionRangeItems ?? [] where item.value.minValue > item.value.maxValue {
            throw TherapySettingsActionError.invertedGlucoseRange(.correctionRange, item.value, unit)
        }
        if let range = change.preMealTargetRange, range.minValue > range.maxValue {
            throw TherapySettingsActionError.invertedGlucoseRange(.preMealRange, range, unit)
        }
        if let range = change.workoutTargetRange, range.minValue > range.maxValue {
            throw TherapySettingsActionError.invertedGlucoseRange(.workoutRange, range, unit)
        }

        var correctionRangeSchedule = current.glucoseTargetRangeSchedule
        if let items = change.correctionRangeItems {
            correctionRangeSchedule = GlucoseRangeSchedule(unit: unit, dailyItems: items, timeZone: current.glucoseTargetRangeSchedule?.timeZone)
            guard correctionRangeSchedule != nil else { throw RemoteTherapySettingsError.invalidSchedule }
        }
        let suspendThreshold = change.suspendThreshold.map { GlucoseThreshold(unit: unit, value: $0) } ?? current.suspendThreshold
        let preMealTargetRange = change.preMealTargetRange.map { $0.quantityRange(for: unit) } ?? current.preMealTargetRange
        let workoutTargetRange = change.workoutTargetRange.map { $0.quantityRange(for: unit) } ?? current.legacyWorkoutTargetRange

        if let value = change.suspendThreshold {
            let lowerBound = Guardrail.suspendThreshold.absoluteBounds.lowerBound
            let upperBound = Guardrail.maxSuspendThresholdValue(correctionRangeSchedule: correctionRangeSchedule, preMealTargetRange: preMealTargetRange, workoutTargetRange: workoutTargetRange)
            let quantity = HKQuantity(unit: unit, doubleValue: value)
            guard quantity >= lowerBound, quantity <= upperBound else {
                throw TherapySettingsActionError.suspendThresholdOutOfRange(value, displayBounds(lowerBound, upperBound, in: unit), unit)
            }
        }

        if let items = change.correctionRangeItems {
            let lowerBound = Guardrail.minCorrectionRangeValue(suspendThreshold: suspendThreshold)
            let upperBound = Guardrail.correctionRange.absoluteBounds.upperBound
            for item in items {
                try checkGlucoseRange(item.value, in: lowerBound, upperBound, unit: unit, setting: .correctionRange)
            }
        }

        // The absolute bounds of `Guardrail.correctionRangeOverride(for:correctionRangeScheduleRange:suspendThreshold:)`,
        // computed directly: building that guardrail's recommended bounds traps when the correction range
        // tops out above 180 mg/dL.
        if let range = change.preMealTargetRange {
            let lowerBound = suspendThreshold?.quantity ?? Guardrail.suspendThreshold.absoluteBounds.lowerBound
            try checkGlucoseRange(range, in: lowerBound, Guardrail.premealCorrectionRangeMaximum, unit: unit, setting: .preMealRange)
        }
        if let range = change.workoutTargetRange {
            let lowerBound = max(Guardrail.unconstrainedWorkoutCorrectionRange.absoluteBounds.lowerBound, suspendThreshold?.quantity ?? Guardrail.unconstrainedWorkoutCorrectionRange.absoluteBounds.lowerBound)
            try checkGlucoseRange(range, in: lowerBound, Guardrail.unconstrainedWorkoutCorrectionRange.absoluteBounds.upperBound, unit: unit, setting: .workoutRange)
        }

        if let items = change.correctionRangeItems {
            let storedUnit = current.glucoseTargetRangeSchedule?.unit ?? unit
            let storedItems = items.map { item in
                RepeatingScheduleValue(startTime: item.startTime, value: DoubleRange(minValue: convert(item.value.minValue, from: unit, to: storedUnit), maxValue: convert(item.value.maxValue, from: unit, to: storedUnit)))
            }
            settings.glucoseTargetRangeSchedule = GlucoseRangeSchedule(unit: storedUnit, dailyItems: storedItems, timeZone: current.glucoseTargetRangeSchedule?.timeZone)
        }
        if let value = change.suspendThreshold {
            let storedUnit = current.suspendThreshold?.unit ?? unit
            settings.suspendThreshold = GlucoseThreshold(unit: storedUnit, value: convert(value, from: unit, to: storedUnit))
        }
        if change.preMealTargetRange != nil {
            settings.preMealTargetRange = preMealTargetRange
        }
        if change.workoutTargetRange != nil {
            settings.legacyWorkoutTargetRange = workoutTargetRange
        }
    }

    /// The insulin needs Loop's override preset editor offers: 10% to 200%.
    static let overrideInsulinNeedsScaleFactorRange = 0.1...2.0

    /// Loop's override preset editor takes any target range, so hold a remote one to the widest range
    /// any of Loop's glucose editors allow: from the lowest glucose safety limit to the highest workout target.
    static var overrideTargetRangeBounds: ClosedRange<HKQuantity> {
        return Guardrail.suspendThreshold.absoluteBounds.lowerBound...Guardrail.unconstrainedWorkoutCorrectionRange.absoluteBounds.upperBound
    }

    /// Builds the new override preset list. A preset keeps the id of the existing preset with the same name.
    static func overridePresets(_ presets: [RemoteTherapySettingsChange.OverridePreset], unit: HKUnit?, replacing current: [TemporaryScheduleOverridePreset]) throws -> [TemporaryScheduleOverridePreset] {
        var names = Set<String>()
        return try presets.map { preset in
            guard !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TherapySettingsActionError.overridePresetNameMissing
            }
            guard names.insert(preset.name).inserted else {
                throw TherapySettingsActionError.overridePresetNameDuplicated(preset.name)
            }
            guard !preset.symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TherapySettingsActionError.overridePresetSymbolMissing(preset.name)
            }
            guard preset.duration >= 0, preset.duration <= LoopConstants.maxOverrideDurationTime else {
                throw TherapySettingsActionError.overridePresetDurationOutOfRange(preset.name, preset.duration)
            }
            let scaleFactor = preset.insulinNeedsScaleFactor
            guard scaleFactor >= overrideInsulinNeedsScaleFactorRange.lowerBound - matchingTolerance,
                  scaleFactor <= overrideInsulinNeedsScaleFactorRange.upperBound + matchingTolerance
            else {
                throw TherapySettingsActionError.overridePresetInsulinNeedsOutOfRange(preset.name, scaleFactor)
            }

            var targetRange: ClosedRange<HKQuantity>?
            if let range = preset.targetRange {
                guard let unit else {
                    throw RemoteTherapySettingsError.unsupportedGlucoseUnit
                }
                guard range.minValue <= range.maxValue else {
                    throw TherapySettingsActionError.invertedGlucoseRange(.overridePreset(preset.name), range, unit)
                }
                try checkGlucoseRange(range, in: overrideTargetRangeBounds.lowerBound, overrideTargetRangeBounds.upperBound, unit: unit, setting: .overridePreset(preset.name))
                targetRange = range.quantityRange(for: unit)
            }

            return TemporaryScheduleOverridePreset(
                id: current.first(where: { $0.name == preset.name })?.id ?? UUID(),
                symbol: preset.symbol,
                name: preset.name,
                settings: TemporaryScheduleOverrideSettings(targetRange: targetRange, insulinNeedsScaleFactor: abs(scaleFactor - 1.0) < matchingTolerance ? nil : scaleFactor),
                duration: preset.duration == 0 ? .indefinite : .finite(preset.duration)
            )
        }
    }

    /// How far a sent value may be from a pump increment and still count as that increment.
    private static let matchingTolerance = 1e-6

    private static func supportedValue(matching value: Double, in supportedValues: [Double]) -> Double? {
        return supportedValues.first { abs($0 - value) < matchingTolerance }
    }

    private static func checkGlucoseRange(_ range: DoubleRange, in lowerBound: HKQuantity, _ upperBound: HKQuantity, unit: HKUnit, setting: TherapySettingsActionError.GlucoseSetting) throws {
        let low = HKQuantity(unit: unit, doubleValue: range.minValue)
        let high = HKQuantity(unit: unit, doubleValue: range.maxValue)
        guard low >= lowerBound, high <= upperBound else {
            throw TherapySettingsActionError.glucoseRangeOutOfRange(setting, range, displayBounds(lowerBound, upperBound, in: unit), unit)
        }
    }

    private static func convert(_ value: Double, from unit: HKUnit, to storedUnit: HKUnit) -> Double {
        return HKQuantity(unit: unit, doubleValue: value).doubleValue(for: storedUnit, withRounding: unit != storedUnit)
    }

    /// Bounds as the values the editors offer in `unit`: rounded inwards to a tenth of a mmol/L or a whole mg/dL.
    static func displayBounds(_ lowerBound: HKQuantity, _ upperBound: HKQuantity, in unit: HKUnit) -> ClosedRange<Double> {
        let scale = unit == .millimolesPerLiter ? 10.0 : 1.0
        let lower = (lowerBound.doubleValue(for: unit) * scale - 1e-6).rounded(.up) / scale
        let upper = (upperBound.doubleValue(for: unit) * scale + 1e-6).rounded(.down) / scale
        return lower...max(lower, upper)
    }

    /// Builds the schedules a remote change asks for, holding each value to the same absolute limits
    /// as Loop's own settings editors. A schedule keeps the time zone — and, for insulin sensitivity,
    /// the glucose unit — of the schedule it replaces.
    static func schedules(for change: RemoteTherapySettingsChange, replacing current: LoopSettings) throws -> (CarbRatioSchedule?, InsulinSensitivitySchedule?) {
        var carbRatioSchedule: CarbRatioSchedule?
        if let items = change.carbRatioItems {
            let gramsPerUnit = HKUnit.gram().unitDivided(by: .internationalUnit())
            for item in items {
                let quantity = HKQuantity(unit: gramsPerUnit, doubleValue: item.value)
                guard Guardrail.carbRatio.absoluteBounds.contains(quantity) else {
                    throw TherapySettingsActionError.carbRatioOutOfRange(item.value)
                }
            }
            carbRatioSchedule = CarbRatioSchedule(unit: .gram(), dailyItems: items, timeZone: current.carbRatioSchedule?.timeZone)
            guard carbRatioSchedule != nil else { throw RemoteTherapySettingsError.invalidSchedule }
        }

        var insulinSensitivitySchedule: InsulinSensitivitySchedule?
        if let items = change.insulinSensitivityItems, let sentUnit = change.insulinSensitivityUnit {
            let storedUnit = current.insulinSensitivitySchedule?.unit ?? sentUnit
            let storedItems = try items.map { item -> RepeatingScheduleValue<Double> in
                let quantity = HKQuantity(unit: sentUnit.unitDivided(by: .internationalUnit()), doubleValue: item.value)
                guard Guardrail.insulinSensitivity.absoluteBounds.contains(quantity) else {
                    throw TherapySettingsActionError.insulinSensitivityOutOfRange(item.value, sentUnit)
                }
                let value = HKQuantity(unit: sentUnit, doubleValue: item.value).doubleValue(for: storedUnit, withRounding: sentUnit != storedUnit)
                return RepeatingScheduleValue(startTime: item.startTime, value: value)
            }
            insulinSensitivitySchedule = InsulinSensitivitySchedule(unit: storedUnit, dailyItems: storedItems, timeZone: current.insulinSensitivitySchedule?.timeZone)
            guard insulinSensitivitySchedule != nil else { throw RemoteTherapySettingsError.invalidSchedule }
        }

        return (carbRatioSchedule, insulinSensitivitySchedule)
    }

    enum TherapySettingsActionError: LocalizedError, Equatable {

        /// A glucose range setting, for naming it in an error.
        enum GlucoseSetting: Equatable {
            case correctionRange
            case preMealRange
            case workoutRange
            case overridePreset(String)

            var localizedName: String {
                switch self {
                case .correctionRange:
                    return NSLocalizedString("Correction range", comment: "Therapy settings error: name of the correction range setting.")
                case .preMealRange:
                    return NSLocalizedString("Pre-meal range", comment: "Therapy settings error: name of the pre-meal range setting.")
                case .workoutRange:
                    return NSLocalizedString("Workout range", comment: "Therapy settings error: name of the workout range setting.")
                case .overridePreset(let name):
                    return String(format: NSLocalizedString("Override preset %1$@ target range", comment: "Therapy settings error: name of an override preset's target range (1: preset name)."), name)
                }
            }
        }

        case carbRatioOutOfRange(Double)
        case insulinSensitivityOutOfRange(Double, HKUnit)
        case noPump
        case tooManyBasalRates(Int, Int)
        case basalRateOutOfRange(Double, ClosedRange<Double>)
        case basalRateNotSupported(Double)
        case maximumBasalRateOutOfRange(Double, ClosedRange<Double>)
        case maximumBasalRateNotSupported(Double)
        case maximumBolusOutOfRange(Double, ClosedRange<Double>)
        case maximumBolusNotSupported(Double)
        case suspendThresholdOutOfRange(Double, ClosedRange<Double>, HKUnit)
        case glucoseRangeOutOfRange(GlucoseSetting, DoubleRange, ClosedRange<Double>, HKUnit)
        case invertedGlucoseRange(GlucoseSetting, DoubleRange, HKUnit)
        case overridePresetNameMissing
        case overridePresetNameDuplicated(String)
        case overridePresetSymbolMissing(String)
        case overridePresetDurationOutOfRange(String, TimeInterval)
        case overridePresetInsulinNeedsOutOfRange(String, Double)

        var errorDescription: String? {
            switch self {
            case .carbRatioOutOfRange(let value):
                let bounds = Guardrail.carbRatio.absoluteBounds
                let gramsPerUnit = HKUnit.gram().unitDivided(by: .internationalUnit())
                return String(format: NSLocalizedString("Carb ratio %1$@ g/U is outside the allowed %2$@–%3$@ g/U", comment: "Therapy settings error description: carb ratio outside guardrails (1: value, 2: minimum, 3: maximum)."),
                              Self.format(value), Self.format(bounds.lowerBound.doubleValue(for: gramsPerUnit)), Self.format(bounds.upperBound.doubleValue(for: gramsPerUnit)))
            case .insulinSensitivityOutOfRange(let value, let unit):
                let bounds = Guardrail.insulinSensitivity.absoluteBounds
                let perUnit = unit.unitDivided(by: .internationalUnit())
                return String(format: NSLocalizedString("Insulin sensitivity %1$@ %4$@/U is outside the allowed %2$@–%3$@ %4$@/U", comment: "Therapy settings error description: insulin sensitivity outside guardrails (1: value, 2: minimum, 3: maximum, 4: glucose unit)."),
                              Self.format(value), Self.format(bounds.lowerBound.doubleValue(for: perUnit)), Self.format(bounds.upperBound.doubleValue(for: perUnit)), unit.shortLocalizedUnitString(avoidLineBreaking: false))
            case .noPump:
                return NSLocalizedString("Basal rates and delivery limits need a pump", comment: "Therapy settings error description: no pump to check or send basal rates and delivery limits to.")
            case .tooManyBasalRates(let count, let maximum):
                return String(format: NSLocalizedString("%1$d basal rates is more than the pump's %2$d", comment: "Therapy settings error description: too many basal rate schedule entries (1: entries sent, 2: pump maximum)."), count, maximum)
            case .basalRateOutOfRange(let value, let bounds):
                return String(format: NSLocalizedString("Basal rate %1$@ U/h is outside the allowed %2$@–%3$@ U/h", comment: "Therapy settings error description: basal rate outside guardrails or above the maximum basal rate (1: value, 2: minimum, 3: maximum)."),
                              Self.format(value, insulin: true), Self.format(bounds.lowerBound, insulin: true), Self.format(bounds.upperBound, insulin: true))
            case .basalRateNotSupported(let value):
                return String(format: NSLocalizedString("Basal rate %1$@ U/h is not a rate the pump can deliver", comment: "Therapy settings error description: basal rate not a pump increment (1: value)."), Self.format(value, insulin: true))
            case .maximumBasalRateOutOfRange(let value, let bounds):
                return String(format: NSLocalizedString("Maximum basal rate %1$@ U/h is outside the allowed %2$@–%3$@ U/h", comment: "Therapy settings error description: maximum basal rate outside guardrails (1: value, 2: minimum, 3: maximum)."),
                              Self.format(value, insulin: true), Self.format(bounds.lowerBound, insulin: true), Self.format(bounds.upperBound, insulin: true))
            case .maximumBasalRateNotSupported(let value):
                return String(format: NSLocalizedString("Maximum basal rate %1$@ U/h is not a rate the pump can deliver", comment: "Therapy settings error description: maximum basal rate not a pump increment (1: value)."), Self.format(value, insulin: true))
            case .maximumBolusOutOfRange(let value, let bounds):
                return String(format: NSLocalizedString("Maximum bolus %1$@ U is outside the allowed %2$@–%3$@ U", comment: "Therapy settings error description: maximum bolus outside guardrails (1: value, 2: minimum, 3: maximum)."),
                              Self.format(value, insulin: true), Self.format(bounds.lowerBound, insulin: true), Self.format(bounds.upperBound, insulin: true))
            case .maximumBolusNotSupported(let value):
                return String(format: NSLocalizedString("Maximum bolus %1$@ U is not a volume the pump can deliver", comment: "Therapy settings error description: maximum bolus not a pump increment (1: value)."), Self.format(value, insulin: true))
            case .suspendThresholdOutOfRange(let value, let bounds, let unit):
                return String(format: NSLocalizedString("Glucose safety limit %1$@ %4$@ is outside the allowed %2$@–%3$@ %4$@", comment: "Therapy settings error description: suspend threshold outside guardrails or above the lowest correction range (1: value, 2: minimum, 3: maximum, 4: glucose unit)."),
                              Self.format(value), Self.format(bounds.lowerBound), Self.format(bounds.upperBound), unit.shortLocalizedUnitString(avoidLineBreaking: false))
            case .glucoseRangeOutOfRange(let setting, let range, let bounds, let unit):
                return String(format: NSLocalizedString("%1$@ %2$@–%3$@ %6$@ is outside the allowed %4$@–%5$@ %6$@", comment: "Therapy settings error description: glucose range outside guardrails (1: setting name, 2: low, 3: high, 4: minimum, 5: maximum, 6: glucose unit)."),
                              setting.localizedName, Self.format(range.minValue), Self.format(range.maxValue), Self.format(bounds.lowerBound), Self.format(bounds.upperBound), unit.shortLocalizedUnitString(avoidLineBreaking: false))
            case .invertedGlucoseRange(let setting, let range, let unit):
                return String(format: NSLocalizedString("%1$@ %2$@–%3$@ %4$@ has its low value above its high value", comment: "Therapy settings error description: glucose range low above high (1: setting name, 2: low, 3: high, 4: glucose unit)."),
                              setting.localizedName, Self.format(range.minValue), Self.format(range.maxValue), unit.shortLocalizedUnitString(avoidLineBreaking: false))
            case .overridePresetNameMissing:
                return NSLocalizedString("An override preset has no name", comment: "Therapy settings error description: override preset without a name.")
            case .overridePresetNameDuplicated(let name):
                return String(format: NSLocalizedString("More than one override preset is named %1$@", comment: "Therapy settings error description: two override presets with the same name (1: name)."), name)
            case .overridePresetSymbolMissing(let name):
                return String(format: NSLocalizedString("Override preset %1$@ has no symbol", comment: "Therapy settings error description: override preset without a symbol (1: name)."), name)
            case .overridePresetDurationOutOfRange(let name, let duration):
                return String(format: NSLocalizedString("Override preset %1$@ duration %2$@ h is outside the allowed 0–%3$@ h", comment: "Therapy settings error description: override preset duration out of range (1: name, 2: duration in hours, 3: maximum in hours)."),
                              name, Self.format(duration.hours), Self.format(LoopConstants.maxOverrideDurationTime.hours))
            case .overridePresetInsulinNeedsOutOfRange(let name, let scaleFactor):
                let bounds = ServicesManager.overrideInsulinNeedsScaleFactorRange
                return String(format: NSLocalizedString("Override preset %1$@ insulin needs %2$@%% is outside the allowed %3$@–%4$@%%", comment: "Therapy settings error description: override preset insulin needs out of range (1: name, 2: percentage, 3: minimum percentage, 4: maximum percentage)."),
                              name, Self.format(scaleFactor * 100), Self.format(bounds.lowerBound * 100), Self.format(bounds.upperBound * 100))
            }
        }

        /// Glucose and carb ratios to a tenth, insulin to the thousandth some pumps deliver.
        private static func format(_ value: Double, insulin: Bool = false) -> String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = insulin ? 3 : 1
            return formatter.string(from: value as NSNumber) ?? "\(value)"
        }
    }

    enum BolusActionError: LocalizedError {
        
        case invalidBolus
        case missingMaxBolus
        case exceedsMaxBolus
        
        var errorDescription: String? {
            switch self {
            case .invalidBolus:
                return NSLocalizedString("Invalid Bolus Amount", comment: "Bolus error description: invalid bolus amount.")
            case .missingMaxBolus:
                return NSLocalizedString("Missing maximum allowed bolus in settings", comment: "Bolus error description: missing maximum bolus in settings.")
            case .exceedsMaxBolus:
                return NSLocalizedString("Exceeds maximum allowed bolus in settings", comment: "Bolus error description: bolus exceeds maximum bolus in settings.")
            }
        }
    }
}

extension ServicesManager: AlertIssuer {
    func issueAlert(_ alert: Alert) {
        alertManager.issueAlert(alert)
    }

    func retractAlert(identifier: Alert.Identifier) {
        alertManager.retractAlert(identifier: identifier)
    }
}

// MARK: - ServiceOnboardingDelegate

extension ServicesManager: ServiceOnboardingDelegate {
    func serviceOnboarding(didCreateService service: Service) {
        log.default("Service with identifier '%{public}@' created", service.pluginIdentifier)
        addActiveService(service)
    }

    func serviceOnboarding(didOnboardService service: Service) {
        precondition(service.isOnboarded)
        log.default("Service with identifier '%{public}@' onboarded", service.pluginIdentifier)
    }
}

extension ServicesManager {
    var availableSupports: [SupportUI] { activeServices.compactMap { $0 as? SupportUI } }
}

// Service extension for rawValue
extension Service {
    typealias RawValue = [String: Any]

    var rawValue: RawValue {
        return [
            "serviceIdentifier": pluginIdentifier,
            "state": rawState
        ]
    }
}
