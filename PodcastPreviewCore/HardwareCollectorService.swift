#if os(macOS)
//
//  HardwareCollectorService.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 24/03/2026.
//

import Foundation
import Darwin
import IOKit.ps

struct HardwareDashboardFrameSignature: Equatable {
    let values: [String]

    init(snapshot: HardwareCollectorPollingSnapshot) {
        var values: [String] = []

        func append(_ key: String, _ value: String?) {
            values.append("\(key)=\(value ?? "nil")")
        }

        func append(_ key: String, _ value: Double?) {
            append(key, value.map { String(format: "%.6f", $0) })
        }

        func append(_ key: String, _ value: UInt64?) {
            append(key, value.map(String.init))
        }

        func append(_ key: String, _ value: Int?) {
            append(key, value.map(String.init))
        }

        func append(_ key: String, _ value: Int64?) {
            append(key, value.map(String.init))
        }

        func append(_ key: String, _ value: Float?) {
            append(key, value.map { String(format: "%.6f", Double($0)) })
        }

        func append(_ key: String, _ value: Date?) {
            append(key, value.map { String(format: "%.3f", $0.timeIntervalSinceReferenceDate) })
        }

        func append(_ key: String, _ value: Bool?) {
            append(key, value.map { $0 ? "true" : "false" })
        }

        append("active", snapshot.status.isMonitoringActive)
        append("profile", snapshot.status.activeProfile.rawValue)
        append("collectorInterval", snapshot.status.collectorIntervalSeconds)
        append("telemetry", snapshot.latestTelemetryFrame.timestamp)
        append("cpu", snapshot.cpu.latestSnapshot?.timestamp)
        append("thermal", snapshot.thermal.latestSnapshot?.timestamp)
        append("ram", snapshot.ram.latestSnapshot?.timestamp)
        append("ane", snapshot.ane.latestSnapshot?.timestamp)
        append("diskIO", snapshot.diskIO.latestSnapshot?.timestamp)
        append("network", snapshot.network.latestSnapshot?.timestamp)
        append("mediaEngineSessions", snapshot.mediaEngine.recentSessions.count)

        let storage = snapshot.storage.latestCapacitySnapshot
        append("storage.free", storage?.freeBytes)
        append("storage.used", storage?.usedBytes)
        append("storage.total", storage?.totalBytes)
        append("storage.label", snapshot.storage.storageLabel)
        append("storage.kind", snapshot.storage.storageKindLabel)
        append("storage.speed", snapshot.storage.storageSpeedLabel)
        append("storage.health", snapshot.storage.storageHealthLabel)

        let appMetrics = snapshot.app.metrics
        append("app.cpu", appMetrics.cpuPercent)
        append("app.memory", appMetrics.residentMemoryBytes)
        append("app.gpu", appMetrics.gpuPercent)
        append("app.read", appMetrics.diskReadMBps)
        append("app.write", appMetrics.diskWriteMBps)
        append("app.snapshot", snapshot.app.latestSnapshot?.timestamp)
        append("app.cpuText", snapshot.app.cpuText)
        append("app.memText", snapshot.app.memText)
        append("app.gpuText", snapshot.app.gpuText)
        append("app.readText", snapshot.app.readText)
        append("app.writeText", snapshot.app.writeText)

        append("running.count", snapshot.runningApps.topRows.count)
        for row in snapshot.runningApps.topRows.prefix(10) {
            values.append([
                "running",
                String(row.pid),
                row.name,
                String(format: "%.3f", row.cpuPercent),
                String(format: "%.3f", row.ramMB),
                String(format: "%.3f", row.diskReadMBps),
                String(format: "%.3f", row.diskWriteMBps)
            ].joined(separator: ":"))
        }

        append("gpuClient.count", snapshot.gpuClients?.activeApps.count)
        if let gpuClients = snapshot.gpuClients {
            for app in gpuClients.activeApps.prefix(10) {
                values.append([
                    "gpuClient",
                    String(app.pid),
                    app.name,
                    String(app.gpuTimeNS),
                    app.gpuDeltaTimeNS.map(String.init) ?? "nil",
                    app.isActive ? "active" : "idle"
                ].joined(separator: ":"))
            }
        }

        append("gpuIdentity.count", snapshot.gpuIdentityUnits?.count)
        if let gpuIdentityUnits = snapshot.gpuIdentityUnits {
            for unit in gpuIdentityUnits.prefix(8) {
                let coreCount = unit.coreCount.map(String.init) ?? "nil"
                let displayCount = unit.connectedDisplayCount.map(String.init) ?? "nil"
                let parts: [String] = [
                    "gpuIdentity",
                    unit.id,
                    unit.name ?? "nil",
                    unit.vendor ?? "nil",
                    unit.bus ?? "nil",
                    unit.gpuType ?? "nil",
                    unit.metalFamily ?? "nil",
                    coreCount,
                    unit.vramDescription ?? "nil",
                    displayCount
                ]
                values.append(parts.joined(separator: ":"))
            }
        }

        let memoryIdentity = snapshot.memoryIdentityUnit
        append("memoryIdentity.id", memoryIdentity?.id)
        append("memoryIdentity.total", memoryIdentity?.totalMemory)
        append("memoryIdentity.arch", memoryIdentity?.architecture)
        append("memoryIdentity.type", memoryIdentity?.type)
        append("memoryIdentity.speed", memoryIdentity?.speed)
        append("memoryIdentity.chip", memoryIdentity?.chip)
        append("memoryIdentity.model", memoryIdentity?.machineModel)

        let networkInterface = snapshot.networkInterfaceSnapshot
        append("networkInterface.ip", networkInterface?.ipv4Address)
        append("networkInterface.router", networkInterface?.routerAddress)
        append("networkInterface.name", networkInterface?.interfaceName)
        append("networkInterface.vpn", networkInterface?.isVPNActive)

        let system = snapshot.power.latestSystemSnapshot
        append("power.uptime", system?.uptimeSeconds)
        append("power.battery", system?.batteryPercent)
        append("power.cycles", system?.cycleCount)
        append("power.processes", system?.processCount)

        let readings = snapshot.power.latestReadingsSnapshot
        append("power.status", (readings?.sampleStatus ?? snapshot.power.sampleStatus).rawValue)
        append("power.cpu", readings?.cpuPowerWatts)
        append("power.gpu", readings?.gpuPowerWatts)
        append("power.ane", readings?.anePowerWatts)
        append("power.combined", readings?.combinedPowerWatts)
        append("power.energy", readings?.cumulativeCombinedEnergyWh)
        append("power.gpuMHz", readings?.gpuFrequencyMHz)
        append("power.last", readings?.lastPowerSampleDate ?? snapshot.power.lastPowerSampleDate)
        append("power.lastUsable", readings?.lastUsablePowerSampleDate ?? snapshot.power.lastUsablePowerSampleDate)
        append("power.source", readings?.source ?? snapshot.power.source)
        append("power.failure", readings?.failureReason ?? snapshot.power.failureReason)

        self.values = values
    }
}

