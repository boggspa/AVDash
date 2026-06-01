import Foundation
#if os(macOS)
import GRDB
import os.log
#endif

public struct HardwareHistoryMetricBucket: Codable, Equatable, Sendable {
    public let bucketStart: Date
    public let bucketDurationSeconds: Int
    public let observedRollupCount: Int
    public let observedSampleCount: Int
    public let estimatedObservedSeconds: Int
    public let minValue: Double?
    public let maxValue: Double?
    public let averageValue: Double?
    public let lastValue: Double?

    public init(
        bucketStart: Date,
        bucketDurationSeconds: Int,
        observedRollupCount: Int,
        observedSampleCount: Int,
        estimatedObservedSeconds: Int,
        minValue: Double?,
        maxValue: Double?,
        averageValue: Double?,
        lastValue: Double?
    ) {
        self.bucketStart = bucketStart
        self.bucketDurationSeconds = bucketDurationSeconds
        self.observedRollupCount = observedRollupCount
        self.observedSampleCount = observedSampleCount
        self.estimatedObservedSeconds = estimatedObservedSeconds
        self.minValue = minValue
        self.maxValue = maxValue
        self.averageValue = averageValue
        self.lastValue = lastValue
    }

    public var coverageRatio: Double {
        guard bucketDurationSeconds > 0 else { return 0 }
        return min(1.0, Double(estimatedObservedSeconds) / Double(bucketDurationSeconds))
    }
}

public struct HardwareHistoryMetricSummary: Codable, Equatable, Sendable {
    public let range: DateInterval
    public let bucketIntervalSeconds: Int
    public let observedBucketCount: Int
    public let observedSampleCount: Int
    public let estimatedObservedSeconds: Int
    public let minValue: Double?
    public let maxValue: Double?
    public let averageValue: Double?
    public let lastValue: Double?
    public let peakValue: Double?
    public let peakBucketStart: Date?

    public init(
        range: DateInterval,
        bucketIntervalSeconds: Int,
        observedBucketCount: Int,
        observedSampleCount: Int,
        estimatedObservedSeconds: Int,
        minValue: Double?,
        maxValue: Double?,
        averageValue: Double?,
        lastValue: Double?,
        peakValue: Double?,
        peakBucketStart: Date?
    ) {
        self.range = range
        self.bucketIntervalSeconds = bucketIntervalSeconds
        self.observedBucketCount = observedBucketCount
        self.observedSampleCount = observedSampleCount
        self.estimatedObservedSeconds = estimatedObservedSeconds
        self.minValue = minValue
        self.maxValue = maxValue
        self.averageValue = averageValue
        self.lastValue = lastValue
        self.peakValue = peakValue
        self.peakBucketStart = peakBucketStart
    }

    public var coverageRatio: Double {
        guard bucketIntervalSeconds > 0 else { return 0 }
        return min(1.0, Double(estimatedObservedSeconds) / range.duration)
    }

    public var average: Double { averageValue ?? 0 }
    public var peak: Double { peakValue ?? maxValue ?? 0 }
    public var minimum: Double { minValue ?? 0 }
}

public struct HardwareHistoryDeviceIdentity: Codable, Equatable, Identifiable, Sendable {
    public let deviceKey: String
    public let deviceName: String
    public let deviceType: String

    public init(deviceKey: String, deviceName: String, deviceType: String) {
        self.deviceKey = deviceKey
        self.deviceName = deviceName
        self.deviceType = deviceType
    }

    public var id: String { deviceKey }
}

