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
}

public protocol ServicesManagerDelegate: AnyObject {
    func enactOverride(name: String, duration: TemporaryScheduleOverride.Duration?, remoteAddress: String) async throws
    func cancelCurrentOverride() async throws
    func deliverCarbs(amountInGrams: Double, absorptionTime: TimeInterval?, foodType: String?, startDate: Date?) async throws
    func updateTherapySchedules(carbRatioSchedule: CarbRatioSchedule?, insulinSensitivitySchedule: InsulinSensitivitySchedule?) async
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
            let (carbRatioSchedule, insulinSensitivitySchedule) = try Self.schedules(for: change, replacing: settingsManager.loopSettings)
            await servicesManagerDelegate?.updateTherapySchedules(carbRatioSchedule: carbRatioSchedule, insulinSensitivitySchedule: insulinSensitivitySchedule)
            log.default("Applied remote therapy settings (carb ratios: %{public}@, insulin sensitivities: %{public}@)",
                        String(describing: carbRatioSchedule?.items.count), String(describing: insulinSensitivitySchedule?.items.count))
            await NotificationManager.sendRemoteTherapySettingsNotification(for: change)
            await remoteDataServicesManager.triggerUpload(for: .settings)
        } catch {
            await NotificationManager.sendRemoteTherapySettingsFailureNotification(for: error, change: change)
            throw error
        }
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

        case carbRatioOutOfRange(Double)
        case insulinSensitivityOutOfRange(Double, HKUnit)

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
            }
        }

        private static func format(_ value: Double) -> String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 1
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