@MainActor
public final class HardwareStatsDemandToken {
    private var invalidationHandler: (() -> Void)?

    public init(_ invalidationHandler: @escaping () -> Void) {
        self.invalidationHandler = invalidationHandler
    }

    public func invalidate() {
        guard let invalidationHandler else { return }
        self.invalidationHandler = nil
        invalidationHandler()
    }

    deinit {
        invalidationHandler?()
    }
}

@MainActor
public final class HardwareCollectorService {
    public let cpuSampler: CPUStatsSampler
    public let thermalSampler: ThermalStatsSampler
    public let gpuSampler: GPUStatsSampler
    public let gpuIdentityProber: GPUIdentityProber
    public let memoryIdentityProber: MemoryIdentityProber
    public let ramSampler: RAMStatsSampler
    public let storageSampler: StorageStatsSampler
    public let aneSampler: ANEStatsSampler
    public let appSampler: AppStatsSampler
    public let runningAppsSampler: RunningAppsSampler
    public let gpuClientsSampler: GPUClientsSampler
    public let diskIOSampler: DiskIOSampler
    public let networkSampler: NetworkStatsSampler
    public let networkInterfaceSampler: NetworkInterfaceSampler
    public let mediaEngineSampler: MediaEngineStatsSampler
    public let powerStatsSampler: PowerStatsSampler
    public let historyReader: HardwareHistoryReader
    public let processHistoryReader: ProcessHistoryReader
    public let eventReader: HardwareEventReader
    public let insightsService: HardwareInsightsService

    private let historyDatabase: HardwareHistoryDatabase
    private let historyStore: HardwareHistoryStore
    private let processHistoryStore: ProcessHistoryStore
    private let eventStore: HardwareEventStore
    private let environmentObserver: HardwareEnvironmentObserving
    private let trackedProcessResolver: @Sendable () -> Set<Int32>
    private let trackedAppGPUUsageResolver: TrackedAppGPUUsageResolver
    private var centralSamplingTimer: DispatchSourceTimer?
    private var centralSamplingGeneration: UInt64 = 0
    private var historyPersistenceTimer: DispatchSourceTimer?
    private var trackedAppGPURefreshTimer: DispatchSourceTimer?
    private var collectionRecoveryTimer: DispatchSourceTimer?
    private let samplingQueue = DispatchQueue(label: "com.chrisizatt.PodcastPreview.CollectorHeartbeat", qos: .utility)
    private var baseCollectionProfile: HardwareCollectionProfile = .dashboard
    private var activeCollectionProfile: HardwareCollectionProfile = .dashboard
    private var demandProfiles: [UUID: HardwareCollectionProfile] = [:]
    private var lastSampleDates: [HardwareCollectorSampleGroup: Date] = [:]
    private var dashboardFrameSequence: UInt64 = 0
    private var lastDashboardFrameSignature: HardwareDashboardFrameSignature?
    private var isRecoveringFromCollectionStall = false
    private var lastObservedThermalLabel: String?
    private var lastObservedPowerSource: String?
    private var lastObservedDisplayCount: Int?
    private var lastObservedMediaState: MediaEngineStatsSampler.ActivityState?
    private var lastObservedPowerSampleStatus: PowerSampleStatus?
    private var lastObservedPowerFailureReason: String?
    public private(set) var isHardwareStatsActive = false
    private static let collectionRecoveryWatchdogIntervalSeconds = 30
    private static let collectionStallThresholdMultiplier = 6

    private final class TrackedAppGPUUsageResolver: @unchecked Sendable {
        private let lock = NSLock()
        private var cachedUsagePercent: Double?

        func replace(usagePercent: Double?) {
            lock.lock()
            defer { lock.unlock() }
            cachedUsagePercent = usagePercent.map { min(max($0, 0), 100) }
        }

        func currentUsagePercent() -> Double? {
            lock.lock()
            defer { lock.unlock() }
            return cachedUsagePercent
        }

        func reset() {
            replace(usagePercent: nil)
        }
    }

