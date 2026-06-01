import Foundation

public struct HardwareCollectorLiveSnapshot: Codable, Sendable {
    public var status: HardwareCollectorStatusSnapshot
    public var latestTelemetryFrame: HardwareTelemetryFrame
    public var cpu: CPUSamplerLiveSnapshot
    public var thermal: ThermalStatsSamplerLiveSnapshot
    public var gpu: GPUStatsSamplerLiveSnapshot
    public var ram: RAMStatsSamplerLiveSnapshot
    public var storage: StorageStatsSamplerLiveSnapshot
    public var ane: ANEStatsSamplerLiveSnapshot
    public var app: AppStatsSamplerLiveSnapshot
    public var runningApps: RunningAppsSamplerLiveSnapshot
    public var gpuClients: GPUClientsSamplerLiveSnapshot?
    public var diskIO: DiskIOSamplerLiveSnapshot
    public var network: NetworkStatsSamplerLiveSnapshot
    public var networkInterfaceSnapshot: NetworkInterfaceSnapshot?
    public var mediaEngine: MediaEngineStatsSamplerLiveSnapshot
    public var power: PowerStatsSamplerLiveSnapshot

    public init(
        status: HardwareCollectorStatusSnapshot,
        latestTelemetryFrame: HardwareTelemetryFrame,
        cpu: CPUSamplerLiveSnapshot,
        thermal: ThermalStatsSamplerLiveSnapshot,
        gpu: GPUStatsSamplerLiveSnapshot,
        ram: RAMStatsSamplerLiveSnapshot,
        storage: StorageStatsSamplerLiveSnapshot,
        ane: ANEStatsSamplerLiveSnapshot,
        app: AppStatsSamplerLiveSnapshot,
        runningApps: RunningAppsSamplerLiveSnapshot,
        gpuClients: GPUClientsSamplerLiveSnapshot? = nil,
        diskIO: DiskIOSamplerLiveSnapshot,
        network: NetworkStatsSamplerLiveSnapshot,
        networkInterfaceSnapshot: NetworkInterfaceSnapshot? = nil,
        mediaEngine: MediaEngineStatsSamplerLiveSnapshot,
        power: PowerStatsSamplerLiveSnapshot
    ) {
        self.status = status
        self.latestTelemetryFrame = latestTelemetryFrame
        self.cpu = cpu
        self.thermal = thermal
        self.gpu = gpu
        self.ram = ram
        self.storage = storage
        self.ane = ane
        self.app = app
        self.runningApps = runningApps
        self.gpuClients = gpuClients
        self.diskIO = diskIO
        self.network = network
        self.networkInterfaceSnapshot = networkInterfaceSnapshot
        self.mediaEngine = mediaEngine
        self.power = power
    }
}

public struct HardwareCollectorPollingSnapshot: Codable, Sendable {
    public var status: HardwareCollectorStatusSnapshot
    public var latestTelemetryFrame: HardwareTelemetryFrame
    public var cpu: CPUSamplerPollingSnapshot
    public var thermal: ThermalStatsSamplerPollingSnapshot
    public var gpu: GPUStatsSamplerPollingSnapshot
    public var gpuIdentityUnits: [GPUUnitMetadata]?
    public var ram: RAMStatsSamplerPollingSnapshot
    public var memoryIdentityUnit: MemoryUnitMetadata?
    public var storage: StorageStatsSamplerLiveSnapshot
    public var ane: ANEStatsSamplerPollingSnapshot
    public var app: AppStatsSamplerPollingSnapshot
    public var runningApps: RunningAppsSamplerLiveSnapshot
    public var gpuClients: GPUClientsSamplerLiveSnapshot?
    public var diskIO: DiskIOSamplerPollingSnapshot
    public var network: NetworkStatsSamplerPollingSnapshot
    public var networkInterfaceSnapshot: NetworkInterfaceSnapshot?
    public var mediaEngine: MediaEngineStatsSamplerPollingSnapshot
    public var power: PowerStatsSamplerPollingSnapshot

    public init(
        status: HardwareCollectorStatusSnapshot,
        latestTelemetryFrame: HardwareTelemetryFrame,
        cpu: CPUSamplerPollingSnapshot,
        thermal: ThermalStatsSamplerPollingSnapshot,
        gpu: GPUStatsSamplerPollingSnapshot,
        gpuIdentityUnits: [GPUUnitMetadata]? = nil,
        ram: RAMStatsSamplerPollingSnapshot,
        memoryIdentityUnit: MemoryUnitMetadata? = nil,
        storage: StorageStatsSamplerLiveSnapshot,
        ane: ANEStatsSamplerPollingSnapshot,
        app: AppStatsSamplerPollingSnapshot,
        runningApps: RunningAppsSamplerLiveSnapshot,
        gpuClients: GPUClientsSamplerLiveSnapshot? = nil,
        diskIO: DiskIOSamplerPollingSnapshot,
        network: NetworkStatsSamplerPollingSnapshot,
        networkInterfaceSnapshot: NetworkInterfaceSnapshot? = nil,
        mediaEngine: MediaEngineStatsSamplerPollingSnapshot,
        power: PowerStatsSamplerPollingSnapshot
    ) {
        self.status = status
        self.latestTelemetryFrame = latestTelemetryFrame
        self.cpu = cpu
        self.thermal = thermal
        self.gpu = gpu
        self.gpuIdentityUnits = gpuIdentityUnits
        self.ram = ram
        self.memoryIdentityUnit = memoryIdentityUnit
        self.storage = storage
        self.ane = ane
        self.app = app
        self.runningApps = runningApps
        self.gpuClients = gpuClients
        self.diskIO = diskIO
        self.network = network
        self.networkInterfaceSnapshot = networkInterfaceSnapshot
        self.mediaEngine = mediaEngine
        self.power = power
    }
}

public struct HardwareDashboardFrame: Codable, Sendable {
    public var sequenceNumber: UInt64
    public var generatedAt: Date
    public var pollingSnapshot: HardwareCollectorPollingSnapshot

    public init(
        sequenceNumber: UInt64,
        generatedAt: Date,
        pollingSnapshot: HardwareCollectorPollingSnapshot
    ) {
        self.sequenceNumber = sequenceNumber
        self.generatedAt = generatedAt
        self.pollingSnapshot = pollingSnapshot
    }
}

