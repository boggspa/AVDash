import Foundation
import CloudKit
import SwiftUI

// MARK: - Remote Machine Identity

public struct RemoteMachineIdentity: Codable, Sendable, Identifiable, Hashable {
    public let machineID: String
    public let displayName: String
    public let modelIdentifier: String
    public let cpuName: String?
    public let gpuName: String?
    public let totalRAMGB: Double?
    public let macOSVersion: String?
    public let chipType: String?

    public var id: String { machineID }

    public init(
        machineID: String,
        displayName: String,
        modelIdentifier: String,
        cpuName: String? = nil,
        gpuName: String? = nil,
        totalRAMGB: Double? = nil,
        macOSVersion: String? = nil,
        chipType: String? = nil
    ) {
        self.machineID = machineID
        self.displayName = displayName
        self.modelIdentifier = modelIdentifier
        self.cpuName = cpuName
        self.gpuName = gpuName
        self.totalRAMGB = totalRAMGB
        self.macOSVersion = macOSVersion
        self.chipType = chipType
    }
}

// MARK: - Tint

public enum CompanionTint: String, Codable, Hashable, CaseIterable, Sendable {
    case slate
    case cyan
    case blue
    case indigo
    case teal
    case green
    case amber
    case orange
    case red
    case pink
    case purple
    case gray

    public var color: Color {
        switch self {
        case .slate:
            return Color(red: 0.50, green: 0.54, blue: 0.60)
        case .cyan:
            if #available(macOS 12.0, iOS 15.0, *) {
                return .cyan
            } else {
                return Color(red: 0.00, green: 0.73, blue: 0.85)
            }
        case .blue:
            return .blue
        case .indigo:
            if #available(macOS 12.0, iOS 15.0, *) {
                return .indigo
            } else {
                return Color(red: 0.36, green: 0.40, blue: 0.93)
            }
        case .teal:
            if #available(macOS 12.0, iOS 15.0, *) {
                return .teal
            } else {
                return Color(red: 0.00, green: 0.62, blue: 0.58)
            }
        case .green:
            return .green
        case .amber:
            return Color(red: 1.00, green: 0.75, blue: 0.00)
        case .orange:
            return .orange
        case .red:
            return .red
        case .pink:
            if #available(macOS 12.0, iOS 15.0, *) {
                return .pink
            } else {
                return Color(red: 1.00, green: 0.18, blue: 0.33)
            }
        case .purple:
            return .purple
        case .gray:
            return .gray
        }
    }
}

// MARK: - Common Models

public struct CompanionKeyValueRow: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(label)-\(value)" }
    public let label: String
    public let value: String
    public let tint: CompanionTint

    public init(label: String, value: String, tint: CompanionTint) {
        self.label = label
        self.value = value
        self.tint = tint
    }
}

// MARK: - Dashboard Models

public struct CompanionSummaryChip: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let value: String
    public let tint: CompanionTint
    public let caption: String?

    public init(id: String, label: String, value: String, tint: CompanionTint, caption: String? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.tint = tint
        self.caption = caption
    }
}

public struct CompanionSeries: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let tint: CompanionTint
    public let values: [Double?]

    public init(id: String, label: String, tint: CompanionTint, values: [Double?]) {
        self.id = id
        self.label = label
        self.tint = tint
        self.values = values
    }
}

public enum CompanionDashboardCardKind: String, Codable, Sendable, Hashable {
    case identity
    case chart
    case meter
    case list
    case insight
}

public struct CompanionDashboardCard: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let detail: String?
    public let kind: CompanionDashboardCardKind
    public let tint: CompanionTint
    public let primaryValue: String?
    public let progress: Double?
    public let series: [CompanionSeries]
    public let rows: [CompanionKeyValueRow]
    public let focusID: String?
    public let footnote: String?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        detail: String? = nil,
        kind: CompanionDashboardCardKind,
        tint: CompanionTint,
        primaryValue: String? = nil,
        progress: Double? = nil,
        series: [CompanionSeries] = [],
        rows: [CompanionKeyValueRow] = [],
        focusID: String? = nil,
        footnote: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.kind = kind
        self.tint = tint
        self.primaryValue = primaryValue
        self.progress = progress
        self.series = series
        self.rows = rows
        self.focusID = focusID
        self.footnote = footnote
    }
}

