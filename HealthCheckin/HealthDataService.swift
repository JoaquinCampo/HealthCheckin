import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

// Service responsible for querying HealthKit and assembling report data
final class HealthDataService {
#if canImport(HealthKit)
    private let store = HKHealthStore()
#endif

    // MARK: - Public API

    func buildReport() async -> ReportV1 {
        let now = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart

        let night = await computeNightWindow(reference: now)

        async let readiness = fetchReadinessSignals(night: night)
        async let activityYesterday = fetchActivityDay(windowStart: yesterdayStart, windowEnd: todayStart)
        async let activityToday = fetchActivityDay(windowStart: todayStart, windowEnd: now)
        async let healthYesterday = fetchHealthDay(windowStart: yesterdayStart, windowEnd: todayStart)
        async let healthToday = fetchHealthDay(windowStart: todayStart, windowEnd: now)

        let readinessSignals = await readiness
        let yesterday = await activityYesterday
        let today = await activityToday
        let healthY = await healthYesterday
        let healthT = await healthToday

        let tz = TimeZone.current
        let meta = ReportMeta(
            generatedAt: now,
            timezoneIdentifier: tz.identifier,
            secondsFromGMT: tz.secondsFromGMT(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )

        let windows = ReportWindows(
            nightStart: night?.start,
            nightEnd: night?.end,
            yesterdayStart: yesterdayStart,
            todayStart: todayStart
        )

        let activity = Activity(yesterday: yesterday, today: today)
        let health = Health(yesterday: healthY, today: healthT)

        let flags: [String: Bool] = [
            "permissions_partial": false
        ]

        return ReportV1(meta: meta, windows: windows, readinessSignals: readinessSignals, activity: activity, health: health, flags: flags)
    }

    // MARK: - Readiness

    private func fetchReadinessSignals(night: NightWindow?) async -> [String: Metric] {
        guard let night else {
            return defaultReadiness()
        }

        async let hrv = timeWeightedAverage(
            type: .heartRateVariabilitySDNN,
            unit: .secondUnit(with: .milli),
            window: night
        )
        async let rhr = timeWeightedAverage(
            type: .restingHeartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            window: night
        )
        async let resp = timeWeightedAverage(
            type: .respiratoryRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            window: night
        )
        async let wristTemp = timeWeightedAverage(
            type: .appleSleepingWristTemperature,
            unit: .degreeCelsius(),
            window: night
        )
        async let spo2 = timeWeightedAverage(
            type: .oxygenSaturation,
            unit: HKUnit.percent(),
            window: night
        )
        async let sleepStages = sleepStageDurations(night: night)
        async let sleepHrAvg = discreteAverageInWindow(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: night.start, end: night.end)
                                         
        let hrvRes = await hrv
        let rhrRes = await rhr
        let respRes = await resp
        let tempRes = await wristTemp
        let spo2Res = await spo2
        let stages = await sleepStages
        let sleepHr = await sleepHrAvg

        var map = [String: Metric]()
        map["hrv_sdnn_ms"] = hrvRes.metric(unitLabel: "ms")
        map["resting_hr_bpm"] = rhrRes.metric(unitLabel: "bpm")
        map["respiratory_rate_br_min"] = respRes.metric(unitLabel: "br/min")
        map["wrist_temp_delta_c"] = tempRes.metric(unitLabel: "°C")
        let spo2Pct = spo2Res.value.map { $0 * 100.0 }
        map["oxygen_saturation_avg_pct"] = Metric(value: spo2Pct, unit: "%", sampleCount: spo2Res.sampleCount, quality: [])
        map["sleep_duration_min"] = Metric(
            value: night.durationMinutes,
            unit: "min",
            sampleCount: night.sampleCount,
            quality: []
        )
        map["sleep_awake_min"] = Metric(value: stages.awakeMin, unit: "min", sampleCount: stages.counts, quality: [])
        map["sleep_core_min"] = Metric(value: stages.coreMin, unit: "min", sampleCount: stages.counts, quality: [])
        map["sleep_deep_min"] = Metric(value: stages.deepMin, unit: "min", sampleCount: stages.counts, quality: [])       
        map["sleep_rem_min"] = Metric(value: stages.remMin, unit: "min", sampleCount: stages.counts, quality: [])
        map["sleep_hr_avg_bpm"] = Metric(value: sleepHr, unit: "bpm", sampleCount: stages.counts, quality: [])
        return map
    }

    private func defaultReadiness() -> [String: Metric] {
        return [
            "hrv_sdnn_ms": Metric(value: nil, unit: "ms", sampleCount: 0, quality: []),
            "resting_hr_bpm": Metric(value: nil, unit: "bpm", sampleCount: 0, quality: []),
            "respiratory_rate_br_min": Metric(value: nil, unit: "br/min", sampleCount: 0, quality: []),
            "wrist_temp_delta_c": Metric(value: nil, unit: "°C", sampleCount: 0, quality: []),
            "sleep_duration_min": Metric(value: nil, unit: "min", sampleCount: 0, quality: []),
            "sleep_awake_min": Metric(value: nil, unit: "min", sampleCount: 0, quality: []),
            "sleep_core_min": Metric(value: nil, unit: "min", sampleCount: 0, quality: []),
            "sleep_deep_min": Metric(value: nil, unit: "min", sampleCount: 0, quality: []),
            "sleep_rem_min": Metric(value: nil, unit: "min", sampleCount: 0, quality: []),
            "sleep_hr_avg_bpm": Metric(value: nil, unit: "bpm", sampleCount: 0, quality: []),
            "oxygen_saturation_avg_pct": Metric(value: nil, unit: "%", sampleCount: 0, quality: [])
        ]
    }

    // MARK: - Activity per day

    private func fetchActivityDay(windowStart: Date, windowEnd: Date) async -> ActivityDay {
        async let steps = dailyCumulative(.stepCount, unit: .count(), start: windowStart, end: windowEnd)
        async let activeEnergy = dailyCumulative(.activeEnergyBurned, unit: .kilocalorie(), start: windowStart, end: windowEnd)
        async let basalEnergy = dailyCumulative(.basalEnergyBurned, unit: .kilocalorie(), start: windowStart, end: windowEnd)
        async let distanceWalkRun = dailyCumulative(.distanceWalkingRunning, unit: .meter(), start: windowStart, end: windowEnd)
        async let distanceCycling = dailyCumulative(.distanceCycling, unit: .meter(), start: windowStart, end: windowEnd)
        async let distanceSwimming = dailyCumulative(.distanceSwimming, unit: .meter(), start: windowStart, end: windowEnd)
        async let flights = dailyCumulative(.flightsClimbed, unit: .count(), start: windowStart, end: windowEnd)
        async let exercise = dailyCumulative(.appleExerciseTime, unit: .minute(), start: windowStart, end: windowEnd)
        async let standMin = dailyCumulative(.appleStandTime, unit: .minute(), start: windowStart, end: windowEnd)
        async let avgHR = discreteAverage(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: windowStart, end: windowEnd)
        async let maxHR = discreteMax(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: windowStart, end: windowEnd)
        async let hrSeries = collectHeartRateSeries(start: windowStart, end: windowEnd)
        async let vo2 = mostRecent(.vo2Max, unit: HKUnit(from: "ml/kg*min"), start: windowStart, end: windowEnd)
        async let workoutsList = workouts(start: windowStart, end: windowEnd)

        let stepsVal = await steps
        let energyVal = await activeEnergy
        let basalEnergyVal = await basalEnergy
        let distWalkRunVal = await distanceWalkRun
        let distCyclingVal = await distanceCycling
        let distSwimVal = await distanceSwimming
        let flightsVal = await flights
        let exerciseVal = await exercise
        let standMinVal = await standMin
        let avgHRVal = await avgHR
        let maxHRVal = await maxHR
        let hrPoints = await hrSeries
        let vo2Val = await vo2
        let workoutsVal = await workoutsList

        let zones = computeHRZones(points: hrPoints)

        return ActivityDay(
            steps: stepsVal.flatMap { Int($0) },
            activeEnergyKcal: energyVal,
            distanceWalkingRunningMeters: distWalkRunVal,
            distanceCyclingMeters: distCyclingVal,
            distanceSwimmingMeters: distSwimVal,
            flightsClimbed: flightsVal,
            basalEnergyKcal: basalEnergyVal,
            standMinutes: standMinVal,
            standHours: standMinVal.map { Int($0 / 60.0) },
            avgHeartRateBpm: avgHRVal,
            maxHeartRateBpm: maxHRVal,
            vo2Max: vo2Val,
            exerciseMinutes: exerciseVal,
            workouts: workoutsVal,
            heartRateBpm: hrPoints,
            hrZonesSec: zones
        )
    }

    private func computeHRZones(points: [HRPoint]?) -> [String: Double]? {
        guard let points, points.count > 1 else { return nil }
        let thresholds: [Double] = [95, 114, 133, 152, 171]
        var accum: [Double] = Array(repeating: 0.0, count: 5)
        for i in 1..<points.count {
            let dt = points[i].time.timeIntervalSince(points[i-1].time)
            let bpm = points[i-1].bpm
            let zoneIndex: Int
            if bpm < thresholds[0] { zoneIndex = 0 }
            else if bpm < thresholds[1] { zoneIndex = 1 }
            else if bpm < thresholds[2] { zoneIndex = 2 }
            else if bpm < thresholds[3] { zoneIndex = 3 }
            else { zoneIndex = 4 }
            accum[zoneIndex] += dt
        }
        return [
            "z1": accum[0],
            "z2": accum[1],
            "z3": accum[2],
            "z4": accum[3],
            "z5": accum[4]
        ]
    }

    // MARK: - Health insights per day

    private func fetchHealthDay(windowStart: Date, windowEnd: Date) async -> HealthDay {
        async let mindful = mindfulMinutesSum(start: windowStart, end: windowEnd)
        async let dietaryEnergy = dailyCumulative(.dietaryEnergyConsumed, unit: .kilocalorie(), start: windowStart, end: windowEnd)
        async let water = dailyCumulative(.dietaryWater, unit: .liter(), start: windowStart, end: windowEnd)
        async let carbs = dailyCumulative(.dietaryCarbohydrates, unit: .gram(), start: windowStart, end: windowEnd)
        async let protein = dailyCumulative(.dietaryProtein, unit: .gram(), start: windowStart, end: windowEnd)
        async let fat = dailyCumulative(.dietaryFatTotal, unit: .gram(), start: windowStart, end: windowEnd)
        async let caffeine = dailyCumulative(.dietaryCaffeine, unit: HKUnit.gramUnit(with: .milli), start: windowStart, end: windowEnd)
        async let sodium = dailyCumulative(.dietarySodium, unit: HKUnit.gramUnit(with: .milli), start: windowStart, end: windowEnd)
        async let bloodGlucose = mostRecent(.bloodGlucose, unit: HKUnit(from: "mg/dL"), start: windowStart, end: windowEnd)
        async let oxygen = discreteAverage(.oxygenSaturation, unit: HKUnit.percent(), start: windowStart, end: windowEnd)
        async let bodyTemp = discreteAverage(.bodyTemperature, unit: .degreeCelsius(), start: windowStart, end: windowEnd)
        async let bp = bloodPressureMostRecent(start: windowStart, end: windowEnd)
        async let bodyMass = mostRecent(.bodyMass, unit: .gramUnit(with: .kilo), start: windowStart, end: windowEnd)
        async let bmi = mostRecent(.bodyMassIndex, unit: .count(), start: windowStart, end: windowEnd)
        async let bodyFat = mostRecent(.bodyFatPercentage, unit: HKUnit.percent(), start: windowStart, end: windowEnd)
        async let ecgs = ecgCount(start: windowStart, end: windowEnd)

        let mindfulVal = await mindful
        let dietaryVal = await dietaryEnergy
        let waterVal = await water
        let carbsVal = await carbs
        let proteinVal = await protein
        let fatVal = await fat
        let caffeineVal = await caffeine.map { $0 }
        let sodiumVal = await sodium.map { $0 }
        let glucoseVal = await bloodGlucose
        let oxygenVal = await oxygen.map { $0 * 100.0 }
        let tempVal = await bodyTemp
        let (sys, dia) = await bp
        let massVal = await bodyMass
        let bmiVal = await bmi
        let bodyFatVal = await bodyFat.map { $0 * 100.0 }
        let ecgVal = await ecgs

        return HealthDay(
            mindfulMinutes: mindfulVal,
            dietaryEnergyKcal: dietaryVal,
            dietaryWaterLiters: waterVal,
            dietaryCarbohydratesGrams: carbsVal,
            dietaryProteinGrams: proteinVal,
            dietaryFatGrams: fatVal,
            dietaryCaffeineMg: caffeineVal,
            dietarySodiumMg: sodiumVal,
            dietaryAlcoholGrams: nil,
            bloodGlucoseMgPerdL: glucoseVal,
            bloodPressureSystolicMmHg: sys,
            bloodPressureDiastolicMmHg: dia,
            oxygenSaturationAvgPct: oxygenVal,
            bodyTemperatureC: tempVal,
            bodyMassKg: massVal,
            bodyMassIndex: bmiVal,
            bodyFatPercent: bodyFatVal,
            ecgCount: ecgVal
        )
    }

    // MARK: - Night window

    struct NightWindow {
        let start: Date
        let end: Date
        let sampleCount: Int

        var durationMinutes: Double {
            return end.timeIntervalSince(start) / 60.0
        }
    }

    private func computeNightWindow(reference: Date) async -> NightWindow? {
#if canImport(HealthKit)
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let startSearch = Calendar.current.date(byAdding: .day, value: -2, to: reference) ?? reference.addingTimeInterval(-2 * 86400)
        let predicate = HKQuery.predicateForSamples(withStart: startSearch, end: reference, options: .strictStartDate)
        let samples: [HKCategorySample] = await fetchCategorySamples(type: sleepType, predicate: predicate)

        // Filter to asleep segments
        let asleepValues: Set<Int>
        if #available(iOS 16.0, *) {
            asleepValues = Set([
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
            ])
        } else {
            asleepValues = Set([HKCategoryValueSleepAnalysis.asleep.rawValue])
        }

        let intervals = samples
            .filter { asleepValues.contains($0.value) }
            .map { ($0.startDate, $0.endDate) }
            .sorted { $0.0 < $1.0 }

        guard !intervals.isEmpty else { return nil }

        // Merge contiguous intervals (<= 5 min gap)
        let merged = mergeIntervals(intervals: intervals, maxGap: 5 * 60)

        // Choose the most recent block (end closest to now). If tie, choose longest.
        let best = merged.max { a, b in
            if a.1 == b.1 { return (a.1.timeIntervalSince(a.0)) < (b.1.timeIntervalSince(b.0)) }
            return a.1 < b.1
        }

        guard let night = best else { return nil }
        let count = samples.count
        return NightWindow(start: night.0, end: night.1, sampleCount: count)
#else
        return nil
#endif
    }

