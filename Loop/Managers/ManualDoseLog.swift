//
//  ManualDoseLog.swift
//  Loop
//
//  Who gave each dose that was given by hand.
//
//  A bolus can be given on this phone, sent from LoopFollow on a caregiver's phone, or given by
//  the evening watch. Two people can correct the same high at the same moment without knowing of
//  each other: on 20 November 2026 0.30 U and 0.50 U were given two minutes apart at 17.2 mmol/L,
//  and glucose was 2.9 three hours later.
//
//  The log is the referee:
//  - A remote bolus says which doses its sender had seen (`knownDosesUntil`). If the log has a
//    later one, nothing is given and the sender is told which dose it missed.
//  - The bolus screen on this phone warns when a dose came from somewhere else in the last half
//    hour, unless the bolus follows a meal: that one is for the food.
//
//  A plain «a bolus was given recently» would not do: meals are often entered as several boluses
//  minutes apart (60 pairs within five minutes in four weeks), all by the same person.
//
//  Nightscout cannot tell these doses apart (all are uploaded as boluses that are not automatic),
//  so the log is uploaded too, for LoopFollow: see `ManualDoseLogNightscout`.
//

import Foundation
import LoopKit
import os.log

struct ManualDose: Codable, Equatable, Identifiable {
    enum Source: String, Codable {
        /// The bolus screen (or the watch) of this phone.
        case phone
        /// A remote command, from LoopFollow.
        case remote
        case eveningWatch
    }

    var id = UUID().uuidString
    /// When it was requested, just before it was sent to the pump. A dose's own start time (what
    /// Nightscout shows) is never earlier than this.
    var date: Date
    var units: Double
    var source: Source
    /// The pump took it. False while it is being sent, and kept false when the pump's answer was
    /// lost, since it may have been given.
    var delivered = false
}

/// Nothing was given: the sender of a remote bolus had not seen these doses.
struct RemoteBolusStopped: LocalizedError, RemoteActionRejection, Equatable {
    static let reason = "unknownDoses"

    let units: Double
    /// Oldest first; never empty.
    let doses: [ManualDose]

    var errorDescription: String? {
        guard let newest = doses.last else { return nil }
        let amount = ManualDoseText.units(newest.units)
        let time = ManualDoseText.time(newest.date)
        switch newest.source {
        case .phone:
            return String(format: NSLocalizedString("Nothing was given: %1$@ U was given on this phone at %2$@, and the sender had not seen it.", comment: "Why a remote bolus was stopped, when a bolus was given on the phone with Loop (1: units, 2: time)"), amount, time)
        case .remote:
            return String(format: NSLocalizedString("Nothing was given: another remote bolus of %1$@ U was given at %2$@, and the sender had not seen it.", comment: "Why a remote bolus was stopped, when another remote bolus was given (1: units, 2: time)"), amount, time)
        case .eveningWatch:
            return String(format: NSLocalizedString("Nothing was given: the high watch gave %1$@ U at %2$@, and the sender had not seen it.", comment: "Why a remote bolus was stopped, when the high watch gave a dose (1: units, 2: time)"), amount, time)
        }
    }

    var remoteActionDetails: [String: Any] {
        [
            "reason": Self.reason,
            "doses": doses.map(ManualDoseLogNightscout.document(_:)),
        ]
    }
}

final class ManualDoseLog {
    static let shared = ManualDoseLog()

    static let changed = Notification.Name("com.loopkit.Loop.ManualDoseLogChanged")

    /// A remote bolus is stopped by a dose its sender had not seen, this far back. Most of a dose
    /// shows in glucose within three hours; an older one the sender sees in the graph.
    static let unknownWithin: TimeInterval = 3 * 60 * 60
    /// The bolus screen warns this long after a dose from somewhere else. Corrections by two
    /// people at once came within a quarter of an hour of each other.
    static let warnsFor: TimeInterval = 30 * 60
    static let keeps: TimeInterval = 24 * 60 * 60
    /// A sender tells the time of the newest dose it has seen in milliseconds, as it read it from
    /// Nightscout, so that time can be a little under the dose's own. Two doses by hand are never
    /// this close.
    static let sameDose: TimeInterval = 0.5