public struct CompanionDashboardSection: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let cards: [CompanionDashboardCard]

    public init(id: String, title: String, subtitle: String? = nil, cards: [CompanionDashboardCard]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.cards = cards
    }
}

public struct CompanionDashboardSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var id: String { machineIdentity.machineID }
    public let machineIdentity: RemoteMachineIdentity
    public let updatedAt: Date
    public let summaryChips: [CompanionSummaryChip]
    public let graphSections: [CompanionDashboardSection]
    public let sidebarSections: [CompanionDashboardSection]
    public let focus: String?

    public init(
        machineIdentity: RemoteMachineIdentity,
        updatedAt: Date,
        summaryChips: [CompanionSummaryChip],
        graphSections: [CompanionDashboardSection],
        sidebarSections: [CompanionDashboardSection],
        focus: String? = nil
    ) {
        self.machineIdentity = machineIdentity
        self.updatedAt = updatedAt
        self.summaryChips = summaryChips
        self.graphSections = graphSections
        self.sidebarSections = sidebarSections
        self.focus = focus
    }
}

// MARK: - Live Snapshots

public struct CompanionLiveCPUSnapshot: Codable, Hashable, Sendable {
    public let displayName: String
    public let totalUsageRatio: Double?
    public let efficiencyUsageRatio: Double?
    public let performanceUsageRatio: Double?
    public let systemUsageRatio: Double?
    public let userUsageRatio: Double?
    public let idleUsageRatio: Double?
    public let efficiencyCoreCount: Int
    public let performanceCoreCount: Int
    public let coreUsages: [Double]

    public init(
        displayName: String,
        totalUsageRatio: Double?,
        efficiencyUsageRatio: Double?,
        performanceUsageRatio: Double?,
        systemUsageRatio: Double?,
        userUsageRatio: Double?,
        idleUsageRatio: Double?,
        efficiencyCoreCount: Int,
        performanceCoreCount: Int,
        coreUsages: [Double]
    ) {
        self.displayName = displayName
        self.totalUsageRatio = totalUsageRatio
        self.efficiencyUsageRatio = efficiencyUsageRatio
        self.performanceUsageRatio = performanceUsageRatio
        self.systemUsageRatio = systemUsageRatio
        self.userUsageRatio = userUsageRatio
        self.idleUsageRatio = idleUsageRatio
        self.efficiencyCoreCount = efficiencyCoreCount
        self.performanceCoreCount = performanceCoreCount
        self.coreUsages = coreUsages
    }
}

public struct CompanionLiveGPUSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let utilizationRatio: Double?
    public let rendererUtilizationRatio: Double?
    public let tilerUtilizationRatio: Double?
    public let memoryAllocatedMB: Double?
    public let memoryInUseMB: Double?
    public let totalPowerWatts: Double?
    public let temperatureCelsius: Double?
    public let coreCount: Int?
    public let connectedDisplayCount: Int?
    public let metalFamily: String?
    public let bus: String?
    public let gpuType: String?

    public init(
        id: String,
        name: String,
        utilizationRatio: Double?,
        rendererUtilizationRatio: Double?,
        tilerUtilizationRatio: Double?,
        memoryAllocatedMB: Double?,
        memoryInUseMB: Double?,
        totalPowerWatts: Double?,
        temperatureCelsius: Double?,
        coreCount: Int?,
        connectedDisplayCount: Int?,
        metalFamily: String?,
        bus: String?,
        gpuType: String?
    ) {
        self.id = id
        self.name = name
        self.utilizationRatio = utilizationRatio
        self.rendererUtilizationRatio = rendererUtilizationRatio
        self.tilerUtilizationRatio = tilerUtilizationRatio
        self.memoryAllocatedMB = memoryAllocatedMB
        self.memoryInUseMB = memoryInUseMB
        self.totalPowerWatts = totalPowerWatts
        self.temperatureCelsius = temperatureCelsius
        self.coreCount = coreCount
        self.connectedDisplayCount = connectedDisplayCount
        self.metalFamily = metalFamily
        self.bus = bus
        self.gpuType = gpuType
    }
}

