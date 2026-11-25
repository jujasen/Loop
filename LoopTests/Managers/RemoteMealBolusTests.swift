//
//  RemoteMealBolusTests.swift
//  LoopTests
//
//  A meal with its bolus from LoopFollow: what is saved, what is given, and what is never given.
//

import HealthKit
import LoopKit
import XCTest
@testable import Loop

final class RemoteMealBolusTests: XCTestCase {

    private let knownDosesUntil = Date(timeIntervalSince1970: 1_795_000_000)

    /// Records what the runner did.
    private final class Pump {
        var maximumBolus: Double? = 5
        var recommendation: Double? = 2.0
        var carbsError: Error?
        var doseGuardError: Error?
        var saveError: Error?
        var deliverError: Error?
        var supportedVolumes: [Double]? = stride(from: 0.05, through: 30, by: 0.05).map { ($0 * 100).rounded() / 100 }

        var steps: [String] = []
        var savedCarbs: [Double] = []
        var delivered: [Double] = []
        var deliveredKnownDosesUntil: [Date?] = []
    }

    private func runner(_ pump: Pump) -> RemoteMealBolusRunner {
        RemoteMealBolusRunner(
            maximumBolus: { pump.maximumBolus },
            validateCarbs: { meal in
                pump.steps.append("validate")
                if let error = pump.carbsError { throw error }
                return NewCarbEntry(quantity: HKQuantity(unit: .gram(), doubleValue: meal.carbsInGrams), startDate: Date(), foodType: meal.foodType, absorptionTime: meal.absorptionTime)
            },
            waitForAutomaticBolus: { pump.steps.append("wait") },
            checkDoseGuard: { _, _ in
                pump.steps.append("guard")
                if let error = pump.doseGuardError { throw error }
            },
            recommendation: { _ in
                pump.steps.append("recommend")
                return pump.recommendation
            },
            roundDown: { units in
                guard let volumes = pump.supportedVolumes else { return nil }
                return RemoteMealBolusRunner.roundDown(units, supportedVolumes: volumes) { $0 }
            },
            saveCarbs: { entry in
                pump.steps.append("save")
                if let error = pump.saveError { throw error }
                pump.savedCarbs.append(entry.quantity.doubleValue(for: .gram()))
            },
            deliverBolus: { units, known in
                pump.steps.append("deliver")
                if let error = pump.deliverError { throw error }
                pump.delivered.append(units)
                pump.deliveredKnownDosesUntil.append(known)
            }
        )
    }

    private func meal(carbs: Double = 45, bolus: Double, follows: Bool, knownDosesUntil: Date?? = nil) -> RemoteMealBolus {
        RemoteMealBolus(carbsInGrams: carbs, foodType: "🍕 Pizza", approvedUnits: bolus, followsRecommendation: follows,
                        knownDosesUntil: knownDosesUntil ?? self.knownDosesUntil)
    }

    private func failure(_ pump: Pump, _ meal: RemoteMealBolus) async -> RemoteMealBolusError? {
        do {
            _ = try await runner(pump).run(meal)
            XCTFail("Should have failed")
            return nil
        } catch let error as RemoteMealBolusError {
            return error
        } catch {
            XCTFail("Unexpected \(error)")
            return nil
        }
    }

    // MARK: How much

    func testFollowingTheRecommendationGivesTheSmallerOfApprovedAndFresh() async throws {
        let pump = Pump()
        pump.recommendation = 2.0
        let outcome = try await runner(pump).run(meal(bolus: 3.25, follows: true))
        XCTAssertEqual(pump.delivered, [2.0])
        XCTAssertEqual(outcome, RemoteMealBolusOutcome(carbsSaved: true, carbsInGrams: 45, approvedUnits: 3.25, recommendedUnits: 2.0, deliveredUnits: 2.0))
        XCTAssertEqual(pump.steps, ["validate", "wait", "guard", "recommend", "save", "deliver"])
        XCTAssertEqual(pump.deliveredKnownDosesUntil, [knownDosesUntil])
    }

    func testFollowingTheRecommendationNeverGivesMoreThanApproved() async throws {
        let pump = Pump()
        pump.recommendation = 4.0
        let outcome = try await runner(pump).run(meal(bolus: 3.25, follows: true))
        XCTAssertEqual(pump.delivered, [3.25])
        XCTAssertEqual(outcome.recommendedUnits, 4.0)
    }