    private func mergeIntervals(intervals: [(Date, Date)], maxGap: TimeInterval) -> [(Date, Date)] {
        var result: [(Date, Date)] = []
        for interval in intervals {
            if var last = result.last {
                if interval.0.timeIntervalSince(last.1) <= maxGap {
                    // merge
                    result.removeLast()
                    last.1 = max(last.1, interval.1)
                    result.append(last)
                } else {
                    result.append(interval)
                }
            } else {
                result.append(interval)
            }
        }
        return result
    }

    // MARK: - Queries

    private struct TWResult {
        let value: Double?
        let sampleCount: Int

        func metric(unitLabel: String) -> Metric {
            return Metric(value: value, unit: unitLabel, sampleCount: sampleCount, quality: [])
        }
    }

    private func timeWeightedAverage(type identifier: HKQuantityTypeIdentifier, unit: HKUnit, window: NightWindow) async -> TWResult {
#if canImport(HealthKit)
        guard let qType = HKObjectType.quantityType(forIdentifier: identifier) else { return TWResult(value: nil, sampleCount: 0) }
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [.strictStartDate, .strictEndDate])
        let samples: [HKQuantitySample] = await fetchQuantitySamples(type: qType, predicate: predicate)
        guard !samples.isEmpty else { return TWResult(value: nil, sampleCount: 0) }