public struct CompanionLiveMemorySnapshot: Codable, Hashable, Sendable {
    public let usageRatio: Double?
    public let usedGB: Double?
    public let totalGB: Double?
    public let pressureRatio: Double?
    public let pressureLabel: String
    public let pressureSubtext: String
    public let swapUsedGB: Double?
    public let swapTotalGB: Double?
    public let cachedGB: Double?
    public let compressedGB: Double?
    public let wiredGB: Double?
    public let appMemoryGB: Double?
    public let architecture: String?
    public let chip: String?

    public init(
        usageRatio: Double?,
        usedGB: Double?,
        totalGB: Double?,
        pressureRatio: Double?,
        pressureLabel: String,
        pressureSubtext: String,
        swapUsedGB: Double?,
        swapTotalGB: Double?,
        cachedGB: Double?,
        compressedGB: Double?,
        wiredGB: Double?,
        appMemoryGB: Double?,
        architecture: String?,
        chip: String?
    ) {
        self.usageRatio = usageRatio
        self.usedGB = usedGB
        self.totalGB = totalGB
        self.pressureRatio = pressureRatio
        self.pressureLabel = pressureLabel
        self.pressureSubtext = pressureSubtext
        self.swapUsedGB = swapUsedGB
        self.swapTotalGB = swapTotalGB
        self.cachedGB = cachedGB
        self.compressedGB = compressedGB
        self.wiredGB = wiredGB
        self.appMemoryGB = appMemoryGB
        self.architecture = architecture
        self.chip = chip
    }
}

public struct CompanionLiveStorageSnapshot: Codable, Hashable, Sendable {
    public let usedRatio: Double
    public let label: String
    public let kindLabel: String
    public let speedLabel: String
    public let healthLabel: String
    public let diskReadMBps: Double?
    public let diskWriteMBps: Double?

    public init(
        usedRatio: Double,
        label: String,
        kindLabel: String,
        speedLabel: String,
        healthLabel: String,
        diskReadMBps: Double?,
        diskWriteMBps: Double?
    ) {
        self.usedRatio = usedRatio
        self.label = label
        self.kindLabel = kindLabel
        self.speedLabel = speedLabel
        self.healthLabel = healthLabel
        self.diskReadMBps = diskReadMBps
        self.diskWriteMBps = diskWriteMBps
    }
}

public struct CompanionLiveNetworkSnapshot: Codable, Hashable, Sendable {
    public let uploadMBps: Double?
    public let downloadMBps: Double?
    public let pingLatencyMilliseconds: Double?
    public let packetLossRatio: Double?
    public let pingTargetLabel: String
    public let connectionLabel: String
    public let interfaceName: String?
    public let localIP: String?
    public let subnetMask: String?
    public let router: String?
    public let dnsServers: [String]
    public let searchDomains: [String]
    public let ethernetSpeed: String?
    public let configMethod: String?

    public init(
        uploadMBps: Double?,
        downloadMBps: Double?,
        pingLatencyMilliseconds: Double?,
        packetLossRatio: Double?,
        pingTargetLabel: String,
        connectionLabel: String,
        interfaceName: String?,
        localIP: String?,
        subnetMask: String?,
        router: String?,
        dnsServers: [String],
        searchDomains: [String],
        ethernetSpeed: String?,
        configMethod: String?
    ) {
        self.uploadMBps = uploadMBps
        self.downloadMBps = downloadMBps
        self.pingLatencyMilliseconds = pingLatencyMilliseconds
        self.packetLossRatio = packetLossRatio
        self.pingTargetLabel = pingTargetLabel
        self.connectionLabel = connectionLabel
        self.interfaceName = interfaceName
        self.localIP = localIP
        self.subnetMask = subnetMask
        self.router = router
        self.dnsServers = dnsServers
        self.searchDomains = searchDomains
        self.ethernetSpeed = ethernetSpeed
        self.configMethod = configMethod
    }
}

