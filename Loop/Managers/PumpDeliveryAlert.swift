//
//  PumpDeliveryAlert.swift
//  Loop
//
//  Alerts on this phone when the pod may not be delivering insulin (see `PumpDeliveryCheck`),
//  for whoever has the phone — the same alert LoopFollow gives the parents.
//
//  After each loop the last hours of glucose, insulin and carbs are read from Loop's stores and
//  weighed with ISF and carb ratio (with the override history applied, as Loop doses). When the
//  rise has gone on for half an hour, a time-sensitive alert says what was seen and what to check.
//  It is not repeated for an hour. On unless switched off under Settings → Pump Delivery Alert.
//

import Foundation
import HealthKit
import LoopKit
import os.log

/// The latest alert, for the settings screen.
struct PumpDeliveryAlertRecord: Codable, Equatable {
    let issued: Date
    let assessment: PumpDeliveryCheck.Assessment
}

extension UserDefaults {
    private enum PumpDeliveryKey: String {
        case enabled = "com.loopkit.Loop.pumpDeliveryAlertEnabled"
        case last = "com.loopkit.Loop.pumpDeliveryAlertLast"
    }

    /// On unless switched off.
    var pumpDeliveryAlertEnabled: Bool {
        get { object(forKey: PumpDeliveryKey.enabled.rawValue) as? Bool ?? true }
        set { set(newValue, forKey: PumpDeliveryKey.enabled.rawValue) }
    }

    var pumpDeliveryAlertLast: PumpDeliveryAlertRecord? {
        get {
            data(forKey: PumpDeliveryKey.last.rawValue).flatMap { try? JSONDecoder().decode(PumpDeliveryAlertRecord.self, from: $0) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                set(data, forKey: PumpDeliveryKey.last.rawValue)
            } else {
                removeObject(forKey: PumpDeliveryKey.last.rawValue)
            }
        }
    }
}

final class PumpDeliveryAlertManager {
    static var current: PumpDeliveryAlertManager?

    static let alertIdentifier = Alert.Identifier(managerIdentifier: "Loop", alertIdentifier: "pumpDeliveryFailure")
    /// No new alert this soon after the last one.
    static let quietPeriod: TimeInterval = .hours(1)
    /// Loops come every five minutes; one check per new reading is enough.
    static let minimumInterval: TimeInterval = .minutes(4)

    typealias Fetch<T> = (_ start: Date, _ end: Date, _ completion: @escaping (Result<[T], Error>) -> Void) -> Void

    private let log = OSLog(category: "PumpDeliveryAlertManager")
    private let queue = DispatchQueue(label: "com.loopkit.Loop.PumpDeliveryAlertManager")
    private let fetchGlucose: Fetch<StoredGlucoseSample>
    private let fetchDoses: Fetch<DoseEntry>
    private let fetchCarbs: Fetch<StoredCarbEntry>
    private let sensitivity: () -> InsulinSensitivitySchedule?
    private let carbRatio: () -> CarbRatioSchedule?
    private let insulinModel: () -> InsulinModel
    private let defaultAbsorption: () -> TimeInterval
    private let glucoseUnit: () -> HKUnit
    private weak var alertIssuer: AlertIssuer?
    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?
    private var lastCheck: Date?
    private var isChecking = false