        let totalSeconds = samples.reduce(0.0) { acc, s in
            acc + overlapDuration(s.startDate, s.endDate, window.start, window.end)
        }
        guard totalSeconds > 0 else { return TWResult(value: nil, sampleCount: samples.count) }

        var weightedSum = 0.0
        for s in samples {
            let overlap = overlapDuration(s.startDate, s.endDate, window.start, window.end)
            if overlap <= 0 { continue }
            let val = s.quantity.doubleValue(for: unit)
            weightedSum += val * overlap
        }

        let average = weightedSum / totalSeconds
        return TWResult(value: average, sampleCount: samples.count)
#else
        return TWResult(value: nil, sampleCount: 0)
#endif
    }

    private func discreteAverageInWindow(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async -> Double? {
#if canImport(HealthKit)
        guard let qType = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
        return await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            let query = HKStatisticsQuery(quantityType: qType, quantitySamplePredicate: predicate, options: .discreteAverage) { _, stats, _ in
                let val = stats?.averageQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: val)
            }
            store.execute(query)
        }
#else
        return nil
#endif
    }

    private func overlapDuration(_ aStart: Date, _ aEnd: Date, _ bStart: Date, _ bEnd: Date) -> Double {
        let start = max(aStart, bStart)
        let end = min(aEnd, bEnd)
        return max(0, end.timeIntervalSince(start))
    }

    private func dailyCumulative(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async -> Double? {
#if canImport(HealthKit)
        guard let qType = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
        return await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            let query = HKStatisticsQuery(quantityType: qType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, _ in
                let val = stats?.sumQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: val)
            }
            store.execute(query)
        }