    public init(
        powerMetricsProvider: HardwarePowerMetricsProvider? = nil,
        appGPUUsageProvider: HardwareAppGPUUsageProvider? = nil,
        runningApplicationProvider: HardwareRunningApplicationProvider? = nil,
        environmentObserver: HardwareEnvironmentObserving? = nil,
        historyRootURL: URL? = nil
    ) {
        let resolvedHistoryRootURL = historyRootURL ?? Self.preferredHistoryRootURL()
        _ = try? HardwareHistoryDatabase.importAvailableUserHistoryIfNeeded(
            intoRootURL: resolvedHistoryRootURL
        )

        // try! is intentional: failure here means the app support directory is
        // inaccessible, which indicates a fundamental system-level problem.
        let database = try! HardwareHistoryDatabase(
            rootURL: resolvedHistoryRootURL
        )
        let trackedProcessResolver: @Sendable () -> Set<Int32> = {
            PodcastPreviewProcessFamilyResolver.processIdentifiers()
        }
        let trackedAppGPUUsageResolver = TrackedAppGPUUsageResolver()
        let resolvedRunningApplicationProvider = runningApplicationProvider ?? HeadlessRunningApplicationProvider.shared
        let resolvedEnvironmentObserver = environmentObserver ?? SystemHardwareEnvironmentObserver()

        let powerStatsSampler = PowerStatsSampler(powerMetricsProvider: powerMetricsProvider)
        self.cpuSampler = CPUStatsSampler()
        self.thermalSampler = ThermalStatsSampler()
        self.gpuSampler = GPUStatsSampler()
        self.gpuIdentityProber = GPUIdentityProber()
        self.memoryIdentityProber = MemoryIdentityProber()
        self.ramSampler = RAMStatsSampler(targetProcessResolver: trackedProcessResolver)
        self.storageSampler = StorageStatsSampler()
        self.aneSampler = ANEStatsSampler(powerSampler: powerStatsSampler)
        self.trackedProcessResolver = trackedProcessResolver
        self.trackedAppGPUUsageResolver = trackedAppGPUUsageResolver
        self.appSampler = AppStatsSampler(
            targetProcessResolver: trackedProcessResolver,
            targetGPUPercentResolver: { _ in
                trackedAppGPUUsageResolver.currentUsagePercent()
            },
            gpuUsageProvider: appGPUUsageProvider
        )
        self.runningAppsSampler = RunningAppsSampler(runningApplicationProvider: resolvedRunningApplicationProvider)
        self.gpuClientsSampler = GPUClientsSampler(runningApplicationProvider: resolvedRunningApplicationProvider)
        self.diskIOSampler = DiskIOSampler()
        self.networkSampler = NetworkStatsSampler()
        self.networkInterfaceSampler = NetworkInterfaceSampler()
        self.mediaEngineSampler = MediaEngineStatsSampler()
        self.powerStatsSampler = powerStatsSampler
        self.environmentObserver = resolvedEnvironmentObserver
        self.historyDatabase = database
        self.historyStore = HardwareHistoryStore(database: database)
        self.processHistoryStore = ProcessHistoryStore(database: database)
        self.eventStore = HardwareEventStore(database: database)
        self.historyReader = HardwareHistoryReader(database: database)
        self.processHistoryReader = ProcessHistoryReader(database: database)
        self.eventReader = HardwareEventReader(database: database)
        self.insightsService = HardwareInsightsService(historyReader: historyReader)

    }

    public func beginHardwareStatsDemand(_ profile: HardwareCollectionProfile) -> HardwareStatsDemandToken {
        let demandID = UUID()
        demandProfiles[demandID] = profile
        if !isHardwareStatsActive {
            startHardwareStatsMonitoring(profile: .historyOnly)
        }
        refreshActiveCollectionProfile()

        return HardwareStatsDemandToken { [weak self] in
            self?.endHardwareStatsDemand(demandID)
        }
    }

    private func endHardwareStatsDemand(_ demandID: UUID) {
        demandProfiles.removeValue(forKey: demandID)
        refreshActiveCollectionProfile()
    }

    public func startHardwareStatsMonitoring(profile: HardwareCollectionProfile = .dashboard) {
        baseCollectionProfile = profile
        refreshActiveCollectionProfile(restartTimer: false)
        guard !isHardwareStatsActive else {
            refreshActiveCollectionProfile()
            return
        }
        isHardwareStatsActive = true

        // One-time hardware identity probes (run once on launch, cached for app lifetime)
        gpuIdentityProber.start()
        memoryIdentityProber.start()

        // Samplers with long cadences or independent timer semantics.
        storageSampler.start()
        appSampler.initializeForExternalClock()
        runningAppsSampler.initializeForExternalClock()
        gpuClientsSampler.initializeForExternalClock()
        networkInterfaceSampler.initializeForExternalClock()

        // Samplers that keep their own queues / special-case behavior, but can safely
        // share the collector heartbeat instead of each owning a 1 Hz timer.
        powerStatsSampler.initializeForExternalClock()
        networkSampler.initializeForExternalClock()
        mediaEngineSampler.initializeForExternalClock()

        // Simple-cadence samplers: initialize without individual timers,
        // then drive them from a single shared DispatchSourceTimer below.
        cpuSampler.initialize()
        thermalSampler.initialize()
        gpuSampler.initialize()
        ramSampler.initialize()
        diskIOSampler.initialize()
        aneSampler.initialize()
        lastSampleDates.removeAll()
        startCollectionRecoveryWatchdog()
        startCentralSamplingTimer()

        startTrackedAppGPUUsageEstimation()
        startHistoryPersistence()
        startEventMonitoring()
    }

    public func stopHardwareStatsMonitoring() {
        guard isHardwareStatsActive else { return }
        isHardwareStatsActive = false
        demandProfiles.removeAll()
        baseCollectionProfile = .historyOnly
        activeCollectionProfile = .historyOnly

        stopEventMonitoring()
        stopTrackedAppGPUUsageEstimation()
        stopCollectionRecoveryWatchdog()
        stopCentralSamplingTimer()

        stopHistoryPersistence()
        cpuSampler.stop()
        thermalSampler.stop()
        gpuSampler.stop()
        ramSampler.stop()
        storageSampler.stop()
        aneSampler.stop()
        appSampler.stop()
        runningAppsSampler.stop()
        gpuClientsSampler.stop()
        diskIOSampler.stop()
        networkSampler.stop()
        networkInterfaceSampler.stop()
        mediaEngineSampler.stop()
        powerStatsSampler.stop()
    }

