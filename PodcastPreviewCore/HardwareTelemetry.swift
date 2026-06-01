import Foundation

public enum MetricBucketAggregation: Sendable {
    case latest
    case average
    case maximum
}

public enum HardwareMetricKey: String, CaseIterable, Codable, Sendable {
    case cpuTotalUsage
    case cpuPerCoreUsage
    case cpuSystemUsage
    case cpuUserUsage
    case cpuIdleUsage
    case cpuEfficiencyUsage
    case cpuPerformanceUsage
    case cpuEfficiencyCoreCount
    case cpuPerformanceCoreCount
    case ramUsageRatio
    case ramUsedGB
    case ramTotalGB
    case cachedMemoryGB
    case compressedMemoryGB
    case wiredMemoryGB
    case appMemoryGB
    case appCPUUsageRatio
    case appGPUUsageRatio
    case appDiskReadMBps
    case appDiskWriteMBps
    case swapUsageRatio
    case swapUsedGB
    case swapTotalGB
    case memoryPressureRatio
    case thermalLevel
    case networkUploadMBps
    case networkDownloadMBps
    case networkPingLatencyMilliseconds
    case networkPingPacketLossRatio
    case diskReadMBps
    case diskWriteMBps
    case cpuPowerWatts
    case gpuPowerWatts
    case anePowerWatts
    case combinedPowerWatts
    case cumulativeCombinedEnergyWh
    case systemUptimeSeconds
    case gpuFrequencyMHz
    case cpuCoreFrequencyMHz
    case aneActivityRatio
    case mediaEngineActivityRatio
    case aneBusyRatio
    case aneClientCount
    case aneCoreCount
}

public enum HardwareMetricUnit: String, Codable, Sendable {
    case ratio
    case megabytesPerSecond
    case milliseconds
    case megabytes
    case kilobytes
    case watts
    case wattHours
    case gigabytes
    case count
    case megahertz
    case celsius
    case rpm
}

public enum HardwareSnapshotDimensionKey: String, Codable, Sendable {
    case cpuDisplayName
    case memoryPressureLevel
    case thermalState
    case aneArchitecture
    case aneEngineStatus
    case aneActivityStatus
}

public struct MetricSample: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let value: Double?

    public init(timestamp: Date = Date(), value: Double?) {
        self.timestamp = timestamp
        self.value = value
    }

    public var isObserved: Bool {
        value != nil
    }
}

public struct MetricSeries: Codable, Equatable, Sendable {
    public let key: HardwareMetricKey
    public let unit: HardwareMetricUnit
    public private(set) var samples: [MetricSample]

    public init(key: HardwareMetricKey, unit: HardwareMetricUnit, samples: [MetricSample] = []) {
        self.key = key
        self.unit = unit
        self.samples = samples
    }

    public mutating func append(_ value: Double?, at timestamp: Date = Date(), capacity: Int? = nil) {
        samples.append(MetricSample(timestamp: timestamp, value: value))

        guard let capacity, capacity > 0, samples.count > capacity else { return }
        samples.removeFirst(samples.count - capacity)
    }

    public mutating func removeAll(keepingCapacity keepCapacity: Bool = true) {
        samples.removeAll(keepingCapacity: keepCapacity)
    }

    public var latestSample: MetricSample? {
        samples.last
    }

    public var latestObservedValue: Double? {
        for sample in samples.reversed() {
            if let value = sample.value {
                return value
            }
        }
        return nil
    }

    public var peakObservedValue: Double? {
        samples.compactMap(\.value).max()
    }

    public func observedValues() -> [Double] {
        samples.compactMap(\.value)
    }

    public func values(fillingMissingWith fillValue: Double = 0.0) -> [Double] {
        samples.map { $0.value ?? fillValue }
    }

    public func recentValues(limit: Int, fillingMissingWith fillValue: Double = 0.0) -> [Double] {
        guard limit > 0 else { return [] }
        return Array(samples.suffix(limit)).map { $0.value ?? fillValue }
    }

    public func bucketedObservedValues(
        windowSeconds: Int,
        bucketIntervalSeconds: Int,
        anchor: Date = Date(),
        aggregation: MetricBucketAggregation = .average
    ) -> [Double] {
        makeBucketedObservedValues(
            samples: samples,
            windowSeconds: windowSeconds,
            bucketIntervalSeconds: bucketIntervalSeconds,
            anchor: anchor,
            aggregation: aggregation
        )
    }
}