#else
        return nil
#endif
    }

    private func discreteAverage(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async -> Double? {
#if canImport(HealthKit)
        guard let qType = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
        return await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            let query = HKStatisticsQuery(quantityType: qType, quantitySamplePredicate: predicate, options: .discreteAverage) { _, stats, _ in
                let val = stats?.averageQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: val)
            }
            store.execute(query)
        }
#else
        return nil
#endif
    }

    private func discreteMax(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async -> Double? {
#if canImport(HealthKit)
        guard let qType = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
        return await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            let query = HKStatisticsQuery(quantityType: qType, quantitySamplePredicate: predicate, options: .discreteMax) { _, stats, _ in
                let val = stats?.maximumQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: val)
            }
            store.execute(query)
        }
#else
        return nil
#endif
    }

    private func mostRecent(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async -> Double? {
#if canImport(HealthKit)
        guard let qType = HKObjectType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
        let samples: [HKQuantitySample] = await fetchQuantitySamples(type: qType, predicate: predicate)
        guard let latest = samples.sorted(by: { $0.startDate > $1.startDate }).first else { return nil }
        return latest.quantity.doubleValue(for: unit)
#else
        return nil
#endif
    }

    private func mindfulMinutesSum(start: Date, end: Date) async -> Double? {
#if canImport(HealthKit)
        guard let mindfulType = HKObjectType.categoryType(forIdentifier: .mindfulSession) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
        let samples: [HKCategorySample] = await fetchCategorySamples(type: mindfulType, predicate: predicate)
        guard !samples.isEmpty else { return nil }
        let totalSec = samples.reduce(0.0) { acc, s in acc + s.endDate.timeIntervalSince(s.startDate) }
        return totalSec / 60.0
#else
        return nil
#endif
    }

    private func bloodPressureMostRecent(start: Date, end: Date) async -> (Double?, Double?) {
#if canImport(HealthKit)
        guard let sysType = HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic),
              let diaType = HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic) else { return (nil, nil) }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
        let mmHg = HKUnit.millimeterOfMercury()

        let sys: Double? = await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: sysType, predicate: predicate, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                let val = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: mmHg)
                continuation.resume(returning: val)
            }
            store.execute(query)
        }

        let dia: Double? = await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: diaType, predicate: predicate, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                let val = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: mmHg)
                continuation.resume(returning: val)
            }
            store.execute(query)
        }

        return (sys, dia)