public struct CompanionLivePowerSnapshot: Codable, Hashable, Sendable {
    public let cpuPowerWatts: Double?
    public let gpuPowerWatts: Double?
    public let anePowerWatts: Double?
    public let combinedPowerWatts: Double?
    public let peakCombinedPowerWatts: Double
    public let cumulativeEnergyWh: Double
    public let uptimeSeconds: Double?
    public let processCount: Int?
    public let gpuFrequencyMHz: Double?
    public let perCoreFrequenciesGHz: [Double]
    public let powermetricsText: String?

    public init(
        cpuPowerWatts: Double?,
        gpuPowerWatts: Double?,
        anePowerWatts: Double?,
        combinedPowerWatts: Double?,
        peakCombinedPowerWatts: Double,
        cumulativeEnergyWh: Double,
        uptimeSeconds: Double?,
        processCount: Int?,
        gpuFrequencyMHz: Double?,
        perCoreFrequenciesGHz: [Double],
        powermetricsText: String?
    ) {
        self.cpuPowerWatts = cpuPowerWatts
        self.gpuPowerWatts = gpuPowerWatts
        self.anePowerWatts = anePowerWatts
        self.combinedPowerWatts = combinedPowerWatts
        self.peakCombinedPowerWatts = peakCombinedPowerWatts
        self.cumulativeEnergyWh = cumulativeEnergyWh
        self.uptimeSeconds = uptimeSeconds
        self.processCount = processCount
        self.gpuFrequencyMHz = gpuFrequencyMHz
        self.perCoreFrequenciesGHz = perCoreFrequenciesGHz
        self.powermetricsText = powermetricsText
    }
}

public struct CompanionLiveANESnapshot: Codable, Hashable, Sendable {
    public let activityRatio: Double
    public let currentPowerWatts: Double
    public let peakPowerWatts: Double
    public let clientCount: Int
    public let statusText: String
    public let coreCountText: String
    public let architectureText: String
    public let engineStatusText: String

    public init(
        activityRatio: Double,
        currentPowerWatts: Double,
        peakPowerWatts: Double,
        clientCount: Int,
        statusText: String,
        coreCountText: String,
        architectureText: String,
        engineStatusText: String
    ) {
        self.activityRatio = activityRatio
        self.currentPowerWatts = currentPowerWatts
        self.peakPowerWatts = peakPowerWatts
        self.clientCount = clientCount
        self.statusText = statusText
        self.coreCountText = coreCountText
        self.architectureText = architectureText
        self.engineStatusText = engineStatusText
    }
}

public struct CompanionLiveMediaSnapshot: Codable, Hashable, Sendable {
    public let activityRatio: Double?
    public let activityStateText: String
    public let codec: String?
    public let recentProcessedFrames: Int
    public let retainedSessionCount: Int
    public let recentEncoderPathCount: Int
    public let activeSessionCount: Int
    public let capabilityTitle: String?
    public let supportedEncodeCodecs: [String]
    public let supportedDecodeCodecs: [String]

    public init(
        activityRatio: Double?,
        activityStateText: String,
        codec: String?,
        recentProcessedFrames: Int,
        retainedSessionCount: Int,
        recentEncoderPathCount: Int,
        activeSessionCount: Int,
        capabilityTitle: String?,
        supportedEncodeCodecs: [String],
        supportedDecodeCodecs: [String]
    ) {
        self.activityRatio = activityRatio
        self.activityStateText = activityStateText
        self.codec = codec
        self.recentProcessedFrames = recentProcessedFrames
        self.retainedSessionCount = retainedSessionCount
        self.recentEncoderPathCount = recentEncoderPathCount
        self.activeSessionCount = activeSessionCount
        self.capabilityTitle = capabilityTitle
        self.supportedEncodeCodecs = supportedEncodeCodecs
        self.supportedDecodeCodecs = supportedDecodeCodecs
    }
}