public struct CPUSamplerPollingSnapshot: Codable, Sendable {
    public var coreUsages: [Float]
    public var cpuDisplayName: String
    public var efficiencyCoreCount: Int
    public var performanceCoreCount: Int
    public var latestSnapshot: HardwareSnapshot?

    public init(
        coreUsages: [Float],
        cpuDisplayName: String,
        efficiencyCoreCount: Int,
        performanceCoreCount: Int,
        latestSnapshot: HardwareSnapshot?
    ) {
        self.coreUsages = coreUsages
        self.cpuDisplayName = cpuDisplayName
        self.efficiencyCoreCount = efficiencyCoreCount
        self.performanceCoreCount = performanceCoreCount
        self.latestSnapshot = latestSnapshot
    }
}

public struct ThermalStatsSamplerPollingSnapshot: Codable, Sendable {
    public var latestSnapshot: HardwareSnapshot?

    public init(latestSnapshot: HardwareSnapshot?) {
        self.latestSnapshot = latestSnapshot
    }
}

public struct GPUStatsSamplerPollingSnapshot: Codable, Sendable {
    public var gpus: [GPUStatsSampler.GPUUnit]
    public var latestDeviceSnapshots: [HardwareDeviceSnapshot]
    public var gpuDisplayName: String

    public init(
        gpus: [GPUStatsSampler.GPUUnit],
        latestDeviceSnapshots: [HardwareDeviceSnapshot],
        gpuDisplayName: String
    ) {
        self.gpus = gpus
        self.latestDeviceSnapshots = latestDeviceSnapshots
        self.gpuDisplayName = gpuDisplayName
    }
}

public struct RAMStatsSamplerPollingSnapshot: Codable, Sendable {
    public var latestMemorySnapshot: RAMStatsSampler.MemorySnapshot?
    public var latestSnapshot: HardwareSnapshot?

    public init(
        latestMemorySnapshot: RAMStatsSampler.MemorySnapshot?,
        latestSnapshot: HardwareSnapshot?
    ) {
        self.latestMemorySnapshot = latestMemorySnapshot
        self.latestSnapshot = latestSnapshot
    }
}

public struct ANEStatsSamplerPollingSnapshot: Codable, Sendable {
    public var latestStatusSnapshot: ANEStatsSampler.StatusSnapshot?
    public var latestSnapshot: HardwareSnapshot?

    public init(
        latestStatusSnapshot: ANEStatsSampler.StatusSnapshot?,
        latestSnapshot: HardwareSnapshot?
    ) {
        self.latestStatusSnapshot = latestStatusSnapshot
        self.latestSnapshot = latestSnapshot
    }
}

public struct DiskIOSamplerPollingSnapshot: Codable, Sendable {
    public var latestSnapshot: HardwareSnapshot?

    public init(latestSnapshot: HardwareSnapshot?) {
        self.latestSnapshot = latestSnapshot
    }
}

public struct NetworkStatsSamplerPollingSnapshot: Codable, Sendable {
    public var latestSnapshot: HardwareSnapshot?
    public var sessionUploadMB: Double
    public var sessionDownloadMB: Double
    public var pingTargetLabel: String
    public var pingLatencyMilliseconds: Double?
    public var pingPacketLossRatio: Double?
    public var lastPingSampleDate: Date?

    public init(
        latestSnapshot: HardwareSnapshot?,
        sessionUploadMB: Double,
        sessionDownloadMB: Double,
        pingTargetLabel: String,
        pingLatencyMilliseconds: Double?,
        pingPacketLossRatio: Double?,
        lastPingSampleDate: Date?
    ) {
        self.latestSnapshot = latestSnapshot
        self.sessionUploadMB = sessionUploadMB
        self.sessionDownloadMB = sessionDownloadMB
        self.pingTargetLabel = pingTargetLabel
        self.pingLatencyMilliseconds = pingLatencyMilliseconds
        self.pingPacketLossRatio = pingPacketLossRatio
        self.lastPingSampleDate = lastPingSampleDate
    }
}

public struct MediaEngineStatsSamplerPollingSnapshot: Codable, Sendable {
    public var latestCapabilityState: MediaEngineStatsSampler.CapabilityState?
    public var latestActivitySummary: MediaEngineStatsSampler.ActivitySummary?
    public var recentSessions: [MediaEngineStatsSampler.RecentSession]

    public init(
        latestCapabilityState: MediaEngineStatsSampler.CapabilityState?,
        latestActivitySummary: MediaEngineStatsSampler.ActivitySummary?,
        recentSessions: [MediaEngineStatsSampler.RecentSession] = []
    ) {
        self.latestCapabilityState = latestCapabilityState
        self.latestActivitySummary = latestActivitySummary
        self.recentSessions = recentSessions
    }

    private enum CodingKeys: String, CodingKey {
        case latestCapabilityState
        case latestActivitySummary
        case recentSessions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            latestCapabilityState: try container.decodeIfPresent(MediaEngineStatsSampler.CapabilityState.self, forKey: .latestCapabilityState),
            latestActivitySummary: try container.decodeIfPresent(MediaEngineStatsSampler.ActivitySummary.self, forKey: .latestActivitySummary),
            recentSessions: try container.decodeIfPresent([MediaEngineStatsSampler.RecentSession].self, forKey: .recentSessions) ?? []
        )
    }
}

public struct PowerStatsSamplerPollingSnapshot: Codable, Sendable {
    public var latestSystemSnapshot: PowerStatsSampler.SystemSnapshot?
    public var latestReadingsSnapshot: PowerStatsSampler.ReadingsSnapshot?
    public var latestSnapshot: HardwareSnapshot?
    public var sampleStatus: PowerSampleStatus
    public var lastPowerSampleDate: Date?
    public var lastUsablePowerSampleDate: Date?
    public var source: String?
    public var failureReason: String?
    /// Start of the monitoring window that ``PowerStatsSampler/cumulativeCombinedEnergyWh`` integrates over (collector daemon or in-process collector).
    public var monitoringSessionStartDate: Date?
    /// Uptime of the helper/collector process responsible for the tracked power session.
    public var hardwareAgentUptimeSeconds: TimeInterval?