#else
        return (nil, nil)
#endif
    }

    private func workouts(start: Date, end: Date) async -> [Workout] {
#if canImport(HealthKit)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
        let workouts: [HKWorkout] = await fetchWorkouts(predicate: predicate)

        var results: [Workout] = []
        for w in workouts {
            let duration = w.endDate.timeIntervalSince(w.startDate) / 60.0
            let (avgHR, maxHR) = await heartRateStats(for: w)
            var totalDistance: Double? = w.totalDistance?.doubleValue(for: .meter())
            var activeKcal: Double? = w.totalEnergyBurned?.doubleValue(for: .kilocalorie())
            if totalDistance == nil {
                totalDistance = await dailyCumulative(.distanceWalkingRunning, unit: .meter(), start: w.startDate, end: w.endDate)
            }
            if activeKcal == nil {
                activeKcal = await dailyCumulative(.activeEnergyBurned, unit: .kilocalorie(), start: w.startDate, end: w.endDate)
            }
            let avgSpeed: Double? = {
                guard let d = totalDistance, duration > 0 else { return nil }
                return (d / (duration * 60.0))
            }()
            let routeSegments = await workoutRouteSegmentCount(for: w)
            let (effort, estEffort) = await workoutEffortScores(for: w)
            let entry = Workout(
                type: workoutDisplayName(w.workoutActivityType),
                start: w.startDate,
                end: w.endDate,
                durationMin: duration,
                averageHeartRate: avgHR,
                maxHeartRate: maxHR,
                totalDistanceMeters: totalDistance,
                activeEnergyKcal: activeKcal,
                avgSpeedMetersPerSec: avgSpeed,
                routeSegments: routeSegments,
                effortScore: effort,
                estimatedEffortScore: estEffort
            )
            results.append(entry)
        }
        return results.sorted { $0.start > $1.start }
#else
        return []
#endif
    }