public struct CompanionLiveProcessSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let bundleIdentifier: String?
    public let cpuPercent: Double
    public let ramMB: Double
    public let gpuActive: Bool
    public let gpuDeltaTimeNS: UInt64?
    public let diskReadMBps: Double
    public let diskWriteMBps: Double
    public let uptimeText: String?

    public init(
        processKey: String,
        displayName: String,
        bundleIdentifier: String?,
        cpuPercent: Double,
        ramMB: Double,
        gpuActive: Bool,
        gpuDeltaTimeNS: UInt64?,
        diskReadMBps: Double,
        diskWriteMBps: Double,
        uptimeText: String?
    ) {
        self.id = processKey
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.cpuPercent = cpuPercent
        self.ramMB = ramMB
        self.gpuActive = gpuActive
        self.gpuDeltaTimeNS = gpuDeltaTimeNS
        self.diskReadMBps = diskReadMBps
        self.diskWriteMBps = diskWriteMBps
        self.uptimeText = uptimeText
    }
}

public struct CompanionLiveSnapshot: Codable, Hashable, Sendable {
    public let cpu: CompanionLiveCPUSnapshot
    public let gpus: [CompanionLiveGPUSnapshot]
    public let memory: CompanionLiveMemorySnapshot
    public let storage: CompanionLiveStorageSnapshot
    public let network: CompanionLiveNetworkSnapshot
    public let power: CompanionLivePowerSnapshot
    public let ane: CompanionLiveANESnapshot?
    public let media: CompanionLiveMediaSnapshot?
    public let topProcesses: [CompanionLiveProcessSnapshot]
    public let hardwareInsights: [CompanionKeyValueRow]

    public init(
        cpu: CompanionLiveCPUSnapshot,
        gpus: [CompanionLiveGPUSnapshot],
        memory: CompanionLiveMemorySnapshot,
        storage: CompanionLiveStorageSnapshot,
        network: CompanionLiveNetworkSnapshot,
        power: CompanionLivePowerSnapshot,
        ane: CompanionLiveANESnapshot?,
        media: CompanionLiveMediaSnapshot?,
        topProcesses: [CompanionLiveProcessSnapshot],
        hardwareInsights: [CompanionKeyValueRow]
    ) {
        self.cpu = cpu
        self.gpus = gpus
        self.memory = memory
        self.storage = storage
        self.network = network
        self.power = power
        self.ane = ane
        self.media = media
        self.topProcesses = topProcesses
        self.hardwareInsights = hardwareInsights
    }
}

// MARK: - Payloads

public struct CompanionCurrentSnapshotPayload: Codable, Hashable, Identifiable, Sendable {
    public var id: String { machineIdentity.machineID }
    public let machineIdentity: RemoteMachineIdentity
    public let updatedAt: Date
    public let liveSnapshot: CompanionLiveSnapshot

    public init(
        machineIdentity: RemoteMachineIdentity,
        updatedAt: Date,
        liveSnapshot: CompanionLiveSnapshot
    ) {
        self.machineIdentity = machineIdentity
        self.updatedAt = updatedAt
        self.liveSnapshot = liveSnapshot
    }
}

public struct CompanionTimelineBucket: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(timestamp.timeIntervalSinceReferenceDate)-\(value.map { String($0) } ?? "nil")" }
    public let timestamp: Date
    public let value: Double?

    public init(timestamp: Date, value: Double?) {
        self.timestamp = timestamp
        self.value = value
    }
}

public struct CompanionTimelineSeriesPayload: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let seriesKey: String
    public let tint: CompanionTint
    public let bucketDurationSeconds: Int
    public let points: [CompanionTimelineBucket]
    public let peakValue: Double?

    public init(id: String, label: String, seriesKey: String, tint: CompanionTint, bucketDurationSeconds: Int, points: [CompanionTimelineBucket], peakValue: Double?) {
        self.id = id
        self.label = label
        self.seriesKey = seriesKey
        self.tint = tint
        self.bucketDurationSeconds = bucketDurationSeconds
        self.points = points
        self.peakValue = peakValue
    }
}

public struct CompanionTimelinePayload: Codable, Hashable, Identifiable, Sendable {
    public var id: String { machineID }
    public let machineID: String
    public let title: String
    public let updatedAt: Date
    public let series: [CompanionTimelineSeriesPayload]