    public var latestTelemetrySnapshot: HardwareSnapshot? {
        let snapshots: [HardwareSnapshot] = [
            cpuSampler.latestSnapshot,
            ramSampler.latestSnapshot,
            thermalSampler.latestSnapshot,
            diskIOSampler.latestSnapshot,
            mediaEngineSampler.latestSnapshot,
            powerStatsSampler.latestSnapshot,
            aneSampler.latestSnapshot,
            appSampler.latestSnapshot
        ]
        .compactMap { $0 }

        guard var merged = snapshots.first else { return nil }

        for snapshot in snapshots.dropFirst() {
            merged = merged.merging(snapshot)
        }

        return merged
    }

    public var latestDeviceTelemetrySnapshots: [HardwareDeviceSnapshot] {
        gpuSampler.latestDeviceSnapshots
    }

    public var latestTelemetryFrame: HardwareTelemetryFrame {
        let snapshot = latestTelemetrySnapshot
        let deviceSnapshots = latestDeviceTelemetrySnapshots
        let timestamps = ([snapshot?.timestamp].compactMap { $0 } + deviceSnapshots.map(\.timestamp))
        let timestamp = timestamps.max() ?? Date()

        return HardwareTelemetryFrame(
            timestamp: timestamp,
            snapshot: snapshot,
            deviceSnapshots: deviceSnapshots
        )
    }

    public var statusSnapshot: HardwareCollectorStatusSnapshot {
        let frame = latestTelemetryFrame
        return HardwareCollectorStatusSnapshot(
            isCollectorInitialized: true,
            isMonitoringActive: isHardwareStatsActive,
            collectorIntervalSeconds: collectorHeartbeatIntervalSeconds(),
            activeProfile: activeCollectionProfile,
            latestFrameTimestamp: frame.isEmpty ? nil : frame.timestamp,
            hasGlobalSnapshot: frame.snapshot != nil,
            deviceSnapshotCount: frame.deviceSnapshots.count
        )
    }

    public var liveSnapshot: HardwareCollectorLiveSnapshot {
        HardwareCollectorLiveSnapshot(
            status: statusSnapshot,
            latestTelemetryFrame: latestTelemetryFrame,
            cpu: cpuSampler.liveSnapshot,
            thermal: thermalSampler.liveSnapshot,
            gpu: gpuSampler.liveSnapshot,
            ram: ramSampler.liveSnapshot,
            storage: storageSampler.liveSnapshot,
            ane: aneSampler.liveSnapshot,
            app: appSampler.liveSnapshot,
            runningApps: runningAppsSampler.liveSnapshot,
            gpuClients: gpuClientsSampler.liveSnapshot,
            diskIO: diskIOSampler.liveSnapshot,
            network: networkSampler.liveSnapshot,
            mediaEngine: mediaEngineSampler.liveSnapshot,
            power: powerStatsSampler.liveSnapshot
        )
    }

    public var pollingSnapshot: HardwareCollectorPollingSnapshot {
        HardwareCollectorPollingSnapshot(
            status: statusSnapshot,
            latestTelemetryFrame: latestTelemetryFrame,
            cpu: CPUSamplerPollingSnapshot(
                coreUsages: cpuSampler.coreUsages,
                cpuDisplayName: cpuSampler.cpuDisplayName,
                efficiencyCoreCount: cpuSampler.efficiencyCoreCount,
                performanceCoreCount: cpuSampler.performanceCoreCount,
                latestSnapshot: cpuSampler.latestSnapshot
            ),
            thermal: ThermalStatsSamplerPollingSnapshot(
                latestSnapshot: thermalSampler.latestSnapshot
            ),
            gpu: GPUStatsSamplerPollingSnapshot(
                gpus: gpuSampler.gpus,
                latestDeviceSnapshots: gpuSampler.latestDeviceSnapshots,
                gpuDisplayName: gpuSampler.gpuDisplayName
            ),
            gpuIdentityUnits: gpuIdentityProber.gpuUnits,
            ram: RAMStatsSamplerPollingSnapshot(
                latestMemorySnapshot: ramSampler.latestMemorySnapshot,
                latestSnapshot: ramSampler.latestSnapshot
            ),
            memoryIdentityUnit: memoryIdentityProber.memoryUnit,
            storage: storageSampler.liveSnapshot,
            ane: ANEStatsSamplerPollingSnapshot(
                latestStatusSnapshot: aneSampler.latestStatusSnapshot,
                latestSnapshot: aneSampler.latestSnapshot
            ),
            app: appSampler.pollingSnapshot,
            runningApps: runningAppsSampler.liveSnapshot,
            gpuClients: gpuClientsSampler.liveSnapshot,
            diskIO: DiskIOSamplerPollingSnapshot(
                latestSnapshot: diskIOSampler.latestSnapshot
            ),
            network: NetworkStatsSamplerPollingSnapshot(
                latestSnapshot: nil,
                sessionUploadMB: 0,
                sessionDownloadMB: 0,
                pingTargetLabel: "—",
                pingLatencyMilliseconds: nil,
                pingPacketLossRatio: nil,
                lastPingSampleDate: nil
            ),
            networkInterfaceSnapshot: networkInterfaceSampler.latestSnapshot,
            mediaEngine: MediaEngineStatsSamplerPollingSnapshot(
                latestCapabilityState: mediaEngineSampler.latestCapabilityState,
                latestActivitySummary: mediaEngineSampler.latestActivitySummary,
                recentSessions: mediaEngineSampler.recentSessions
            ),
            power: PowerStatsSamplerPollingSnapshot(
                latestSystemSnapshot: powerStatsSampler.latestSystemSnapshot,
                latestReadingsSnapshot: powerStatsSampler.latestReadingsSnapshot,
                latestSnapshot: powerStatsSampler.latestSnapshot,
                sampleStatus: powerStatsSampler.sampleStatus,
                lastPowerSampleDate: powerStatsSampler.lastPowerSampleDate,
                lastUsablePowerSampleDate: powerStatsSampler.lastUsablePowerSampleDate,
                source: powerStatsSampler.powerSampleSource,
                failureReason: powerStatsSampler.powerSampleFailureReason,
                monitoringSessionStartDate: powerStatsSampler.monitoringSessionStartDate,
                hardwareAgentUptimeSeconds: powerStatsSampler.hardwareAgentUptimeSeconds
            )
        )
    }