#if canImport(HealthKit)
    private func heartRateStats(for workout: HKWorkout) async -> (Double?, Double?) {
        guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return (nil, nil) }
        let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [.strictStartDate, .strictEndDate])
        let unit = HKUnit.count().unitDivided(by: .minute())
        return await withCheckedContinuation { (continuation: CheckedContinuation<(Double?, Double?), Never>) in
            let query = HKStatisticsQuery(quantityType: hrType, quantitySamplePredicate: predicate, options: [.discreteAverage, .discreteMax]) { _, stats, _ in
                let avg = stats?.averageQuantity()?.doubleValue(for: unit)
                let max = stats?.maximumQuantity()?.doubleValue(for: unit)
                continuation.resume(returning: (avg, max))
            }
            store.execute(query)
        }
    }

    private func fetchQuantitySamples(type: HKQuantityType, predicate: NSPredicate) async -> [HKQuantitySample] {
        return await withCheckedContinuation { (continuation: CheckedContinuation<[HKQuantitySample], Never>) in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
            }
            store.execute(query)
        }
    }

    private func fetchCategorySamples(type: HKCategoryType, predicate: NSPredicate) async -> [HKCategorySample] {
        return await withCheckedContinuation { (continuation: CheckedContinuation<[HKCategorySample], Never>) in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: samples as? [HKCategorySample] ?? [])
            }
            store.execute(query)
        }
    }

    private func fetchWorkouts(predicate: NSPredicate) async -> [HKWorkout] {
        return await withCheckedContinuation { (continuation: CheckedContinuation<[HKWorkout], Never>) in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: samples as? [HKWorkout] ?? [])
            }
            store.execute(query)
        }
    }

    private func workoutDisplayName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .traditionalStrengthTraining: return "Strength"
        case .highIntensityIntervalTraining: return "HIIT"
        case .yoga: return "Yoga"
        case .pilates: return "Pilates"
        case .tennis: return "Tennis"
        case .paddleSports: return "Paddle"
        case .hiking: return "Hiking"
        case .swimming: return "Swimming"
        default: return String(describing: type)
        }
    }

    private func collectHeartRateSeries(start: Date, end: Date) async -> [HRPoint]? {
        guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
        let samples: [HKQuantitySample] = await fetchQuantitySamples(type: hrType, predicate: predicate)
        guard !samples.isEmpty else { return nil }
        let unit = HKUnit.count().unitDivided(by: .minute())
        return samples.sorted(by: { $0.startDate < $1.startDate }).map { s in
            HRPoint(time: s.startDate, bpm: s.quantity.doubleValue(for: unit))
        }
    }

    private func ecgCount(start: Date, end: Date) async -> Int? {
        if #available(iOS 14.0, *) {
            let ecgType = HKObjectType.electrocardiogramType()
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
            return await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
                let query = HKSampleQuery(sampleType: ecgType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                    continuation.resume(returning: samples?.count)
                }
                store.execute(query)
            }
        } else {
            return nil
        }
    }

    // Compute sleep stage durations (minutes) within the night window
    private func sleepStageDurations(night: NightWindow) async -> (awakeMin: Double?, coreMin: Double?, deepMin: Double?, remMin: Double?, counts: Int) {
#if canImport(HealthKit)
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return (nil, nil, nil, nil, 0) }
        let predicate = HKQuery.predicateForSamples(withStart: night.start, end: night.end, options: [.strictStartDate, .strictEndDate])
        let samples: [HKCategorySample] = await fetchCategorySamples(type: sleepType, predicate: predicate)
        if samples.isEmpty { return (nil, nil, nil, nil, 0) }

        var awakeSec: Double = 0
        var coreSec: Double = 0
        var deepSec: Double = 0
        var remSec: Double = 0
        var count = 0

        for s in samples {
            let overlap = overlapDuration(s.startDate, s.endDate, night.start, night.end)
            if overlap <= 0 { continue }
            count += 1
            if #available(iOS 16.0, *) {
                switch s.value {
                case HKCategoryValueSleepAnalysis.awake.rawValue:
                    awakeSec += overlap
                case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                    coreSec += overlap
                case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                    deepSec += overlap
                case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                    remSec += overlap
                default:
                    break
                }
            } else {
                // Pre-iOS16 has only .asleep and .inBed/.awake categories
                if s.value == HKCategoryValueSleepAnalysis.awake.rawValue {
                    awakeSec += overlap
                }
                // Treat generic asleep as core for reporting purposes
                if s.value == HKCategoryValueSleepAnalysis.asleep.rawValue {
                    coreSec += overlap
                }
            }
        }

        func toMin(_ sec: Double) -> Double? { return sec > 0 ? sec / 60.0 : nil }
        return (toMin(awakeSec), toMin(coreSec), toMin(deepSec), toMin(remSec), count)