    func testAChosenAmountIsGivenAsApproved() async throws {
        let pump = Pump()
        pump.recommendation = 1.0
        let outcome = try await runner(pump).run(meal(bolus: 3.25, follows: false))
        XCTAssertEqual(pump.delivered, [3.25])
        XCTAssertEqual(outcome.deliveredUnits, 3.25)
        XCTAssertEqual(outcome.recommendedUnits, 1.0)
    }

    func testAChosenAmountIsGivenWithoutARecommendation() async throws {
        let pump = Pump()
        pump.recommendation = nil
        let outcome = try await runner(pump).run(meal(bolus: 1.5, follows: false))
        XCTAssertEqual(pump.delivered, [1.5])
        XCTAssertNil(outcome.recommendedUnits)
    }

    func testTheBolusIsRoundedDownToThePump() async throws {
        let pump = Pump()
        pump.recommendation = 2.07
        let outcome = try await runner(pump).run(meal(bolus: 3, follows: true))
        XCTAssertEqual(pump.delivered.first ?? 0, 2.05, accuracy: 1e-9)
        XCTAssertEqual(outcome.deliveredUnits, 2.05, accuracy: 1e-9)
    }

    func testRoundingDownNeverGoesUp() {
        XCTAssertEqual(RemoteMealBolusRunner.roundDown(0.149999999, supportedVolumes: [0.05, 0.1, 0.15], pumpRounding: { $0 }), 0.15, accuracy: 1e-9)
        XCTAssertEqual(RemoteMealBolusRunner.roundDown(0.14, supportedVolumes: [0.05, 0.1, 0.15], pumpRounding: { $0 }), 0.1, accuracy: 1e-9)
        XCTAssertEqual(RemoteMealBolusRunner.roundDown(0.04, supportedVolumes: [0.05, 0.1], pumpRounding: { $0 }), 0)
        XCTAssertEqual(RemoteMealBolusRunner.roundDown(0.14, supportedVolumes: [], pumpRounding: { _ in 0.2 }), 0.14)
    }

    // MARK: No bolus

    func testARecommendationOfZeroSavesTheCarbsAndGivesNothing() async throws {
        let pump = Pump()
        pump.recommendation = 0
        let outcome = try await runner(pump).run(meal(bolus: 3.25, follows: true))
        XCTAssertEqual(pump.savedCarbs, [45])
        XCTAssertEqual(pump.delivered, [])
        XCTAssertFalse(pump.steps.contains("deliver"))
        XCTAssertEqual(outcome, RemoteMealBolusOutcome(carbsSaved: true, carbsInGrams: 45, approvedUnits: 3.25, recommendedUnits: 0, deliveredUnits: 0))
    }

    func testARecommendationBelowThePumpsSmallestStepGivesNothing() async throws {
        let pump = Pump()
        pump.recommendation = 0.03
        let outcome = try await runner(pump).run(meal(bolus: 3.25, follows: true))
        XCTAssertEqual(pump.savedCarbs, [45])
        XCTAssertEqual(pump.delivered, [])
        XCTAssertEqual(outcome.deliveredUnits, 0)
    }

    func testAnApprovedZeroSavesTheCarbsOnly() async throws {
        let pump = Pump()
        let outcome = try await runner(pump).run(meal(bolus: 0, follows: true, knownDosesUntil: .some(nil)))
        XCTAssertEqual(pump.savedCarbs, [45])
        XCTAssertEqual(pump.delivered, [])
        XCTAssertTrue(outcome.carbsSaved)
    }

    // MARK: Nothing saved

    func testADoseTheSenderHadNotSeenStopsEverything() async throws {
        let pump = Pump()
        let phone = ManualDose(date: knownDosesUntil.addingTimeInterval(60), units: 0.3, source: .phone, delivered: true)
        pump.doseGuardError = RemoteBolusStopped(units: 3.25, doses: [phone])
        let error = await failure(pump, meal(bolus: 3.25, follows: true))
        XCTAssertEqual(error?.outcome.carbsSaved, false)
        XCTAssertEqual(error?.outcome.deliveredUnits, 0)
        XCTAssertTrue(error?.underlyingError is RemoteBolusStopped)
        XCTAssertEqual(pump.savedCarbs, [])
        XCTAssertEqual(pump.delivered, [])
        XCTAssertFalse(pump.steps.contains("save"))
    }

