import Foundation

public enum HardwareCollectionProfile: String, Codable, CaseIterable, Sendable {
    case historyOnly
    case toolbar
    case dashboard
    case focusedHighResolution

    public var priority: Int {
        switch self {
        case .historyOnly:
            return 0
        case .toolbar:
            return 1
        case .dashboard:
            return 2
        case .focusedHighResolution:
            return 3
        }
    }

    public static func highest<S: Sequence>(_ profiles: S) -> HardwareCollectionProfile where S.Element == HardwareCollectionProfile {
        profiles.max { $0.priority < $1.priority } ?? .historyOnly
    }
}

public enum HardwareCollectorSampleGroup: String, Codable, CaseIterable, Sendable {
    case cpu
    case ram
    case thermal
    case gpu
    case diskIO
    case ane
    case app
    case runningApps
    case gpuClients
    case networkInterface
    case power
    case network
    case mediaEngine
}

public enum HardwareSamplerCadencePolicy {
    public static func heartbeatIntervalSeconds(for profile: HardwareCollectionProfile) -> Int {
        switch profile {
        case .focusedHighResolution:
            return 1
        case .dashboard:
            return 2
        case .toolbar:
            return 5
        case .historyOnly:
            return 15
        }
    }

    public static func sampleIntervalSeconds(
        for group: HardwareCollectorSampleGroup,
        profile: HardwareCollectionProfile
    ) -> TimeInterval {
        switch profile {
        case .focusedHighResolution:
            switch group {
            case .gpu, .gpuClients, .runningApps, .power:
                return 2
            default:
                return 1
            }
        case .dashboard:
            switch group {
            case .cpu, .ram, .app:
                return 2
            case .gpu, .gpuClients, .runningApps, .power, .network, .mediaEngine, .ane, .thermal, .diskIO:
                return 5
            case .networkInterface:
                return 60
            }
        case .toolbar:
            switch group {
            case .cpu, .ram, .app:
                return 5
            case .gpu, .gpuClients, .runningApps, .power, .network, .mediaEngine, .ane, .thermal, .diskIO:
                return 15
            case .networkInterface:
                return 60
            }
        case .historyOnly:
            switch group {
            case .cpu, .ram, .app, .thermal, .diskIO:
                return 15
            case .gpu, .gpuClients, .runningApps, .power, .network, .mediaEngine, .ane:
                return 30
            case .networkInterface:
                return 120
            }
        }
    }
}

public struct HardwareCollectionProfileRequest: Codable, Equatable, Sendable {
    public let profile: HardwareCollectionProfile

    public init(profile: HardwareCollectionProfile) {
        self.profile = profile
    }
}

public struct HardwareMonitoringQueryRange: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var dateInterval: DateInterval {
        if start <= end {
            return DateInterval(start: start, end: end)
        }
        return DateInterval(start: end, end: start)
    }
}

public struct HardwareCollectorStatusSnapshot: Codable, Equatable, Sendable {
    public let isCollectorInitialized: Bool
    public let isMonitoringActive: Bool
    public let collectorIntervalSeconds: Int
    public let activeProfile: HardwareCollectionProfile
    public let latestFrameTimestamp: Date?
    public let hasGlobalSnapshot: Bool
    public let deviceSnapshotCount: Int

    public init(
        isCollectorInitialized: Bool,
        isMonitoringActive: Bool,
        collectorIntervalSeconds: Int,
        activeProfile: HardwareCollectionProfile = .dashboard,
        latestFrameTimestamp: Date?,
        hasGlobalSnapshot: Bool,
        deviceSnapshotCount: Int
    ) {
        self.isCollectorInitialized = isCollectorInitialized
        self.isMonitoringActive = isMonitoringActive
        self.collectorIntervalSeconds = collectorIntervalSeconds
        self.activeProfile = activeProfile
        self.latestFrameTimestamp = latestFrameTimestamp
        self.hasGlobalSnapshot = hasGlobalSnapshot
        self.deviceSnapshotCount = deviceSnapshotCount
    }

    private enum CodingKeys: String, CodingKey {
        case isCollectorInitialized
        case isMonitoringActive
        case collectorIntervalSeconds
        case activeProfile
        case latestFrameTimestamp
        case hasGlobalSnapshot
        case deviceSnapshotCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isCollectorInitialized: try container.decode(Bool.self, forKey: .isCollectorInitialized),
            isMonitoringActive: try container.decode(Bool.self, forKey: .isMonitoringActive),
            collectorIntervalSeconds: try container.decode(Int.self, forKey: .collectorIntervalSeconds),
            activeProfile: try container.decodeIfPresent(HardwareCollectionProfile.self, forKey: .activeProfile) ?? .dashboard,
            latestFrameTimestamp: try container.decodeIfPresent(Date.self, forKey: .latestFrameTimestamp),
            hasGlobalSnapshot: try container.decode(Bool.self, forKey: .hasGlobalSnapshot),
            deviceSnapshotCount: try container.decode(Int.self, forKey: .deviceSnapshotCount)
        )
    }
}

