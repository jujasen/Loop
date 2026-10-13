//
//  GlucoseInsight.swift
//  Loop
//
//  The child's glucose today and over the weeks behind, worked out on the phone from the
//  Nightscout history: time in range per part of the day, how meals went (with the ones muddled by
//  extra carbs, corrections or treated lows marked), how far Loop's forecast missed, and how the
//  AI doses that were shown turned out. Every number is worked out here, in code; the model only
//  reads them and writes what they mean (see GlucoseInsightManager).
//

import Foundation

// MARK: - Numbers

struct GlucoseInsightPeriod: Codable, Equatable {
    var meanMmol: Double
    var timeInRangePercent: Int
    var belowRangePercent: Int
    var aboveRangePercent: Int
    /// Two readings or more in a row below 3.9 mmol/L count as one.
    var lowEpisodes: Int
    var readings: Int
}

struct GlucoseInsightMeal: Codable, Equatable {
    enum Flag: String, Codable {
        /// More carbs (not for a low) within three hours: the outcome is not this meal's alone.
        case extraCarbs = "extra_carbs"
        /// A bolus without carbs within three hours.
        case correction
        /// Carbs given for a low within four hours.
        case treatedLow = "treated_low"
        /// Glucose was under 4.5 mmol/L when the meal started.
        case startedLow = "started_low"
        /// Less than four hours ago.
        case unfinished
    }

    var date: Date
    var daypart: String
    var carbsGrams: Double
    var foods: [String]
    var bolusUnits: Double
    var automaticUnitsWithin3h: Double
    var startMmol: Double?
    var peakMmol: Double?
    var after2hMmol: Double?
    var after3hMmol: Double?
    var lowestWithin4hMmol: Double?
    var flags: [Flag]

    var isClean: Bool { flags.isEmpty }
}

struct GlucoseInsightDaypart: Codable, Equatable {
    var name: String
    var last7Days: GlucoseInsightPeriod?
    var last30Days: GlucoseInsightPeriod?
    /// Median of actual minus forecast, in mmol/L: positive when Loop forecast too low.
    var loopForecastError1hMmol: Double?
    var loopForecastError2hMmol: Double?
    var forecastChecks: Int
    /// Meals without anything muddling their outcome.
    var cleanMeals: Int
    var medianGramsPerUnit: Double?
    var medianRiseMmol: Double?
    var median3hChangeMmol: Double?
    /// Share of clean meals with glucose under 3.9 within four hours.
    var lowAfterMealPercent: Int?
    /// Share of clean meals over 10 mmol/L three hours on.
    var highAt3hPercent: Int?
}

/// How an AI dose that was shown turned out.
struct GlucoseInsightAdvice: Codable, Equatable {
    var date: Date
    var loopUnits: Double?
    var suggestedUnits: Double
    var accepted: Bool
    var after3hMmol: Double?
    var lowestWithin4hMmol: Double?
}

struct GlucoseInsightLongTerm: Codable, Equatable {
    var days: Int
    var last7Days: GlucoseInsightPeriod?
    /// The days before the last seven, to see which way things are going.
    var earlierDays: GlucoseInsightPeriod?
    var dayparts: [GlucoseInsightDaypart]
    /// 09–15, kindergarten hours on weekdays.
    var weekdayDaytime: GlucoseInsightPeriod?
    var weekendDaytime: GlucoseInsightPeriod?
    var averageDailyCarbsGrams: Double
    var averageDailyBolusUnits: Double
    /// Finished meals, newest last.
    var meals: [GlucoseInsightMeal]
    var advice: [GlucoseInsightAdvice]
    var computedAt: Date
}

struct GlucoseInsightToday: Codable, Equatable {
    var period: GlucoseInsightPeriod?
    var lowEpisodeStarts: [Date]
    var hoursAboveTen: Double
    var meals: [GlucoseInsightMeal]
    /// Today's median forecast error an hour on, and the usual one for the same hours.
    var loopForecastError1hMmol: Double?
    var usualForecastError1hMmol: Double?
    /// Today's minus the usual: positive when Loop is missing low by more than usual today, so
    /// more insulin is needed than it thinks.
    var forecastDeviationMmol: Double?
    var computedAt: Date
}