#if os(macOS)
public actor HardwareHistoryReader: HardwareHistoryQuerying {
    private static let logger = Logger(
        subsystem: "com.chrisizatt.PodcastPreview",
        category: "HardwareHistoryReader"
    )

    private struct StoredRollup: Sendable {
        let bucketStart: Date
        let bucketDurationSeconds: Int
        let observedCount: Int
        let frameCount: Int
        let estimatedObservedSeconds: Int
        let minValue: Double
        let maxValue: Double
        let averageValue: Double
        let lastValue: Double
        let deviceID: String
        let deviceKind: String
    }

    private let database: HardwareHistoryDatabase

    public init(database: HardwareHistoryDatabase) {
        self.database = database
    }

    public func metricTimeline(
        for key: HardwareMetricKey,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> [HardwareHistoryMetricBucket] {
        await timeline(
            metricKey: key.rawValue,
            deviceID: "",
            deviceKind: "",
            in: range,
            bucketIntervalSeconds: bucketIntervalSeconds
        )
    }

    public func metricSummary(
        for key: HardwareMetricKey,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> HardwareHistoryMetricSummary {
        let timeline = await metricTimeline(
            for: key,
            in: range,
            bucketIntervalSeconds: bucketIntervalSeconds
        )
        return summarizeTimeline(
            timeline,
            in: range,
            bucketIntervalSeconds: max(60, bucketIntervalSeconds)
        )
    }

    public func deviceMetricTimeline(
        for key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> [HardwareHistoryMetricBucket] {
        await timeline(
            metricKey: key.rawValue,
            deviceID: deviceID,
            deviceKind: deviceKind.rawValue,
            in: range,
            bucketIntervalSeconds: bucketIntervalSeconds
        )
    }

    public func deviceMetricSummary(
        for key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> HardwareHistoryMetricSummary {
        let timeline = await deviceMetricTimeline(
            for: key,
            deviceID: deviceID,
            deviceKind: deviceKind,
            in: range,
            bucketIntervalSeconds: bucketIntervalSeconds
        )
        return summarizeTimeline(
            timeline,
            in: range,
            bucketIntervalSeconds: max(60, bucketIntervalSeconds)
        )
    }

    public func availableDevices(
        ofKind deviceKind: HardwareDeviceKind?,
        in range: DateInterval
    ) async -> [HardwareHistoryDeviceIdentity] {
        let preferredDuration = preferredSourceDuration(for: 3600)
        let primaryCandidates = await fetchRollups(
            metricKey: nil,
            deviceID: nil,
            deviceKind: deviceKind?.rawValue,
            bucketDurationSeconds: preferredDuration,
            in: range
        )
        let candidates = primaryCandidates.isEmpty
            ? await fetchRollups(
                metricKey: nil,
                deviceID: nil,
                deviceKind: deviceKind?.rawValue,
                bucketDurationSeconds: preferredDuration == 3600 ? 60 : 3600,
                in: range
            )
            : primaryCandidates

        var identities: [HardwareHistoryDeviceIdentity] = []
        var seen = Set<String>()

        for rollup in candidates where !rollup.deviceID.isEmpty {
            guard seen.insert(rollup.deviceID).inserted else { continue }
            let displayName = await deviceName(for: rollup.deviceID, deviceKind: rollup.deviceKind, in: range)
            identities.append(
                HardwareHistoryDeviceIdentity(
                    deviceKey: rollup.deviceID,
                    deviceName: displayName ?? rollup.deviceID,
                    deviceType: rollup.deviceKind
                )
            )
        }

        return identities.sorted {
            if $0.deviceName.caseInsensitiveCompare($1.deviceName) == .orderedSame {
                return $0.deviceKey.localizedCaseInsensitiveCompare($1.deviceKey) == .orderedAscending
            }
            return $0.deviceName.localizedCaseInsensitiveCompare($1.deviceName) == .orderedAscending
        }
    }

    private func timeline(
        metricKey: String,
        deviceID: String,
        deviceKind: String,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> [HardwareHistoryMetricBucket] {
        let sourceRows = await loadRollups(
            metricKey: metricKey,
            deviceID: deviceID,
            deviceKind: deviceKind,
            in: range,
            bucketIntervalSeconds: bucketIntervalSeconds
        )
        guard !sourceRows.isEmpty else { return [] }

        let targetInterval = max(1, bucketIntervalSeconds)
        guard let sourceDuration = sourceRows.first?.bucketDurationSeconds else {
            return []
        }

        if sourceDuration == targetInterval {
            return sourceRows.map(bucket(from:))
        }

        if sourceDuration < targetInterval {
            return aggregate(sourceRows, into: targetInterval)
        }

        return sourceRows.map(bucket(from:))
    }

    private func loadRollups(
        metricKey: String,
        deviceID: String,
        deviceKind: String,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> [StoredRollup] {
        let preferredDuration = preferredSourceDuration(for: bucketIntervalSeconds)
        let rollups = await fetchRollups(
            metricKey: metricKey,
            deviceID: deviceID,
            deviceKind: deviceKind,
            bucketDurationSeconds: preferredDuration,
            in: range
        )

        if rollups.isEmpty {
            let alternateDuration = preferredDuration == 3600 ? 60 : 3600
            return await fetchRollups(
                metricKey: metricKey,
                deviceID: deviceID,
                deviceKind: deviceKind,
                bucketDurationSeconds: alternateDuration,
                in: range
            )
        }

        return rollups
    }

    private func fetchRollups(
        metricKey: String?,
        deviceID: String?,
        deviceKind: String?,
        bucketDurationSeconds: Int,
        in range: DateInterval
    ) async -> [StoredRollup] {
        let startMs = Int64(range.start.timeIntervalSince1970 * 1000)
        let endMs = Int64(range.end.timeIntervalSince1970 * 1000)

        do {
            return try await database.dbQueue.read { db in
                var sql = """
                    SELECT bucket_start_ms, bucket_duration_s, observed_count, frame_count,
                           estimated_observed_s, min_value, max_value, avg_value, last_value,
                           device_id, device_kind
                    FROM metric_rollups
                    WHERE bucket_duration_s = ?
                      AND bucket_start_ms < ?
                      AND (bucket_start_ms + bucket_duration_s * 1000) > ?
                    """

                var arguments: StatementArguments = [Int64(bucketDurationSeconds), endMs, startMs]

                if let metricKey {
                    sql += " AND metric_key = ?"
                    _ = arguments.append(contentsOf: [metricKey])
                }
                if let deviceID {
                    sql += " AND device_id = ?"
                    _ = arguments.append(contentsOf: [deviceID])
                }
                if let deviceKind {
                    sql += " AND device_kind = ?"
                    _ = arguments.append(contentsOf: [deviceKind])
                }

                sql += " ORDER BY bucket_start_ms ASC, device_kind ASC, device_id ASC"

                let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
                var decoded: [StoredRollup] = []
                decoded.reserveCapacity(rows.count)
                var droppedRowCount = 0

                for row in rows {
                    guard let rollup = Self.storedRollup(from: row) else {
                        droppedRowCount += 1
                        continue
                    }
                    decoded.append(rollup)
                }

                if droppedRowCount > 0 {
                    Self.logger.error(
                        "Dropped \(droppedRowCount, privacy: .public) malformed hardware history rollup rows for metric \(metricKey ?? "any", privacy: .public), duration \(bucketDurationSeconds, privacy: .public)s"
                    )
                }

                return decoded
            }
        } catch {
            Self.logger.error(
                "Failed to fetch hardware history rollups for metric \(metricKey ?? "any", privacy: .public), duration \(bucketDurationSeconds, privacy: .public)s: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }

    private static func storedRollup(from row: Row) -> StoredRollup? {
        guard let bucketStartMs = int64Value(row, "bucket_start_ms"),
              let bucketDurationSeconds = intValue(row, "bucket_duration_s"),
              let observedCount = intValue(row, "observed_count"),
              let frameCount = intValue(row, "frame_count"),
              let estimatedObservedSeconds = intValue(row, "estimated_observed_s"),
              let minValue = doubleValue(row, "min_value"),
              let maxValue = doubleValue(row, "max_value"),
              let averageValue = doubleValue(row, "avg_value"),
              let lastValue = doubleValue(row, "last_value"),
              let deviceID = stringValue(row, "device_id"),
              let deviceKind = stringValue(row, "device_kind")
        else {
            return nil
        }

        return StoredRollup(
            bucketStart: Date(timeIntervalSince1970: Double(bucketStartMs) / 1000.0),
            bucketDurationSeconds: bucketDurationSeconds,
            observedCount: observedCount,
            frameCount: frameCount,
            estimatedObservedSeconds: estimatedObservedSeconds,
            minValue: minValue,
            maxValue: maxValue,
            averageValue: averageValue,
            lastValue: lastValue,
            deviceID: deviceID,
            deviceKind: deviceKind
        )
    }

    private static func intValue(_ row: Row, _ column: String) -> Int? {
        if let value: Int = row[column] {
            return value
        }
        if let value: Int64 = row[column] {
            return Int(exactly: value)
        }
        if let value: Int32 = row[column] {
            return Int(value)
        }
        if let value: Double = row[column], value.isFinite, value.rounded(.towardZero) == value {
            return Int(exactly: Int64(value))
        }
        return nil
    }

    private static func int64Value(_ row: Row, _ column: String) -> Int64? {
        if let value: Int64 = row[column] {
            return value
        }
        if let value: Int = row[column] {
            return Int64(value)
        }
        if let value: Int32 = row[column] {
            return Int64(value)
        }
        if let value: Double = row[column], value.isFinite, value.rounded(.towardZero) == value {
            return Int64(value)
        }
        return nil
    }

    private static func doubleValue(_ row: Row, _ column: String) -> Double? {
        if let value: Double = row[column] {
            return value
        }
        if let value: Int64 = row[column] {
            return Double(value)
        }
        if let value: Int = row[column] {
            return Double(value)
        }
        return nil
    }

    private static func stringValue(_ row: Row, _ column: String) -> String? {
        row[column] as String?
    }

    private func deviceName(
        for deviceID: String,
        deviceKind: String,
        in range: DateInterval
    ) async -> String? {
        let startMs = Int64(range.start.timeIntervalSince1970 * 1000)
        let endMs = Int64(range.end.timeIntervalSince1970 * 1000)

        do {
            return try await database.dbQueue.read { db in
                let row = try? Row.fetchOne(
                    db,
                    sql: """
                        SELECT dimension_value
                        FROM dimension_snapshots
                        WHERE device_id = ?
                          AND device_kind = ?
                          AND dimension_key = ?
                          AND bucket_start_ms < ?
                          AND (bucket_start_ms + bucket_duration_s * 1000) > ?
                        ORDER BY bucket_start_ms DESC
                        LIMIT 1
                        """,
                    arguments: [
                        deviceID,
                        deviceKind,
                        HardwareDeviceDimensionKey.name.rawValue,
                        endMs,
                        startMs
                    ]
                )
                return row?["dimension_value"] as String?
            }
        } catch {
            return nil
        }
    }

    private func aggregate(
        _ sourceRows: [StoredRollup],
        into targetIntervalSeconds: Int
    ) -> [HardwareHistoryMetricBucket] {
        let targetInterval = TimeInterval(max(1, targetIntervalSeconds))
        let grouped = Dictionary(grouping: sourceRows) { rollup in
            let bucketStartSeconds = floor(rollup.bucketStart.timeIntervalSinceReferenceDate / targetInterval) * targetInterval
            return Date(timeIntervalSinceReferenceDate: bucketStartSeconds)
        }

        return grouped.keys.sorted().compactMap { bucketStart in
            guard let rows = grouped[bucketStart], !rows.isEmpty else { return nil }
            let bucketDurationSeconds = max(1, targetIntervalSeconds)
            let observedRollupCount = rows.reduce(0) { $0 + $1.frameCount }
            let observedSampleCount = rows.reduce(0) { $0 + $1.observedCount }
            let estimatedObservedSeconds = rows.reduce(0) { $0 + $1.estimatedObservedSeconds }
            let minValue = rows.map(\.minValue).min()
            let maxValue = rows.map(\.maxValue).max()
            let lastValue = rows.max(by: { $0.bucketStart < $1.bucketStart })?.lastValue

            let weightedAverageComponents = rows.map { row in
                (row.averageValue, max(max(row.estimatedObservedSeconds, row.observedCount), 1))
            }
            let totalWeight = weightedAverageComponents.reduce(0) { $0 + $1.1 }
            let weightedAverage = totalWeight > 0
                ? weightedAverageComponents.reduce(0.0) { partial, component in
                    partial + component.0 * Double(component.1)
                } / Double(totalWeight)
                : 0

            return HardwareHistoryMetricBucket(
                bucketStart: bucketStart,
                bucketDurationSeconds: bucketDurationSeconds,
                observedRollupCount: observedRollupCount,
                observedSampleCount: observedSampleCount,
                estimatedObservedSeconds: estimatedObservedSeconds,
                minValue: minValue,
                maxValue: maxValue,
                averageValue: weightedAverage.isFinite ? weightedAverage : nil,
                lastValue: lastValue
            )
        }
    }

    private func bucket(from row: StoredRollup) -> HardwareHistoryMetricBucket {
        HardwareHistoryMetricBucket(
            bucketStart: row.bucketStart,
            bucketDurationSeconds: row.bucketDurationSeconds,
            observedRollupCount: row.frameCount,
            observedSampleCount: row.observedCount,
            estimatedObservedSeconds: row.estimatedObservedSeconds,
            minValue: row.minValue,
            maxValue: row.maxValue,
            averageValue: row.averageValue,
            lastValue: row.lastValue
        )
    }

    private func summarizeTimeline(
        _ timeline: [HardwareHistoryMetricBucket],
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) -> HardwareHistoryMetricSummary {
        guard !timeline.isEmpty else {
            return HardwareHistoryMetricSummary(
                range: range,
                bucketIntervalSeconds: bucketIntervalSeconds,
                observedBucketCount: 0,
                observedSampleCount: 0,
                estimatedObservedSeconds: 0,
                minValue: nil,
                maxValue: nil,
                averageValue: nil,
                lastValue: nil,
                peakValue: nil,
                peakBucketStart: nil
            )
        }

        let observedSampleCount = timeline.reduce(0) { $0 + $1.observedSampleCount }
        let estimatedObservedSeconds = timeline.reduce(0) { $0 + $1.estimatedObservedSeconds }
        let minimum = timeline.compactMap(\.minValue).min()
        let maximum = timeline.compactMap(\.maxValue).max()
        let lastValue = timeline.compactMap(\.lastValue).last

        let weightedAverageComponents = timeline.compactMap { bucket -> (Double, Int)? in
            guard let average = bucket.averageValue else { return nil }
            let weight = max(max(bucket.estimatedObservedSeconds, bucket.observedSampleCount), 1)
            return (average, weight)
        }

        let weightedAverage: Double?
        if weightedAverageComponents.isEmpty {
            weightedAverage = nil
        } else {
            let weightedSum = weightedAverageComponents.reduce(0.0) { partialResult, component in
                partialResult + (component.0 * Double(component.1))
            }
            let totalWeight = weightedAverageComponents.reduce(0) { $0 + $1.1 }
            weightedAverage = totalWeight > 0 ? weightedSum / Double(totalWeight) : nil
        }

        let peakBucket = timeline.max { lhs, rhs in
            (lhs.maxValue ?? lhs.averageValue ?? lhs.lastValue ?? .leastNonzeroMagnitude)
                < (rhs.maxValue ?? rhs.averageValue ?? rhs.lastValue ?? .leastNonzeroMagnitude)
        }

        return HardwareHistoryMetricSummary(
            range: range,
            bucketIntervalSeconds: bucketIntervalSeconds,
            observedBucketCount: timeline.count,
            observedSampleCount: observedSampleCount,
            estimatedObservedSeconds: estimatedObservedSeconds,
            minValue: minimum,
            maxValue: maximum,
            averageValue: weightedAverage,
            lastValue: lastValue,
            peakValue: peakBucket.flatMap { $0.maxValue ?? $0.averageValue ?? $0.lastValue },
            peakBucketStart: peakBucket?.bucketStart
        )
    }

    private func preferredSourceDuration(for requestedBucketIntervalSeconds: Int) -> Int {
        requestedBucketIntervalSeconds >= 3600 ? 3600 : 60
    }
}
#endif
