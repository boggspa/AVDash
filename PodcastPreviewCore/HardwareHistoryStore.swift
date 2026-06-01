import Foundation

public struct PersistedHardwareDimensionValue: Codable, Equatable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct PersistedHardwareMetricRollup: Codable, Equatable, Sendable {
    public let key: String
    public let observedCount: Int
    public let minValue: Double
    public let maxValue: Double
    public let averageValue: Double
    public let lastValue: Double

    public init(
        key: String,
        observedCount: Int,
        minValue: Double,
        maxValue: Double,
        averageValue: Double,
        lastValue: Double
    ) {
        self.key = key
        self.observedCount = observedCount
        self.minValue = minValue
        self.maxValue = maxValue
        self.averageValue = averageValue
        self.lastValue = lastValue
    }
}

public struct PersistedHardwareDeviceRollupRecord: Codable, Equatable, Sendable {
    public let deviceID: String
    public let deviceKind: String
    public let metrics: [PersistedHardwareMetricRollup]
    public let dimensions: [PersistedHardwareDimensionValue]

    public init(
        deviceID: String,
        deviceKind: String,
        metrics: [PersistedHardwareMetricRollup],
        dimensions: [PersistedHardwareDimensionValue]
    ) {
        self.deviceID = deviceID
        self.deviceKind = deviceKind
        self.metrics = metrics
        self.dimensions = dimensions
    }
}

public struct PersistedHardwareRollupRecord: Codable, Equatable, Sendable {
    public let bucketStart: Date
    public let bucketDurationSeconds: Int
    public let observedFrameCount: Int
    public let estimatedObservedSeconds: Int
    public let metrics: [PersistedHardwareMetricRollup]
    public let dimensions: [PersistedHardwareDimensionValue]
    public let deviceRollups: [PersistedHardwareDeviceRollupRecord]

    public init(
        bucketStart: Date,
        bucketDurationSeconds: Int,
        observedFrameCount: Int,
        estimatedObservedSeconds: Int,
        metrics: [PersistedHardwareMetricRollup],
        dimensions: [PersistedHardwareDimensionValue],
        deviceRollups: [PersistedHardwareDeviceRollupRecord]
    ) {
        self.bucketStart = bucketStart
        self.bucketDurationSeconds = bucketDurationSeconds
        self.observedFrameCount = observedFrameCount
        self.estimatedObservedSeconds = estimatedObservedSeconds
        self.metrics = metrics
        self.dimensions = dimensions
        self.deviceRollups = deviceRollups
    }

    private enum CodingKeys: String, CodingKey {
        case bucketStart
        case bucketDurationSeconds
        case observedFrameCount
        case estimatedObservedSeconds
        case metrics
        case dimensions
        case deviceRollups
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bucketStart = try container.decode(Date.self, forKey: .bucketStart)
        let bucketDurationSeconds = try container.decode(Int.self, forKey: .bucketDurationSeconds)
        let observedFrameCount = try container.decode(Int.self, forKey: .observedFrameCount)
        let estimatedObservedSeconds = try container.decodeIfPresent(Int.self, forKey: .estimatedObservedSeconds)
            ?? min(bucketDurationSeconds, observedFrameCount)
        let metrics = try container.decode([PersistedHardwareMetricRollup].self, forKey: .metrics)
        let dimensions = try container.decode([PersistedHardwareDimensionValue].self, forKey: .dimensions)
        let deviceRollups = try container.decode([PersistedHardwareDeviceRollupRecord].self, forKey: .deviceRollups)

        self.init(
            bucketStart: bucketStart,
            bucketDurationSeconds: bucketDurationSeconds,
            observedFrameCount: observedFrameCount,
            estimatedObservedSeconds: estimatedObservedSeconds,
            metrics: metrics,
            dimensions: dimensions,
            deviceRollups: deviceRollups
        )
    }
}

public typealias PersistedHardwareMinuteRollupRecord = PersistedHardwareRollupRecord
public typealias PersistedHardwareHourlyRollupRecord = PersistedHardwareRollupRecord

#if os(macOS)
import GRDB