    public var dashboardFrame: HardwareDashboardFrame {
        let snapshot = pollingSnapshot
        refreshDashboardFrameSequence(for: snapshot)

        return HardwareDashboardFrame(
            sequenceNumber: dashboardFrameSequence,
            generatedAt: Date(),
            pollingSnapshot: snapshot
        )
    }

    private func refreshDashboardFrameSequence(for snapshot: HardwareCollectorPollingSnapshot) {
        let signature = HardwareDashboardFrameSignature(snapshot: snapshot)
        guard signature != lastDashboardFrameSignature else { return }
        lastDashboardFrameSignature = signature
        dashboardFrameSequence &+= 1
    }

    private func refreshActiveCollectionProfile(restartTimer: Bool = true) {
        let resolvedProfile = HardwareCollectionProfile.highest([baseCollectionProfile] + Array(demandProfiles.values))
        guard resolvedProfile != activeCollectionProfile else { return }

        activeCollectionProfile = resolvedProfile
        lastSampleDates.removeAll()

        guard isHardwareStatsActive, restartTimer else { return }
        stopCentralSamplingTimer()
        stopTrackedAppGPUUsageEstimation(resetState: false)
        startCentralSamplingTimer()
        startTrackedAppGPUUsageEstimation()
        samplingQueue.async { [weak self] in
            self?.sampleCollectors(force: true)
        }
    }

    // MARK: - Central Sampling Timer

    /// Drives the collector-owned 1 Hz heartbeat. Simple samplers run directly on this
    /// timer, while power / network / media keep their sampler-specific queues and
    /// secondary behavior behind trigger methods.
    private func startCentralSamplingTimer() {
        stopCentralSamplingTimer()
        guard isHardwareStatsActive else { return }

        centralSamplingGeneration &+= 1
        scheduleNextSample(generation: centralSamplingGeneration)
    }