#else
        return (nil, nil, nil, nil, 0)
#endif
    }

    private func workoutRouteSegmentCount(for workout: HKWorkout) async -> Int? {
        if #available(iOS 11.0, *) {
            let routeType = HKSeriesType.workoutRoute()
            let predicate = HKQuery.predicateForObjects(from: workout)
            return await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
                let q = HKSampleQuery(sampleType: routeType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                    continuation.resume(returning: samples?.count)
                }
                store.execute(q)
            }
        } else {
            return nil
        }
    }

    private func workoutEffortScores(for workout: HKWorkout) async -> (Double?, Double?) {
        if #available(iOS 18.0, *) {
            let effortType = HKQuantityType.quantityType(forIdentifier: .workoutEffortScore)!
            let estType = HKQuantityType.quantityType(forIdentifier: .estimatedWorkoutEffortScore)!
            let predicate = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: [.strictStartDate, .strictEndDate])
            let unit = HKUnit.count()
            let eff = await discreteAverageWithType(effortType, unit: unit, predicate: predicate)
            let est = await discreteAverageWithType(estType, unit: unit, predicate: predicate)
            return (eff, est)
        } else {
            return (nil, nil)
        }
    }

    private func discreteAverageWithType(_ type: HKQuantityType, unit: HKUnit, predicate: NSPredicate) async -> Double? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            let q = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .discreteAverage) { _, stats, _ in
                continuation.resume(returning: stats?.averageQuantity()?.doubleValue(for: unit))
            }
            store.execute(q)
        }
    }
#endif
}