/// What the model made of the numbers.
struct GlucoseInsightText: Codable, Equatable {
    var summary: String
    var points: [String]
    var doseHints: [String]
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case summary, points
        case doseHints = "dose_hints"
        case createdAt = "created_at"
    }
}

struct GlucoseInsightStatus: Codable, Equatable {
    var longTerm: GlucoseInsightLongTerm?
    var today: GlucoseInsightToday?
    /// Written at night by the deep model, from the weeks behind.
    var longTermText: GlucoseInsightText?
    /// Written through the day by the fast model, when a meal is over or after a low.
    var todayText: GlucoseInsightText?
    var dataUpdatedAt: Date?
    var lastError: String?
}

// MARK: - Working it out

enum GlucoseInsight {
    /// Day parts in local time; the day is mostly kindergarten hours.
    static let dayparts: [(name: String, hours: Range<Int>)] = [
        ("natt 00-06", 0..<6),
        ("morgen 06-09", 6..<9),
        ("dag 09-15", 9..<15),
        ("ettermiddag 15-19", 15..<19),
        ("kveld 19-24", 19..<24),
    ]

    static let rangeMgdl: ClosedRange<Double> = 70...180 // 3.9–10 mmol/L
    /// Carbs entered under 5 mmol/L without a bolus are for a low, not a meal.
    static let treatmentCarbsBelowMgdl = 90.0
    static let startedLowBelowMgdl = 81.0 // 4.5
    /// Entries this close are one meal.
    static let mealGap: TimeInterval = .hours(1)
    /// Most finished meals kept.
    static let maximumMeals = 120

    static func mmol(_ mgdl: Double) -> Double {
        round1(mgdl / 18.0182)
    }

