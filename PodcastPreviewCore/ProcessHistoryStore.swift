import Foundation

public struct PersistedProcessIdentity: Codable, Hashable, Sendable {
    public let processKey: String
    public let displayName: String
    public let bundleIdentifier: String?

    public init(processKey: String, displayName: String, bundleIdentifier: String?) {
        self.processKey = processKey
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
    }

    public init(displayName: String, bundleIdentifier: String?) {
        self.init(
            processKey: PersistedProcessIdentity.makeKey(bundleIdentifier: bundleIdentifier, name: displayName),
            displayName: displayName,
            bundleIdentifier: bundleIdentifier
        )
    }

    public static func makeKey(bundleIdentifier: String?, name: String) -> String {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier.lowercased()
        }
        return name.lowercased()
    }
}

public struct PersistedProcessObservation: Codable, Equatable, Sendable {
    public let identity: PersistedProcessIdentity
    public let cpuPercent: Double
    public let ramMB: Double
    public let gpuActive: Bool
    public let gpuDeltaTimeNS: UInt64?
    public let avgPowerScore: Double?

    public init(
        identity: PersistedProcessIdentity,
        cpuPercent: Double,
        ramMB: Double,
        gpuActive: Bool,
        gpuDeltaTimeNS: UInt64? = nil,
        avgPowerScore: Double? = nil
    ) {
        self.identity = identity
        self.cpuPercent = cpuPercent
        self.ramMB = ramMB
        self.gpuActive = gpuActive
        self.gpuDeltaTimeNS = gpuDeltaTimeNS
        self.avgPowerScore = avgPowerScore
    }
}

public struct PersistedProcessRollup: Codable, Equatable, Sendable {
    public let identity: PersistedProcessIdentity
    public let observedCount: Int
    public let estimatedObservedSeconds: Int
    public let avgCPUPercent: Double
    public let maxCPUPercent: Double
    public let avgRAMMB: Double
    public let maxRAMMB: Double
    public let gpuActiveRatio: Double
    public let gpuActiveCount: Int
    public let avgGPUTimeNS: UInt64
    public let maxGPUTimeNS: UInt64
    public let avgPowerScore: Double
    public let lastUptimeSeconds: Double?

    public init(
        identity: PersistedProcessIdentity,
        observedCount: Int,
        estimatedObservedSeconds: Int,
        avgCPUPercent: Double,
        maxCPUPercent: Double,
        avgRAMMB: Double,
        maxRAMMB: Double,
        gpuActiveRatio: Double,
        gpuActiveCount: Int,
        avgGPUTimeNS: UInt64 = 0,
        maxGPUTimeNS: UInt64 = 0,
        avgPowerScore: Double,
        lastUptimeSeconds: Double?
    ) {
        self.identity = identity
        self.observedCount = observedCount
        self.estimatedObservedSeconds = estimatedObservedSeconds
        self.avgCPUPercent = avgCPUPercent
        self.maxCPUPercent = maxCPUPercent
        self.avgRAMMB = avgRAMMB
        self.maxRAMMB = maxRAMMB
        self.gpuActiveRatio = gpuActiveRatio
        self.gpuActiveCount = gpuActiveCount
        self.avgGPUTimeNS = avgGPUTimeNS
        self.maxGPUTimeNS = maxGPUTimeNS
        self.avgPowerScore = avgPowerScore
        self.lastUptimeSeconds = lastUptimeSeconds
    }

    public var averageCPUPercent: Double {
        avgCPUPercent
    }

    public var peakCPUPercent: Double {
        maxCPUPercent
    }

    public var averageRAMMB: Double {
        avgRAMMB
    }

    public var peakRAMMB: Double {
        maxRAMMB
    }

    public var averageGPUActiveRatio: Double {
        gpuActiveRatio
    }

    public var averageGPUShareRatio: Double {
        guard observedCount > 0 else { return 0 }
        let averageGPUTime = Double(avgGPUTimeNS)
        return min(max(averageGPUTime / 1_000_000_000.0, 0), 1)
    }

    public var peakGPUShareRatio: Double {
        let peakGPUTime = Double(maxGPUTimeNS)
        return min(max(peakGPUTime / 1_000_000_000.0, 0), 1)
    }

    public var averagePowerScore: Double {
        avgPowerScore
    }

    public var latestUptimeSeconds: Double? {
        lastUptimeSeconds
    }

    public var peakGPUTimeNS: UInt64 {
        maxGPUTimeNS
    }
}

public struct PersistedProcessRollupRecord: Codable, Equatable, Sendable {
    public let bucketStart: Date
    public let bucketDurationSeconds: Int
    public let rollups: [PersistedProcessRollup]

    public init(
        bucketStart: Date,
        bucketDurationSeconds: Int,
        rollups: [PersistedProcessRollup]
    ) {
        self.bucketStart = bucketStart
        self.bucketDurationSeconds = bucketDurationSeconds
        self.rollups = rollups
    }
}