public struct HardwareSnapshot: Codable, Equatable, Sendable {
    public var timestamp: Date
    public private(set) var numericMetrics: [HardwareMetricKey: Double]
    public private(set) var dimensions: [HardwareSnapshotDimensionKey: String]

    public init(
        timestamp: Date = Date(),
        numericMetrics: [HardwareMetricKey: Double] = [:],
        dimensions: [HardwareSnapshotDimensionKey: String] = [:]
    ) {
        self.timestamp = timestamp
        self.numericMetrics = numericMetrics
        self.dimensions = dimensions
    }

    public var isEmpty: Bool {
        numericMetrics.isEmpty && dimensions.isEmpty
    }

    public func metric(_ key: HardwareMetricKey) -> Double? {
        numericMetrics[key]
    }

    public func dimension(_ key: HardwareSnapshotDimensionKey) -> String? {
        dimensions[key]
    }

    public mutating func setMetric(_ key: HardwareMetricKey, value: Double) {
        numericMetrics[key] = value
    }

    public mutating func setDimension(_ key: HardwareSnapshotDimensionKey, value: String) {
        dimensions[key] = value
    }

    public func merging(_ other: HardwareSnapshot) -> HardwareSnapshot {
        var merged = self

        if other.timestamp > merged.timestamp {
            merged.timestamp = other.timestamp
        }

        merged.numericMetrics.merge(other.numericMetrics) { _, new in new }
        merged.dimensions.merge(other.dimensions) { _, new in new }
        return merged
    }
}

public enum HardwareDeviceKind: String, Codable, Sendable {
    case gpu
}

public enum HardwareDeviceMetricKey: String, Codable, Sendable {
    case utilizationRatio
    case rendererUtilizationRatio
    case tilerUtilizationRatio
    case vramTotalMegabytes
    case vramUsedMegabytes
    case vramFreeMegabytes
    case rendererAllocatedPageBufferMegabytes
    case tilerSceneKilobytes
    case memoryAllocatedMegabytes
    case memoryInUseMegabytes
    case memoryDriverInUseMegabytes
    case temperatureCelsius
    case fanRPM
    case coreClockMegahertz
    case memoryClockMegahertz
    case totalPowerWatts
    case coreCount
}

public enum HardwareDeviceDimensionKey: String, Codable, Sendable {
    case name
}

public struct HardwareDeviceMetricSeries: Codable, Equatable, Sendable {
    public let deviceID: String
    public let deviceKind: HardwareDeviceKind
    public let key: HardwareDeviceMetricKey
    public let unit: HardwareMetricUnit
    public private(set) var samples: [MetricSample]

    public init(
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        key: HardwareDeviceMetricKey,
        unit: HardwareMetricUnit,
        samples: [MetricSample] = []
    ) {
        self.deviceID = deviceID
        self.deviceKind = deviceKind
        self.key = key
        self.unit = unit
        self.samples = samples
    }

    public mutating func append(_ value: Double?, at timestamp: Date = Date(), capacity: Int? = nil) {
        samples.append(MetricSample(timestamp: timestamp, value: value))

        guard let capacity, capacity > 0, samples.count > capacity else { return }
        samples.removeFirst(samples.count - capacity)
    }

    public mutating func removeAll(keepingCapacity keepCapacity: Bool = true) {
        samples.removeAll(keepingCapacity: keepCapacity)
    }

    public var latestSample: MetricSample? {
        samples.last
    }

    public var latestObservedValue: Double? {
        for sample in samples.reversed() {
            if let value = sample.value {
                return value
            }
        }
        return nil
    }

    public var peakObservedValue: Double? {
        samples.compactMap(\.value).max()
    }

    public func observedValues() -> [Double] {
        samples.compactMap(\.value)
    }

    public func values(fillingMissingWith fillValue: Double = 0.0) -> [Double] {
        samples.map { $0.value ?? fillValue }
    }