public actor HardwareHistoryStore {
    public struct Configuration: Sendable {
        public struct RetentionPolicy: Sendable {
            public let minuteRollupDays: Int
            public let hourlyRollupDays: Int
            public let sweepIntervalSeconds: TimeInterval

            public init(
                minuteRollupDays: Int = 30,
                hourlyRollupDays: Int = 365,
                sweepIntervalSeconds: TimeInterval = 3600
            ) {
                self.minuteRollupDays = max(1, minuteRollupDays)
                self.hourlyRollupDays = max(1, hourlyRollupDays)
                self.sweepIntervalSeconds = max(300, sweepIntervalSeconds)
            }
        }

        public let retentionPolicy: RetentionPolicy

        public init(retentionPolicy: RetentionPolicy = RetentionPolicy()) {
            self.retentionPolicy = retentionPolicy
        }
    }

    private let database: HardwareHistoryDatabase
    private let configuration: Configuration
    private let calendar: Calendar
    private var activeMinuteRollup: TimeRollupAccumulator?
    private var activeHourlyRollup: TimeRollupAccumulator?
    private var lastPersistedActiveHourlyRollupDate: Date?
    private var lastPersistedFrameTimestamp: Date?
    private var lastRetentionSweepDate: Date?
    private static let activeHourlyRollupPersistenceInterval: TimeInterval = 60

    public init(database: HardwareHistoryDatabase, configuration: Configuration = Configuration()) {
        self.database = database
        self.configuration = configuration

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        self.calendar = calendar

        let referenceDate = Date()
        do {
            self.activeMinuteRollup = try Self.loadAccumulator(
                database: database,
                bucketStart: Self.bucketStart(
                    for: referenceDate,
                    bucketDurationSeconds: 60,
                    calendar: calendar
                ),
                bucketDurationSeconds: 60
            )
            self.activeHourlyRollup = try Self.loadAccumulator(
                database: database,
                bucketStart: Self.bucketStart(
                    for: referenceDate,
                    bucketDurationSeconds: 3600,
                    calendar: calendar
                ),
                bucketDurationSeconds: 3600
            )
        } catch {
            Self.logDebugError("HardwareHistoryStore restore failed: \(error)")
        }
    }

    public func append(_ frame: HardwareTelemetryFrame, estimatedObservedSeconds: Int = 1) {
        guard !frame.isEmpty else { return }

        // Deduplicate: ignore frames that are out-of-order or exact repeats.
        if let lastPersistedFrameTimestamp, frame.timestamp <= lastPersistedFrameTimestamp {
            return
        }

        do {
            try ingest(frame, estimatedObservedSeconds: estimatedObservedSeconds)
            try persistActiveRollups(referenceDate: frame.timestamp)
            try pruneIfNeeded(referenceDate: frame.timestamp)
            lastPersistedFrameTimestamp = frame.timestamp
        } catch {
            Self.logDebugError("HardwareHistoryStore append failed: \(error)")
        }
    }

    public func flush() {
        do {
            try flushActiveMinuteRollup()
            try flushActiveHourlyRollup()
            try pruneIfNeeded(referenceDate: Date(), force: true)
        } catch {
            Self.logDebugError("HardwareHistoryStore flush failed: \(error)")
        }
    }

    private func ingest(_ frame: HardwareTelemetryFrame, estimatedObservedSeconds: Int) throws {
        let minuteBucketStart = minuteBucketStart(for: frame.timestamp)
        let hourlyBucketStart = hourlyBucketStart(for: frame.timestamp)

        if let activeMinuteRollup, activeMinuteRollup.bucketStart != minuteBucketStart {
            try flushActiveMinuteRollup()
        }
        if activeMinuteRollup == nil {
            activeMinuteRollup = TimeRollupAccumulator(bucketStart: minuteBucketStart, bucketDurationSeconds: 60)
        }

        if let activeHourlyRollup, activeHourlyRollup.bucketStart != hourlyBucketStart {
            try flushActiveHourlyRollup()
        }
        if activeHourlyRollup == nil {
            activeHourlyRollup = TimeRollupAccumulator(bucketStart: hourlyBucketStart, bucketDurationSeconds: 3600)
        }

        activeMinuteRollup?.ingest(frame, estimatedObservedSeconds: estimatedObservedSeconds)
        activeHourlyRollup?.ingest(frame, estimatedObservedSeconds: estimatedObservedSeconds)
    }

    private func flushActiveMinuteRollup() throws {
        guard let accumulator = activeMinuteRollup else { return }
        try flushAccumulator(accumulator)
        activeMinuteRollup = nil
    }

    private func flushActiveHourlyRollup() throws {
        guard let accumulator = activeHourlyRollup else { return }
        try flushAccumulator(accumulator)
        activeHourlyRollup = nil
        lastPersistedActiveHourlyRollupDate = nil
    }

    private func persistActiveRollups(referenceDate: Date) throws {
        if let activeMinuteRollup {
            try flushAccumulator(activeMinuteRollup)
        }
        guard shouldPersistActiveHourlyRollup(at: referenceDate),
              let activeHourlyRollup else {
            return
        }

        try flushAccumulator(activeHourlyRollup)
        lastPersistedActiveHourlyRollupDate = referenceDate
    }

    private func shouldPersistActiveHourlyRollup(at date: Date) -> Bool {
        guard activeHourlyRollup != nil else { return false }
        guard let lastPersistedActiveHourlyRollupDate else { return true }
        return date.timeIntervalSince(lastPersistedActiveHourlyRollupDate) >= Self.activeHourlyRollupPersistenceInterval
    }

    private func flushAccumulator(_ accumulator: TimeRollupAccumulator) throws {
        let bucketMs = Int64(accumulator.bucketStart.timeIntervalSince1970 * 1000)
        let bucketDurationS = accumulator.bucketDurationSeconds
        let frameCount = accumulator.observedFrameCount
        let clampedEstimatedS = min(bucketDurationS, accumulator.estimatedObservedSeconds)

        try database.dbQueue.write { db in
            let metricStmt = try db.makeStatement(sql: """
                INSERT OR REPLACE INTO metric_rollups
                (bucket_start_ms, bucket_duration_s, metric_key, device_id, device_kind,
                 observed_count, frame_count, estimated_observed_s,
                 min_value, max_value, avg_value, last_value)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)

            let dimStmt = try db.makeStatement(sql: """
                INSERT OR REPLACE INTO dimension_snapshots
                (bucket_start_ms, bucket_duration_s, dimension_key, device_id, device_kind, dimension_value)
                VALUES (?, ?, ?, ?, ?, ?)
                """)

            // Global metrics
            for (key, m) in accumulator.metrics {
                try metricStmt.execute(arguments: [
                    bucketMs, bucketDurationS, key, "", "",
                    m.observedCount, frameCount, clampedEstimatedS,
                    m.minValue, m.maxValue,
                    m.observedCount > 0 ? m.sum / Double(m.observedCount) : 0,
                    m.lastValue
                ])
            }

            // Global dimensions
            for (key, value) in accumulator.dimensions {
                try dimStmt.execute(arguments: [
                    bucketMs, bucketDurationS, key, "", "", value
                ])
            }

            // Device metrics + dimensions
            for (_, dev) in accumulator.deviceRollups {
                for (metricKey, m) in dev.metrics {
                    try metricStmt.execute(arguments: [
                        bucketMs, bucketDurationS, metricKey,
                        dev.deviceID, dev.deviceKind,
                        m.observedCount, frameCount, clampedEstimatedS,
                        m.minValue, m.maxValue,
                        m.observedCount > 0 ? m.sum / Double(m.observedCount) : 0,
                        m.lastValue
                    ])
                }
                for (dimKey, dimValue) in dev.dimensions {
                    try dimStmt.execute(arguments: [
                        bucketMs, bucketDurationS, dimKey,
                        dev.deviceID, dev.deviceKind, dimValue
                    ])
                }
            }
        }
    }

    private func pruneIfNeeded(referenceDate: Date, force: Bool = false) throws {
        if !force,
           let lastRetentionSweepDate,
           referenceDate.timeIntervalSince(lastRetentionSweepDate) < configuration.retentionPolicy.sweepIntervalSeconds {
            return
        }

        let policy = configuration.retentionPolicy
        let minuteCutoff = cutoffMs(days: policy.minuteRollupDays, referenceDate: referenceDate)
        let hourlyCutoff = cutoffMs(days: policy.hourlyRollupDays, referenceDate: referenceDate)

        try database.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM metric_rollups WHERE bucket_duration_s = 60 AND bucket_start_ms < ?",
                           arguments: [minuteCutoff])
            try db.execute(sql: "DELETE FROM metric_rollups WHERE bucket_duration_s = 3600 AND bucket_start_ms < ?",
                           arguments: [hourlyCutoff])
            try db.execute(sql: "DELETE FROM dimension_snapshots WHERE bucket_duration_s = 60 AND bucket_start_ms < ?",
                           arguments: [minuteCutoff])
            try db.execute(sql: "DELETE FROM dimension_snapshots WHERE bucket_duration_s = 3600 AND bucket_start_ms < ?",
                           arguments: [hourlyCutoff])
        }

        lastRetentionSweepDate = referenceDate
    }

    private func cutoffMs(days: Int, referenceDate: Date) -> Int64 {
        let cutoffDate = calendar.date(
            byAdding: .day,
            value: -(max(1, days) - 1),
            to: dayStart(for: referenceDate)
        ) ?? dayStart(for: referenceDate)
        return Int64(cutoffDate.timeIntervalSince1970 * 1000)
    }

    private func minuteBucketStart(for timestamp: Date) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: timestamp)
        return calendar.date(from: components) ?? timestamp
    }

    private func hourlyBucketStart(for timestamp: Date) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: timestamp)
        return calendar.date(from: components) ?? timestamp
    }

    private func dayStart(for timestamp: Date) -> Date {
        let components = calendar.dateComponents([.year, .month, .day], from: timestamp)
        return calendar.date(from: components) ?? timestamp
    }

    private static func loadAccumulator(
        database: HardwareHistoryDatabase,
        bucketStart: Date,
        bucketDurationSeconds: Int
    ) throws -> TimeRollupAccumulator? {
        let bucketMs = Int64(bucketStart.timeIntervalSince1970 * 1000)

        let result = try database.dbQueue.read { db in
            let metricRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT bucket_start_ms, bucket_duration_s, metric_key, device_id, device_kind,
                           observed_count, frame_count, estimated_observed_s,
                           min_value, max_value, avg_value, last_value
                    FROM metric_rollups
                    WHERE bucket_start_ms = ?
                      AND bucket_duration_s = ?
                    """,
                arguments: [bucketMs, bucketDurationSeconds]
            )
            let dimensionRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT dimension_key, device_id, device_kind, dimension_value
                    FROM dimension_snapshots
                    WHERE bucket_start_ms = ?
                      AND bucket_duration_s = ?
                    """,
                arguments: [bucketMs, bucketDurationSeconds]
            )
            return (metricRows, dimensionRows)
        }

        let metricRows = result.0
        let dimensionRows = result.1
        guard !(metricRows.isEmpty && dimensionRows.isEmpty) else {
            return nil
        }

        var accumulator = TimeRollupAccumulator(
            bucketStart: bucketStart,
            bucketDurationSeconds: bucketDurationSeconds
        )
        accumulator.observedFrameCount = metricRows.compactMap { row in
            row["frame_count"] as Int?
        }.max() ?? 0
        accumulator.estimatedObservedSeconds = metricRows.compactMap { row in
            row["estimated_observed_s"] as Int?
        }.max() ?? 0

        for row in metricRows {
            let metricKey: String = row["metric_key"]
            let deviceID: String = row["device_id"]
            let deviceKind: String = row["device_kind"]

            if deviceID.isEmpty && deviceKind.isEmpty {
                accumulator.metrics[metricKey] = metricAccumulator(from: row)
                continue
            }

            let deviceRollupKey = "\(deviceKind):\(deviceID)"
            var deviceAccumulator = accumulator.deviceRollups[deviceRollupKey]
                ?? DeviceRollupAccumulator(deviceID: deviceID, deviceKind: deviceKind)
            deviceAccumulator.metrics[metricKey] = metricAccumulator(from: row)
            accumulator.deviceRollups[deviceRollupKey] = deviceAccumulator
        }

        for row in dimensionRows {
            let dimensionKey: String = row["dimension_key"]
            let deviceID: String = row["device_id"]
            let deviceKind: String = row["device_kind"]
            let dimensionValue: String = row["dimension_value"]

            if deviceID.isEmpty && deviceKind.isEmpty {
                accumulator.dimensions[dimensionKey] = dimensionValue
                continue
            }

            let deviceRollupKey = "\(deviceKind):\(deviceID)"
            var deviceAccumulator = accumulator.deviceRollups[deviceRollupKey]
                ?? DeviceRollupAccumulator(deviceID: deviceID, deviceKind: deviceKind)
            deviceAccumulator.dimensions[dimensionKey] = dimensionValue
            accumulator.deviceRollups[deviceRollupKey] = deviceAccumulator
        }

        return accumulator
    }

    private static func metricAccumulator(from row: Row) -> MetricRollupAccumulator {
        let observedCount = max(0, (row["observed_count"] as Int?) ?? 0)
        let averageValue = (row["avg_value"] as Double?) ?? 0
        return MetricRollupAccumulator(
            observedCount: observedCount,
            sum: averageValue * Double(observedCount),
            minValue: (row["min_value"] as Double?) ?? 0,
            maxValue: (row["max_value"] as Double?) ?? 0,
            lastValue: (row["last_value"] as Double?) ?? 0
        )
    }

    private static func bucketStart(
        for timestamp: Date,
        bucketDurationSeconds: Int,
        calendar: Calendar
    ) -> Date {
        let components: Set<Calendar.Component>
        if bucketDurationSeconds >= 3600 {
            components = [.year, .month, .day, .hour]
        } else {
            components = [.year, .month, .day, .hour, .minute]
        }
        return calendar.date(from: calendar.dateComponents(components, from: timestamp)) ?? timestamp
    }

    private static func logDebugError(_ message: String) {
        #if DEBUG
        guard let data = (message + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
        #endif
    }
}

private struct MetricRollupAccumulator: Sendable {
    var observedCount: Int = 0
    var sum: Double = 0
    var minValue: Double = 0
    var maxValue: Double = 0
    var lastValue: Double = 0

    mutating func ingest(_ value: Double) {
        observedCount += 1
        sum += value
        lastValue = value

        if observedCount == 1 {
            minValue = value
            maxValue = value
        } else {
            minValue = min(minValue, value)
            maxValue = max(maxValue, value)
        }
    }
}

private struct DeviceRollupAccumulator: Sendable {
    let deviceID: String
    let deviceKind: String
    var metrics: [String: MetricRollupAccumulator] = [:]
    var dimensions: [String: String] = [:]

    mutating func ingest(_ snapshot: HardwareDeviceSnapshot) {
        for (key, value) in snapshot.numericMetrics {
            var accumulator = metrics[key.rawValue] ?? MetricRollupAccumulator()
            accumulator.ingest(value)
            metrics[key.rawValue] = accumulator
        }

        for (key, value) in snapshot.dimensions {
            dimensions[key.rawValue] = value
        }
    }
}

private struct TimeRollupAccumulator: Sendable {
    let bucketStart: Date
    let bucketDurationSeconds: Int
    var observedFrameCount: Int = 0
    var estimatedObservedSeconds: Int = 0
    var metrics: [String: MetricRollupAccumulator] = [:]
    var dimensions: [String: String] = [:]
    var deviceRollups: [String: DeviceRollupAccumulator] = [:]

    mutating func ingest(_ frame: HardwareTelemetryFrame, estimatedObservedSeconds: Int) {
        observedFrameCount += 1
        self.estimatedObservedSeconds += max(0, estimatedObservedSeconds)

        if let snapshot = frame.snapshot {
            for (key, value) in snapshot.numericMetrics {
                var accumulator = metrics[key.rawValue] ?? MetricRollupAccumulator()
                accumulator.ingest(value)
                metrics[key.rawValue] = accumulator
            }

            for (key, value) in snapshot.dimensions {
                dimensions[key.rawValue] = value
            }
        }

        for deviceSnapshot in frame.deviceSnapshots {
            let deviceRollupKey = "\(deviceSnapshot.deviceKind.rawValue):\(deviceSnapshot.deviceID)"
            var deviceAccumulator = deviceRollups[deviceRollupKey]
                ?? DeviceRollupAccumulator(
                    deviceID: deviceSnapshot.deviceID,
                    deviceKind: deviceSnapshot.deviceKind.rawValue
                )
            deviceAccumulator.ingest(deviceSnapshot)
            deviceRollups[deviceRollupKey] = deviceAccumulator
        }
    }
}
#endif