    public init(
        latestSystemSnapshot: PowerStatsSampler.SystemSnapshot?,
        latestReadingsSnapshot: PowerStatsSampler.ReadingsSnapshot?,
        latestSnapshot: HardwareSnapshot?,
        sampleStatus: PowerSampleStatus = .warmup,
        lastPowerSampleDate: Date? = nil,
        lastUsablePowerSampleDate: Date? = nil,
        source: String? = nil,
        failureReason: String? = nil,
        monitoringSessionStartDate: Date? = nil,
        hardwareAgentUptimeSeconds: TimeInterval? = nil
    ) {
        self.latestSystemSnapshot = latestSystemSnapshot
        self.latestReadingsSnapshot = latestReadingsSnapshot
        self.latestSnapshot = latestSnapshot
        self.sampleStatus = sampleStatus
        self.lastPowerSampleDate = lastPowerSampleDate
        self.lastUsablePowerSampleDate = lastUsablePowerSampleDate
        self.source = source
        self.failureReason = failureReason
        self.monitoringSessionStartDate = monitoringSessionStartDate
        self.hardwareAgentUptimeSeconds = hardwareAgentUptimeSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case latestSystemSnapshot
        case latestReadingsSnapshot
        case latestSnapshot
        case sampleStatus
        case lastPowerSampleDate
        case lastUsablePowerSampleDate
        case source
        case failureReason
        case monitoringSessionStartDate
        case hardwareAgentUptimeSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let readings = try container.decodeIfPresent(PowerStatsSampler.ReadingsSnapshot.self, forKey: .latestReadingsSnapshot)
        self.init(
            latestSystemSnapshot: try container.decodeIfPresent(PowerStatsSampler.SystemSnapshot.self, forKey: .latestSystemSnapshot),
            latestReadingsSnapshot: readings,
            latestSnapshot: try container.decodeIfPresent(HardwareSnapshot.self, forKey: .latestSnapshot),
            sampleStatus: try container.decodeIfPresent(PowerSampleStatus.self, forKey: .sampleStatus)
                ?? readings?.sampleStatus
                ?? .live,
            lastPowerSampleDate: try container.decodeIfPresent(Date.self, forKey: .lastPowerSampleDate) ?? readings?.lastPowerSampleDate,
            lastUsablePowerSampleDate: try container.decodeIfPresent(Date.self, forKey: .lastUsablePowerSampleDate) ?? readings?.lastUsablePowerSampleDate,
            source: try container.decodeIfPresent(String.self, forKey: .source) ?? readings?.source,
            failureReason: try container.decodeIfPresent(String.self, forKey: .failureReason) ?? readings?.failureReason,
            monitoringSessionStartDate: try container.decodeIfPresent(Date.self, forKey: .monitoringSessionStartDate),
            hardwareAgentUptimeSeconds: try container.decodeIfPresent(TimeInterval.self, forKey: .hardwareAgentUptimeSeconds)
        )
    }
}

public struct CPUSamplerLiveSnapshot: Codable, Sendable {
    public var coreUsages: [Float]
    public var totalUsage: Float?
    public var usageHistory: [Float]
    public var cpuDisplayName: String
    public var systemUsage: Float?
    public var userUsage: Float?
    public var idleUsage: Float?
    public var efficiencyUsage: Float?
    public var efficiencyHistory: [Float]
    public var performanceUsage: Float?
    public var performanceHistory: [Float]
    public var efficiencyCoreCount: Int
    public var performanceCoreCount: Int
    public var perCoreUsageSeries: [MetricSeries]
    public var totalUsageSeries: MetricSeries
    public var efficiencyUsageSeries: MetricSeries
    public var performanceUsageSeries: MetricSeries
    public var latestSnapshot: HardwareSnapshot?

    public init(
        coreUsages: [Float],
        totalUsage: Float?,
        usageHistory: [Float],
        cpuDisplayName: String,
        systemUsage: Float?,
        userUsage: Float?,
        idleUsage: Float?,
        efficiencyUsage: Float?,
        efficiencyHistory: [Float],
        performanceUsage: Float?,
        performanceHistory: [Float],
        efficiencyCoreCount: Int,
        performanceCoreCount: Int,
        perCoreUsageSeries: [MetricSeries],
        totalUsageSeries: MetricSeries,
        efficiencyUsageSeries: MetricSeries,
        performanceUsageSeries: MetricSeries,
        latestSnapshot: HardwareSnapshot?
    ) {
        self.coreUsages = coreUsages
        self.totalUsage = totalUsage
        self.usageHistory = usageHistory
        self.cpuDisplayName = cpuDisplayName
        self.systemUsage = systemUsage
        self.userUsage = userUsage
        self.idleUsage = idleUsage
        self.efficiencyUsage = efficiencyUsage
        self.efficiencyHistory = efficiencyHistory
        self.performanceUsage = performanceUsage
        self.performanceHistory = performanceHistory
        self.efficiencyCoreCount = efficiencyCoreCount
        self.performanceCoreCount = performanceCoreCount
        self.perCoreUsageSeries = perCoreUsageSeries
        self.totalUsageSeries = totalUsageSeries
        self.efficiencyUsageSeries = efficiencyUsageSeries
        self.performanceUsageSeries = performanceUsageSeries
        self.latestSnapshot = latestSnapshot
    }
}

public struct ThermalStatsSamplerLiveSnapshot: Codable, Sendable {
    public var thermalValue: Float?
    public var thermalLabel: String
    public var thermalHistory: [Float]
    public var thermalSeries: MetricSeries
    public var latestSnapshot: HardwareSnapshot?

    public init(
        thermalValue: Float?,
        thermalLabel: String,
        thermalHistory: [Float],
        thermalSeries: MetricSeries,
        latestSnapshot: HardwareSnapshot?
    ) {
        self.thermalValue = thermalValue
        self.thermalLabel = thermalLabel
        self.thermalHistory = thermalHistory
        self.thermalSeries = thermalSeries
        self.latestSnapshot = latestSnapshot
    }
}

public struct GPUStatsSamplerLiveSnapshot: Codable, Sendable {
    public var gpus: [GPUStatsSampler.GPUUnit]
    public var usageSeriesByGPU: [String: HardwareDeviceMetricSeries]
    public var rendererSeriesByGPU: [String: HardwareDeviceMetricSeries]
    public var tilerSeriesByGPU: [String: HardwareDeviceMetricSeries]
    public var memoryUsageSeriesByGPU: [String: HardwareDeviceMetricSeries]
    public var latestDeviceSnapshots: [HardwareDeviceSnapshot]
    public var gpuDisplayName: String

