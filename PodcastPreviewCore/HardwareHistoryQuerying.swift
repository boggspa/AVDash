import Foundation

public struct ProcessHistoryBucket: Codable, Equatable, Sendable {
    public let bucketStart: Date
    public let bucketDurationSeconds: Int
    public let rollup: PersistedProcessRollup

    public init(
        bucketStart: Date,
        bucketDurationSeconds: Int,
        rollup: PersistedProcessRollup
    ) {
        self.bucketStart = bucketStart
        self.bucketDurationSeconds = bucketDurationSeconds
        self.rollup = rollup
    }
}

public struct ProcessHistorySummary: Codable, Equatable, Sendable {
    public let range: DateInterval
    public let rollup: PersistedProcessRollup

    public init(
        range: DateInterval,
        rollup: PersistedProcessRollup
    ) {
        self.range = range
        self.rollup = rollup
    }

    // Computed properties for consuming code compatibility
    public var averageCPUPercent: Double { rollup.avgCPUPercent }
    public var peakCPUPercent: Double { rollup.maxCPUPercent }
    public var averageRAMMB: Double { rollup.avgRAMMB }
    public var peakRAMMB: Double { rollup.maxRAMMB }
    public var averageGPUActiveRatio: Double { rollup.gpuActiveRatio }
    public var averageGPUShareRatio: Double { rollup.averageGPUShareRatio }
    public var peakGPUShareRatio: Double { rollup.peakGPUShareRatio }
    public var averagePowerScore: Double { rollup.avgPowerScore }
    public var latestUptimeSeconds: Double? { rollup.lastUptimeSeconds }
    public var peakGPUTimeNS: UInt64 { rollup.maxGPUTimeNS }
}

public protocol HardwareHistoryQuerying: Sendable {
    func metricTimeline(
        for key: HardwareMetricKey,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> [HardwareHistoryMetricBucket]

    func metricSummary(
        for key: HardwareMetricKey,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> HardwareHistoryMetricSummary

    func deviceMetricTimeline(
        for key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> [HardwareHistoryMetricBucket]

    func deviceMetricSummary(
        for key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> HardwareHistoryMetricSummary

    func availableDevices(
        ofKind deviceKind: HardwareDeviceKind?,
        in range: DateInterval
    ) async -> [HardwareHistoryDeviceIdentity]
}

public extension HardwareHistoryQuerying {
    func metricTimeline(
        for key: HardwareMetricKey,
        in range: DateInterval
    ) async -> [HardwareHistoryMetricBucket] {
        await metricTimeline(for: key, in: range, bucketIntervalSeconds: 60)
    }

    func metricSummary(
        for key: HardwareMetricKey,
        in range: DateInterval
    ) async -> HardwareHistoryMetricSummary {
        await metricSummary(for: key, in: range, bucketIntervalSeconds: 60)
    }

    func deviceMetricTimeline(
        for key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        in range: DateInterval
    ) async -> [HardwareHistoryMetricBucket] {
        await deviceMetricTimeline(
            for: key,
            deviceID: deviceID,
            deviceKind: deviceKind,
            in: range,
            bucketIntervalSeconds: 60
        )
    }

    func deviceMetricSummary(
        for key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        in range: DateInterval
    ) async -> HardwareHistoryMetricSummary {
        await deviceMetricSummary(
            for: key,
            deviceID: deviceID,
            deviceKind: deviceKind,
            in: range,
            bucketIntervalSeconds: 60
        )
    }

    func availableDevices(
        in range: DateInterval
    ) async -> [HardwareHistoryDeviceIdentity] {
        await availableDevices(ofKind: nil, in: range)
    }
}

// ProcessHistoryQuerying is defined in ProcessHistoryStore.swift

public protocol HardwareEventQuerying: Sendable {
    func events(
        in range: DateInterval,
        categories: [HardwareEventCategory]?,
        limit: Int
    ) async -> [HardwareTimelineEvent]
}

public extension HardwareEventQuerying {
    func events(
        in range: DateInterval
    ) async -> [HardwareTimelineEvent] {
        await events(in: range, categories: nil, limit: 96)
    }

    func events(
        in range: DateInterval,
        categories: [HardwareEventCategory]?
    ) async -> [HardwareTimelineEvent] {
        await events(in: range, categories: categories, limit: 96)
    }
}