    func testFollowingARecommendationLoopCannotCalculateSavesNothing() async throws {
        let pump = Pump()
        pump.recommendation = nil
        let error = await failure(pump, meal(bolus: 2, follows: true))
        XCTAssertEqual(error?.underlyingError as? RemoteMealBolusRefusal, .noRecommendation)
        XCTAssertEqual(error?.outcome.carbsSaved, false)
        XCTAssertEqual(pump.savedCarbs, [])
    }

    func testABolusAboveTheMaximumSavesNothing() async throws {
        let pump = Pump()
        pump.maximumBolus = 3
        let error = await failure(pump, meal(bolus: 3.25, follows: false))
        XCTAssertEqual(error?.outcome.carbsSaved, false)
        XCTAssertEqual(pump.steps, [])
    }

    func testABolusWithoutTheDosesItsSenderHadSeenSavesNothing() async throws {
        let pump = Pump()
        let error = await failure(pump, meal(bolus: 1, follows: false, knownDosesUntil: .some(nil)))
        XCTAssertEqual(error?.underlyingError as? RemoteMealBolusRefusal, .missingKnownDoses)
        XCTAssertEqual(pump.savedCarbs, [])
    }

    func testCarbsOutsideTheLimitsSaveNothing() async throws {
        let pump = Pump()
        pump.carbsError = LoopDataManager.CarbActionError.exceedsMaxCarbs
        let error = await failure(pump, meal(carbs: 500, bolus: 1, follows: false))
        XCTAssertEqual(error?.outcome.carbsSaved, false)
        XCTAssertEqual(pump.savedCarbs, [])
        XCTAssertEqual(pump.delivered, [])
    }

    func testCarbsThatCannotBeSavedGiveNoBolus() async throws {
        let pump = Pump()
        pump.saveError = URLError(.cannotCreateFile)
        let error = await failure(pump, meal(bolus: 1, follows: false))
        XCTAssertEqual(error?.outcome.carbsSaved, false)
        XCTAssertEqual(pump.delivered, [])
        XCTAssertFalse(pump.steps.contains("deliver"))
    }

    func testNoPumpSavesNothing() async throws {
        let pump = Pump()
        pump.supportedVolumes = nil
        let error = await failure(pump, meal(bolus: 1, follows: false))
        XCTAssertEqual(error?.outcome.carbsSaved, false)
        XCTAssertEqual(pump.savedCarbs, [])
    }

    // MARK: The bolus fails after the carbs were saved

    func testABolusFailureAfterTheCarbsWereSavedSaysSo() async throws {
        let pump = Pump()
        pump.deliverError = PumpManagerError.communication(nil)
        let error = await failure(pump, meal(bolus: 3.25, follows: true))
        XCTAssertEqual(error?.outcome.carbsSaved, true)
        XCTAssertEqual(error?.outcome.deliveredUnits, 0)
        XCTAssertEqual(error?.outcome.recommendedUnits, 2.0)
        XCTAssertEqual(pump.savedCarbs, [45])
    }

    func testAnUncertainBolusAfterTheCarbsWereSavedCountsAsPerhapsGiven() async throws {
        let pump = Pump()
        pump.deliverError = PumpManagerError.uncertainDelivery
        let error = await failure(pump, meal(bolus: 3.25, follows: true))
        XCTAssertEqual(error?.outcome.carbsSaved, true)
        XCTAssertEqual(error?.outcome.deliveredUnits, 2.0)
        guard case PumpManagerError.uncertainDelivery? = error?.underlyingError as? PumpManagerError else {
            return XCTFail("Not uncertain")
        }
    }

    // MARK: The dose log

    func testTheDoseLogCheckRecordsNothing() throws {
        let suite = "RemoteMealBolusTests"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let log = ManualDoseLog(defaults: UserDefaults(suiteName: suite)!)
        let now = knownDosesUntil.addingTimeInterval(600)
        log.finished(try log.began(units: 0.3, source: .phone, at: now.addingTimeInterval(-120)), error: nil)

        XCTAssertThrowsError(try log.check(units: 2, knownDosesUntil: knownDosesUntil, at: now)) { error in
            XCTAssertEqual((error as? RemoteBolusStopped)?.doses.map(\.units), [0.3])
        }
        XCTAssertNoThrow(try log.check(units: 2, knownDosesUntil: now, at: now))
        XCTAssertEqual(log.doses.count, 1)
    }
}