    public init(
        gpus: [GPUStatsSampler.GPUUnit],
        usageSeriesByGPU: [String: HardwareDeviceMetricSeries],
        rendererSeriesByGPU: [String: HardwareDeviceMetricSeries],
        tilerSeriesByGPU: [String: HardwareDeviceMetricSeries],
        memoryUsageSeriesByGPU: [String: HardwareDeviceMetricSeries],
        latestDeviceSnapshots: [HardwareDeviceSnapshot],
        gpuDisplayName: String
    ) {
        self.gpus = gpus
        self.usageSeriesByGPU = usageSeriesByGPU
        self.rendererSeriesByGPU = rendererSeriesByGPU
        self.tilerSeriesByGPU = tilerSeriesByGPU
        self.memoryUsageSeriesByGPU = memoryUsageSeriesByGPU
        self.latestDeviceSnapshots = latestDeviceSnapshots
        self.gpuDisplayName = gpuDisplayName
    }
}

public struct RAMStatsSamplerLiveSnapshot: Codable, Sendable {
    public var ramUsage: Float?
    public var usageHistory: [Float]
    public var ramLabel: String?
    public var swapLabel: String
    public var swapUsedRatio: Float
    public var swapUsageHistory: [Float]
    public var swapUsedGB: Double?
    public var swapTotalGB: Double?
    public var cachedFilesLabel: String
    public var compressedLabel: String
    public var wiredLabel: String
    public var appMemoryLabel: String
    public var pressureLabel: String
    public var pressureSubtext: String
    public var pressureValue: Float
    public var pressureHistory: [Float]
    public var usageSeries: MetricSeries
    public var swapUsageSeries: MetricSeries
    public var pressureSeries: MetricSeries
    public var latestMemorySnapshot: RAMStatsSampler.MemorySnapshot?
    public var latestSnapshot: HardwareSnapshot?

    public init(
        ramUsage: Float?,
        usageHistory: [Float],
        ramLabel: String?,
        swapLabel: String,
        swapUsedRatio: Float,
        swapUsageHistory: [Float],
        swapUsedGB: Double?,
        swapTotalGB: Double?,
        cachedFilesLabel: String,
        compressedLabel: String,
        wiredLabel: String,
        appMemoryLabel: String,
        pressureLabel: String,
        pressureSubtext: String,
        pressureValue: Float,
        pressureHistory: [Float],
        usageSeries: MetricSeries,
        swapUsageSeries: MetricSeries,
        pressureSeries: MetricSeries,
        latestMemorySnapshot: RAMStatsSampler.MemorySnapshot?,
        latestSnapshot: HardwareSnapshot?
    ) {
        self.ramUsage = ramUsage
        self.usageHistory = usageHistory
        self.ramLabel = ramLabel
        self.swapLabel = swapLabel
        self.swapUsedRatio = swapUsedRatio
        self.swapUsageHistory = swapUsageHistory
        self.swapUsedGB = swapUsedGB
        self.swapTotalGB = swapTotalGB
        self.cachedFilesLabel = cachedFilesLabel
        self.compressedLabel = compressedLabel
        self.wiredLabel = wiredLabel
        self.appMemoryLabel = appMemoryLabel
        self.pressureLabel = pressureLabel
        self.pressureSubtext = pressureSubtext
        self.pressureValue = pressureValue
        self.pressureHistory = pressureHistory
        self.usageSeries = usageSeries
        self.swapUsageSeries = swapUsageSeries
        self.pressureSeries = pressureSeries
        self.latestMemorySnapshot = latestMemorySnapshot
        self.latestSnapshot = latestSnapshot
    }
}

public struct StorageStatsSamplerLiveSnapshot: Codable, Sendable {
    public var latestCapacitySnapshot: StorageStatsSampler.CapacitySnapshot?
    public var storageLabel: String
    public var storageUsedRatio: Float
    public var storageKindLabel: String
    public var storageSpeedLabel: String
    public var storageHealthLabel: String

    public init(
        latestCapacitySnapshot: StorageStatsSampler.CapacitySnapshot?,
        storageLabel: String,
        storageUsedRatio: Float,
        storageKindLabel: String,
        storageSpeedLabel: String,
        storageHealthLabel: String
    ) {
        self.latestCapacitySnapshot = latestCapacitySnapshot
        self.storageLabel = storageLabel
        self.storageUsedRatio = storageUsedRatio
        self.storageKindLabel = storageKindLabel
        self.storageSpeedLabel = storageSpeedLabel
        self.storageHealthLabel = storageHealthLabel
    }
}

public struct AppStatsSamplerPollingSnapshot: Codable, Sendable {
    public var metrics: AppStatsSampler.Metrics
    public var cpuText: String
    public var memText: String
    public var gpuText: String
    public var readText: String
    public var writeText: String
    public var latestSnapshot: HardwareSnapshot?

    public init(
        metrics: AppStatsSampler.Metrics,
        cpuText: String,
        memText: String,
        gpuText: String,
        readText: String,
        writeText: String,
        latestSnapshot: HardwareSnapshot?
    ) {
        self.metrics = metrics
        self.cpuText = cpuText
        self.memText = memText
        self.gpuText = gpuText
        self.readText = readText
        self.writeText = writeText
        self.latestSnapshot = latestSnapshot
    }
}

public struct ANEStatsSamplerLiveSnapshot: Codable, Sendable {
    public var coreCountText: String
    public var architectureText: String
    public var engineStatusText: String
    public var clientsText: [String]
    public var activityState: ANEStatsSampler.ActivityState
    public var activityValue: Float
    public var activityHistory: [Float]
    public var statusText: String
    public var currentPowerMilliwatts: Double
    public var powerDeltaMilliwatts: Double
    public var peakPowerMilliwatts: Double
    public var peakPowerWattsText: String
    public var powerDeltaWattsText: String
    public var clientCount: Int
    public var activitySeries: MetricSeries
    public var powerSeries: MetricSeries
    public var latestStatusSnapshot: ANEStatsSampler.StatusSnapshot?
    public var latestSnapshot: HardwareSnapshot?