    static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    static func daypartName(_ date: Date, calendar: Calendar) -> String {
        let hour = calendar.component(.hour, from: date)
        return dayparts.first { $0.hours.contains(hour) }?.name ?? dayparts[0].name
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func percent(_ count: Int, of total: Int) -> Int? {
        total > 0 ? Int((Double(count) / Double(total) * 100).rounded()) : nil
    }

    // MARK: Periods

    static func period(_ readings: [NightscoutGlucoseReading]) -> GlucoseInsightPeriod? {
        guard !readings.isEmpty else { return nil }
        let count = Double(readings.count)
        let below = readings.filter { $0.mgdl < rangeMgdl.lowerBound }.count
        let above = readings.filter { $0.mgdl > rangeMgdl.upperBound }.count
        return GlucoseInsightPeriod(
            meanMmol: mmol(readings.map(\.mgdl).reduce(0, +) / count),
            timeInRangePercent: Int((Double(readings.count - below - above) / count * 100).rounded()),
            belowRangePercent: Int((Double(below) / count * 100).rounded()),
            aboveRangePercent: Int((Double(above) / count * 100).rounded()),
            lowEpisodes: lowEpisodeStarts(readings).count,
            readings: readings.count
        )
    }

    /// Where runs of two or more readings below range begin. A gap over 15 minutes ends a run.
    static func lowEpisodeStarts(_ readings: [NightscoutGlucoseReading]) -> [Date] {
        var starts: [Date] = []
        var runStart: Date?
        var runLength = 0
        var previous: Date?
        for reading in readings.sorted(by: { $0.date < $1.date }) {
            let continues = previous.map { reading.date.timeIntervalSince($0) <= .minutes(15) } ?? false
            if reading.mgdl < rangeMgdl.lowerBound {
                if continues && runLength > 0 {
                    runLength += 1
                } else {
                    runStart = reading.date
                    runLength = 1
                }
                if runLength == 2, let runStart {
                    starts.append(runStart)
                }
            } else {
                runLength = 0
            }
            previous = reading.date
        }
        return starts
    }

    // MARK: Meals

    static func reading(near date: Date, in glucose: [NightscoutGlucoseReading]) -> Double? {
        glucose
            .filter { abs($0.date.timeIntervalSince(date)) <= .minutes(10) }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?
            .mgdl
    }

    /// The meals in `treatments`, each with how glucose went for four hours after it.
    static func meals(glucose: [NightscoutGlucoseReading], treatments: [NightscoutTreatment], now: Date, calendar: Calendar) -> [GlucoseInsightMeal] {
        let glucose = glucose.sorted { $0.date < $1.date }
        let treatments = treatments.sorted { $0.date < $1.date }
        let carbEntries = treatments.filter { ($0.carbs ?? 0) > 0 }

        func isTreatment(_ entry: NightscoutTreatment) -> Bool {
            guard let mgdl = reading(near: entry.date, in: glucose), mgdl < treatmentCarbsBelowMgdl else { return false }
            let bolused = treatments.contains { !$0.isAutomatic && ($0.insulin ?? 0) > 0 && $0.date >= entry.date.addingTimeInterval(-.minutes(20)) && $0.date <= entry.date.addingTimeInterval(.minutes(30)) }
            return !bolused
        }

        // Entries an hour or less apart are one meal; carbs for a low are not a meal.
        var groups: [[NightscoutTreatment]] = []
        for entry in carbEntries where !isTreatment(entry) {
            if let last = groups.last?.last, entry.date.timeIntervalSince(last.date) <= mealGap {
                groups[groups.count - 1].append(entry)
            } else {
                groups.append([entry])
            }
        }

        return groups.map { group in
            let start = group[0].date
            let last = group[group.count - 1].date
            let carbs = group.compactMap(\.carbs).reduce(0, +)
            let mealBoluses = treatments.filter { !$0.isAutomatic && ($0.insulin ?? 0) > 0 && $0.date >= start.addingTimeInterval(-.minutes(20)) && $0.date <= last.addingTimeInterval(.minutes(30)) }
            let automatic = treatments.filter { $0.isAutomatic && $0.date >= start && $0.date <= start.addingTimeInterval(.hours(3)) }
            let after = glucose.filter { $0.date >= start && $0.date <= start.addingTimeInterval(.hours(4)) }
            let firstThree = after.filter { $0.date <= start.addingTimeInterval(.hours(3)) }
            let startMgdl = reading(near: start, in: glucose)

            var flags: [GlucoseInsightMeal.Flag] = []
            let laterCarbs = carbEntries.filter { $0.date > last && $0.date <= start.addingTimeInterval(.hours(4)) }
            if laterCarbs.contains(where: { $0.date <= start.addingTimeInterval(.hours(3)) && !isTreatment($0) }) {
                flags.append(.extraCarbs)
            }
            let corrections = treatments.filter { !$0.isAutomatic && ($0.insulin ?? 0) > 0 && $0.date > last.addingTimeInterval(.minutes(30)) && $0.date <= start.addingTimeInterval(.hours(3)) }
            let correctionsWithoutCarbs = corrections.filter { bolus in !carbEntries.contains { abs($0.date.timeIntervalSince(bolus.date)) <= .minutes(30) } }
            if !correctionsWithoutCarbs.isEmpty {
                flags.append(.correction)
            }
            if laterCarbs.contains(where: isTreatment) {
                flags.append(.treatedLow)
            }
            if let startMgdl, startMgdl < startedLowBelowMgdl {
                flags.append(.startedLow)
            }
            if now < start.addingTimeInterval(.hours(4)) {
                flags.append(.unfinished)
            }

            return GlucoseInsightMeal(
                date: start,
                daypart: daypartName(start, calendar: calendar),
                carbsGrams: carbs,
                foods: group.compactMap(\.foodType),
                bolusUnits: (mealBoluses.compactMap(\.insulin).reduce(0, +) * 100).rounded() / 100,
                automaticUnitsWithin3h: (automatic.compactMap(\.insulin).reduce(0, +) * 100).rounded() / 100,
                startMmol: startMgdl.map(mmol),
                peakMmol: firstThree.map(\.mgdl).max().map(mmol),
                after2hMmol: reading(near: start.addingTimeInterval(.hours(2)), in: glucose).map(mmol),
                after3hMmol: reading(near: start.addingTimeInterval(.hours(3)), in: glucose).map(mmol),
                lowestWithin4hMmol: after.map(\.mgdl).min().map(mmol),
                flags: flags
            )
        }
    }

    // MARK: Loop's forecast

    /// Actual minus forecast, in mmol/L, for each forecast whose hour (or two) has come.
    static func forecastErrors(_ forecasts: [LoopForecastCheck], glucose: [NightscoutGlucoseReading], hours: Int) -> [(date: Date, mmol: Double)] {
        forecasts.compactMap { forecast in
            guard let predicted = hours == 1 ? forecast.in60Mgdl : forecast.in120Mgdl,
                  let actual = reading(near: forecast.date.addingTimeInterval(.hours(Double(hours))), in: glucose)
            else { return nil }
            return (forecast.date, (actual - predicted) / 18.0182)
        }
    }

    // MARK: All of it

    static func longTerm(history: NightscoutHistory, advice: [AIDoseAdviceRecord], days: Int, now: Date, calendar: Calendar = .current) -> GlucoseInsightLongTerm {
        let start = now.addingTimeInterval(-.hours(24 * Double(days)))
        let weekStart = now.addingTimeInterval(-.hours(24 * 7))
        let glucose = history.glucose.filter { $0.date >= start && $0.date <= now }.sorted { $0.date < $1.date }
        let treatments = history.treatments.filter { $0.date >= start && $0.date <= now }
        let meals = Self.meals(glucose: glucose, treatments: treatments, now: now, calendar: calendar).filter { !$0.flags.contains(.unfinished) }
        let errors1h = forecastErrors(history.forecasts, glucose: glucose, hours: 1)
        let errors2h = forecastErrors(history.forecasts, glucose: glucose, hours: 2)

        func hour(_ date: Date) -> Int { calendar.component(.hour, from: date) }

        let parts = dayparts.map { part -> GlucoseInsightDaypart in
            let inPart = glucose.filter { part.hours.contains(hour($0.date)) }
            let clean = meals.filter { $0.daypart == part.name && $0.isClean }
            let gramsPerUnit = clean.filter { $0.bolusUnits > 0 }.map { $0.carbsGrams / $0.bolusUnits }
            let rises = clean.compactMap { meal in meal.peakMmol.flatMap { peak in meal.startMmol.map { peak - $0 } } }
            let changes = clean.compactMap { meal in meal.after3hMmol.flatMap { after in meal.startMmol.map { after - $0 } } }
            let partErrors1h = errors1h.filter { part.hours.contains(hour($0.date)) }.map(\.mmol)
            let partErrors2h = errors2h.filter { part.hours.contains(hour($0.date)) }.map(\.mmol)
            return GlucoseInsightDaypart(
                name: part.name,
                last7Days: period(inPart.filter { $0.date >= weekStart }),
                last30Days: period(inPart),
                loopForecastError1hMmol: median(partErrors1h).map(round1),
                loopForecastError2hMmol: median(partErrors2h).map(round1),
                forecastChecks: partErrors1h.count,
                cleanMeals: clean.count,
                medianGramsPerUnit: median(gramsPerUnit).map(round1),
                medianRiseMmol: median(rises).map(round1),
                median3hChangeMmol: median(changes).map(round1),
                lowAfterMealPercent: percent(clean.filter { ($0.lowestWithin4hMmol ?? 99) < 3.9 }.count, of: clean.count),
                highAt3hPercent: percent(clean.filter { ($0.after3hMmol ?? 0) > 10 }.count, of: clean.filter { $0.after3hMmol != nil }.count)
            )
        }

        let daytime = glucose.filter { (9..<15).contains(hour($0.date)) }
        let isWeekend: (Date) -> Bool = { calendar.isDateInWeekend($0) }

        let adviceOutcomes = advice.filter { $0.date >= start }.map { record -> GlucoseInsightAdvice in
            let finished = now >= record.date.addingTimeInterval(.hours(4))
            let after = glucose.filter { $0.date >= record.date && $0.date <= record.date.addingTimeInterval(.hours(4)) }
            return GlucoseInsightAdvice(
                date: record.date,
                loopUnits: record.loopUnits,
                suggestedUnits: record.suggestedUnits,
                accepted: record.accepted,
                after3hMmol: finished ? reading(near: record.date.addingTimeInterval(.hours(3)), in: glucose).map(mmol) : nil,
                lowestWithin4hMmol: finished ? after.map(\.mgdl).min().map(mmol) : nil
            )
        }

        return GlucoseInsightLongTerm(
            days: days,
            last7Days: period(glucose.filter { $0.date >= weekStart }),
            earlierDays: period(glucose.filter { $0.date < weekStart }),
            dayparts: parts,
            weekdayDaytime: period(daytime.filter { !isWeekend($0.date) }),
            weekendDaytime: period(daytime.filter { isWeekend($0.date) }),
            averageDailyCarbsGrams: (treatments.compactMap(\.carbs).reduce(0, +) / Double(days)).rounded(),
            averageDailyBolusUnits: round1(treatments.filter { !$0.isAutomatic }.compactMap(\.insulin).reduce(0, +) / Double(days)),
            meals: Array(meals.suffix(maximumMeals)),
            advice: adviceOutcomes,
            computedAt: now
        )
    }

    static func today(history: NightscoutHistory, now: Date, calendar: Calendar = .current) -> GlucoseInsightToday {
        let startOfDay = calendar.startOfDay(for: now)
        let glucose = history.glucose.filter { $0.date >= startOfDay && $0.date <= now }.sorted { $0.date < $1.date }
        // Meals from late yesterday evening still count for this morning's glucose, but only today's are listed.
        let treatments = history.treatments.filter { $0.date >= startOfDay.addingTimeInterval(-.hours(4)) && $0.date <= now }
        let glucoseForMeals = history.glucose.filter { $0.date >= startOfDay.addingTimeInterval(-.hours(4)) && $0.date <= now }
        let meals = Self.meals(glucose: glucoseForMeals, treatments: treatments, now: now, calendar: calendar).filter { $0.date >= startOfDay }

        var minutesAboveTen = 0.0
        for (reading, next) in zip(glucose, glucose.dropFirst()) where reading.mgdl > rangeMgdl.upperBound {
            minutesAboveTen += min(next.date.timeIntervalSince(reading.date), .minutes(10)) / 60
        }

        // Today's forecast misses, against the usual for the same hours over the last two weeks.
        let allErrors = forecastErrors(history.forecasts, glucose: history.glucose, hours: 1)
        let todayErrors = allErrors.filter { $0.date >= startOfDay }
        let hoursToday = Set(todayErrors.map { calendar.component(.hour, from: $0.date) })
        let usual = allErrors.filter { $0.date < startOfDay && hoursToday.contains(calendar.component(.hour, from: $0.date)) }
        let todayError = todayErrors.count >= 3 ? median(todayErrors.map(\.mmol)) : nil
        let usualError = todayErrors.count >= 3 ? median(usual.map(\.mmol)) : nil

        return GlucoseInsightToday(
            period: period(glucose),
            lowEpisodeStarts: lowEpisodeStarts(glucose),
            hoursAboveTen: round1(minutesAboveTen / 60),
            meals: meals,
            loopForecastError1hMmol: todayError.map(round1),
            usualForecastError1hMmol: usualError.map(round1),
            forecastDeviationMmol: todayError.flatMap { today in usualError.map { round1(today - $0) } },
            computedAt: now
        )
    }

    // MARK: Similar meals

    /// The finished meals most like this one: the same part of the day and hour, the same food, a
    /// similar amount of carbs, and clean outcomes and recent ones first.
    static func similarMeals(to carbs: Double, foodType: String?, at date: Date, in meals: [GlucoseInsightMeal], count: Int = 5, calendar: Calendar = .current) -> [GlucoseInsightMeal] {
        let daypart = daypartName(date, calendar: calendar)
        let minuteOfDay = { (date: Date) -> Double in
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        }
        let words = foodWords(foodType)

        func score(_ meal: GlucoseInsightMeal) -> Double {
            var score = 0.0
            if meal.daypart == daypart { score += 3 }
            let minutes = abs(minuteOfDay(meal.date) - minuteOfDay(date))
            score -= min(minutes, 1440 - minutes) / 120
            if !words.isEmpty, !words.isDisjoint(with: meal.foods.reduce(into: Set<String>()) { $0.formUnion(foodWords($1)) }) {
                score += 3
            }
            if carbs > 0, meal.carbsGrams > 0 {
                score -= abs(log(meal.carbsGrams / carbs)) * 2
            }
            if meal.isClean { score += 1.5 }
            score -= date.timeIntervalSince(meal.date) / .hours(24 * 30)
            return score
        }

        return Array(meals.filter { !$0.flags.contains(.unfinished) }.sorted { score($0) > score($1) }.prefix(count))
    }

    /// Lowercased words and emoji of a food type, "🍕 Pizza m/ ost" → {"🍕", "pizza", "ost"}.
    static func foodWords(_ foodType: String?) -> Set<String> {
        guard let foodType else { return [] }
        var words = Set<String>()
        for word in foodType.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "/" || $0 == "&" }) {
            let text = String(word)
            if text.count >= 3 || text.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
                words.insert(text)
            }
        }
        return words
    }
}
