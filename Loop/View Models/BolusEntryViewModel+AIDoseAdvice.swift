//
//  BolusEntryViewModel+AIDoseAdvice.swift
//  Loop
//
//  The AI dose advice section on the bolus screen: gathers what the model needs, asks for the
//  advice, holds the dose to the limits and keeps a record of what was shown and accepted.
//

import Foundation
import HealthKit
import LoopKit

extension BolusEntryViewModel {
    /// True when the section is shown at all: turned on in settings and built with an OpenAI key.
    var isAIDoseAdviceAvailable: Bool {
        UserDefaults.standard.aiDoseAdviceSettings.isEnabled && AIDoseAdvisor.shared != nil
    }

    /// Opens the section and asks for advice, or closes it.
    func setAIDoseAdviceOpen(_ open: Bool) {
        aiDoseAdviceTask?.cancel()
        aiDoseAdviceTask = nil
        guard open else {
            aiDoseAdviceState = .off
            return
        }
        requestAIDoseAdvice()
    }

    /// Why no advice may be given with what the screen shows now, or `nil`.
    private func aiDoseBlockingReason(now: Date) -> String? {
        let latest = glucoseValues.last
        let lowestForecast = predictedGlucoseValues
            .filter { $0.startDate > now }
            .map { $0.quantity.doubleValue(for: .milligramsPerDeciliter) }
            .min()
        return AIDoseAdvisor.blockingReason(
            glucoseMgdl: latest?.quantity.doubleValue(for: .milligramsPerDeciliter),
            glucoseDate: latest?.startDate,
            notice: activeNotice,
            loopUnits: recommendedBolusAmount,
            lowestForecastMgdl: lowestForecast,
            suspendThresholdMgdl: delegate?.settings.suspendThreshold?.quantity.doubleValue(for: .milligramsPerDeciliter),
            now: now
        )
    }

    /// Called when Loop's recommendation or notice changes: advice given for the earlier
    /// situation can no longer be used, and is asked for again.
    func aiDoseInputsDidChange() {
        guard case .ready(let advice) = aiDoseAdviceState else { return }
        let now = Date()
        if let reason = aiDoseBlockingReason(now: now) {
            aiDoseAdviceState = .unavailable(reason)
        } else if let loop = recommendedBolusAmount, let earlier = advice.loopUnits, abs(loop - earlier) < 0.001 {
            return
        } else {
            aiDoseAdviceState = .failed(String(localized: "Loop's recommendation changed. Ask again for advice that fits it.", comment: "AI dose advice withdrawn because Loop's recommendation changed"))
        }
    }

    func requestAIDoseAdvice() {
        let now = Date()
        if let reason = aiDoseBlockingReason(now: now) {
            aiDoseAdviceState = .unavailable(reason)
            return
        }
        guard let advisor = AIDoseAdvisor.shared else { return }

        aiDoseAdviceState = .loading
        let settings = UserDefaults.standard.aiDoseAdviceSettings
        let meal = aiDoseMealContext

        aiDoseAdviceTask = Task { [weak self] in
            guard let self else { return }
            let startOfDay = Calendar.current.startOfDay(for: now)
            let local = await self.delegate?.aiDoseLocalHistory(start: min(startOfDay, now.addingTimeInterval(-.hours(3)))) ?? AIDoseLocalHistory()
            let history = await NightscoutHistory.summary(days: settings.historyDays, now: now)
            let situation = self.aiDoseSituation(now: now, settings: settings, local: local, history: history)
            do {
                let answer = try await advisor.advise(situation: situation, meal: meal)
                guard !Task.isCancelled else { return }
                // Loop may have changed its mind while the model was thinking.
                if let reason = self.aiDoseBlockingReason(now: Date()) {
                    self.aiDoseAdviceState = .unavailable(reason)
                    return
                }
                let limited = AIDoseAdvisor.limitedDose(
                    answer.doseUnits,
                    loopUnits: self.recommendedBolusAmount,
                    maximumBolus: self.maximumBolus?.doubleValue(for: .internationalUnit()) ?? self.delegate?.settings.maximumBolus,
                    settings: settings,
                    allowsMoreThanLoop: self.activeNotice != .glucoseBelowTarget,
                    round: { self.delegate?.roundBolusVolume(units: $0) ?? ($0 * 20).rounded(.down) / 20 }
                )
                let advice = AIDoseAdvice(answer: answer, units: limited.units, loopUnits: self.recommendedBolusAmount, limitedFrom: limited.limitedFrom, date: now)
                self.aiDoseAdviceState = .ready(advice)
                self.recordAIDoseAdvice(advice, accepted: false)
            } catch {
                guard !Task.isCancelled else { return }
                self.aiDoseAdviceState = .failed(error.localizedDescription)
            }
        }
    }

