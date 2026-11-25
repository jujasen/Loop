//
//  RemoteMealBolus.swift
//  Loop
//
//  A meal and its bolus sent together from LoopFollow, carried out as Loop's own «Save and
//  Deliver». Contract with LoopFollow («Måltid med bolus»); change both apps together.
//
//  Before, LoopFollow sent the carbs, waited about five minutes for Loop to upload a new
//  recommendation, and then sent the bolus as a command of its own. Now it is one command, and
//  Loop calculates the bolus with the meal itself, the moment it gives it:
//
//  1. Check everything: the carbs against the limits of a remote carb entry, the bolus against the
//     maximum bolus, and the doses given by hand that the sender had not seen (`ManualDoseLog`).
//     Nothing is saved when any of it fails.
//  2. Loop's fresh recommendation with the meal, as on the bolus screen.
//  3. Save the carbs.
//  4. The bolus: the smaller of the approved amount and the fresh recommendation when the sender
//     kept the suggested amount, else the approved amount; never above the maximum bolus, rounded
//     down to what the pump can give. 0 gives no bolus.
//  5. Give it the way a remote bolus is given (waiting for Loop's own automatic bolus, the dose
//     log checked again as it is sent).
//

import Foundation
import LoopKit

/// Loop gave nothing and saved nothing, for a reason LoopFollow can show in its own words.
enum RemoteMealBolusRefusal: LocalizedError, RemoteActionRejection, Equatable {
    /// The sender kept Loop's suggested bolus, but Loop cannot calculate one now, so it cannot
    /// check that the amount is still right.
    case noRecommendation
    /// A bolus must say which doses its sender had seen (`known-doses-until`).
    case missingKnownDoses

    var errorDescription: String? {
        switch self {
        case .noRecommendation:
            return NSLocalizedString("Nothing was saved or given: Loop cannot calculate a bolus recommendation right now.", comment: "Why a remote meal with bolus was refused: no fresh bolus recommendation")
        case .missingKnownDoses:
            return NSLocalizedString("Nothing was saved or given: the command did not say which doses its sender had seen.", comment: "Why a remote meal with bolus was refused: the command lacks known-doses-until")
        }
    }

    var remoteActionDetails: [String: Any] {
        switch self {
        case .noRecommendation:
            return ["reason": "noRecommendation"]
        case .missingKnownDoses:
            return ["reason": "missingKnownDoses"]
        }
    }
}

/// The steps of a meal with bolus, each given by the app (or by a test).
struct RemoteMealBolusRunner {
    var maximumBolus: () -> Double?
    /// The carb entry to save, or throws when it is outside the limits of a remote carb entry.
    var validateCarbs: (RemoteMealBolus) throws -> NewCarbEntry
    var waitForAutomaticBolus: () async -> Void
    /// Throws `RemoteBolusStopped` when the sender had not seen a dose. Records nothing.
    var checkDoseGuard: (_ units: Double, _ knownDosesUntil: Date) throws -> Void
    /// Loop's recommendation with the meal as a potential carb entry; nil when it has none.
    var recommendation: (NewCarbEntry) async -> Double?
    /// Down to a volume the pump can give; nil without a pump.
    var roundDown: (Double) -> Double?
    var saveCarbs: (NewCarbEntry) async throws -> Void
    var deliverBolus: (_ units: Double, _ knownDosesUntil: Date?) async throws -> Void

    /// - Throws: `RemoteMealBolusError` only.
    func run(_ meal: RemoteMealBolus) async throws -> RemoteMealBolusOutcome {
        var recommended: Double?
        func outcome(carbsSaved: Bool, delivered: Double = 0) -> RemoteMealBolusOutcome {
            RemoteMealBolusOutcome(carbsSaved: carbsSaved, carbsInGrams: meal.carbsInGrams, approvedUnits: meal.approvedUnits,
                                   recommendedUnits: recommended, deliveredUnits: delivered)
        }

        // 1–2, 4: everything checked and the bolus decided before anything is saved.
        let carbEntry: NewCarbEntry
        let units: Double
        do {
            guard meal.approvedUnits.isFinite, meal.approvedUnits >= 0 else {
                throw ServicesManager.BolusActionError.invalidBolus
            }
            guard let maximumBolus = maximumBolus() else {
                throw ServicesManager.BolusActionError.missingMaxBolus
            }
            guard meal.approvedUnits <= maximumBolus else {
                throw ServicesManager.BolusActionError.exceedsMaxBolus
            }
            carbEntry = try validateCarbs(meal)

            let givesBolus = meal.approvedUnits > 0
            if givesBolus {
                guard let knownDosesUntil = meal.knownDosesUntil else {
                    throw RemoteMealBolusRefusal.missingKnownDoses
                }
                // Loop's own dose first, so that both the dose log and the recommendation see it.
                await waitForAutomaticBolus()
                try checkDoseGuard(meal.approvedUnits, knownDosesUntil)
            }

            recommended = await recommendation(carbEntry)

            if givesBolus {
                if meal.followsRecommendation && recommended == nil {
                    throw RemoteMealBolusRefusal.noRecommendation
                }
                let wanted = Self.units(approved: meal.approvedUnits, followsRecommendation: meal.followsRecommendation,
                                        recommended: recommended, maximumBolus: maximumBolus)
                if wanted > 0 {
                    guard let rounded = roundDown(wanted) else {
                        throw LoopError.configurationError(.pumpManager)
                    }
                    units = rounded
                } else {
                    units = 0
                }
            } else {
                units = 0
            }
        } catch {
            throw RemoteMealBolusError(outcome: outcome(carbsSaved: false), underlyingError: error)
        }

        // 3
        do {
            try await saveCarbs(carbEntry)
        } catch {
            throw RemoteMealBolusError(outcome: outcome(carbsSaved: false), underlyingError: error)
        }

        guard units > 0 else {
            return outcome(carbsSaved: true)
        }

        // 5
        do {
            try await deliverBolus(units, meal.knownDosesUntil)
        } catch {
            // The pump's answer was lost: it may have been given, so say so.
            let delivered: Double
            if case PumpManagerError.uncertainDelivery = error {
                delivered = units
            } else {
                delivered = 0
            }
            throw RemoteMealBolusError(outcome: outcome(carbsSaved: true, delivered: delivered), underlyingError: error)
        }
        return outcome(carbsSaved: true, delivered: units)
    }

    /// The bolus to give, before rounding to the pump.
    static func units(approved: Double, followsRecommendation: Bool, recommended: Double?, maximumBolus: Double) -> Double {
        var units = approved
        if followsRecommendation, let recommended {
            units = min(units, max(0, recommended))
        }
        return min(units, maximumBolus)
    }

    /// The largest of the pump's volumes that is not above `units` (a hair of tolerance for
    /// floating point), or what the pump rounds to when it lists none, never above `units`.
    static func roundDown(_ units: Double, supportedVolumes: [Double], pumpRounding: (Double) -> Double) -> Double {
        guard units > 0 else { return 0 }
        if !supportedVolumes.isEmpty {
            return supportedVolumes.filter { $0 <= units + 1e-9 }.max() ?? 0
        }
        return min(pumpRounding(units), units)
    }
}