    public func bucketedObservedValues(
        windowSeconds: Int,
        bucketIntervalSeconds: Int,
        anchor: Date = Date(),
        aggregation: MetricBucketAggregation = .average
    ) -> [Double] {
        makeBucketedObservedValues(
            samples: samples,
            windowSeconds: windowSeconds,
            bucketIntervalSeconds: bucketIntervalSeconds,
            anchor: anchor,
            aggregation: aggregation
        )
    }
}

public struct HardwareDeviceSnapshot: Codable, Equatable, Sendable, Identifiable {
    public let deviceID: String
    public let deviceKind: HardwareDeviceKind
    public var timestamp: Date
    public private(set) var numericMetrics: [HardwareDeviceMetricKey: Double]
    public private(set) var dimensions: [HardwareDeviceDimensionKey: String]

    public init(
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        timestamp: Date = Date(),
        numericMetrics: [HardwareDeviceMetricKey: Double] = [:],
        dimensions: [HardwareDeviceDimensionKey: String] = [:]
    ) {
        self.deviceID = deviceID
        self.deviceKind = deviceKind
        self.timestamp = timestamp
        self.numericMetrics = numericMetrics
        self.dimensions = dimensions
    }

    public var id: String {
        "\(deviceKind.rawValue):\(deviceID)"
    }

    public var isEmpty: Bool {
        numericMetrics.isEmpty && dimensions.isEmpty
    }

    public func metric(_ key: HardwareDeviceMetricKey) -> Double? {
        numericMetrics[key]
    }

    public func dimension(_ key: HardwareDeviceDimensionKey) -> String? {
        dimensions[key]
    }

    public mutating func setMetric(_ key: HardwareDeviceMetricKey, value: Double) {
        numericMetrics[key] = value
    }

    public mutating func setDimension(_ key: HardwareDeviceDimensionKey, value: String) {
        dimensions[key] = value
    }

    public func merging(_ other: HardwareDeviceSnapshot) -> HardwareDeviceSnapshot {
        guard other.deviceID == deviceID, other.deviceKind == deviceKind else { return other }

        var merged = self

        if other.timestamp > merged.timestamp {
            merged.timestamp = other.timestamp
        }

        merged.numericMetrics.merge(other.numericMetrics) { _, new in new }
        merged.dimensions.merge(other.dimensions) { _, new in new }
        return merged
    }
}

public struct HardwareTelemetryFrame: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var snapshot: HardwareSnapshot?
    public var deviceSnapshots: [HardwareDeviceSnapshot]

    public init(
        timestamp: Date = Date(),
        snapshot: HardwareSnapshot? = nil,
        deviceSnapshots: [HardwareDeviceSnapshot] = []
    ) {
        self.timestamp = timestamp
        self.snapshot = snapshot
        self.deviceSnapshots = deviceSnapshots
    }

    public var isEmpty: Bool {
        snapshot == nil && deviceSnapshots.isEmpty
    }
}

private func makeBucketedObservedValues(
    samples: [MetricSample],
    windowSeconds: Int,
    bucketIntervalSeconds: Int,
    anchor: Date,
    aggregation: MetricBucketAggregation
) -> [Double] {
    let window = TimeInterval(max(1, windowSeconds))
    let bucketInterval = TimeInterval(max(1, bucketIntervalSeconds))
    let lowerBound = anchor.addingTimeInterval(-window)

    var bucketedValues: [Double] = []
    var currentBucketID: Int64?
    var currentValues: [Double] = []

    func flushCurrentBucket() {
        guard !currentValues.isEmpty else { return }
        bucketedValues.append(aggregateBucketValues(currentValues, aggregation: aggregation))
        currentValues.removeAll(keepingCapacity: true)
    }

    for sample in samples {
        guard sample.timestamp >= lowerBound, sample.timestamp <= anchor else { continue }
        guard let value = sample.value else { continue }

        let bucketID = Int64(floor(sample.timestamp.timeIntervalSinceReferenceDate / bucketInterval))
        if currentBucketID == bucketID {
            currentValues.append(value)
            continue
        }

        flushCurrentBucket()
        currentBucketID = bucketID
        currentValues.append(value)
    }

    flushCurrentBucket()
    return bucketedValues
}

private func aggregateBucketValues(
    _ values: [Double],
    aggregation: MetricBucketAggregation
) -> Double {
    switch aggregation {
    case .latest:
        return values.last ?? 0
    case .average:
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    case .maximum:
        return values.max() ?? 0
    }
}