    public init(machineID: String, title: String, updatedAt: Date, series: [CompanionTimelineSeriesPayload]) {
        self.machineID = machineID
        self.title = title
        self.updatedAt = updatedAt
        self.series = series
    }
}

public struct CompanionProcessRollupPayload: Codable, Hashable, Identifiable, Sendable {
    public var id: String { machineID }
    public let machineID: String
    public let updatedAt: Date
    public let rows: [CompanionKeyValueRow]

    public init(machineID: String, updatedAt: Date, rows: [CompanionKeyValueRow]) {
        self.machineID = machineID
        self.updatedAt = updatedAt
        self.rows = rows
    }
}

public struct CompanionHardwareEventPayload: Codable, Hashable, Identifiable, Sendable {
    public struct Entry: Codable, Hashable, Identifiable, Sendable {
        public let id: String
        public let timestamp: Date
        public let category: String
        public let severity: Int
        public let title: String
        public let detail: String?

        public init(id: String, timestamp: Date, category: String, severity: Int, title: String, detail: String?) {
            self.id = id
            self.timestamp = timestamp
            self.category = category
            self.severity = severity
            self.title = title
            self.detail = detail
        }
    }

    public var id: String { machineID }
    public let machineID: String
    public let updatedAt: Date
    public let entries: [Entry]

    public init(machineID: String, updatedAt: Date, entries: [Entry]) {
        self.machineID = machineID
        self.updatedAt = updatedAt
        self.entries = entries
    }
}

// MARK: - CloudKit Extensions

extension RemoteMachineIdentity {
    public func makeCloudKitRecord(zoneID: CKRecordZone.ID? = nil) throws -> CKRecord {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)

        let record = CKRecord(
            recordType: CompanionCloudKitSchema.machineIdentityRecordType,
            recordID: CKRecord.ID(
                recordName: CompanionCloudKitSchema.machineIdentityRecordName(for: machineID),
                zoneID: zoneID ?? .default
            )
        )
        record[CompanionCloudKitSchema.machineIDField] = machineID as CKRecordValue
        record[CompanionCloudKitSchema.displayNameField] = displayName as CKRecordValue
        CompanionCloudKitSchema.insertData(data, into: record, field: CompanionCloudKitSchema.payloadDataField)
        return record
    }

    public init?(record: CKRecord) {
        guard let data = CompanionCloudKitSchema.extractData(from: record, field: CompanionCloudKitSchema.payloadDataField) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let identity = try? decoder.decode(Self.self, from: data) else { return nil }
        self = identity
    }
}

extension CompanionDashboardSnapshot {
    public init?(record: CKRecord) {
        guard let data = CompanionCloudKitSchema.extractData(from: record, field: CompanionCloudKitSchema.snapshotDataField) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(Self.self, from: data) else {
            return nil
        }
        self = snapshot
    }

    public func makeCloudKitRecord(zoneID: CKRecordZone.ID? = nil) throws -> CKRecord {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)

        let record = CKRecord(
            recordType: CompanionCloudKitSchema.dashboardRecordType,
            recordID: CKRecord.ID(
                recordName: CompanionCloudKitSchema.dashboardRecordName(for: machineIdentity.machineID),
                zoneID: zoneID ?? .default
            )
        )
        record[CompanionCloudKitSchema.machineIDField] = machineIdentity.machineID as CKRecordValue
        record[CompanionCloudKitSchema.displayNameField] = machineIdentity.displayName as CKRecordValue
        record[CompanionCloudKitSchema.updatedAtField] = updatedAt as CKRecordValue
        CompanionCloudKitSchema.insertData(data, into: record, field: CompanionCloudKitSchema.snapshotDataField)
        return record
    }
}