public protocol ProcessHistoryQuerying: Sendable {
    func processTimeline(
        for identity: PersistedProcessIdentity,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> [PersistedProcessRollup]

    func processSummary(
        for identity: PersistedProcessIdentity,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> PersistedProcessRollup?

    func topProcesses(
        in range: DateInterval,
        limit: Int
    ) async -> [PersistedProcessRollup]
}

// MARK: - Backward Compatibility Aliases

public extension ProcessHistoryQuerying {
    // Aliases for consuming code that uses the old API names
    func timeline(
        for identity: PersistedProcessIdentity,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> [PersistedProcessRollup] {
        await processTimeline(for: identity, in: range, bucketIntervalSeconds: bucketIntervalSeconds)
    }

    func summary(
        for identity: PersistedProcessIdentity,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> ProcessHistorySummary {
        let rollup = await processSummary(for: identity, in: range, bucketIntervalSeconds: bucketIntervalSeconds)
            ?? PersistedProcessRollup(
                identity: identity,
                observedCount: 0,
                estimatedObservedSeconds: 0,
                avgCPUPercent: 0,
                maxCPUPercent: 0,
                avgRAMMB: 0,
                maxRAMMB: 0,
                gpuActiveRatio: 0,
                gpuActiveCount: 0,
                avgGPUTimeNS: 0,
                maxGPUTimeNS: 0,
                avgPowerScore: 0,
                lastUptimeSeconds: nil
            )
        return ProcessHistorySummary(range: range, rollup: rollup)
    }
}

#if os(macOS)
import GRDB

public actor ProcessHistoryStore {
    public struct Configuration: Sendable {
        public let retentionDays: Int
        public let sweepIntervalSeconds: TimeInterval

        public init(retentionDays: Int = 30, sweepIntervalSeconds: TimeInterval = 3600) {
            self.retentionDays = max(1, retentionDays)
            self.sweepIntervalSeconds = max(300, sweepIntervalSeconds)
        }
    }

    private let database: HardwareHistoryDatabase
    private let configuration: Configuration
    private let calendar: Calendar
    private var processRollups: [String: ProcessRollupAccumulator] = [:]
    private var lastRetentionSweepDate: Date?
    private var lastBucketStart: Date?

    public init(database: HardwareHistoryDatabase, configuration: Configuration = Configuration()) {
        self.database = database
        self.configuration = configuration

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        self.calendar = calendar
    }

    public func append(
        timestamp: Date,
        apps: [RunningAppsSampler.Row],
        gpuApps: [GPUClientsSampler.GPUClientApp],
        estimatedObservedSeconds: Int = 1
    ) {
        let bucketStart = minuteBucketStart(for: timestamp)

        if let lastBucketStart, lastBucketStart != bucketStart {
            flush()
        }

        self.lastBucketStart = bucketStart

        for app in apps {
            guard let identity = Self.persistedIdentity(for: app) else { continue }
            let key = identity.processKey

            let gpuApp = gpuApps.first(where: { $0.pid == app.pid })
            let observation = PersistedProcessObservation(
                identity: identity,
                cpuPercent: app.cpuPercent,
                ramMB: app.ramMB,
                gpuActive: gpuApp?.isActive ?? false,
                gpuDeltaTimeNS: gpuApp?.gpuDeltaTimeNS,
                avgPowerScore: nil // Calculated later if needed
            )

            var accumulator = processRollups[key] ?? ProcessRollupAccumulator(identity: identity)
            accumulator.ingest(observation, estimatedObservedSeconds: estimatedObservedSeconds)
            processRollups[key] = accumulator
        }

        do {
            try pruneIfNeeded(referenceDate: timestamp)
        } catch {
            logDebugError("ProcessHistoryStore prune failed: \(error)")
        }
    }

    private static func persistedIdentity(for app: RunningAppsSampler.Row) -> PersistedProcessIdentity? {
        let displayName = app.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else { return nil }
        guard !isUnresolvedPIDFallback(displayName, bundleIdentifier: app.bundleIdentifier) else { return nil }

        let key = PersistedProcessIdentity.makeKey(
            bundleIdentifier: app.bundleIdentifier,
            name: displayName
        )
        return PersistedProcessIdentity(
            processKey: key,
            displayName: displayName,
            bundleIdentifier: app.bundleIdentifier
        )
    }

    private static func isUnresolvedPIDFallback(_ displayName: String, bundleIdentifier: String?) -> Bool {
        guard bundleIdentifier == nil else { return false }

        let lowercasedName = displayName.lowercased()
        guard lowercasedName.hasPrefix("pid ") else { return false }
        let suffix = lowercasedName.dropFirst(4)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    public func flush() {
        guard let bucketStart = lastBucketStart, !processRollups.isEmpty else { return }

        let bucketMs = Int64(bucketStart.timeIntervalSince1970 * 1000)
        let rollups = Array(processRollups.values)
        processRollups.removeAll()

        do {
            try database.dbQueue.write { db in
                let stmt = try db.makeStatement(sql: """
                    INSERT OR REPLACE INTO process_rollups
                    (bucket_start_ms, bucket_duration_s, process_key, bundle_identifier, process_name,
                     observed_count, estimated_observed_s,
                     avg_cpu_percent, max_cpu_percent, avg_ram_mb, max_ram_mb,
                     gpu_active_ratio, gpu_active_count, avg_gpu_time_ns, max_gpu_time_ns,
                     avg_power_score, last_uptime_seconds)
                    VALUES (?, 60, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """)

                for accumulator in rollups {
                    let r = accumulator.rollup(estimatedObservedSeconds: 60)
                    try stmt.execute(arguments: [
                        bucketMs,
                        r.identity.processKey,
                        r.identity.bundleIdentifier ?? "",
                        r.identity.displayName,
                        r.observedCount,
                        r.estimatedObservedSeconds,
                        r.avgCPUPercent,
                        r.maxCPUPercent,
                        r.avgRAMMB,
                        r.maxRAMMB,
                        r.gpuActiveRatio,
                        r.gpuActiveCount,
                        r.avgGPUTimeNS,
                        r.maxGPUTimeNS,
                        r.avgPowerScore,
                        r.lastUptimeSeconds
                    ])
                }
            }
        } catch {
            logDebugError("ProcessHistoryStore flush failed: \(error)")
        }
    }

    private func pruneIfNeeded(referenceDate: Date, force: Bool = false) throws {
        if !force,
           let lastRetentionSweepDate,
           referenceDate.timeIntervalSince(lastRetentionSweepDate) < configuration.sweepIntervalSeconds {
            return
        }

        let cutoffDate = calendar.date(
            byAdding: .day,
            value: -(configuration.retentionDays - 1),
            to: dayStart(for: referenceDate)
        ) ?? referenceDate
        let cutoffMs = Int64(cutoffDate.timeIntervalSince1970 * 1000)

        try database.dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM process_rollups WHERE bucket_start_ms < ?",
                arguments: [cutoffMs]
            )
        }
        lastRetentionSweepDate = referenceDate
    }

    private func minuteBucketStart(for timestamp: Date) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: timestamp)
        return calendar.date(from: components) ?? timestamp
    }

    private func dayStart(for timestamp: Date) -> Date {
        let components = calendar.dateComponents([.year, .month, .day], from: timestamp)
        return calendar.date(from: components) ?? timestamp
    }

    private func logDebugError(_ message: String) {
        #if DEBUG
        guard let data = (message + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
        #endif
    }
}

private struct ProcessRollupAccumulator {
    let identity: PersistedProcessIdentity
    var observedCount: Int = 0
    var estimatedObservedSeconds: Int = 0
    var sumCPUPercent: Double = 0
    var maxCPUPercent: Double = 0
    var sumRAMMB: Double = 0
    var maxRAMMB: Double = 0
    var gpuActiveCount: Int = 0
    var sumGPUTimeNS: UInt64 = 0
    var maxGPUTimeNS: UInt64 = 0
    var sumPowerScore: Double = 0
    var lastUptimeSeconds: Double?

    mutating func ingest(_ observation: PersistedProcessObservation, estimatedObservedSeconds: Int) {
        observedCount += 1
        self.estimatedObservedSeconds += estimatedObservedSeconds
        sumCPUPercent += observation.cpuPercent
        maxCPUPercent = max(maxCPUPercent, observation.cpuPercent)
        sumRAMMB += observation.ramMB
        maxRAMMB = max(maxRAMMB, observation.ramMB)
        if observation.gpuActive {
            gpuActiveCount += 1
        }
        if let gpuTime = observation.gpuDeltaTimeNS {
            sumGPUTimeNS += gpuTime
            maxGPUTimeNS = max(maxGPUTimeNS, gpuTime)
        }
        sumPowerScore += observation.avgPowerScore ?? 0
    }

    func rollup(estimatedObservedSeconds: Int) -> PersistedProcessRollup {
        let count = Double(max(1, observedCount))
        return PersistedProcessRollup(
            identity: identity,
            observedCount: observedCount,
            estimatedObservedSeconds: self.estimatedObservedSeconds,
            avgCPUPercent: sumCPUPercent / count,
            maxCPUPercent: maxCPUPercent,
            avgRAMMB: sumRAMMB / count,
            maxRAMMB: maxRAMMB,
            gpuActiveRatio: Double(gpuActiveCount) / count,
            gpuActiveCount: gpuActiveCount,
            avgGPUTimeNS: sumGPUTimeNS / UInt64(count),
            maxGPUTimeNS: maxGPUTimeNS,
            avgPowerScore: sumPowerScore / count,
            lastUptimeSeconds: lastUptimeSeconds
        )
    }
}

public actor ProcessHistoryReader: ProcessHistoryQuerying {
    private let database: HardwareHistoryDatabase

    public init(database: HardwareHistoryDatabase) {
        self.database = database
    }

    public func processTimeline(
        for identity: PersistedProcessIdentity,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> [PersistedProcessRollup] {
        return [] // Stub
    }

    public func processSummary(
        for identity: PersistedProcessIdentity,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> PersistedProcessRollup? {
        return nil // Stub
    }

    public func topProcesses(
        in range: DateInterval,
        limit: Int
    ) async -> [PersistedProcessRollup] {
        return [] // Stub
    }
}
#endif