    private let defaults: UserDefaults
    private let key = "com.loopkit.Loop.manualDoseLog"
    private let lock = NSLock()
    private var stored: [ManualDose]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let doses = try? JSONDecoder().decode([ManualDose].self, from: data) {
            stored = doses
        } else {
            stored = []
        }
    }

    var doses: [ManualDose] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    // MARK: The rules

    /// The doses a sender who had seen everything up to `knownUntil` did not know of.
    static func unknown(in doses: [ManualDose], knownUntil: Date, now: Date) -> [ManualDose] {
        doses
            .filter { $0.date.timeIntervalSince(knownUntil) > sameDose && now.timeIntervalSince($0.date) <= unknownWithin }
            .sorted { $0.date < $1.date }
    }

    /// The newest dose that did not come from this phone's own bolus screen, while it still calls
    /// for a warning there.
    static func fromElsewhere(in doses: [ManualDose], now: Date) -> ManualDose? {
        doses
            .filter { $0.source != .phone && now.timeIntervalSince($0.date) <= warnsFor && $0.date <= now.addingTimeInterval(60) }
            .max { $0.date < $1.date }
    }

    func fromElsewhere(now: Date = Date()) -> ManualDose? {
        Self.fromElsewhere(in: doses, now: now)
    }

    // MARK: Recording

    /// Records a dose about to be sent to the pump and returns its id.
    ///
    /// With `knownDosesUntil` (a remote bolus) it first checks that the sender knew of every dose,
    /// and throws `RemoteBolusStopped` otherwise. Check and record are one step, so two doses
    /// starting at the same moment cannot both pass.
    @discardableResult
    func began(units: Double, source: ManualDose.Source, knownDosesUntil: Date? = nil, at now: Date = Date()) throws -> String {
        lock.lock()
        if let knownDosesUntil {
            let unknown = Self.unknown(in: stored, knownUntil: knownDosesUntil, now: now)
            if !unknown.isEmpty {
                lock.unlock()
                throw RemoteBolusStopped(units: units, doses: unknown)
            }
        }
        let dose = ManualDose(date: now, units: units, source: source)
        stored = stored.filter { now.timeIntervalSince($0.date) <= Self.keeps } + [dose]
        save()
        lock.unlock()
        announce()
        return dose.id
    }

    /// Throws `RemoteBolusStopped` when the sender who had seen everything up to `knownDosesUntil`
    /// did not know of a dose, without recording anything. For a meal with bolus, checked before
    /// the carbs are saved; `began` checks again as the bolus is sent.
    func check(units: Double, knownDosesUntil: Date, at now: Date = Date()) throws {
        let unknown = Self.unknown(in: doses, knownUntil: knownDosesUntil, now: now)
        if !unknown.isEmpty {
            throw RemoteBolusStopped(units: units, doses: unknown)
        }
    }

    /// The pump's answer. A dose that was definitely not given is forgotten; one whose answer was
    /// lost stays, since it may have been given.
    func finished(_ id: String, error: Error?) {
        lock.lock()
        guard let index = stored.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        if let error {
            if case PumpManagerError.uncertainDelivery = error {
                // Kept as it is.
            } else {
                stored.remove(at: index)
            }
        } else {
            stored[index].delivered = true
        }
        save()
        lock.unlock()
        announce()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: key)
        }
    }

    private func announce() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }
}