public struct HardwareAvailableDevicesRequest: Codable, Equatable, Sendable {
    public let deviceKind: HardwareDeviceKind?
    public let range: HardwareMonitoringQueryRange

    public init(deviceKind: HardwareDeviceKind? = nil, range: HardwareMonitoringQueryRange) {
        self.deviceKind = deviceKind
        self.range = range
    }
}

public struct HardwareMetricTimelineRequest: Codable, Equatable, Sendable {
    public let key: HardwareMetricKey
    public let range: HardwareMonitoringQueryRange
    public let bucketIntervalSeconds: Int

    public init(
        key: HardwareMetricKey,
        range: HardwareMonitoringQueryRange,
        bucketIntervalSeconds: Int = 60
    ) {
        self.key = key
        self.range = range
        self.bucketIntervalSeconds = bucketIntervalSeconds
    }
}

public struct HardwareDeviceMetricTimelineRequest: Codable, Equatable, Sendable {
    public let key: HardwareDeviceMetricKey
    public let deviceID: String
    public let deviceKind: HardwareDeviceKind
    public let range: HardwareMonitoringQueryRange
    public let bucketIntervalSeconds: Int

    public init(
        key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        range: HardwareMonitoringQueryRange,
        bucketIntervalSeconds: Int = 60
    ) {
        self.key = key
        self.deviceID = deviceID
        self.deviceKind = deviceKind
        self.range = range
        self.bucketIntervalSeconds = bucketIntervalSeconds
    }
}

public struct HardwareMetricInsightRequest: Codable, Equatable, Sendable {
    public let key: HardwareMetricKey
    public let range: HardwareMonitoringQueryRange
    public let summaryBucketIntervalSeconds: Int

    public init(
        key: HardwareMetricKey,
        range: HardwareMonitoringQueryRange,
        summaryBucketIntervalSeconds: Int = 3600
    ) {
        self.key = key
        self.range = range
        self.summaryBucketIntervalSeconds = summaryBucketIntervalSeconds
    }
}

public struct HardwareDeviceMetricInsightRequest: Codable, Equatable, Sendable {
    public let key: HardwareDeviceMetricKey
    public let deviceID: String
    public let deviceKind: HardwareDeviceKind
    public let range: HardwareMonitoringQueryRange
    public let summaryBucketIntervalSeconds: Int

    public init(
        key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        range: HardwareMonitoringQueryRange,
        summaryBucketIntervalSeconds: Int = 3600
    ) {
        self.key = key
        self.deviceID = deviceID
        self.deviceKind = deviceKind
        self.range = range
        self.summaryBucketIntervalSeconds = summaryBucketIntervalSeconds
    }
}

public struct HardwareProcessTimelineRequest: Codable, Equatable, Sendable {
    public let identity: PersistedProcessIdentity
    public let range: HardwareMonitoringQueryRange
    public let bucketIntervalSeconds: Int

    public init(
        identity: PersistedProcessIdentity,
        range: HardwareMonitoringQueryRange,
        bucketIntervalSeconds: Int = 3600
    ) {
        self.identity = identity
        self.range = range
        self.bucketIntervalSeconds = bucketIntervalSeconds
    }
}

public struct HardwareProcessSummaryRequest: Codable, Equatable, Sendable {
    public let identity: PersistedProcessIdentity
    public let range: HardwareMonitoringQueryRange
    public let bucketIntervalSeconds: Int

    public init(
        identity: PersistedProcessIdentity,
        range: HardwareMonitoringQueryRange,
        bucketIntervalSeconds: Int = 3600
    ) {
        self.identity = identity
        self.range = range
        self.bucketIntervalSeconds = bucketIntervalSeconds
    }
}

public struct HardwareEventsRequest: Codable, Equatable, Sendable {
    public let range: HardwareMonitoringQueryRange
    public let categories: [HardwareEventCategory]?
    public let limit: Int

    public init(
        range: HardwareMonitoringQueryRange,
        categories: [HardwareEventCategory]? = nil,
        limit: Int = 96
    ) {
        self.range = range
        self.categories = categories
        self.limit = limit
    }
}