    public init(
        coreCountText: String,
        architectureText: String,
        engineStatusText: String,
        clientsText: [String],
        activityState: ANEStatsSampler.ActivityState,
        activityValue: Float,
        activityHistory: [Float],
        statusText: String,
        currentPowerMilliwatts: Double,
        powerDeltaMilliwatts: Double,
        peakPowerMilliwatts: Double,
        peakPowerWattsText: String,
        powerDeltaWattsText: String,
        clientCount: Int,
        activitySeries: MetricSeries,
        powerSeries: MetricSeries,
        latestStatusSnapshot: ANEStatsSampler.StatusSnapshot?,
        latestSnapshot: HardwareSnapshot?
    ) {
        self.coreCountText = coreCountText
        self.architectureText = architectureText
        self.engineStatusText = engineStatusText
        self.clientsText = clientsText
        self.activityState = activityState
        self.activityValue = activityValue
        self.activityHistory = activityHistory
        self.statusText = statusText
        self.currentPowerMilliwatts = currentPowerMilliwatts
        self.powerDeltaMilliwatts = powerDeltaMilliwatts
        self.peakPowerMilliwatts = peakPowerMilliwatts
        self.peakPowerWattsText = peakPowerWattsText
        self.powerDeltaWattsText = powerDeltaWattsText
        self.clientCount = clientCount
        self.activitySeries = activitySeries
        self.powerSeries = powerSeries
        self.latestStatusSnapshot = latestStatusSnapshot
        self.latestSnapshot = latestSnapshot
    }
}

public struct AppStatsSamplerLiveSnapshot: Codable, Sendable {
    public var metrics: AppStatsSampler.Metrics
    public var cpuText: String
    public var memText: String
    public var gpuText: String
    public var readText: String
    public var writeText: String
    public var cpuSeries: MetricSeries
    public var memorySeries: MetricSeries
    public var gpuSeries: MetricSeries
    public var readSeries: MetricSeries
    public var writeSeries: MetricSeries

    public init(
        metrics: AppStatsSampler.Metrics,
        cpuText: String,
        memText: String,
        gpuText: String,
        readText: String,
        writeText: String,
        cpuSeries: MetricSeries,
        memorySeries: MetricSeries,
        gpuSeries: MetricSeries,
        readSeries: MetricSeries,
        writeSeries: MetricSeries
    ) {
        self.metrics = metrics
        self.cpuText = cpuText
        self.memText = memText
        self.gpuText = gpuText
        self.readText = readText
        self.writeText = writeText
        self.cpuSeries = cpuSeries
        self.memorySeries = memorySeries
        self.gpuSeries = gpuSeries
        self.readSeries = readSeries
        self.writeSeries = writeSeries
    }

    private enum CodingKeys: String, CodingKey {
        case metrics
        case cpuText
        case memText
        case gpuText
        case readText
        case writeText
        case cpuSeries
        case memorySeries
        case gpuSeries
        case readSeries
        case writeSeries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metrics = try container.decodeIfPresent(AppStatsSampler.Metrics.self, forKey: .metrics) ?? AppStatsSampler.Metrics()
        cpuText = try container.decodeIfPresent(String.self, forKey: .cpuText) ?? metrics.cpuText
        memText = try container.decodeIfPresent(String.self, forKey: .memText) ?? metrics.memText
        gpuText = try container.decodeIfPresent(String.self, forKey: .gpuText) ?? metrics.gpuText
        readText = try container.decodeIfPresent(String.self, forKey: .readText) ?? metrics.diskReadText
        writeText = try container.decodeIfPresent(String.self, forKey: .writeText) ?? metrics.diskWriteText
        cpuSeries = try container.decodeIfPresent(MetricSeries.self, forKey: .cpuSeries)
            ?? MetricSeries(key: .appCPUUsageRatio, unit: .ratio)
        memorySeries = try container.decodeIfPresent(MetricSeries.self, forKey: .memorySeries)
            ?? MetricSeries(key: .appMemoryGB, unit: .gigabytes)
        gpuSeries = try container.decodeIfPresent(MetricSeries.self, forKey: .gpuSeries)
            ?? MetricSeries(key: .appGPUUsageRatio, unit: .ratio)
        readSeries = try container.decodeIfPresent(MetricSeries.self, forKey: .readSeries)
            ?? MetricSeries(key: .appDiskReadMBps, unit: .megabytesPerSecond)
        writeSeries = try container.decodeIfPresent(MetricSeries.self, forKey: .writeSeries)
            ?? MetricSeries(key: .appDiskWriteMBps, unit: .megabytesPerSecond)
    }
}

public struct RunningAppsSamplerLiveSnapshot: Codable, Sendable {
    public var topRows: [RunningAppsSampler.Row]

    public init(topRows: [RunningAppsSampler.Row]) {
        self.topRows = topRows
    }
}

public struct DiskIOSamplerLiveSnapshot: Codable, Sendable {
    public var readMBps: Float?
    public var writeMBps: Float?
    public var readText: String
    public var writeText: String
    public var readPeakText: String
    public var writePeakText: String
    public var readHistory: [Float]
    public var writeHistory: [Float]
    public var readSeries: MetricSeries
    public var writeSeries: MetricSeries
    public var latestSnapshot: HardwareSnapshot?

    public init(
        readMBps: Float?,
        writeMBps: Float?,
        readText: String,
        writeText: String,
        readPeakText: String,
        writePeakText: String,
        readHistory: [Float],
        writeHistory: [Float],
        readSeries: MetricSeries,
        writeSeries: MetricSeries,
        latestSnapshot: HardwareSnapshot?
    ) {
        self.readMBps = readMBps
        self.writeMBps = writeMBps
        self.readText = readText
        self.writeText = writeText
        self.readPeakText = readPeakText
        self.writePeakText = writePeakText
        self.readHistory = readHistory
        self.writeHistory = writeHistory
        self.readSeries = readSeries
        self.writeSeries = writeSeries
        self.latestSnapshot = latestSnapshot
    }
}

public struct NetworkStatsSamplerLiveSnapshot: Codable, Sendable {
    public var uploadMBps: Float?
    public var downloadMBps: Float?
    public var uploadText: String
    public var downloadText: String
    public var uploadPeakText: String
    public var downloadPeakText: String
    public var uploadHistory: [Float]
    public var downloadHistory: [Float]
    public var pingLatencyHistory: [Float]
    public var pingPacketLossHistory: [Float]
    public var uploadSeries: MetricSeries
    public var downloadSeries: MetricSeries
    public var pingLatencySeries: MetricSeries
    public var pingPacketLossSeries: MetricSeries
    public var latestSnapshot: HardwareSnapshot?
    public var sessionUploadMB: Double
    public var sessionDownloadMB: Double
    public var pingTargetLabel: String
    public var pingLatencyMilliseconds: Double?
    public var pingPacketLossRatio: Double?
    public var pingLatencyText: String
    public var pingPacketLossText: String
    public var lastPingSampleDate: Date?