extension CompanionCurrentSnapshotPayload {
    public init?(record: CKRecord) {
        guard let data = CompanionCloudKitSchema.extractData(from: record, field: CompanionCloudKitSchema.payloadDataField) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Self.self, from: data) else { return nil }
        self = payload
    }

    public func makeCloudKitRecord(zoneID: CKRecordZone.ID? = nil) throws -> CKRecord {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)

        let record = CKRecord(
            recordType: CompanionCloudKitSchema.currentSnapshotRecordType,
            recordID: CKRecord.ID(
                recordName: CompanionCloudKitSchema.currentSnapshotRecordName(for: machineIdentity.machineID),
                zoneID: zoneID ?? .default
            )
        )
        record[CompanionCloudKitSchema.machineIDField] = machineIdentity.machineID as CKRecordValue
        record[CompanionCloudKitSchema.displayNameField] = machineIdentity.displayName as CKRecordValue
        record[CompanionCloudKitSchema.updatedAtField] = updatedAt as CKRecordValue
        CompanionCloudKitSchema.insertData(data, into: record, field: CompanionCloudKitSchema.payloadDataField)
        return record
    }
}

extension CompanionTimelinePayload {
    public init?(record: CKRecord) {
        guard let data = CompanionCloudKitSchema.extractData(from: record, field: CompanionCloudKitSchema.payloadDataField) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Self.self, from: data) else { return nil }
        self = payload
    }

    public func makeCloudKitRecord(recordType: String, zoneID: CKRecordZone.ID? = nil) throws -> CKRecord {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)

        let record = CKRecord(
            recordType: recordType,
            recordID: CKRecord.ID(
                recordName: {
                    switch recordType {
                    case CompanionCloudKitSchema.minuteRollupRecordType:
                        return CompanionCloudKitSchema.minuteRollupRecordName(for: machineID)
                    case CompanionCloudKitSchema.hourlyRollupRecordType:
                        return CompanionCloudKitSchema.hourlyRollupRecordName(for: machineID)
                    default:
                        return "\(machineID).\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"
                    }
                }(),
                zoneID: zoneID ?? .default
            )
        )
        record[CompanionCloudKitSchema.machineIDField] = machineID as CKRecordValue
        record[CompanionCloudKitSchema.displayNameField] = title as CKRecordValue
        record[CompanionCloudKitSchema.updatedAtField] = updatedAt as CKRecordValue
        CompanionCloudKitSchema.insertData(data, into: record, field: CompanionCloudKitSchema.payloadDataField)
        return record
    }
}

extension CompanionProcessRollupPayload {
    public init?(record: CKRecord) {
        guard let data = CompanionCloudKitSchema.extractData(from: record, field: CompanionCloudKitSchema.payloadDataField) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Self.self, from: data) else { return nil }
        self = payload
    }

    public func makeCloudKitRecord(zoneID: CKRecordZone.ID? = nil) throws -> CKRecord {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)

        let record = CKRecord(
            recordType: CompanionCloudKitSchema.processRollupRecordType,
            recordID: CKRecord.ID(
                recordName: CompanionCloudKitSchema.processRollupRecordName(for: machineID),
                zoneID: zoneID ?? .default
            )
        )
        record[CompanionCloudKitSchema.machineIDField] = machineID as CKRecordValue
        record[CompanionCloudKitSchema.updatedAtField] = updatedAt as CKRecordValue
        CompanionCloudKitSchema.insertData(data, into: record, field: CompanionCloudKitSchema.payloadDataField)
        return record
    }
}

extension CompanionHardwareEventPayload {
    public init?(record: CKRecord) {
        guard let data = CompanionCloudKitSchema.extractData(from: record, field: CompanionCloudKitSchema.payloadDataField) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Self.self, from: data) else { return nil }
        self = payload
    }

    public func makeCloudKitRecord(zoneID: CKRecordZone.ID? = nil) throws -> CKRecord {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)

        let record = CKRecord(
            recordType: CompanionCloudKitSchema.hardwareEventRecordType,
            recordID: CKRecord.ID(
                recordName: CompanionCloudKitSchema.hardwareEventRecordName(for: machineID),
                zoneID: zoneID ?? .default
            )
        )
        record[CompanionCloudKitSchema.machineIDField] = machineID as CKRecordValue
        record[CompanionCloudKitSchema.updatedAtField] = updatedAt as CKRecordValue
        CompanionCloudKitSchema.insertData(data, into: record, field: CompanionCloudKitSchema.payloadDataField)
        return record
    }
}