    /// Notes that the shown advice went into the bolus field.
    /// True when the advice still fits what the screen shows, so it may go into the bolus field.
    func canAcceptAIDoseAdvice(_ advice: AIDoseAdvice) -> Bool {
        guard aiDoseBlockingReason(now: Date()) == nil, let loop = recommendedBolusAmount, let earlier = advice.loopUnits else {
            aiDoseInputsDidChange()
            return false
        }
        guard abs(loop - earlier) < 0.001 else {
            aiDoseInputsDidChange()
            return false
        }
        return true
    }

    func didAcceptAIDoseAdvice(_ advice: AIDoseAdvice) {
        recordAIDoseAdvice(advice, accepted: true)
    }

    private func recordAIDoseAdvice(_ advice: AIDoseAdvice, accepted: Bool) {
        var records = UserDefaults.standard.aiDoseAdviceRecords
        let record = AIDoseAdviceRecord(
            date: advice.date,
            loopUnits: advice.loopUnits,
            suggestedUnits: advice.units,
            carbsGrams: potentialCarbEntry?.quantity.doubleValue(for: .gram()),
            accepted: accepted
        )
        if let index = records.lastIndex(where: { $0.date == advice.date }) {
            records[index] = record
        } else {
            records.append(record)
        }
        UserDefaults.standard.aiDoseAdviceRecords = records
    }

    // MARK: - The situation

    private func aiDoseSituation(now: Date, settings: AIDoseAdviceSettings, local: AIDoseLocalHistory, history: NightscoutHistorySummary?) -> AIDoseSituation {
        let mmolUnit = HKUnit.millimolesPerLiter
        func mmol(_ quantity: HKQuantity) -> Double {
            (quantity.doubleValue(for: mmolUnit) * 10).rounded() / 10
        }
        func minutes(from date: Date) -> Int {
            Int((date.timeIntervalSince(now) / 60).rounded())
        }
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "nb_NO")
        clock.dateFormat = "HH:mm"
        let fullTime = DateFormatter()
        fullTime.locale = Locale(identifier: "nb_NO")
        fullTime.dateFormat = "EEEE d. MMMM yyyy HH:mm"

        // Glucose: the last three hours every ten minutes, so the trend is clear without every reading.
        let glucose = (local.glucose.isEmpty ? glucoseValues : local.glucose).sorted { $0.startDate < $1.startDate }
        var lastThreeHours: [AIDoseSituation.Point] = []
        var lastKept: Date?
        for value in glucose where value.startDate >= now.addingTimeInterval(-.hours(3)) {
            if let kept = lastKept, value.startDate.timeIntervalSince(kept) < .minutes(9) { continue }
            lastThreeHours.append(.init(minutes: minutes(from: value.startDate), mmol: mmol(value.quantity)))
            lastKept = value.startDate
        }
        let latest = glucose.last
        let fifteenAgo = glucose.last { $0.startDate <= now.addingTimeInterval(-.minutes(14)) && $0.startDate >= now.addingTimeInterval(-.minutes(25)) }
        let change = latest.flatMap { latest in fifteenAgo.map { ((latest.quantity.doubleValue(for: mmolUnit) - $0.quantity.doubleValue(for: mmolUnit)) * 10).rounded() / 10 } }

        // Loop's forecast every half hour, six hours ahead.
        var forecast: [AIDoseSituation.Point] = []
        for value in predictedGlucoseValues where value.startDate > now {
            let minute = minutes(from: value.startDate)
            if minute % 30 < 5, !forecast.contains(where: { abs($0.minutes - minute) < 25 }), minute <= 360 {
                forecast.append(.init(minutes: minute, mmol: mmol(value.quantity)))
            }
        }

