//
//  ContentView.swift
//  HealthCheckin
//
//  Created by Joaquin Campo Nario on 7/9/25.
//

import SwiftUI
#if canImport(HealthKit)
import HealthKit
#endif

// MARK: - Domain (minimal JSON v1 skeleton)

struct ReportMeta: Codable {
    let generatedAt: Date
    let timezoneIdentifier: String
    let secondsFromGMT: Int
    let appVersion: String?
}

struct ReportWindows: Codable {
    let nightStart: Date?
    let nightEnd: Date?
    let yesterdayStart: Date
    let todayStart: Date
}

struct Metric: Codable {
    let value: Double?
    let unit: String
    let sampleCount: Int
    let quality: [String]
}

struct ActivityDay: Codable {
    let steps: Int?
    let activeEnergyKcal: Double?
    let distanceWalkingRunningMeters: Double?
    let distanceCyclingMeters: Double?
    let distanceSwimmingMeters: Double?
    let flightsClimbed: Double?
    let basalEnergyKcal: Double?
    let standMinutes: Double?
    let standHours: Int?
    let avgHeartRateBpm: Double?
    let maxHeartRateBpm: Double?
    let vo2Max: Double?
    let exerciseMinutes: Double?
    let workouts: [Workout]
    let heartRateBpm: [HRPoint]?
    let hrZonesSec: [String: Double]?
}

struct Activity: Codable {
    let yesterday: ActivityDay
    let today: ActivityDay
}

struct Workout: Codable {
    let type: String
    let start: Date
    let end: Date
    let durationMin: Double
    let averageHeartRate: Double?
    let maxHeartRate: Double?
    let totalDistanceMeters: Double?
    let activeEnergyKcal: Double?
    let avgSpeedMetersPerSec: Double?
    let routeSegments: Int?
    let effortScore: Double?
    let estimatedEffortScore: Double?
}

struct HealthDay: Codable {
    let mindfulMinutes: Double?
    let dietaryEnergyKcal: Double?
    let dietaryWaterLiters: Double?
    let dietaryCarbohydratesGrams: Double?
    let dietaryProteinGrams: Double?
    let dietaryFatGrams: Double?
    let dietaryCaffeineMg: Double?
    let dietarySodiumMg: Double?
    let dietaryAlcoholGrams: Double?
    let bloodGlucoseMgPerdL: Double?
    let bloodPressureSystolicMmHg: Double?
    let bloodPressureDiastolicMmHg: Double?
    let oxygenSaturationAvgPct: Double?
    let bodyTemperatureC: Double?
    let bodyMassKg: Double?
    let bodyMassIndex: Double?
    let bodyFatPercent: Double?
    let ecgCount: Int?
}

struct Health: Codable {
    let yesterday: HealthDay
    let today: HealthDay
}

struct ReportV1: Codable {
    let meta: ReportMeta
    let windows: ReportWindows
    let readinessSignals: [String: Metric]
    let activity: Activity
    let health: Health
    let flags: [String: Bool]
}

struct HRPoint: Codable {
	let time: Date
	let bpm: Double
}

// MARK: - Storage (simple JSON cache)

final class StorageManager {
    static let shared = StorageManager()
    private init() {}