enum ManualDoseText {
    static func units(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// «3 min ago», for the bolus screen.
    static func minutesAgo(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 {
            return NSLocalizedString("just now", comment: "How long ago a dose from somewhere else was given, when under a minute")
        }
        return String(format: NSLocalizedString("%d min ago", comment: "How long ago a dose from somewhere else was given (1: minutes)"), minutes)
    }

    static func warningTitle(_ dose: ManualDose, now: Date) -> String {
        let ago = minutesAgo(dose.date, now: now)
        switch dose.source {
        case .eveningWatch:
            return String(format: NSLocalizedString("The high watch gave %1$@ U %2$@", comment: "Bolus screen warning title after a dose by the high watch (1: units, 2: how long ago)"), units(dose.units), ago)
        case .remote, .phone:
            return String(format: NSLocalizedString("Remote bolus of %1$@ U %2$@", comment: "Bolus screen warning title after a remote bolus (1: units, 2: how long ago)"), units(dose.units), ago)
        }
    }

    static func warningCaption(_ dose: ManualDose) -> String {
        switch dose.source {
        case .eveningWatch:
            return String(format: NSLocalizedString("It was given at %@. Check the insulin on board before you give more.", comment: "Bolus screen warning caption after a dose by the evening watch (1: time)"), time(dose.date))
        case .remote, .phone:
            return String(format: NSLocalizedString("It was sent from LoopFollow at %@. Someone else may be correcting the same glucose: check before you give more.", comment: "Bolus screen warning caption after a remote bolus (1: time)"), time(dose.date))
        }
    }

    static func confirmMessage(_ dose: ManualDose, units newUnits: String, now: Date) -> String {
        String(format: NSLocalizedString("%1$@.\n\nIf you give %2$@ U now, it comes on top of that dose.", comment: "Message of the alert before a bolus on top of a dose from somewhere else (1: the warning title, 2: the new units)"), warningTitle(dose, now: now), newUnits)
    }
}

/// The log in Nightscout, for LoopFollow. Contract with LoopFollow (`Remote/LoopAPNS/DoseGuard.swift`);
/// change both apps together.
///
/// One "Manual Dose Log" treatment, replaced whenever the log changes: `source: "manualDoseLog"`
/// and `doses`, the last six hours oldest first, each with `id`, `date` (ISO 8601 with
/// milliseconds, when the dose was requested), `units`, `source` ("phone", "remote" or
/// "eveningWatch") and `delivered`. It has no `insulin` field, so it never counts as a dose; the
/// boluses themselves are uploaded as always.
enum ManualDoseLogNightscout {
    static let eventType = "Manual Dose Log"
    static let source = "manualDoseLog"
    static let uploads: TimeInterval = 6 * 60 * 60

    private static let idKey = "com.loopkit.Loop.manualDoseLog.nightscoutID"
    private static var pending: Task<Void, Never>?
    private static let log = OSLog(category: "ManualDoseLog")

    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func document(_ dose: ManualDose) -> [String: Any] {
        [
            "id": dose.id,
            "date": formatter.string(from: dose.date),
            "units": dose.units,
            "source": dose.source.rawValue,
            "delivered": dose.delivered,
        ]
    }

    static func document(doses: [ManualDose], now: Date) -> [String: Any] {
        [
            "eventType": eventType,
            "created_at": formatter.string(from: now),
            "enteredBy": "Loop",
            "source": source,
            "doses": doses
                .filter { now.timeIntervalSince($0.date) <= uploads }
                .sorted { $0.date < $1.date }
                .map(document(_:)),
        ]
    }

    /// Starts uploading every change of the log. A bolus changes it twice within seconds (sent,
    /// then taken by the pump), so the upload waits a moment and takes the latest.
    static func start(log doseLog: ManualDoseLog = .shared) {
        NotificationCenter.default.addObserver(forName: ManualDoseLog.changed, object: doseLog, queue: .main) { _ in
            pending?.cancel()
            pending = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                await upload(doseLog.doses, now: Date())
            }
        }
    }

    private static func upload(_ doses: [ManualDose], now: Date) async {
        guard let api = SuggestionNightscoutAPI.fromKeychain() else { return }
        do {
            let created = try await api.create(document(doses: doses, now: now))
            // The new one is in place before the old one goes, so LoopFollow always finds one.
            if let old = UserDefaults.standard.string(forKey: idKey), old != created {
                try await api.delete(old)
            }
            UserDefaults.standard.set(created, forKey: idKey)
        } catch {
            log.error("Could not upload the manual dose log: %{public}@", String(describing: error))
        }
    }
}