        let loopSettings = delegate?.settings
        var activeOverride: String?
        if let override = loopSettings?.preMealOverride ?? loopSettings?.scheduleOverride, override.isActive(at: now) {
            let name: String
            switch override.context {
            case .preset(let preset): name = "\(preset.symbol) \(preset.name)"
            case .preMeal: name = "Pre-meal"
            case .legacyWorkout: name = "Workout"
            case .custom: name = "Custom"
            }
            let percent = override.settings.insulinNeedsScaleFactor.map { " \(Int(($0 * 100).rounded())) % insulinbehov" } ?? ""
            let target = override.settings.targetRange.map { " mål \(mmol($0.lowerBound))–\(mmol($0.upperBound))" } ?? ""
            activeOverride = name + percent + target
        }
        let targetRange = loopSettings?.glucoseTargetRangeSchedule?.quantityRange(at: now)
        let therapy = AIDoseSituation.Therapy(
            carbRatioGramsPerUnit: loopSettings?.carbRatioSchedule?.value(at: now),
            insulinSensitivityMmolPerUnit: loopSettings?.insulinSensitivitySchedule.map { mmol($0.quantity(at: now)) },
            targetMmol: targetRange.map { [mmol($0.lowerBound), mmol($0.upperBound)] },
            suspendThresholdMmol: loopSettings?.suspendThreshold.map { mmol($0.quantity) },
            maximumBolusUnits: maximumBolus?.doubleValue(for: .internationalUnit()) ?? loopSettings?.maximumBolus,
            activeOverride: activeOverride
        )

        var meal: AIDoseSituation.Meal?
        if let entry = potentialCarbEntry {
            meal = AIDoseSituation.Meal(
                carbsGrams: entry.quantity.doubleValue(for: .gram()),
                absorptionHours: (entry.absorptionTime ?? .hours(3)) / .hours(1),
                foodType: entry.foodType,
                foodName: aiDoseMealContext?.foodName,
                minutesFromNow: minutes(from: entry.startDate),
                fatGrams: mealNutrition?.fatGrams,
                proteinGrams: mealNutrition?.proteinGrams,
                fatProteinBoost: fatProteinBoostSummary,
                isEditOfEarlierEntry: originalCarbEntry != nil
            )
        }

        let startOfDay = Calendar.current.startOfDay(for: now)
        let todayCarbs = local.carbEntries
            .filter { entry in entry.startDate >= startOfDay && (originalCarbEntry == nil || entry.syncIdentifier != originalCarbEntry?.syncIdentifier) }
            .sorted { $0.startDate < $1.startDate }
            .map { AIDoseSituation.TodayCarbs(time: clock.string(from: $0.startDate), grams: $0.quantity.doubleValue(for: .gram()), foodType: $0.foodType) }
        let todayInsulin = local.doses
            .filter { $0.type == .bolus && $0.startDate >= startOfDay }
            .sorted { $0.startDate < $1.startDate }
            .map { AIDoseSituation.TodayInsulin(time: clock.string(from: $0.startDate), units: (($0.deliveredUnits ?? $0.programmedUnits) * 100).rounded() / 100, automatic: $0.automatic ?? false) }
        let todayReadings = local.glucose
            .filter { $0.startDate >= startOfDay }
            .map { NightscoutGlucoseReading(date: $0.startDate, mgdl: $0.quantity.doubleValue(for: .milligramsPerDeciliter)) }

        var notice: String?
        switch activeNotice {
        case .glucoseBelowTarget?: notice = "Blodsukkeret er under målområdet."
        case .predictedGlucoseInRange?: notice = "Loop venter at blodsukkeret holder seg i målområdet uten mer insulin."
        default: notice = nil
        }

        return AIDoseSituation(
            localTime: fullTime.string(from: now),
            childProfile: settings.childProfile.trimmingCharacters(in: .whitespacesAndNewlines),
            glucoseMmol: latest.map { mmol($0.quantity) },
            glucoseMinutesAgo: latest.map { -minutes(from: $0.startDate) },
            glucoseChangeLast15MinMmol: change,
            glucoseLast3Hours: lastThreeHours,
            loopRecommendedUnits: recommendedBolusAmount,
            loopForecast: forecast,
            loopNotice: notice,
            insulinOnBoardUnits: activeInsulin.map { ($0.doubleValue(for: .internationalUnit()) * 100).rounded() / 100 },
            carbsOnBoardGrams: activeCarbs.map { $0.doubleValue(for: .gram()).rounded() },
            therapy: therapy,
            meal: meal,
            todayCarbs: todayCarbs,
            todayInsulin: todayInsulin,
            todayGlucose: NightscoutHistory.daypart(readings: todayReadings, name: "i dag"),
            history: history,
            earlierAdvice: UserDefaults.standard.aiDoseAdviceRecords.suffix(15).map { $0 }
        )
    }
}