    private var cacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("healthcheckin_report.json")
    }

    func save(report: ReportV1) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(report)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // Swallow for MVP; surfaced in UI via lastUpdated and JSON text anyway
        }
    }

    func loadPrettyJSON() -> String? {
        do {
            let data = try Data(contentsOf: cacheURL)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

// MARK: - HealthKit Manager (authorization + placeholder)

final class HealthKitManager: ObservableObject {
#if canImport(HealthKit)
    private let store = HKHealthStore()
#endif

    func isHealthDataAvailable() -> Bool {
#if canImport(HealthKit)
        return HKHealthStore.isHealthDataAvailable()
#else
        return false
#endif
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
#if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false)
            return
        }

        var readTypes = Set<HKObjectType>()
        // Readiness
        if let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { readTypes.insert(hrv) }
        if let rhr = HKObjectType.quantityType(forIdentifier: .restingHeartRate) { readTypes.insert(rhr) }
        if let resp = HKObjectType.quantityType(forIdentifier: .respiratoryRate) { readTypes.insert(resp) }
        if #available(iOS 16.0, *), let wristTemp = HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature) { readTypes.insert(wristTemp) }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { readTypes.insert(sleep) }
        // Activity
        if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) { readTypes.insert(steps) }
        if let activeEnergy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { readTypes.insert(activeEnergy) }
        if let distance = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) { readTypes.insert(distance) }
        if let exercise = HKObjectType.quantityType(forIdentifier: .appleExerciseTime) { readTypes.insert(exercise) }
        if let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate) { readTypes.insert(heartRate) }
        if let vo2 = HKObjectType.quantityType(forIdentifier: .vo2Max) { readTypes.insert(vo2) }
        // Additional activity metrics
        if let basalEnergy = HKObjectType.quantityType(forIdentifier: .basalEnergyBurned) { readTypes.insert(basalEnergy) }
        if let distanceCycling = HKObjectType.quantityType(forIdentifier: .distanceCycling) { readTypes.insert(distanceCycling) }
        if let distanceSwimming = HKObjectType.quantityType(forIdentifier: .distanceSwimming) { readTypes.insert(distanceSwimming) }
        if let flights = HKObjectType.quantityType(forIdentifier: .flightsClimbed) { readTypes.insert(flights) }
        if let standTime = HKObjectType.quantityType(forIdentifier: .appleStandTime) { readTypes.insert(standTime) }
        // Health insights
        if let mindful = HKObjectType.categoryType(forIdentifier: .mindfulSession) { readTypes.insert(mindful) }
        if let dietaryEnergy = HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed) { readTypes.insert(dietaryEnergy) }
        if let water = HKObjectType.quantityType(forIdentifier: .dietaryWater) { readTypes.insert(water) }
        if let carbs = HKObjectType.quantityType(forIdentifier: .dietaryCarbohydrates) { readTypes.insert(carbs) }
        if let protein = HKObjectType.quantityType(forIdentifier: .dietaryProtein) { readTypes.insert(protein) }
        if let fat = HKObjectType.quantityType(forIdentifier: .dietaryFatTotal) { readTypes.insert(fat) }
        if let caffeine = HKObjectType.quantityType(forIdentifier: .dietaryCaffeine) { readTypes.insert(caffeine) }
        if let sodium = HKObjectType.quantityType(forIdentifier: .dietarySodium) { readTypes.insert(sodium) }
        if let glucose = HKObjectType.quantityType(forIdentifier: .bloodGlucose) { readTypes.insert(glucose) }
        if let oxy = HKObjectType.quantityType(forIdentifier: .oxygenSaturation) { readTypes.insert(oxy) }
        if let bodyTemp = HKObjectType.quantityType(forIdentifier: .bodyTemperature) { readTypes.insert(bodyTemp) }
        if let sys = HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic) { readTypes.insert(sys) }
        if let dia = HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic) { readTypes.insert(dia) }
        if let bodyMass = HKObjectType.quantityType(forIdentifier: .bodyMass) { readTypes.insert(bodyMass) }
        if let bmi = HKObjectType.quantityType(forIdentifier: .bodyMassIndex) { readTypes.insert(bmi) }
        if let bodyFat = HKObjectType.quantityType(forIdentifier: .bodyFatPercentage) { readTypes.insert(bodyFat) }
        // ECG & mobility
        if #available(iOS 14.0, *) { readTypes.insert(HKObjectType.electrocardiogramType()) }
        if let walkingSpeed = HKObjectType.quantityType(forIdentifier: .walkingSpeed) { readTypes.insert(walkingSpeed) }
        if let stepLength = HKObjectType.quantityType(forIdentifier: .walkingStepLength) { readTypes.insert(stepLength) }
        if let doubleSupport = HKObjectType.quantityType(forIdentifier: .walkingDoubleSupportPercentage) { readTypes.insert(doubleSupport) }
        if let asymmetry = HKObjectType.quantityType(forIdentifier: .walkingAsymmetryPercentage) { readTypes.insert(asymmetry) }
        if let steadiness = HKObjectType.quantityType(forIdentifier: .appleWalkingSteadiness) { readTypes.insert(steadiness) }
        // Effort scores (iOS 18+)
        if #available(iOS 18.0, *), let effort = HKObjectType.quantityType(forIdentifier: .workoutEffortScore) { readTypes.insert(effort) }
        if #available(iOS 18.0, *), let estEffort = HKObjectType.quantityType(forIdentifier: .estimatedWorkoutEffortScore) { readTypes.insert(estEffort) }
        // Workout routes
        if #available(iOS 11.0, *) { readTypes.insert(HKSeriesType.workoutRoute()) }
        readTypes.insert(HKObjectType.workoutType())

        store.requestAuthorization(toShare: nil, read: readTypes) { success, _ in
            DispatchQueue.main.async {
                completion(success)
            }
        }
#else
        completion(false)
#endif
    }
}

// MARK: - ViewModel

@MainActor
final class HealthViewModel: ObservableObject {
    @Published var jsonText: String = "" // pretty-printed JSON
    @Published var isLoading: Bool = false
    @Published var lastUpdated: Date? = nil
    @Published var permissionsRequested: Bool = false
    @Published var healthDataAvailable: Bool = false