    public init(
        uploadMBps: Float?,
        downloadMBps: Float?,
        uploadText: String,
        downloadText: String,
        uploadPeakText: String,
        downloadPeakText: String,
        uploadHistory: [Float],
        downloadHistory: [Float],
        pingLatencyHistory: [Float],
        pingPacketLossHistory: [Float],
        uploadSeries: MetricSeries,
        downloadSeries: MetricSeries,
        pingLatencySeries: MetricSeries,
        pingPacketLossSeries: MetricSeries,
        latestSnapshot: HardwareSnapshot?,
        sessionUploadMB: Double,
        sessionDownloadMB: Double,
        pingTargetLabel: String,
        pingLatencyMilliseconds: Double?,
        pingPacketLossRatio: Double?,
        pingLatencyText: String,
        pingPacketLossText: String,
        lastPingSampleDate: Date?
    ) {
        self.uploadMBps = uploadMBps
        self.downloadMBps = downloadMBps
        self.uploadText = uploadText
        self.downloadText = downloadText
        self.uploadPeakText = uploadPeakText
        self.downloadPeakText = downloadPeakText
        self.uploadHistory = uploadHistory
        self.downloadHistory = downloadHistory
        self.pingLatencyHistory = pingLatencyHistory
        self.pingPacketLossHistory = pingPacketLossHistory
        self.uploadSeries = uploadSeries
        self.downloadSeries = downloadSeries
        self.pingLatencySeries = pingLatencySeries
        self.pingPacketLossSeries = pingPacketLossSeries
        self.latestSnapshot = latestSnapshot
        self.sessionUploadMB = sessionUploadMB
        self.sessionDownloadMB = sessionDownloadMB
        self.pingTargetLabel = pingTargetLabel
        self.pingLatencyMilliseconds = pingLatencyMilliseconds
        self.pingPacketLossRatio = pingPacketLossRatio
        self.pingLatencyText = pingLatencyText
        self.pingPacketLossText = pingPacketLossText
        self.lastPingSampleDate = lastPingSampleDate
    }
}

public struct MediaEngineStatsSamplerLiveSnapshot: Codable, Sendable {
    public var isSupported: Bool
    public var hasEverDetectedSupport: Bool
    public var shouldShowCard: Bool
    public var isActive: Bool
    public var supportsEncode: Bool
    public var supportsDecode: Bool
    public var supportedCodecsText: String
    public var latestCapabilityState: MediaEngineStatsSampler.CapabilityState?
    public var subtitleText: String
    public var statusText: String
    public var codecText: String
    public var framesProcessedText: String
    public var sessionsText: String
    public var lastActiveText: String
    public var latestActivitySummary: MediaEngineStatsSampler.ActivitySummary?
    public var recentSessions: [MediaEngineStatsSampler.RecentSession]
    public var activityState: MediaEngineStatsSampler.ActivityState
    public var activityValue: Float
    public var activityHistory: [Float]
    public var activitySeries: MetricSeries

    public init(
        isSupported: Bool,
        hasEverDetectedSupport: Bool,
        shouldShowCard: Bool,
        isActive: Bool,
        supportsEncode: Bool,
        supportsDecode: Bool,
        supportedCodecsText: String,
        latestCapabilityState: MediaEngineStatsSampler.CapabilityState?,
        subtitleText: String,
        statusText: String,
        codecText: String,
        framesProcessedText: String,
        sessionsText: String,
        lastActiveText: String,
        latestActivitySummary: MediaEngineStatsSampler.ActivitySummary?,
        recentSessions: [MediaEngineStatsSampler.RecentSession],
        activityState: MediaEngineStatsSampler.ActivityState,
        activityValue: Float,
        activityHistory: [Float],
        activitySeries: MetricSeries
    ) {
        self.isSupported = isSupported
        self.hasEverDetectedSupport = hasEverDetectedSupport
        self.shouldShowCard = shouldShowCard
        self.isActive = isActive
        self.supportsEncode = supportsEncode
        self.supportsDecode = supportsDecode
        self.supportedCodecsText = supportedCodecsText
        self.latestCapabilityState = latestCapabilityState
        self.subtitleText = subtitleText
        self.statusText = statusText
        self.codecText = codecText
        self.framesProcessedText = framesProcessedText
        self.sessionsText = sessionsText
        self.lastActiveText = lastActiveText
        self.latestActivitySummary = latestActivitySummary
        self.recentSessions = recentSessions
        self.activityState = activityState
        self.activityValue = activityValue
        self.activityHistory = activityHistory
        self.activitySeries = activitySeries
    }

    private enum CodingKeys: String, CodingKey {
        case isSupported
        case hasEverDetectedSupport
        case shouldShowCard
        case isActive
        case supportsEncode
        case supportsDecode
        case supportedCodecsText
        case latestCapabilityState
        case subtitleText
        case statusText
        case codecText
        case framesProcessedText
        case sessionsText
        case lastActiveText
        case latestActivitySummary
        case recentSessions
        case activityState
        case activityValue
        case activityHistory
        case activitySeries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isSupported: try container.decodeIfPresent(Bool.self, forKey: .isSupported) ?? false,
            hasEverDetectedSupport: try container.decodeIfPresent(Bool.self, forKey: .hasEverDetectedSupport) ?? false,
            shouldShowCard: try container.decodeIfPresent(Bool.self, forKey: .shouldShowCard) ?? false,
            isActive: try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false,
            supportsEncode: try container.decodeIfPresent(Bool.self, forKey: .supportsEncode) ?? false,
            supportsDecode: try container.decodeIfPresent(Bool.self, forKey: .supportsDecode) ?? false,
            supportedCodecsText: try container.decodeIfPresent(String.self, forKey: .supportedCodecsText) ?? "—",
            latestCapabilityState: try container.decodeIfPresent(MediaEngineStatsSampler.CapabilityState.self, forKey: .latestCapabilityState),
            subtitleText: try container.decodeIfPresent(String.self, forKey: .subtitleText) ?? "Hardware media path detected",
            statusText: try container.decodeIfPresent(String.self, forKey: .statusText) ?? "Idle",
            codecText: try container.decodeIfPresent(String.self, forKey: .codecText) ?? "—",
            framesProcessedText: try container.decodeIfPresent(String.self, forKey: .framesProcessedText) ?? "—",
            sessionsText: try container.decodeIfPresent(String.self, forKey: .sessionsText) ?? "—",
            lastActiveText: try container.decodeIfPresent(String.self, forKey: .lastActiveText) ?? "—",
            latestActivitySummary: try container.decodeIfPresent(MediaEngineStatsSampler.ActivitySummary.self, forKey: .latestActivitySummary),
            recentSessions: try container.decodeIfPresent([MediaEngineStatsSampler.RecentSession].self, forKey: .recentSessions) ?? [],
            activityState: try container.decodeIfPresent(MediaEngineStatsSampler.ActivityState.self, forKey: .activityState) ?? .idle,
            activityValue: try container.decodeIfPresent(Float.self, forKey: .activityValue) ?? 0.0,
            activityHistory: try container.decodeIfPresent([Float].self, forKey: .activityHistory) ?? [],
            activitySeries: try container.decodeIfPresent(MetricSeries.self, forKey: .activitySeries) ?? MetricSeries(key: .mediaEngineActivityRatio, unit: .ratio)
        )
    }
}