    private func scheduleNextSample(generation: UInt64) {
        let interval = collectorHeartbeatIntervalSeconds()
        let timer = DispatchSource.makeTimerSource(queue: samplingQueue)
        timer.schedule(deadline: .now() + .seconds(interval))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.isHardwareStatsActive, self.centralSamplingGeneration == generation else { return }
            self.sampleCollectors()
            guard self.isHardwareStatsActive, self.centralSamplingGeneration == generation else { return }
            self.scheduleNextSample(generation: generation)
        }
        timer.resume()
        centralSamplingTimer = timer
    }

    private func stopCentralSamplingTimer() {
        centralSamplingGeneration &+= 1
        centralSamplingTimer?.cancel()
        centralSamplingTimer = nil
    }

    private func collectorHeartbeatIntervalSeconds() -> Int {
        HardwareSamplerCadencePolicy.heartbeatIntervalSeconds(for: activeCollectionProfile)
    }

    private func sampleIntervalSeconds(for group: HardwareCollectorSampleGroup) -> TimeInterval {
        HardwareSamplerCadencePolicy.sampleIntervalSeconds(for: group, profile: activeCollectionProfile)
    }

    private func isSampleDue(_ group: HardwareCollectorSampleGroup, at now: Date, force: Bool) -> Bool {
        guard !force else { return true }
        guard let lastSampleDate = lastSampleDates[group] else { return true }
        return now.timeIntervalSince(lastSampleDate) >= sampleIntervalSeconds(for: group)
    }

    private func markSampled(_ group: HardwareCollectorSampleGroup, at now: Date) {
        lastSampleDates[group] = now
    }

    private func sampleCollectors(force: Bool = false) {
        guard isHardwareStatsActive else { return }

        let now = Date()
        if isSampleDue(.cpu, at: now, force: force) {
            cpuSampler.sample()
            markSampled(.cpu, at: now)
        }
        if isSampleDue(.gpu, at: now, force: force) {
            gpuSampler.sample()
            markSampled(.gpu, at: now)
        }
        if isSampleDue(.ram, at: now, force: force) {
            ramSampler.sample()
            markSampled(.ram, at: now)
        }
        if isSampleDue(.thermal, at: now, force: force) {
            thermalSampler.sample()
            markSampled(.thermal, at: now)
        }
        if isSampleDue(.diskIO, at: now, force: force) {
            diskIOSampler.sample()
            markSampled(.diskIO, at: now)
        }
        if isSampleDue(.ane, at: now, force: force) {
            aneSampler.sample()
            markSampled(.ane, at: now)
        }
        if isSampleDue(.app, at: now, force: force) {
            appSampler.triggerSample()
            markSampled(.app, at: now)
        }
        if isSampleDue(.runningApps, at: now, force: force) {
            runningAppsSampler.triggerSample()
            markSampled(.runningApps, at: now)
        }
        if isSampleDue(.gpuClients, at: now, force: force) {
            gpuClientsSampler.triggerSample()
            markSampled(.gpuClients, at: now)
        }
        if isSampleDue(.networkInterface, at: now, force: force) {
            networkInterfaceSampler.triggerSample()
            markSampled(.networkInterface, at: now)
        }
        if isSampleDue(.power, at: now, force: force) {
            powerStatsSampler.triggerSample()
            markSampled(.power, at: now)
        }
        if isSampleDue(.network, at: now, force: force) {
            networkSampler.triggerSample()
            markSampled(.network, at: now)
        }
        if isSampleDue(.mediaEngine, at: now, force: force) {
            mediaEngineSampler.triggerTick()
            markSampled(.mediaEngine, at: now)
        }
    }

    private func startCollectionRecoveryWatchdog() {
        stopCollectionRecoveryWatchdog()

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(
            deadline: .now() + .seconds(Self.collectionRecoveryWatchdogIntervalSeconds),
            repeating: .seconds(Self.collectionRecoveryWatchdogIntervalSeconds),
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.checkCollectionHealth()
            }
        }
        timer.resume()
        collectionRecoveryTimer = timer
    }

    private func stopCollectionRecoveryWatchdog() {
        collectionRecoveryTimer?.cancel()
        collectionRecoveryTimer = nil
        isRecoveringFromCollectionStall = false
    }

    private func checkCollectionHealth() {
        guard isHardwareStatsActive, !isRecoveringFromCollectionStall else { return }

        let frame = latestTelemetryFrame
        guard !frame.isEmpty else { return }

        let ageSeconds = Date().timeIntervalSince(frame.timestamp)
        let collectorInterval = Double(HardwareCollectionSettings.collectorIntervalSeconds())
        let stallThreshold = max(
            Double(Self.collectionRecoveryWatchdogIntervalSeconds),
            collectorInterval * Double(Self.collectionStallThresholdMultiplier)
        )

        guard ageSeconds >= stallThreshold else { return }

        Task {
            await recoverCollectionAfterStall(staleFrameTimestamp: frame.timestamp, ageSeconds: ageSeconds)
        }
    }

    private func recoverCollectionAfterStall(staleFrameTimestamp: Date, ageSeconds: TimeInterval) async {
        guard !isRecoveringFromCollectionStall else { return }
        isRecoveringFromCollectionStall = true

        recordEvent(
            category: .system,
            type: "collector-recovered",
            title: "Collector restarted",
            detail: String(format: "Latest frame at %@ stalled for %.0f seconds; rebuilding the collection pipeline.", String(describing: staleFrameTimestamp), ageSeconds),
            timestamp: Date(),
            severity: .highlight
        )

        stopCentralSamplingTimer()
        stopHistoryPersistence(flushFinalSnapshot: false)
        stopTrackedAppGPUUsageEstimation(resetState: false)

        storageSampler.start()
        appSampler.initializeForExternalClock()
        runningAppsSampler.initializeForExternalClock()
        gpuClientsSampler.initializeForExternalClock()
        networkInterfaceSampler.initializeForExternalClock()
        powerStatsSampler.initializeForExternalClock()
        mediaEngineSampler.initializeForExternalClock()
        cpuSampler.initialize()
        thermalSampler.initialize()
        gpuSampler.initialize()
        ramSampler.initialize()
        diskIOSampler.initialize()
        aneSampler.initialize()

        // Run one sample on the sampling queue to check if it still hangs,
        // but don't block the Main Actor indefinitely.
        let didSample = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + .seconds(10))
            timer.setEventHandler {
                timer.cancel()
                continuation.resume(returning: false)
            }
            timer.resume()

            samplingQueue.async { [weak self] in
                self?.sampleCollectors(force: true)
                timer.cancel()
                continuation.resume(returning: true)
            }
        }

        if !didSample {
            recordEvent(
                category: .system,
                type: "collector-stall-warning",
                title: "Collector still stalled",
                detail: "A manual sample attempt on the interactive queue also timed out after 10s. The hardware stats may remain stale.",
                severity: .highlight
            )
        }

        startCentralSamplingTimer()
        startTrackedAppGPUUsageEstimation()
        startHistoryPersistence()

        isRecoveringFromCollectionStall = false
    }

    private func startTrackedAppGPUUsageEstimation() {
        stopTrackedAppGPUUsageEstimation(resetState: false)
        refreshTrackedAppGPUUsageEstimate()

        let interval = Int(max(2, sampleIntervalSeconds(for: .gpuClients)))
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshTrackedAppGPUUsageEstimate()
            }
        }
        timer.resume()
        trackedAppGPURefreshTimer = timer
    }

    private func stopTrackedAppGPUUsageEstimation(resetState: Bool = true) {
        trackedAppGPURefreshTimer?.cancel()
        trackedAppGPURefreshTimer = nil

        guard resetState else { return }
        trackedAppGPUUsageResolver.reset()
    }

    private func refreshTrackedAppGPUUsageEstimate() {
        let trackedPIDs = trackedProcessResolver()
        guard !trackedPIDs.isEmpty else {
            trackedAppGPUUsageResolver.reset()
            return
        }

        let totalGPUUsageRatio = min(
            gpuSampler.gpus.compactMap(\.usage).reduce(0.0) { partialResult, usage in
                partialResult + Double(usage)
            },
            1.0
        )
        let totalGPUUsagePercent = totalGPUUsageRatio * 100.0
        let activeApps = gpuClientsSampler.activeApps
        let totalDeltaTime = activeApps.reduce(UInt64(0)) { partialResult, app in
            partialResult &+ (app.gpuDeltaTimeNS ?? 0)
        }
        let trackedDeltaTime = activeApps.reduce(UInt64(0)) { partialResult, app in
            guard trackedPIDs.contains(app.pid) else { return partialResult }
            return partialResult &+ (app.gpuDeltaTimeNS ?? 0)
        }

        let usagePercent: Double
        if totalDeltaTime > 0 {
            usagePercent = totalGPUUsagePercent * (Double(trackedDeltaTime) / Double(totalDeltaTime))
        } else {
            usagePercent = 0
        }

        trackedAppGPUUsageResolver.replace(usagePercent: min(max(usagePercent, 0), 100))
    }

    /// How often we feed the latest telemetry frame into the history store.
    /// The store upserts the active minute bucket on this cadence, while
    /// throttling active hourly bucket rewrites to keep SQLite churn bounded.
    private static let historyPersistenceIntervalSeconds = 10

    private func startHistoryPersistence() {
        stopHistoryPersistence(flushFinalSnapshot: false)

        persistCurrentTelemetryFrame()

        let interval = Self.historyPersistenceIntervalSeconds
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.persistCurrentTelemetryFrame()
            }
        }
        timer.resume()
        historyPersistenceTimer = timer
    }

    private func stopHistoryPersistence(flushFinalSnapshot: Bool = true) {
        historyPersistenceTimer?.cancel()
        historyPersistenceTimer = nil

        guard flushFinalSnapshot else { return }
        let frame = latestTelemetryFrame
        let estimatedObservedSeconds = Self.historyPersistenceIntervalSeconds
        Task {
            await historyStore.append(frame, estimatedObservedSeconds: estimatedObservedSeconds)
            await processHistoryStore.append(
                timestamp: frame.timestamp,
                apps: runningAppsSampler.topRows,
                gpuApps: gpuClientsSampler.activeApps,
                estimatedObservedSeconds: estimatedObservedSeconds
            )
            await historyStore.flush()
            await processHistoryStore.flush()
        }
    }

    private func persistCurrentTelemetryFrame() {
        let frame = latestTelemetryFrame
        let estimatedObservedSeconds = Self.historyPersistenceIntervalSeconds
        recordDerivedEvents(at: frame.timestamp)
        Task {
            await historyStore.append(frame, estimatedObservedSeconds: estimatedObservedSeconds)
            await processHistoryStore.append(
                timestamp: frame.timestamp,
                apps: runningAppsSampler.topRows,
                gpuApps: gpuClientsSampler.activeApps,
                estimatedObservedSeconds: estimatedObservedSeconds
            )
        }
    }

    private func startEventMonitoring() {
        stopEventMonitoring()

        lastObservedThermalLabel = currentThermalLabel()
        lastObservedPowerSource = Self.currentPowerSourceDescription()
        lastObservedDisplayCount = environmentObserver.currentDisplayCount
        lastObservedMediaState = mediaEngineSampler.latestActivitySummary?.activityState ?? .idle
        lastObservedPowerSampleStatus = powerStatsSampler.sampleStatus
        lastObservedPowerFailureReason = powerStatsSampler.powerSampleFailureReason

        environmentObserver.startObserving { [weak self] event in
            Task { @MainActor [weak self] in
                switch event {
                case .systemWillSleep:
                    self?.recordEvent(
                        category: .system,
                        type: "sleep",
                        title: "System sleeping",
                        detail: "macOS signaled an imminent sleep transition."
                    )
                    self?.suspendCollectionForSleep()
                case .systemDidWake:
                    self?.resumeCollectionAfterWake()
                    self?.recordEvent(
                        category: .system,
                        type: "wake",
                        title: "System woke",
                        detail: "The machine resumed from sleep."
                    )
                }
            }
        }
    }

    private func stopEventMonitoring() {
        environmentObserver.stopObserving()
        lastObservedThermalLabel = nil
        lastObservedPowerSource = nil
        lastObservedDisplayCount = nil
        lastObservedMediaState = nil
        lastObservedPowerSampleStatus = nil
        lastObservedPowerFailureReason = nil
    }

    // MARK: - Sleep / Wake

    /// Flush the latest data to the database and tear down sampling timers so
    /// that no stale frames are produced while the machine is asleep. This
    /// avoids the "sometimes-collects, sometimes-doesn't" inconsistency caused
    /// by GCD timers being frozen at unpredictable points during sleep.
    private func suspendCollectionForSleep() {
        // Persist whatever we have right now so the pre-sleep edge is clean.
        stopHistoryPersistence(flushFinalSnapshot: true)
        stopCentralSamplingTimer()
        stopTrackedAppGPUUsageEstimation(resetState: false)
    }

    /// Restart sampling after wake. Because hardware state may have changed
    /// arbitrarily while asleep (e.g. thermals reset, GPU clients gone),
    /// we spin up fresh timers rather than resuming suspended ones.
    private func resumeCollectionAfterWake() {
        guard isHardwareStatsActive else { return }

        sampleCollectors(force: true)
        startCentralSamplingTimer()
        startTrackedAppGPUUsageEstimation()
        startHistoryPersistence()
    }

    private func recordDerivedEvents(at timestamp: Date) {
        recordPowerChannelEventIfNeeded(at: timestamp)

        if let thermalLabel = currentThermalLabel(),
           let previousThermalLabel = lastObservedThermalLabel,
           thermalLabel != previousThermalLabel {
            recordEvent(
                category: .thermal,
                type: "thermal-state-changed",
                title: "Thermal state changed",
                detail: "\(previousThermalLabel) -> \(thermalLabel)",
                timestamp: timestamp,
                severity: thermalLabel.lowercased().contains("serious") || thermalLabel.lowercased().contains("critical") ? .highlight : .info
            )
        }
        lastObservedThermalLabel = currentThermalLabel()

        let currentPowerSource = Self.currentPowerSourceDescription()
        if let currentPowerSource,
           let previousPowerSource = lastObservedPowerSource,
           currentPowerSource != previousPowerSource {
            recordEvent(
                category: .power,
                type: "power-source-changed",
                title: "Power source changed",
                detail: "\(previousPowerSource) -> \(currentPowerSource)",
                timestamp: timestamp
            )
        }
        lastObservedPowerSource = currentPowerSource

        if let displayCount = environmentObserver.currentDisplayCount {
            if let previousDisplayCount = lastObservedDisplayCount,
               displayCount != previousDisplayCount {
                let direction = displayCount > previousDisplayCount ? "connected" : "disconnected"
                recordEvent(
                    category: .display,
                    type: "display-configuration-changed",
                    title: "Display configuration changed",
                    detail: "\(abs(displayCount - previousDisplayCount)) display \(direction); \(displayCount) online now.",
                    timestamp: timestamp
                )
            }
            lastObservedDisplayCount = displayCount
        }

        let mediaSummary = mediaEngineSampler.latestActivitySummary
        let currentMediaState = mediaSummary?.activityState ?? .idle
        if let previousMediaState = lastObservedMediaState,
           currentMediaState != previousMediaState {
            if currentMediaState == .idle {
                recordEvent(
                    category: .media,
                    type: "media-engines-idle",
                    title: "Media engines went idle",
                    detail: mediaSummary?.lastActiveText == "—" ? nil : "Last active \(mediaSummary?.lastActiveText ?? "")",
                    timestamp: timestamp
                )
            } else {
                var parts: [String] = []
                if let codec = mediaSummary?.codec, !codec.isEmpty {
                    parts.append(codec)
                }
                if let frames = mediaSummary?.recentProcessedFrames, frames > 0 {
                    parts.append("\(frames) recent frames")
                }
                recordEvent(
                    category: .media,
                    type: "media-engines-active",
                    title: "Media engines became active",
                    detail: parts.isEmpty ? nil : parts.joined(separator: " | "),
                    timestamp: timestamp,
                    severity: currentMediaState == .busy ? .highlight : .info
                )
            }
        }
        lastObservedMediaState = currentMediaState
    }

    private func recordPowerChannelEventIfNeeded(at timestamp: Date) {
        let status = powerStatsSampler.sampleStatus
        let failureReason = powerStatsSampler.powerSampleFailureReason
        defer {
            lastObservedPowerSampleStatus = status
            lastObservedPowerFailureReason = failureReason
        }

        guard status != .warmup else { return }
        guard status != lastObservedPowerSampleStatus || failureReason != lastObservedPowerFailureReason else {
            return
        }

        let lastSampleText = powerStatsSampler.lastPowerSampleDate.map {
            String(format: "%.0fs ago", max(0, timestamp.timeIntervalSince($0)))
        }
        let lastUsableText = powerStatsSampler.lastUsablePowerSampleDate.map {
            String(format: "%.0fs ago", max(0, timestamp.timeIntervalSince($0)))
        }
        let detailParts = [
            powerStatsSampler.powerSampleSource.map { "source \($0)" },
            lastSampleText.map { "last sample \($0)" },
            lastUsableText.map { "last usable \($0)" },
            failureReason.map { "reason \($0)" }
        ].compactMap { $0 }

        switch status {
        case .live:
            guard lastObservedPowerSampleStatus == .stale || lastObservedPowerSampleStatus == .unavailable else {
                return
            }
            recordEvent(
                category: .power,
                type: "power-channel-recovered",
                title: "Power Metrics recovered",
                detail: detailParts.isEmpty ? nil : detailParts.joined(separator: "; "),
                timestamp: timestamp,
                severity: .highlight
            )
        case .stale:
            recordEvent(
                category: .power,
                type: "power-channel-stale",
                title: "Power Metrics stale",
                detail: detailParts.isEmpty ? "Displaying the last usable power and CPU frequency sample." : detailParts.joined(separator: "; "),
                timestamp: timestamp,
                severity: .caution
            )
        case .unavailable:
            recordEvent(
                category: .power,
                type: "power-channel-unavailable",
                title: "Power Metrics unavailable",
                detail: detailParts.isEmpty ? "Live power and CPU frequency readings are unavailable." : detailParts.joined(separator: "; "),
                timestamp: timestamp,
                severity: .highlight
            )
        case .warmup:
            break
        }
    }

    private func currentThermalLabel() -> String? {
        thermalSampler.latestSnapshot?.dimension(.thermalState) ?? thermalSampler.thermalLabel
    }

    private func recordEvent(
        category: HardwareEventCategory,
        type: String,
        title: String,
        detail: String? = nil,
        timestamp: Date = Date(),
        severity: HardwareEventSeverity = .info
    ) {
        Task {
            await eventStore.append(
                category: category,
                type: type,
                title: title,
                detail: detail,
                severity: severity,
                timestamp: timestamp
            )
        }
    }

    private static func currentPowerSourceDescription() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for powerSource in list {
            guard let description = IOPSGetPowerSourceDescription(info, powerSource)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            guard let type = description[kIOPSTypeKey as String] as? String,
                  type == (kIOPSInternalBatteryType as String) else {
                continue
            }

            if let sourceState = description[kIOPSPowerSourceStateKey as String] as? String {
                if sourceState == (kIOPSACPowerValue as String) {
                    return "AC Power"
                }
                if sourceState == (kIOPSBatteryPowerValue as String) {
                    return "Battery"
                }
                return sourceState
            }
        }

        return "AC Power"
    }

    private static func preferredHistoryRootURL() -> URL? {
        guard geteuid() == 0 else { return nil }

        return FileManager.default.urls(for: .applicationSupportDirectory, in: .localDomainMask).first
            ?? URL(fileURLWithPath: "/Library/Application Support", isDirectory: true)
    }
}

#endif