    private let healthKitManager = HealthKitManager()
    private let dataService = HealthDataService()

    init() {
        self.healthDataAvailable = healthKitManager.isHealthDataAvailable()
        if let cached = StorageManager.shared.loadPrettyJSON() {
            self.jsonText = cached
        } else {
            self.jsonText = Self.emptyPrettyJSON()
        }
    }

    func requestPermissions() {
        healthKitManager.requestAuthorization { [weak self] _ in
            guard let self else { return }
            self.permissionsRequested = true
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let report = await dataService.buildReport()
        StorageManager.shared.save(report: report)
        self.lastUpdated = report.meta.generatedAt
        if let cached = StorageManager.shared.loadPrettyJSON() {
            self.jsonText = cached
        }
    }

    private static func buildPlaceholderReport() -> ReportV1 {
        let tz = TimeZone.current
        let seconds = tz.secondsFromGMT()
        let now = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart

        let meta = ReportMeta(
            generatedAt: now,
            timezoneIdentifier: tz.identifier,
            secondsFromGMT: seconds,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )

        let windows = ReportWindows(
            nightStart: nil,
            nightEnd: nil,
            yesterdayStart: yesterdayStart,
            todayStart: todayStart
        )

        let readiness: [String: Metric] = [
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

        let emptyDay = ActivityDay(
            steps: nil,
            activeEnergyKcal: nil,
            distanceWalkingRunningMeters: nil,
            distanceCyclingMeters: nil,
            distanceSwimmingMeters: nil,
            flightsClimbed: nil,
            basalEnergyKcal: nil,
            standMinutes: nil,
            standHours: nil,
            avgHeartRateBpm: nil,
            maxHeartRateBpm: nil,
            vo2Max: nil,
            exerciseMinutes: nil,
            workouts: [],
            heartRateBpm: nil,
            hrZonesSec: nil
        )
        let activity = Activity(yesterday: emptyDay, today: emptyDay)
        let emptyHealthDay = HealthDay(
            mindfulMinutes: nil,
            dietaryEnergyKcal: nil,
            dietaryWaterLiters: nil,
            dietaryCarbohydratesGrams: nil,
            dietaryProteinGrams: nil,
            dietaryFatGrams: nil,
            dietaryCaffeineMg: nil,
            dietarySodiumMg: nil,
            dietaryAlcoholGrams: nil,
            bloodGlucoseMgPerdL: nil,
            bloodPressureSystolicMmHg: nil,
            bloodPressureDiastolicMmHg: nil,
            oxygenSaturationAvgPct: nil,
            bodyTemperatureC: nil,
            bodyMassKg: nil,
            bodyMassIndex: nil,
            bodyFatPercent: nil,
            ecgCount: nil
        )
        let health = Health(yesterday: emptyHealthDay, today: emptyHealthDay)

        let flags: [String: Bool] = [
            "permissions_partial": false,
            "skeleton_data": true
        ]

        return ReportV1(meta: meta, windows: windows, readinessSignals: readiness, activity: activity, health: health, flags: flags)
    }

    private static func emptyPrettyJSON() -> String {
        let placeholder = buildPlaceholderReport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(placeholder)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{}"
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = HealthViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                statusRow
                actionRow
                jsonViewer
            }
            .padding()
            .navigationTitle("HealthCheckin")
        }
        .onAppear {
            if !viewModel.permissionsRequested {
                viewModel.requestPermissions()
            }
        }
    }

    private var statusRow: some View {
        HStack {
            let updated = viewModel.lastUpdated
            Text("Last updated: \(updated.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "—")")
                .font(.subheadline)
            Spacer()
            Group {
                pill(text: viewModel.healthDataAvailable ? "HealthKit" : "No HealthKit", ok: viewModel.healthDataAvailable)
                pill(text: viewModel.permissionsRequested ? "Permissions" : "Request", ok: viewModel.permissionsRequested)
            }
        }
    }

    private func pill(text: String, ok: Bool) -> some View {
        Text(text)
            .font(.caption)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(ok ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
            .foregroundStyle(ok ? .green : .orange)
            .clipShape(Capsule())
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button(action: { Task { await viewModel.refresh() } }) {
                if viewModel.isLoading {
                    ProgressView().progressViewStyle(.circular)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }

            Button(action: copyJSON) {
                Label("Copy JSON", systemImage: "doc.on.doc")
            }

            ShareLink(item: viewModel.jsonText, preview: SharePreview("HealthCheckin.json")) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var jsonViewer: some View {
        ScrollView {
            Text(viewModel.jsonText)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .background(Color(UIColor.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func copyJSON() {
        #if canImport(UIKit)
        UIPasteboard.general.string = viewModel.jsonText
        #endif
    }
}

#Preview {
    ContentView()
}