    init(
        fetchGlucose: @escaping Fetch<StoredGlucoseSample>,
        fetchDoses: @escaping Fetch<DoseEntry>,
        fetchCarbs: @escaping Fetch<StoredCarbEntry>,
        sensitivity: @escaping () -> InsulinSensitivitySchedule?,
        carbRatio: @escaping () -> CarbRatioSchedule?,
        insulinModel: @escaping () -> InsulinModel,
        defaultAbsorption: @escaping () -> TimeInterval,
        glucoseUnit: @escaping () -> HKUnit,
        alertIssuer: AlertIssuer?,
        defaults: UserDefaults = .standard
    ) {
        self.fetchGlucose = fetchGlucose
        self.fetchDoses = fetchDoses
        self.fetchCarbs = fetchCarbs
        self.sensitivity = sensitivity
        self.carbRatio = carbRatio
        self.insulinModel = insulinModel
        self.defaultAbsorption = defaultAbsorption
        self.glucoseUnit = glucoseUnit
        self.alertIssuer = alertIssuer
        self.defaults = defaults
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Checks after every completed loop.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .LoopCompleted, object: nil, queue: nil) { [weak self] _ in
            self?.checkIfDue()
        }
    }

    var isEnabled: Bool {
        get { defaults.pumpDeliveryAlertEnabled }
        set {
            defaults.pumpDeliveryAlertEnabled = newValue
            if !newValue {
                alertIssuer?.retractAlert(identifier: Self.alertIdentifier)
            }
        }
    }

    func checkIfDue(now: Date = Date()) {
        queue.async {
            guard self.defaults.pumpDeliveryAlertEnabled, !self.isChecking else { return }
            if let lastCheck = self.lastCheck, now.timeIntervalSince(lastCheck) < Self.minimumInterval { return }
            self.isChecking = true
            self.lastCheck = now
            self.check(now: now) { assessment in
                self.queue.async {
                    self.isChecking = false
                    if let assessment {
                        self.alertIfQuietPeriodOver(assessment, now: now)
                    }
                }
            }
        }
    }

    /// Reads the stores and runs the check; nil when there is nothing to alert on or data is missing.
    func check(now: Date = Date(), completion: @escaping (PumpDeliveryCheck.Assessment?) -> Void) {
        guard let sensitivity = sensitivity(), let carbRatio = carbRatio() else {
            completion(nil)
            return
        }
        let curve = PumpDeliveryCheck.InsulinCurve(insulinModel())
        let absorption = defaultAbsorption()

        let group = DispatchGroup()
        var glucose: [StoredGlucoseSample] = []
        var doses: [DoseEntry] = []
        var carbs: [StoredCarbEntry] = []
        var failed = false
        let lock = NSLock()
        func collect<T>(_ result: Result<[T], Error>, into store: @escaping ([T]) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            switch result {
            case .success(let values): store(values)
            case .failure(let error):
                failed = true
                log.error("Pump delivery check could not read its data: %{public}@", String(describing: error))
            }
        }

        group.enter()
        fetchGlucose(now.addingTimeInterval(-PumpDeliveryCheck.glucoseHistory), now) { result in
            collect(result) { glucose = $0 }
            group.leave()
        }
        group.enter()
        fetchDoses(now.addingTimeInterval(-PumpDeliveryCheck.insulinHistory), now) { result in
            collect(result) { doses = $0 }
            group.leave()
        }
        group.enter()
        fetchCarbs(now.addingTimeInterval(-PumpDeliveryCheck.carbHistory), now) { result in
            collect(result) { carbs = $0 }
            group.leave()
        }

        group.notify(queue: queue) {
            guard !failed else {
                completion(nil)
                return
            }
            let check = PumpDeliveryCheck(
                glucose: PumpDeliveryCheck.readings(glucose),
                doses: PumpDeliveryCheck.doses(doses, now: now),
                carbs: PumpDeliveryCheck.carbs(carbs, defaultAbsorption: absorption, now: now),
                sensitivity: PumpDeliveryCheck.sensitivity(sensitivity),
                carbRatio: PumpDeliveryCheck.carbRatio(carbRatio),
                curve: curve
            )
            completion(check.suspectedFailure(now: now))
        }
    }

    private func alertIfQuietPeriodOver(_ assessment: PumpDeliveryCheck.Assessment, now: Date) {
        if let last = defaults.pumpDeliveryAlertLast, now.timeIntervalSince(last.issued) < Self.quietPeriod { return }
        defaults.pumpDeliveryAlertLast = PumpDeliveryAlertRecord(issued: now, assessment: assessment)
        log.default("Pump may not be delivering: glucose %{public}.0f mg/dL, insulin drop %{public}.0f, unexplained %{public}.0f",
                    assessment.glucose, assessment.insulinDrop, assessment.unexplainedRise)
        alertIssuer?.issueAlert(Self.alert(for: assessment, unit: glucoseUnit()))
    }

    // MARK: - Alert

    static func alert(for assessment: PumpDeliveryCheck.Assessment, unit: HKUnit) -> Alert {
        let content = Alert.Content(
            title: PumpDeliveryText.title,
            body: PumpDeliveryText.body(assessment, unit: unit),
            acknowledgeActionButtonLabel: NSLocalizedString("OK", comment: "Alert acknowledgment OK button")
        )
        return Alert(identifier: alertIdentifier, foregroundContent: content, backgroundContent: content, trigger: .immediate, interruptionLevel: .timeSensitive)
    }
}

enum PumpDeliveryText {
    static var title: String {
        String(localized: "Pump May Not Be Delivering Insulin", comment: "Title of the alert when glucose keeps rising although insulin was given")
    }

    static var advice: String {
        String(localized: "Check the pod and cannula, measure ketones, and consider insulin by pen and a new pod.", comment: "Advice in the pump delivery alert")
    }

    static func body(_ assessment: PumpDeliveryCheck.Assessment, unit: HKUnit) -> String {
        let finding = String(
            format: String(localized: "Glucose %1$@ and not falling. The insulin from the last 90 minutes should have lowered it by %2$@, yet it is %3$@ higher than insulin and carbs explain.", comment: "Pump delivery alert (1: current glucose)(2: expected drop from insulin)(3: unexplained rise)"),
            glucose(assessment.glucose, unit: unit),
            glucose(assessment.insulinDrop, unit: unit),
            glucose(assessment.unexplainedRise, unit: unit)
        )
        return finding + " " + advice
    }

    /// A glucose value or difference in mg/dL, in the display unit.
    static func glucose(_ mgdl: Double, unit: HKUnit) -> String {
        let quantity = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl)
        return QuantityFormatter(for: unit).string(from: quantity) ?? "\(Int(mgdl.rounded())) mg/dL"
    }
}