public struct PowerStatsSamplerLiveSnapshot: Codable, Sendable {
    public var uptimeText: String
    public var batteryPercent: Int?
    public var cycleCount: Int?
    public var processCount: Int?
    public var cpuPowerWattsText: String
    public var gpuPowerWattsText: String
    public var anePowerWattsText: String
    public var combinedPowerWattsText: String
    public var peakCombinedPowerWattsText: String
    public var cumulativeCombinedEnergyText: String
    public var cumulativeCombinedEnergyWh: Double
    public var gpuFrequencyMHzText: String
    public var perCoreFrequenciesHz: [Double]
    public var perCoreFrequencySeries: [MetricSeries]
    public var livePowerReadingsText: String
    public var anePowerMilliwatts: Double?
    public var sampleStatus: PowerSampleStatus
    public var lastPowerSampleDate: Date?
    public var lastUsablePowerSampleDate: Date?
    public var source: String?
    public var failureReason: String?
    public var latestSystemSnapshot: PowerStatsSampler.SystemSnapshot?
    public var latestReadingsSnapshot: PowerStatsSampler.ReadingsSnapshot?
    public var cpuPowerSeries: MetricSeries
    public var gpuPowerSeries: MetricSeries
    public var anePowerSeries: MetricSeries
    public var combinedPowerSeries: MetricSeries
    public var cumulativeEnergySeries: MetricSeries
    public var gpuFrequencySeries: MetricSeries
    public var latestSnapshot: HardwareSnapshot?
    /// Same semantic as ``PowerStatsSamplerPollingSnapshot/monitoringSessionStartDate``; required for session-average power from tracked Wh.
    public var monitoringSessionStartDate: Date?
    /// Uptime of the helper/collector process responsible for the tracked power session.
    public var hardwareAgentUptimeSeconds: TimeInterval?

    public init(
        uptimeText: String,
        batteryPercent: Int?,
        cycleCount: Int?,
        processCount: Int?,
        cpuPowerWattsText: String,
        gpuPowerWattsText: String,
        anePowerWattsText: String,
        combinedPowerWattsText: String,
        peakCombinedPowerWattsText: String,
        cumulativeCombinedEnergyText: String,
        cumulativeCombinedEnergyWh: Double,
        gpuFrequencyMHzText: String,
        perCoreFrequenciesHz: [Double],
        perCoreFrequencySeries: [MetricSeries],
        livePowerReadingsText: String,
        anePowerMilliwatts: Double?,
        sampleStatus: PowerSampleStatus = .warmup,
        lastPowerSampleDate: Date? = nil,
        lastUsablePowerSampleDate: Date? = nil,
        source: String? = nil,
        failureReason: String? = nil,
        latestSystemSnapshot: PowerStatsSampler.SystemSnapshot?,
        latestReadingsSnapshot: PowerStatsSampler.ReadingsSnapshot?,
        cpuPowerSeries: MetricSeries,
        gpuPowerSeries: MetricSeries,
        anePowerSeries: MetricSeries,
        combinedPowerSeries: MetricSeries,
        cumulativeEnergySeries: MetricSeries,
        gpuFrequencySeries: MetricSeries,
        latestSnapshot: HardwareSnapshot?,
        monitoringSessionStartDate: Date? = nil,
        hardwareAgentUptimeSeconds: TimeInterval? = nil
    ) {
        self.uptimeText = uptimeText
        self.batteryPercent = batteryPercent
        self.cycleCount = cycleCount
        self.processCount = processCount
        self.cpuPowerWattsText = cpuPowerWattsText
        self.gpuPowerWattsText = gpuPowerWattsText
        self.anePowerWattsText = anePowerWattsText
        self.combinedPowerWattsText = combinedPowerWattsText
        self.peakCombinedPowerWattsText = peakCombinedPowerWattsText
        self.cumulativeCombinedEnergyText = cumulativeCombinedEnergyText
        self.cumulativeCombinedEnergyWh = cumulativeCombinedEnergyWh
        self.gpuFrequencyMHzText = gpuFrequencyMHzText
        self.perCoreFrequenciesHz = perCoreFrequenciesHz
        self.perCoreFrequencySeries = perCoreFrequencySeries
        self.livePowerReadingsText = livePowerReadingsText
        self.anePowerMilliwatts = anePowerMilliwatts
        self.sampleStatus = sampleStatus
        self.lastPowerSampleDate = lastPowerSampleDate
        self.lastUsablePowerSampleDate = lastUsablePowerSampleDate
        self.source = source
        self.failureReason = failureReason
        self.latestSystemSnapshot = latestSystemSnapshot
        self.latestReadingsSnapshot = latestReadingsSnapshot
        self.cpuPowerSeries = cpuPowerSeries
        self.gpuPowerSeries = gpuPowerSeries
        self.anePowerSeries = anePowerSeries
        self.combinedPowerSeries = combinedPowerSeries
        self.cumulativeEnergySeries = cumulativeEnergySeries
        self.gpuFrequencySeries = gpuFrequencySeries
        self.latestSnapshot = latestSnapshot
        self.monitoringSessionStartDate = monitoringSessionStartDate
        self.hardwareAgentUptimeSeconds = hardwareAgentUptimeSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case uptimeText
        case batteryPercent
        case cycleCount
        case processCount
        case cpuPowerWattsText
        case gpuPowerWattsText
        case anePowerWattsText
        case combinedPowerWattsText
        case peakCombinedPowerWattsText
        case cumulativeCombinedEnergyText
        case cumulativeCombinedEnergyWh
        case gpuFrequencyMHzText
        case perCoreFrequenciesHz
        case perCoreFrequencySeries
        case livePowerReadingsText
        case anePowerMilliwatts
        case sampleStatus
        case lastPowerSampleDate
        case lastUsablePowerSampleDate
        case source
        case failureReason
        case latestSystemSnapshot
        case latestReadingsSnapshot
        case cpuPowerSeries
        case gpuPowerSeries
        case anePowerSeries
        case combinedPowerSeries
        case cumulativeEnergySeries
        case gpuFrequencySeries
        case latestSnapshot
        case monitoringSessionStartDate
        case hardwareAgentUptimeSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let readings = try container.decodeIfPresent(PowerStatsSampler.ReadingsSnapshot.self, forKey: .latestReadingsSnapshot)
        self.init(
            uptimeText: try container.decodeIfPresent(String.self, forKey: .uptimeText) ?? "—",
            batteryPercent: try container.decodeIfPresent(Int.self, forKey: .batteryPercent),
            cycleCount: try container.decodeIfPresent(Int.self, forKey: .cycleCount),
            processCount: try container.decodeIfPresent(Int.self, forKey: .processCount),
            cpuPowerWattsText: try container.decodeIfPresent(String.self, forKey: .cpuPowerWattsText) ?? readings?.cpuPowerWattsText ?? "—",
            gpuPowerWattsText: try container.decodeIfPresent(String.self, forKey: .gpuPowerWattsText) ?? readings?.gpuPowerWattsText ?? "—",
            anePowerWattsText: try container.decodeIfPresent(String.self, forKey: .anePowerWattsText) ?? readings?.anePowerWattsText ?? "—",
            combinedPowerWattsText: try container.decodeIfPresent(String.self, forKey: .combinedPowerWattsText) ?? readings?.combinedPowerWattsText ?? "—",
            peakCombinedPowerWattsText: try container.decodeIfPresent(String.self, forKey: .peakCombinedPowerWattsText) ?? readings?.peakCombinedPowerWattsText ?? "—",
            cumulativeCombinedEnergyText: try container.decodeIfPresent(String.self, forKey: .cumulativeCombinedEnergyText) ?? readings?.cumulativeCombinedEnergyText ?? "—",
            cumulativeCombinedEnergyWh: try container.decodeIfPresent(Double.self, forKey: .cumulativeCombinedEnergyWh) ?? readings?.cumulativeCombinedEnergyWh ?? 0,
            gpuFrequencyMHzText: try container.decodeIfPresent(String.self, forKey: .gpuFrequencyMHzText) ?? readings?.gpuFrequencyMHzText ?? "—",
            perCoreFrequenciesHz: try container.decodeIfPresent([Double].self, forKey: .perCoreFrequenciesHz) ?? readings?.perCoreFrequenciesHz ?? [],
            perCoreFrequencySeries: try container.decodeIfPresent([MetricSeries].self, forKey: .perCoreFrequencySeries) ?? [],
            livePowerReadingsText: try container.decodeIfPresent(String.self, forKey: .livePowerReadingsText) ?? readings?.livePowerReadingsText ?? "—",
            anePowerMilliwatts: try container.decodeIfPresent(Double.self, forKey: .anePowerMilliwatts) ?? readings?.anePowerMilliwatts,
            sampleStatus: try container.decodeIfPresent(PowerSampleStatus.self, forKey: .sampleStatus) ?? readings?.sampleStatus ?? .live,
            lastPowerSampleDate: try container.decodeIfPresent(Date.self, forKey: .lastPowerSampleDate) ?? readings?.lastPowerSampleDate,
            lastUsablePowerSampleDate: try container.decodeIfPresent(Date.self, forKey: .lastUsablePowerSampleDate) ?? readings?.lastUsablePowerSampleDate,
            source: try container.decodeIfPresent(String.self, forKey: .source) ?? readings?.source,
            failureReason: try container.decodeIfPresent(String.self, forKey: .failureReason) ?? readings?.failureReason,
            latestSystemSnapshot: try container.decodeIfPresent(PowerStatsSampler.SystemSnapshot.self, forKey: .latestSystemSnapshot),
            latestReadingsSnapshot: readings,
            cpuPowerSeries: try container.decodeIfPresent(MetricSeries.self, forKey: .cpuPowerSeries) ?? MetricSeries(key: .cpuPowerWatts, unit: .watts),
            gpuPowerSeries: try container.decodeIfPresent(MetricSeries.self, forKey: .gpuPowerSeries) ?? MetricSeries(key: .gpuPowerWatts, unit: .watts),
            anePowerSeries: try container.decodeIfPresent(MetricSeries.self, forKey: .anePowerSeries) ?? MetricSeries(key: .anePowerWatts, unit: .watts),
            combinedPowerSeries: try container.decodeIfPresent(MetricSeries.self, forKey: .combinedPowerSeries) ?? MetricSeries(key: .combinedPowerWatts, unit: .watts),
            cumulativeEnergySeries: try container.decodeIfPresent(MetricSeries.self, forKey: .cumulativeEnergySeries) ?? MetricSeries(key: .cumulativeCombinedEnergyWh, unit: .wattHours),
            gpuFrequencySeries: try container.decodeIfPresent(MetricSeries.self, forKey: .gpuFrequencySeries) ?? MetricSeries(key: .gpuFrequencyMHz, unit: .megahertz),
            latestSnapshot: try container.decodeIfPresent(HardwareSnapshot.self, forKey: .latestSnapshot),
            monitoringSessionStartDate: try container.decodeIfPresent(Date.self, forKey: .monitoringSessionStartDate),
            hardwareAgentUptimeSeconds: try container.decodeIfPresent(TimeInterval.self, forKey: .hardwareAgentUptimeSeconds)
        )
    }
}
