//
//  HardwareMonitoringModel.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 21/03/2026.
//

import Foundation
import PodcastPreviewCore

@MainActor
final class HardwareMonitoringModel {
    static let shared = HardwareMonitoringModel()

    private let collectorService: HardwareCollectorService?
    private let otherAppsDisplaySampler: OtherAppsSampler?
    private let remoteBridge: RemoteHardwareMonitoringBridge?

    private init() {
        let headlessServiceClient = HardwareMonitoringServiceClient()
        let isHeadlessServiceReachable = headlessServiceClient.isServiceReachableSynchronously()
        let shouldUseHeadlessBackend =
            HardwareMonitoringFeatureFlags.prefersHeadlessAgentBackend
            && headlessServiceClient.isSupportedPlatform
            && isHeadlessServiceReachable

        if shouldUseHeadlessBackend {
            self.collectorService = nil
            self.otherAppsDisplaySampler = nil

            let remoteBridge = RemoteHardwareMonitoringBridge()
            self.remoteBridge = remoteBridge
        } else {
            let collectorService = HardwareCollectorService(
                powerMetricsProvider: AppPowerMetricsProvider.live,
                appGPUUsageProvider: AppGPUUsageProvider.live,
                runningApplicationProvider: AppRunningApplicationProvider.live
            )
            self.collectorService = collectorService

            let otherAppsDisplaySampler = OtherAppsSampler(
                sampler: collectorService.runningAppsSampler,
                gpuSampler: collectorService.gpuSampler,
                gpuClientsSampler: collectorService.gpuClientsSampler,
                iconProvider: AppRunningApplicationProvider.live
            )
            self.otherAppsDisplaySampler = otherAppsDisplaySampler
            self.remoteBridge = nil
        }
    }

    var cpuSampler: CPUStatsSampler { remoteBridge?.cpuSampler ?? collectorService!.cpuSampler }
    var thermalSampler: ThermalStatsSampler { remoteBridge?.thermalSampler ?? collectorService!.thermalSampler }
    var gpuSampler: GPUStatsSampler { remoteBridge?.gpuSampler ?? collectorService!.gpuSampler }
    var gpuIdentityProber: GPUIdentityProber { remoteBridge?.gpuIdentityProber ?? collectorService!.gpuIdentityProber }
    var memoryIdentityProber: MemoryIdentityProber { remoteBridge?.memoryIdentityProber ?? collectorService!.memoryIdentityProber }
    var ramSampler: RAMStatsSampler { remoteBridge?.ramSampler ?? collectorService!.ramSampler }
    var storageSampler: StorageStatsSampler { remoteBridge?.storageSampler ?? collectorService!.storageSampler }
    var aneSampler: ANEStatsSampler { remoteBridge?.aneSampler ?? collectorService!.aneSampler }
    var appSampler: AppStatsSampler { remoteBridge?.appSampler ?? collectorService!.appSampler }
    var otherAppsSampler: OtherAppsSampler { remoteBridge?.otherAppsSampler ?? otherAppsDisplaySampler! }
    var gpuClientsSampler: GPUClientsSampler { remoteBridge?.gpuClientsSampler ?? collectorService!.gpuClientsSampler }
    var diskIOSampler: DiskIOSampler { remoteBridge?.diskIOSampler ?? collectorService!.diskIOSampler }
    var networkSampler: NetworkStatsSampler { remoteBridge?.networkSampler ?? collectorService!.networkSampler }
    var networkInterfaceSampler: NetworkInterfaceSampler { remoteBridge?.networkInterfaceSampler ?? collectorService!.networkInterfaceSampler }
    var mediaEngineSampler: MediaEngineStatsSampler { remoteBridge?.mediaEngineSampler ?? collectorService!.mediaEngineSampler }
    var powerStatsSampler: PowerStatsSampler { remoteBridge?.powerStatsSampler ?? collectorService!.powerStatsSampler }
    var historyReader: any HardwareHistoryQuerying { remoteBridge?.historyReader ?? collectorService!.historyReader }
    var processHistoryReader: any ProcessHistoryQuerying { remoteBridge?.processHistoryReader ?? collectorService!.processHistoryReader }
    var eventReader: any HardwareEventQuerying { remoteBridge?.eventReader ?? collectorService!.eventReader }
    var insightsService: HardwareInsightsService { remoteBridge?.insightsService ?? collectorService!.insightsService }
    var isHardwareStatsActive: Bool { remoteBridge?.isHardwareStatsActive ?? collectorService?.isHardwareStatsActive ?? false }

    func ensureHistoryCollectionIsRunning() {
        if let remoteBridge {
            remoteBridge.activateHeadlessCollectorIfNeeded(profile: .historyOnly)
        } else {
            collectorService?.startHardwareStatsMonitoring(profile: .historyOnly)
        }
    }

    func activateHeadlessCollectorIfNeeded() {
        remoteBridge?.activateHeadlessCollectorIfNeeded(profile: .historyOnly)
    }

    func beginHardwareStatsDemand(_ profile: HardwareCollectionProfile) -> HardwareStatsDemandToken {
        if let remoteBridge {
            return remoteBridge.beginHardwareStatsDemand(profile)
        }
        if let collectorService {
            return collectorService.beginHardwareStatsDemand(profile)
        }
        return HardwareStatsDemandToken {}
    }

    func startHardwareStatsMonitoring() {
        if let remoteBridge {
            remoteBridge.startMonitoringUI()
        } else {
            collectorService?.startHardwareStatsMonitoring(profile: .dashboard)
        }
    }

    func stopHardwareStatsMonitoring() {
        if let remoteBridge {
            remoteBridge.stopMonitoringUI()
        } else {
            collectorService?.stopHardwareStatsMonitoring()
        }
    }

    var latestTelemetrySnapshot: HardwareSnapshot? {
        remoteBridge?.latestTelemetryFrame.snapshot ?? collectorService?.latestTelemetrySnapshot
    }

    var latestDeviceTelemetrySnapshots: [HardwareDeviceSnapshot] {
        remoteBridge?.latestTelemetryFrame.deviceSnapshots ?? collectorService?.latestDeviceTelemetrySnapshots ?? []
    }

    var latestTelemetryFrame: HardwareTelemetryFrame {
        remoteBridge?.latestTelemetryFrame ?? collectorService?.latestTelemetryFrame ?? HardwareTelemetryFrame()
    }
}

@MainActor
private final class RemoteHardwareMonitoringBridge {
    private static let collectorSnapshotPollingIntervalSeconds = 2
    private static let usablePowerSnapshotGraceWindow: TimeInterval = 8.0
    private static var liveSeriesCapacity: Int {
        HardwareCollectionSettings.liveSeriesCapacity(
            sampleIntervalSeconds: collectorSnapshotPollingIntervalSeconds
        )
    }
    private static let diskHistoryNormalizationCeilingMBps = 500.0
    private static let networkHistoryNormalizationCeilingMBps = 100.0

    let cpuSampler = CPUStatsSampler()
    let thermalSampler = ThermalStatsSampler()
    let gpuSampler = GPUStatsSampler()
    let gpuIdentityProber = GPUIdentityProber()
    let memoryIdentityProber = MemoryIdentityProber()
    let ramSampler = RAMStatsSampler()
    let storageSampler = StorageStatsSampler()
    let aneSampler = ANEStatsSampler()
    let appSampler = AppStatsSampler()
    let runningAppsSampler = RunningAppsSampler()
    let gpuClientsSampler = GPUClientsSampler()
    let diskIOSampler = DiskIOSampler()
    let networkSampler = NetworkStatsSampler()
    let networkInterfaceSampler = NetworkInterfaceSampler(autoRefresh: true)
    let mediaEngineSampler = MediaEngineStatsSampler()
    let powerStatsSampler = PowerStatsSampler()
    let historyReader: any HardwareHistoryQuerying
    let processHistoryReader: any ProcessHistoryQuerying
    let eventReader: any HardwareEventQuerying
    let insightsService: HardwareInsightsService
    let otherAppsSampler: OtherAppsSampler

    private let client: HardwareMonitoringServiceClient
    private let localPowerFallbackSampler: PowerStatsSampler?
    private var pollTimer: DispatchSourceTimer?
    private var isFetchingSnapshot = false
    private var lastUsablePowerSnapshot: PowerStatsSamplerLiveSnapshot?
    private var lastUsablePowerSnapshotDate: Date?
    private var baseProfile: HardwareCollectionProfile = .historyOnly
    private var demandProfiles: [UUID: HardwareCollectionProfile] = [:]
    private var activeProfile: HardwareCollectionProfile = .historyOnly
    private var lastAppliedDashboardSequence: UInt64?
    private var dashboardTransportMode: DashboardTransportMode = .dashboardFrame
    private var supportsCollectionProfileUpdates = true

    private(set) var latestTelemetryFrame = HardwareTelemetryFrame()
    private(set) var isHardwareStatsActive = false

    private enum DashboardTransportMode {
        case dashboardFrame
        case pollingSnapshot
        case collectorSnapshot
    }

    private var usesLocalPowerMetricsFallback: Bool {
        HardwareMonitoringServiceAvailability.usesLegacyUserLaunchAgent
            && PowerMetricsServiceAvailability.usesSMJobBless
    }

    init() {
        let client = HardwareMonitoringServiceClient()
        let usesLocalPowerMetricsFallback =
            HardwareMonitoringServiceAvailability.usesLegacyUserLaunchAgent
            && PowerMetricsServiceAvailability.usesSMJobBless
        self.client = client
        self.localPowerFallbackSampler = usesLocalPowerMetricsFallback
            ? PowerStatsSampler(powerMetricsProvider: AppPowerMetricsProvider.live)
            : nil
        let historyReader = RemoteHardwareHistoryReaderProxy(client: client)
        let processHistoryReader = RemoteHardwareProcessHistoryReaderProxy(client: client)
        let eventReader = RemoteHardwareEventReaderProxy(client: client)
        self.historyReader = historyReader
        self.processHistoryReader = processHistoryReader
        self.eventReader = eventReader
        self.insightsService = HardwareInsightsService(historyReader: historyReader)
        self.otherAppsSampler = OtherAppsSampler(
            sampler: runningAppsSampler,
            gpuSampler: gpuSampler,
            gpuClientsSampler: gpuClientsSampler,
            iconProvider: AppRunningApplicationProvider.live
        )
    }

    deinit {
        pollTimer?.cancel()
        localPowerFallbackSampler?.stop()
        Task { @MainActor [client] in
            client.invalidate()
        }
    }

    func activateHeadlessCollectorIfNeeded(profile: HardwareCollectionProfile = .historyOnly) {
        activateHeadlessCollectorIfNeeded(profile: profile, seedSnapshot: false)
    }

    private func activateHeadlessCollectorIfNeeded(profile: HardwareCollectionProfile, seedSnapshot: Bool) {
        guard client.isSupportedPlatform else { return }
        baseProfile = profile

        client.startMonitoring { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let status {
                    self.isHardwareStatsActive = status.isMonitoringActive
                }
                self.applyResolvedCollectionProfile()
                if seedSnapshot {
                    self.refreshDashboardFrame(forceApply: true)
                }
            }
        }
    }

    func beginHardwareStatsDemand(_ profile: HardwareCollectionProfile) -> HardwareStatsDemandToken {
        let demandID = UUID()
        demandProfiles[demandID] = profile
        if profile.priority >= HardwareCollectionProfile.dashboard.priority {
            startDashboardAuxiliarySamplers()
        }
        applyResolvedCollectionProfile()

        return HardwareStatsDemandToken { [weak self] in
            self?.demandProfiles.removeValue(forKey: demandID)
            self?.applyResolvedCollectionProfile()
            self?.stopDashboardAuxiliarySamplersIfIdle()
        }
    }

    func startMonitoringUI() {
        startDashboardAuxiliarySamplers()
        startPolling()
        activateHeadlessCollectorIfNeeded(profile: .dashboard, seedSnapshot: true)
    }

    func stopMonitoringUI() {
        pollTimer?.cancel()
        pollTimer = nil
        localPowerFallbackSampler?.stop()
        networkInterfaceSampler.stop()
        mediaEngineSampler.stop()
        baseProfile = .historyOnly
        applyResolvedCollectionProfile()
    }

    private func startDashboardAuxiliarySamplers() {
        localPowerFallbackSampler?.start()
        gpuIdentityProber.start()
        memoryIdentityProber.start()
        networkInterfaceSampler.start()
        mediaEngineSampler.start()
    }

    private func stopDashboardAuxiliarySamplersIfIdle() {
        let nextProfile = HardwareCollectionProfile.highest([baseProfile] + Array(demandProfiles.values))
        guard nextProfile.priority < HardwareCollectionProfile.dashboard.priority else { return }
        localPowerFallbackSampler?.stop()
        networkInterfaceSampler.stop()
        mediaEngineSampler.stop()
    }

    private func applyResolvedCollectionProfile() {
        let nextProfile = HardwareCollectionProfile.highest([baseProfile] + Array(demandProfiles.values))
        let didChangeProfile = nextProfile != activeProfile
        let shouldRestartPolling = didChangeProfile
        activeProfile = nextProfile

        if supportsCollectionProfileUpdates {
            client.setCollectionProfile(nextProfile) { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let status {
                        self.isHardwareStatsActive = status.isMonitoringActive
                    } else {
                        self.supportsCollectionProfileUpdates = false
                        self.dashboardTransportMode = .collectorSnapshot
                        self.client.invalidate()
                        self.applyLegacyMonitoringState(for: nextProfile, force: true)
                    }
                }
            }
        } else {
            applyLegacyMonitoringState(for: nextProfile, force: didChangeProfile)
        }

        guard shouldRestartPolling,
              nextProfile.priority >= HardwareCollectionProfile.dashboard.priority else { return }
        restartPolling()
    }

    private func applyLegacyMonitoringState(for profile: HardwareCollectionProfile, force: Bool) {
        guard force else { return }
        if profile.priority >= HardwareCollectionProfile.dashboard.priority {
            client.startMonitoring { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let status {
                        self.isHardwareStatsActive = status.isMonitoringActive
                    }
                    self.refreshCollectorSnapshotFallback(forceApply: true)
                }
            }
        } else {
            client.stopMonitoring { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let status {
                        self.isHardwareStatsActive = status.isMonitoringActive
                    }
                }
            }
        }
    }

    private func restartPolling() {
        pollTimer?.cancel()
        pollTimer = nil
        startPolling()
    }

    private func startPolling() {
        guard pollTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(
            deadline: .now(),
            repeating: .seconds(Self.collectorSnapshotPollingIntervalSeconds)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshDashboardFrame()
            }
        }
        timer.resume()
        pollTimer = timer
    }

    private func refreshCollectorSnapshot() {
        guard client.isSupportedPlatform, !isFetchingSnapshot else { return }
        isFetchingSnapshot = true

        client.fetchCollectorSnapshot { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isFetchingSnapshot = false
                guard let snapshot else { return }
                self.applySeed(snapshot)
            }
        }
    }

    private func refreshDashboardFrame(forceApply: Bool = false) {
        guard client.isSupportedPlatform, !isFetchingSnapshot else { return }

        switch dashboardTransportMode {
        case .dashboardFrame:
            break
        case .pollingSnapshot:
            refreshPollingSnapshotFallback(forceApply: forceApply)
            return
        case .collectorSnapshot:
            refreshCollectorSnapshotFallback(forceApply: forceApply)
            return
        }

        isFetchingSnapshot = true

        client.fetchDashboardFrame { [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isFetchingSnapshot = false
                guard let frame else {
                    self.client.invalidate()
                    self.dashboardTransportMode = .collectorSnapshot
                    self.refreshCollectorSnapshotFallback(forceApply: true)
                    return
                }
                if !forceApply, self.lastAppliedDashboardSequence == frame.sequenceNumber {
                    return
                }
                self.lastAppliedDashboardSequence = frame.sequenceNumber
                self.apply(frame.pollingSnapshot)
            }
        }
    }

    private func refreshPollingSnapshotFallback(forceApply: Bool = false) {
        guard client.isSupportedPlatform, !isFetchingSnapshot else { return }
        isFetchingSnapshot = true

        client.fetchPollingSnapshot { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isFetchingSnapshot = false
                guard let snapshot else {
                    self.client.invalidate()
                    self.dashboardTransportMode = .collectorSnapshot
                    self.refreshCollectorSnapshotFallback(forceApply: true)
                    return
                }
                self.apply(snapshot)
            }
        }
    }

    private func refreshCollectorSnapshotFallback(forceApply: Bool = false) {
        guard client.isSupportedPlatform, !isFetchingSnapshot else { return }
        isFetchingSnapshot = true

        client.fetchCollectorSnapshot { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isFetchingSnapshot = false
                guard let snapshot else { return }
                self.applySeed(snapshot)
            }
        }
    }

    private func applySeed(_ snapshot: HardwareCollectorLiveSnapshot) {
        latestTelemetryFrame = snapshot.latestTelemetryFrame
        isHardwareStatsActive = snapshot.status.isMonitoringActive

        cpuSampler.applyRemoteSnapshot(snapshot.cpu)
        thermalSampler.applyRemoteSnapshot(snapshot.thermal)
        gpuSampler.applyRemoteSnapshot(snapshot.gpu)
        ramSampler.applyRemoteSnapshot(snapshot.ram)
        storageSampler.applyRemoteSnapshot(snapshot.storage)
        aneSampler.applyRemoteSnapshot(snapshot.ane)
        appSampler.applyRemoteSnapshot(snapshot.app)
        runningAppsSampler.applyRemoteSnapshot(snapshot.runningApps)
        if let gpuClientsSnapshot = snapshot.gpuClients {
            gpuClientsSampler.applyRemoteSnapshot(gpuClientsSnapshot)
        }
        diskIOSampler.applyRemoteSnapshot(snapshot.diskIO)
        networkSampler.applyRemoteSnapshot(snapshot.network)
        // Note: networkInterfaceSampler collects data locally via SystemConfiguration
        // since daemon does not provide networkInterfaceSnapshot in live snapshot
        if let networkInterfaceSnapshot = snapshot.networkInterfaceSnapshot {
            let samplerSnapshot = NetworkInterfaceSamplerLiveSnapshot(
                ipv4Address: networkInterfaceSnapshot.ipv4Address ?? "—",
                routerAddress: networkInterfaceSnapshot.routerAddress ?? "—",
                dnsServers: networkInterfaceSnapshot.dnsServers.joined(separator: ", "),
                interfaceName: networkInterfaceSnapshot.interfaceName ?? "—",
                isVPNActive: networkInterfaceSnapshot.isVPNActive,
                latestSnapshot: networkInterfaceSnapshot
            )
            networkInterfaceSampler.applyRemoteSnapshot(samplerSnapshot)
        }
        mediaEngineSampler.applyRemoteSnapshot(snapshot.mediaEngine)
        applyPowerSnapshot(snapshot.power)
    }

    private func apply(_ snapshot: HardwareCollectorPollingSnapshot) {
        latestTelemetryFrame = snapshot.latestTelemetryFrame
        isHardwareStatsActive = snapshot.status.isMonitoringActive

        cpuSampler.applyRemoteSnapshot(makeCPUSnapshot(from: snapshot.cpu))
        thermalSampler.applyRemoteSnapshot(makeThermalSnapshot(from: snapshot.thermal))
        gpuSampler.applyRemoteSnapshot(makeGPUSnapshot(from: snapshot.gpu))
        ramSampler.applyRemoteSnapshot(makeRAMSnapshot(from: snapshot.ram))
        storageSampler.applyRemoteSnapshot(snapshot.storage)
        aneSampler.applyRemoteSnapshot(makeANESnapshot(from: snapshot.ane))
        appSampler.applyRemoteSnapshot(snapshot.app)
        runningAppsSampler.applyRemoteSnapshot(snapshot.runningApps)
        if let gpuClientsSnapshot = snapshot.gpuClients {
            gpuClientsSampler.applyRemoteSnapshot(gpuClientsSnapshot)
        }
        diskIOSampler.applyRemoteSnapshot(makeDiskIOSnapshot(from: snapshot.diskIO))
        networkSampler.applyRemoteSnapshot(makeNetworkSnapshot(from: snapshot.network))
        mediaEngineSampler.applyRemoteSnapshot(makeMediaEngineSnapshot(from: snapshot.mediaEngine))
        applyPowerSnapshot(makePowerSnapshot(from: snapshot.power))
        applyIdentityMetadata(from: snapshot)
    }

    private func applyIdentityMetadata(from snapshot: HardwareCollectorPollingSnapshot) {
        if let gpuIdentityUnits = snapshot.gpuIdentityUnits, !gpuIdentityUnits.isEmpty {
            gpuIdentityProber.gpuUnits = gpuIdentityUnits
            gpuIdentityProber.isLoading = false
            gpuIdentityProber.lastProbeDate = latestTelemetryFrame.timestamp
        } else if gpuIdentityProber.gpuUnits.isEmpty, snapshot.gpu.gpus.isEmpty == false {
            gpuIdentityProber.gpuUnits = snapshot.gpu.gpus.map(makeFallbackGPUIdentity)
            gpuIdentityProber.isLoading = false
            gpuIdentityProber.lastProbeDate = latestTelemetryFrame.timestamp
        }

        if let memoryIdentityUnit = snapshot.memoryIdentityUnit {
            memoryIdentityProber.memoryUnit = memoryIdentityUnit
            memoryIdentityProber.isLoading = false
            memoryIdentityProber.lastProbeDate = latestTelemetryFrame.timestamp
        } else if memoryIdentityProber.memoryUnit == nil,
                  let fallbackMemoryUnit = makeFallbackMemoryIdentity(from: snapshot.ram) {
            memoryIdentityProber.memoryUnit = fallbackMemoryUnit
            memoryIdentityProber.isLoading = false
            memoryIdentityProber.lastProbeDate = latestTelemetryFrame.timestamp
        }

        if let networkInterfaceSnapshot = snapshot.networkInterfaceSnapshot {
            networkInterfaceSampler.applyRemoteSnapshot(
                NetworkInterfaceSamplerLiveSnapshot(
                    ipv4Address: networkInterfaceSnapshot.ipv4Address ?? "—",
                    routerAddress: networkInterfaceSnapshot.routerAddress ?? "—",
                    dnsServers: networkInterfaceSnapshot.dnsServers.isEmpty
                        ? "—"
                        : networkInterfaceSnapshot.dnsServers.joined(separator: ", "),
                    interfaceName: networkInterfaceSnapshot.interfaceName ?? "—",
                    isVPNActive: networkInterfaceSnapshot.isVPNActive,
                    latestSnapshot: networkInterfaceSnapshot
                )
            )
        }
    }

    private func makeFallbackGPUIdentity(from gpu: GPUStatsSampler.GPUUnit) -> GPUUnitMetadata {
        GPUUnitMetadata(
            id: gpu.id,
            name: gpu.name,
            vendor: inferredGPUVendor(from: gpu.name),
            bus: nil,
            gpuType: inferredMemoryArchitecture(fromCPUDisplayName: cpuSampler.cpuDisplayName) == "Unified"
                ? "Integrated"
                : nil,
            metalFamily: nil,
            coreCount: gpu.coreCount,
            vramDescription: gpu.vramTotalMB.map { formatGigabytes(Double($0) / 1024.0) },
            deviceID: nil,
            revisionID: nil,
            isRemovable: nil,
            pcieWidth: nil,
            connectedDisplayCount: nil
        )
    }

    private func makeFallbackMemoryIdentity(from snapshot: RAMStatsSamplerPollingSnapshot) -> MemoryUnitMetadata? {
        let totalMemory = snapshot.latestMemorySnapshot.map {
            formatGigabytes(Double($0.totalBytes) / 1_073_741_824.0)
        }
        let architecture = inferredMemoryArchitecture(fromCPUDisplayName: cpuSampler.cpuDisplayName)

        guard totalMemory != nil || architecture != nil else { return nil }

        return MemoryUnitMetadata(
            id: "local-memory-unit",
            totalMemory: totalMemory,
            architecture: architecture,
            type: architecture == "Unified" ? "Unified" : nil,
            speed: nil,
            ecc: nil,
            upgradeable: architecture == "Unified" ? false : nil,
            manufacturerSummary: nil,
            moduleSummary: architecture == "Unified" ? "Package-on-chip" : nil,
            slotCount: nil,
            populatedSlotCount: nil,
            chip: nil,
            machineModel: nil,
            modules: []
        )
    }

    private func inferredMemoryArchitecture(fromCPUDisplayName cpuDisplayName: String) -> String? {
        let normalized = cpuDisplayName.lowercased()
        if normalized.contains("apple") ||
            normalized.contains("m1") ||
            normalized.contains("m2") ||
            normalized.contains("m3") ||
            normalized.contains("m4") {
            return "Unified"
        }

        return nil
    }

    private func inferredGPUVendor(from name: String) -> String? {
        let normalized = name.lowercased()
        if normalized.contains("apple") { return "Apple" }
        if normalized.contains("amd") || normalized.contains("radeon") { return "AMD" }
        if normalized.contains("intel") { return "Intel" }
        if normalized.contains("nvidia") || normalized.contains("geforce") || normalized.contains("quadro") { return "NVIDIA" }
        return nil
    }

    private func formatGigabytes(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f GB", value)
    }

    private func applyPowerSnapshot(_ snapshot: PowerStatsSamplerLiveSnapshot) {
        let now = Date()

        if snapshotHasLiveReadings(snapshot) {
            lastUsablePowerSnapshot = snapshot
            lastUsablePowerSnapshotDate = now
            powerStatsSampler.applyRemoteSnapshot(snapshot)
            return
        }

        if snapshot.sampleStatus == .stale {
            powerStatsSampler.applyRemoteSnapshot(snapshot)
            return
        }

        if usesLocalPowerMetricsFallback,
           let fallbackSnapshot = localPowerFallbackSampler?.liveSnapshot,
           snapshotHasLiveReadings(fallbackSnapshot) {
            lastUsablePowerSnapshot = fallbackSnapshot
            lastUsablePowerSnapshotDate = now
            powerStatsSampler.applyRemoteSnapshot(fallbackSnapshot)
            return
        }

        if let lastUsablePowerSnapshot,
           let lastUsablePowerSnapshotDate,
           now.timeIntervalSince(lastUsablePowerSnapshotDate) < Self.usablePowerSnapshotGraceWindow {
            powerStatsSampler.applyRemoteSnapshot(lastUsablePowerSnapshot)
            return
        }

        self.lastUsablePowerSnapshot = nil
        self.lastUsablePowerSnapshotDate = nil
        powerStatsSampler.applyRemoteSnapshot(snapshot)
    }

    private func snapshotHasLiveReadings(_ snapshot: PowerStatsSamplerLiveSnapshot) -> Bool {
        guard snapshot.sampleStatus == .live else {
            return false
        }
        if let readings = snapshot.latestReadingsSnapshot {
            return readings.cpuPowerWatts != nil
                || readings.gpuPowerWatts != nil
                || readings.combinedPowerWatts != nil
                || readings.perCoreFrequenciesHz.contains(where: { $0 > 0 })
        }

        return snapshot.latestSnapshot?.metric(.combinedPowerWatts) != nil
            || snapshot.latestSnapshot?.metric(.cpuPowerWatts) != nil
            || snapshot.perCoreFrequenciesHz.contains(where: { $0 > 0 })
    }

    private func timestamp(
        latestSnapshot: HardwareSnapshot?,
        fallback: Date
    ) -> Date {
        latestSnapshot?.timestamp ?? fallback
    }

    private func metric(
        _ snapshot: HardwareSnapshot?,
        _ key: HardwareMetricKey
    ) -> Double? {
        snapshot?.metric(key)
    }

    private func metric(
        _ snapshot: HardwareDeviceSnapshot,
        _ key: HardwareDeviceMetricKey
    ) -> Double? {
        snapshot.metric(key)
    }

    private func appendSeriesValue(
        _ value: Double?,
        to currentSeries: MetricSeries,
        at timestamp: Date
    ) -> MetricSeries {
        var series = currentSeries
        series.append(value, at: timestamp, capacity: Self.liveSeriesCapacity)
        return series
    }

    private func appendPerCoreSeriesValues(
        _ values: [Double?],
        to currentSeries: [MetricSeries],
        key: HardwareMetricKey,
        unit: HardwareMetricUnit,
        at timestamp: Date
    ) -> [MetricSeries] {
        let count = max(values.count, currentSeries.count)
        guard count > 0 else { return [] }

        return (0..<count).map { index in
            var series: MetricSeries
            if index < currentSeries.count {
                series = currentSeries[index]
            } else {
                series = MetricSeries(key: key, unit: unit)
            }
            series.append(index < values.count ? values[index] : nil, at: timestamp, capacity: Self.liveSeriesCapacity)
            return series
        }
    }

    private func appendDeviceSeriesValue(
        _ value: Double?,
        to currentSeries: HardwareDeviceMetricSeries?,
        deviceID: String,
        key: HardwareDeviceMetricKey,
        unit: HardwareMetricUnit = .ratio,
        at timestamp: Date
    ) -> HardwareDeviceMetricSeries {
        var series: HardwareDeviceMetricSeries
        if let currentSeries, currentSeries.key == key, currentSeries.unit == unit {
            series = currentSeries
        } else {
            series = HardwareDeviceMetricSeries(
                deviceID: deviceID,
                deviceKind: .gpu,
                key: key,
                unit: unit
            )
        }
        series.append(value, at: timestamp, capacity: Self.liveSeriesCapacity)
        return series
    }

    private func normalizedHistory(
        from series: MetricSeries,
        ceiling: Double
    ) -> [Float] {
        series.values().map { Float(min($0 / ceiling, 1.0)) }
    }

    private func formatRate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f MB/s", value)
    }

    private func formatPeakRate(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return String(format: "Peak %.2f MB/s", value)
    }

    private func makeCPUSnapshot(from snapshot: CPUSamplerPollingSnapshot) -> CPUSamplerLiveSnapshot {
        let sampleTimestamp = timestamp(
            latestSnapshot: snapshot.latestSnapshot,
            fallback: latestTelemetryFrame.timestamp
        )
        let totalSeries = appendSeriesValue(
            metric(snapshot.latestSnapshot, .cpuTotalUsage),
            to: cpuSampler.totalUsageSeries,
            at: sampleTimestamp
        )
        let efficiencySeries = appendSeriesValue(
            metric(snapshot.latestSnapshot, .cpuEfficiencyUsage),
            to: cpuSampler.efficiencyUsageSeries,
            at: sampleTimestamp
        )
        let performanceSeries = appendSeriesValue(
            metric(snapshot.latestSnapshot, .cpuPerformanceUsage),
            to: cpuSampler.performanceUsageSeries,
            at: sampleTimestamp
        )
        let perCoreUsageSeries = appendPerCoreSeriesValues(
            snapshot.coreUsages.map(Double.init),
            to: cpuSampler.perCoreUsageSeries,
            key: .cpuPerCoreUsage,
            unit: .ratio,
            at: sampleTimestamp
        )
        return CPUSamplerLiveSnapshot(
            coreUsages: snapshot.coreUsages,
            totalUsage: metric(snapshot.latestSnapshot, .cpuTotalUsage).map(Float.init),
            usageHistory: totalSeries.values().map(Float.init),
            cpuDisplayName: snapshot.cpuDisplayName,
            systemUsage: metric(snapshot.latestSnapshot, .cpuSystemUsage).map(Float.init),
            userUsage: metric(snapshot.latestSnapshot, .cpuUserUsage).map(Float.init),
            idleUsage: metric(snapshot.latestSnapshot, .cpuIdleUsage).map(Float.init),
            efficiencyUsage: metric(snapshot.latestSnapshot, .cpuEfficiencyUsage).map(Float.init),
            efficiencyHistory: efficiencySeries.values().map(Float.init),
            performanceUsage: metric(snapshot.latestSnapshot, .cpuPerformanceUsage).map(Float.init),
            performanceHistory: performanceSeries.values().map(Float.init),
            efficiencyCoreCount: snapshot.efficiencyCoreCount,
            performanceCoreCount: snapshot.performanceCoreCount,
            perCoreUsageSeries: perCoreUsageSeries,
            totalUsageSeries: totalSeries,
            efficiencyUsageSeries: efficiencySeries,
            performanceUsageSeries: performanceSeries,
            latestSnapshot: snapshot.latestSnapshot
        )
    }

    private func makeThermalSnapshot(from snapshot: ThermalStatsSamplerPollingSnapshot) -> ThermalStatsSamplerLiveSnapshot {
        let sampleTimestamp = timestamp(
            latestSnapshot: snapshot.latestSnapshot,
            fallback: latestTelemetryFrame.timestamp
        )
        let thermalSeries = appendSeriesValue(
            metric(snapshot.latestSnapshot, .thermalLevel),
            to: thermalSampler.thermalSeries,
            at: sampleTimestamp
        )
        let thermalLabel = snapshot.latestSnapshot?.dimension(.thermalState) ?? thermalSampler.thermalLabel
        return ThermalStatsSamplerLiveSnapshot(
            thermalValue: metric(snapshot.latestSnapshot, .thermalLevel).map(Float.init),
            thermalLabel: thermalLabel,
            thermalHistory: thermalSeries.values().map(Float.init),
            thermalSeries: thermalSeries,
            latestSnapshot: snapshot.latestSnapshot
        )
    }

    private func makeGPUSnapshot(from snapshot: GPUStatsSamplerPollingSnapshot) -> GPUStatsSamplerLiveSnapshot {
        var usageSeriesByGPU = gpuSampler.usageSeriesByGPU
        var rendererSeriesByGPU = gpuSampler.rendererSeriesByGPU
        var tilerSeriesByGPU = gpuSampler.tilerSeriesByGPU
        var memoryUsageSeriesByGPU = gpuSampler.memoryUsageSeriesByGPU

        for deviceSnapshot in snapshot.latestDeviceSnapshots where deviceSnapshot.deviceKind == .gpu {
            let sampleTimestamp = deviceSnapshot.timestamp
            usageSeriesByGPU[deviceSnapshot.deviceID] = appendDeviceSeriesValue(
                metric(deviceSnapshot, .utilizationRatio),
                to: usageSeriesByGPU[deviceSnapshot.deviceID],
                deviceID: deviceSnapshot.deviceID,
                key: .utilizationRatio,
                at: sampleTimestamp
            )
            rendererSeriesByGPU[deviceSnapshot.deviceID] = appendDeviceSeriesValue(
                metric(deviceSnapshot, .rendererUtilizationRatio),
                to: rendererSeriesByGPU[deviceSnapshot.deviceID],
                deviceID: deviceSnapshot.deviceID,
                key: .rendererUtilizationRatio,
                at: sampleTimestamp
            )
            tilerSeriesByGPU[deviceSnapshot.deviceID] = appendDeviceSeriesValue(
                metric(deviceSnapshot, .tilerUtilizationRatio),
                to: tilerSeriesByGPU[deviceSnapshot.deviceID],
                deviceID: deviceSnapshot.deviceID,
                key: .tilerUtilizationRatio,
                at: sampleTimestamp
            )
            let memoryMetricKey: HardwareDeviceMetricKey
            let memoryMetricValue: Double?
            if let allocatedMemory = metric(deviceSnapshot, .memoryAllocatedMegabytes) {
                memoryMetricKey = .memoryAllocatedMegabytes
                memoryMetricValue = allocatedMemory
            } else {
                memoryMetricKey = .vramUsedMegabytes
                memoryMetricValue = metric(deviceSnapshot, .vramUsedMegabytes)
            }
            memoryUsageSeriesByGPU[deviceSnapshot.deviceID] = appendDeviceSeriesValue(
                memoryMetricValue,
                to: memoryUsageSeriesByGPU[deviceSnapshot.deviceID],
                deviceID: deviceSnapshot.deviceID,
                key: memoryMetricKey,
                unit: .megabytes,
                at: sampleTimestamp
            )
        }

        return GPUStatsSamplerLiveSnapshot(
            gpus: snapshot.gpus,
            usageSeriesByGPU: usageSeriesByGPU,
            rendererSeriesByGPU: rendererSeriesByGPU,
            tilerSeriesByGPU: tilerSeriesByGPU,
            memoryUsageSeriesByGPU: memoryUsageSeriesByGPU,
            latestDeviceSnapshots: snapshot.latestDeviceSnapshots,
            gpuDisplayName: snapshot.gpuDisplayName
        )
    }

    private func makeRAMSnapshot(from snapshot: RAMStatsSamplerPollingSnapshot) -> RAMStatsSamplerLiveSnapshot {
        let sampleTimestamp = timestamp(
            latestSnapshot: snapshot.latestSnapshot,
            fallback: latestTelemetryFrame.timestamp
        )
        let usageSeries = appendSeriesValue(
            metric(snapshot.latestSnapshot, .ramUsageRatio),
            to: ramSampler.usageSeries,
            at: sampleTimestamp
        )
        let swapSeries = appendSeriesValue(
            metric(snapshot.latestSnapshot, .swapUsageRatio),
            to: ramSampler.swapUsageSeries,
            at: sampleTimestamp
        )
        let pressureSeries = appendSeriesValue(
            metric(snapshot.latestSnapshot, .memoryPressureRatio),
            to: ramSampler.pressureSeries,
            at: sampleTimestamp
        )
        let memorySnapshot = snapshot.latestMemorySnapshot
        return RAMStatsSamplerLiveSnapshot(
            ramUsage: metric(snapshot.latestSnapshot, .ramUsageRatio).map(Float.init),
            usageHistory: usageSeries.values().map(Float.init),
            ramLabel: memorySnapshot?.ramLabel,
            swapLabel: memorySnapshot?.swapLabel ?? "—",
            swapUsedRatio: memorySnapshot?.swapUsedRatio ?? 0,
            swapUsageHistory: swapSeries.values().map(Float.init),
            swapUsedGB: memorySnapshot?.swapUsedGB,
            swapTotalGB: memorySnapshot?.swapTotalGB,
            cachedFilesLabel: memorySnapshot?.cachedFilesLabel ?? "—",
            compressedLabel: memorySnapshot?.compressedLabel ?? "—",
            wiredLabel: memorySnapshot?.wiredLabel ?? "—",
            appMemoryLabel: memorySnapshot?.appMemoryLabel ?? "—",
            pressureLabel: memorySnapshot?.pressureLabel ?? "—",
            pressureSubtext: memorySnapshot?.pressureSubtext ?? "Purgeable —  ·  Reusable —",
            pressureValue: Float(memorySnapshot?.pressureValue ?? 0),
            pressureHistory: pressureSeries.values().map(Float.init),
            usageSeries: usageSeries,
            swapUsageSeries: swapSeries,
            pressureSeries: pressureSeries,
            latestMemorySnapshot: memorySnapshot,
            latestSnapshot: snapshot.latestSnapshot
        )
    }

    private func makeANESnapshot(from snapshot: ANEStatsSamplerPollingSnapshot) -> ANEStatsSamplerLiveSnapshot {
        let sampleTimestamp = timestamp(
            latestSnapshot: snapshot.latestSnapshot,
            fallback: latestTelemetryFrame.timestamp
        )
        let statusSnapshot = snapshot.latestStatusSnapshot
        let activitySeries = appendSeriesValue(
            metric(snapshot.latestSnapshot, .aneActivityRatio),
            to: aneSampler.activitySeries,
            at: sampleTimestamp
        )
        let powerSeries = appendSeriesValue(
            statusSnapshot.map { $0.currentPowerMilliwatts > 0 ? $0.currentPowerMilliwatts / 1000.0 : nil } ?? nil,
            to: aneSampler.powerSeries,
            at: sampleTimestamp
        )
        return ANEStatsSamplerLiveSnapshot(
            coreCountText: statusSnapshot?.coreCountText ?? "—",
            architectureText: statusSnapshot?.architectureText ?? "—",
            engineStatusText: statusSnapshot?.engineStatus ?? "—",
            clientsText: statusSnapshot?.clients ?? [],
            activityState: statusSnapshot?.activityState ?? .idle,
            activityValue: Float(statusSnapshot?.activityValue ?? 0),
            activityHistory: activitySeries.values().map(Float.init),
            statusText: statusSnapshot?.statusText ?? "—",
            currentPowerMilliwatts: statusSnapshot?.currentPowerMilliwatts ?? 0,
            powerDeltaMilliwatts: statusSnapshot?.powerDeltaMilliwatts ?? 0,
            peakPowerMilliwatts: statusSnapshot?.peakPowerMilliwatts ?? 0,
            peakPowerWattsText: statusSnapshot?.peakPowerText ?? "—",
            powerDeltaWattsText: statusSnapshot.map {
                $0.powerDeltaMilliwatts == 0 ? "—" : String(format: "%.3f W", $0.powerDeltaMilliwatts / 1000.0)
            } ?? "—",
            clientCount: statusSnapshot?.clientCount ?? 0,
            activitySeries: activitySeries,
            powerSeries: powerSeries,
            latestStatusSnapshot: statusSnapshot,
            latestSnapshot: snapshot.latestSnapshot
        )
    }

    private func makeDiskIOSnapshot(from snapshot: DiskIOSamplerPollingSnapshot) -> DiskIOSamplerLiveSnapshot {
        let sampleTimestamp = timestamp(
            latestSnapshot: snapshot.latestSnapshot,
            fallback: latestTelemetryFrame.timestamp
        )
        let readSeries = appendSeriesValue(
            metric(snapshot.latestSnapshot, .diskReadMBps),
            to: diskIOSampler.readSeries,
            at: sampleTimestamp
        )
        let writeSeries = appendSeriesValue(
            metric(snapshot.latestSnapshot, .diskWriteMBps),
            to: diskIOSampler.writeSeries,
            at: sampleTimestamp
        )
        let readValue = metric(snapshot.latestSnapshot, .diskReadMBps)
        let writeValue = metric(snapshot.latestSnapshot, .diskWriteMBps)
        return DiskIOSamplerLiveSnapshot(
            readMBps: readValue.map(Float.init),
            writeMBps: writeValue.map(Float.init),
            readText: formatRate(readValue),
            writeText: formatRate(writeValue),
            readPeakText: formatPeakRate(readSeries.peakObservedValue),
            writePeakText: formatPeakRate(writeSeries.peakObservedValue),
            readHistory: normalizedHistory(from: readSeries, ceiling: Self.diskHistoryNormalizationCeilingMBps),
            writeHistory: normalizedHistory(from: writeSeries, ceiling: Self.diskHistoryNormalizationCeilingMBps),
            readSeries: readSeries,
            writeSeries: writeSeries,
            latestSnapshot: snapshot.latestSnapshot
        )
    }

    private func makeNetworkSnapshot(from snapshot: NetworkStatsSamplerPollingSnapshot) -> NetworkStatsSamplerLiveSnapshot {
        let sampleTimestamp = timestamp(
            latestSnapshot: snapshot.latestSnapshot,
            fallback: latestTelemetryFrame.timestamp
        )
        let uploadSeries = appendSeriesValue(
            metric(snapshot.latestSnapshot, .networkUploadMBps),
            to: networkSampler.uploadSeries,
            at: sampleTimestamp
        )
        let downloadSeries = appendSeriesValue(
            metric(snapshot.latestSnapshot, .networkDownloadMBps),
            to: networkSampler.downloadSeries,
            at: sampleTimestamp
        )
        let shouldAppendPingSample =
            snapshot.lastPingSampleDate != nil &&
            snapshot.lastPingSampleDate != networkSampler.lastPingSampleDate
        let pingSampleTimestamp = snapshot.lastPingSampleDate ?? sampleTimestamp
        let pingLatencySeries = shouldAppendPingSample
            ? appendSeriesValue(
                snapshot.pingLatencyMilliseconds,
                to: networkSampler.pingLatencySeries,
                at: pingSampleTimestamp
            )
            : networkSampler.pingLatencySeries
        let pingPacketLossSeries = shouldAppendPingSample
            ? appendSeriesValue(
                snapshot.pingPacketLossRatio,
                to: networkSampler.pingPacketLossSeries,
                at: pingSampleTimestamp
            )
            : networkSampler.pingPacketLossSeries
        let uploadValue = metric(snapshot.latestSnapshot, .networkUploadMBps)
        let downloadValue = metric(snapshot.latestSnapshot, .networkDownloadMBps)
        return NetworkStatsSamplerLiveSnapshot(
            uploadMBps: uploadValue.map(Float.init),
            downloadMBps: downloadValue.map(Float.init),
            uploadText: formatRate(uploadValue),
            downloadText: formatRate(downloadValue),
            uploadPeakText: formatPeakRate(uploadSeries.peakObservedValue),
            downloadPeakText: formatPeakRate(downloadSeries.peakObservedValue),
            uploadHistory: normalizedHistory(from: uploadSeries, ceiling: Self.networkHistoryNormalizationCeilingMBps),
            downloadHistory: normalizedHistory(from: downloadSeries, ceiling: Self.networkHistoryNormalizationCeilingMBps),
            pingLatencyHistory: pingLatencySeries.values().map {
                Float(min(max($0 / 200.0, 0.0), 1.0))
            },
            pingPacketLossHistory: pingPacketLossSeries.values().map {
                Float(min(max($0, 0.0), 1.0))
            },
            uploadSeries: uploadSeries,
            downloadSeries: downloadSeries,
            pingLatencySeries: pingLatencySeries,
            pingPacketLossSeries: pingPacketLossSeries,
            latestSnapshot: snapshot.latestSnapshot,
            sessionUploadMB: snapshot.sessionUploadMB,
            sessionDownloadMB: snapshot.sessionDownloadMB,
            pingTargetLabel: snapshot.pingTargetLabel,
            pingLatencyMilliseconds: snapshot.pingLatencyMilliseconds,
            pingPacketLossRatio: snapshot.pingPacketLossRatio,
            pingLatencyText: snapshot.pingLatencyMilliseconds.map {
                $0 >= 100 ? String(format: "Ping %.0f ms", $0) : String(format: "Ping %.1f ms", $0)
            } ?? "Ping —",
            pingPacketLossText: snapshot.pingPacketLossRatio.map {
                String(format: "Loss %.1f%%", $0 * 100.0)
            } ?? "Loss —",
            lastPingSampleDate: snapshot.lastPingSampleDate
        )
    }

    private func makeMediaEngineSnapshot(from snapshot: MediaEngineStatsSamplerPollingSnapshot) -> MediaEngineStatsSamplerLiveSnapshot {
        let capabilityState = snapshot.latestCapabilityState
        let activitySummary = snapshot.latestActivitySummary
        let recentSessions = snapshot.recentSessions
        var activityHistory = mediaEngineSampler.activityHistory
        if let activitySummary {
            activityHistory.append(Float(activitySummary.activityValue))
            if activityHistory.count > Self.liveSeriesCapacity {
                activityHistory.removeFirst(activityHistory.count - Self.liveSeriesCapacity)
            }
        }
        return MediaEngineStatsSamplerLiveSnapshot(
            isSupported: capabilityState?.isSupported ?? false,
            hasEverDetectedSupport: capabilityState?.hasEverDetectedSupport ?? mediaEngineSampler.hasEverDetectedSupport,
            shouldShowCard: capabilityState?.shouldShowCard ?? mediaEngineSampler.shouldShowCard,
            isActive: activitySummary?.activityState != .idle,
            supportsEncode: capabilityState?.supportsEncode ?? false,
            supportsDecode: capabilityState?.supportsDecode ?? false,
            supportedCodecsText: capabilityState?.supportedCodecsText ?? "—",
            latestCapabilityState: capabilityState,
            subtitleText: activitySummary?.subtitleText(supportsEncode: capabilityState?.supportsEncode ?? false) ?? "Hardware encode available",
            statusText: activitySummary?.statusText ?? "Idle",
            codecText: activitySummary?.codecText ?? "—",
            framesProcessedText: activitySummary?.framesProcessedText ?? "—",
            sessionsText: activitySummary?.sessionsText ?? "—",
            lastActiveText: activitySummary?.lastActiveText ?? "—",
            latestActivitySummary: activitySummary,
            recentSessions: recentSessions,
            activityState: activitySummary?.activityState ?? .idle,
            activityValue: Float(activitySummary?.activityValue ?? 0),
            activityHistory: activityHistory,
            activitySeries: mediaEngineSampler.activitySeries
        )
    }

    private func makePowerSnapshot(from snapshot: PowerStatsSamplerPollingSnapshot) -> PowerStatsSamplerLiveSnapshot {
        let sampleTimestamp = timestamp(
            latestSnapshot: snapshot.latestSnapshot,
            fallback: latestTelemetryFrame.timestamp
        )
        let systemSnapshot = snapshot.latestSystemSnapshot
        let readingsSnapshot = snapshot.latestReadingsSnapshot
        let shouldRecordLivePower = (readingsSnapshot?.sampleStatus ?? snapshot.sampleStatus) == .live
        let cpuPowerSeries = appendSeriesValue(
            shouldRecordLivePower ? readingsSnapshot?.cpuPowerWatts : nil,
            to: powerStatsSampler.cpuPowerSeries,
            at: sampleTimestamp
        )
        let gpuPowerSeries = appendSeriesValue(
            shouldRecordLivePower ? readingsSnapshot?.gpuPowerWatts : nil,
            to: powerStatsSampler.gpuPowerSeries,
            at: sampleTimestamp
        )
        let anePowerSeries = appendSeriesValue(
            shouldRecordLivePower ? readingsSnapshot?.anePowerWatts : nil,
            to: powerStatsSampler.anePowerSeries,
            at: sampleTimestamp
        )
        let combinedPowerSeries = appendSeriesValue(
            shouldRecordLivePower ? readingsSnapshot?.combinedPowerWatts : nil,
            to: powerStatsSampler.combinedPowerSeries,
            at: sampleTimestamp
        )
        let cumulativeEnergySeries = appendSeriesValue(
            shouldRecordLivePower ? readingsSnapshot?.cumulativeCombinedEnergyWh : nil,
            to: powerStatsSampler.cumulativeEnergySeries,
            at: sampleTimestamp
        )
        let gpuFrequencySeries = appendSeriesValue(
            shouldRecordLivePower ? readingsSnapshot?.gpuFrequencyMHz : nil,
            to: powerStatsSampler.gpuFrequencySeries,
            at: sampleTimestamp
        )
        let perCoreFrequencySeries = appendPerCoreSeriesValues(
            shouldRecordLivePower
                ? (readingsSnapshot?.perCoreFrequenciesHz ?? []).map { Optional($0 / 1_000_000.0) }
                : [],
            to: powerStatsSampler.perCoreFrequencySeries,
            key: .cpuCoreFrequencyMHz,
            unit: .megahertz,
            at: sampleTimestamp
        )
        return PowerStatsSamplerLiveSnapshot(
            uptimeText: systemSnapshot?.uptimeText ?? "—",
            batteryPercent: systemSnapshot?.batteryPercent,
            cycleCount: systemSnapshot?.cycleCount,
            processCount: systemSnapshot?.processCount,
            cpuPowerWattsText: readingsSnapshot?.cpuPowerWattsText ?? "—",
            gpuPowerWattsText: readingsSnapshot?.gpuPowerWattsText ?? "—",
            anePowerWattsText: readingsSnapshot?.anePowerWattsText ?? "—",
            combinedPowerWattsText: readingsSnapshot?.combinedPowerWattsText ?? "—",
            peakCombinedPowerWattsText: readingsSnapshot?.peakCombinedPowerWattsText ?? "—",
            cumulativeCombinedEnergyText: readingsSnapshot?.cumulativeCombinedEnergyText ?? "—",
            cumulativeCombinedEnergyWh: readingsSnapshot?.cumulativeCombinedEnergyWh ?? 0,
            gpuFrequencyMHzText: readingsSnapshot?.gpuFrequencyMHzText ?? "—",
            perCoreFrequenciesHz: readingsSnapshot?.perCoreFrequenciesHz ?? [],
            perCoreFrequencySeries: perCoreFrequencySeries,
            livePowerReadingsText: readingsSnapshot?.livePowerReadingsText ?? "—",
            anePowerMilliwatts: readingsSnapshot?.anePowerMilliwatts,
            sampleStatus: readingsSnapshot?.sampleStatus ?? snapshot.sampleStatus,
            lastPowerSampleDate: readingsSnapshot?.lastPowerSampleDate ?? snapshot.lastPowerSampleDate,
            lastUsablePowerSampleDate: readingsSnapshot?.lastUsablePowerSampleDate ?? snapshot.lastUsablePowerSampleDate,
            source: readingsSnapshot?.source ?? snapshot.source,
            failureReason: readingsSnapshot?.failureReason ?? snapshot.failureReason,
            latestSystemSnapshot: systemSnapshot,
            latestReadingsSnapshot: readingsSnapshot,
            cpuPowerSeries: cpuPowerSeries,
            gpuPowerSeries: gpuPowerSeries,
            anePowerSeries: anePowerSeries,
            combinedPowerSeries: combinedPowerSeries,
            cumulativeEnergySeries: cumulativeEnergySeries,
            gpuFrequencySeries: gpuFrequencySeries,
            latestSnapshot: snapshot.latestSnapshot,
            monitoringSessionStartDate: snapshot.monitoringSessionStartDate,
            hardwareAgentUptimeSeconds: snapshot.hardwareAgentUptimeSeconds
        )
    }
}

private actor RemoteHardwareHistoryReaderProxy: HardwareHistoryQuerying {
    private let client: HardwareMonitoringServiceClient

    init(client: HardwareMonitoringServiceClient) {
        self.client = client
    }

    func metricTimeline(
        for key: HardwareMetricKey,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> [HardwareHistoryMetricBucket] {
        await withCheckedContinuation { continuation in
            let client = self.client
            Task { @MainActor in
                client.fetchMetricTimeline(
                    for: key,
                    in: range,
                    bucketIntervalSeconds: bucketIntervalSeconds
                ) { timeline in
                    continuation.resume(returning: timeline ?? [])
                }
            }
        }
    }

    func metricSummary(
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

    func deviceMetricTimeline(
        for key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> [HardwareHistoryMetricBucket] {
        await withCheckedContinuation { continuation in
            let client = self.client
            Task { @MainActor in
                client.fetchDeviceMetricTimeline(
                    for: key,
                    deviceID: deviceID,
                    deviceKind: deviceKind,
                    in: range,
                    bucketIntervalSeconds: bucketIntervalSeconds
                ) { timeline in
                    continuation.resume(returning: timeline ?? [])
                }
            }
        }
    }

    func deviceMetricSummary(
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

    func availableDevices(
        ofKind deviceKind: HardwareDeviceKind?,
        in range: DateInterval
    ) async -> [HardwareHistoryDeviceIdentity] {
        await withCheckedContinuation { continuation in
            let client = self.client
            Task { @MainActor in
                client.fetchAvailableDevices(deviceKind: deviceKind, in: range) { devices in
                    continuation.resume(returning: devices ?? [])
                }
            }
        }
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
            (lhs.maxValue ?? lhs.lastValue ?? lhs.averageValue ?? -Double.infinity)
                < (rhs.maxValue ?? rhs.lastValue ?? rhs.averageValue ?? -Double.infinity)
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
            peakValue: peakBucket?.maxValue ?? peakBucket?.lastValue ?? peakBucket?.averageValue,
            peakBucketStart: peakBucket?.bucketStart
        )
    }
}

private actor RemoteHardwareProcessHistoryReaderProxy: ProcessHistoryQuerying {
    private let client: HardwareMonitoringServiceClient

    init(client: HardwareMonitoringServiceClient) {
        self.client = client
    }

    func processTimeline(
        for identity: PersistedProcessIdentity,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> [PersistedProcessRollup] {
        await withCheckedContinuation { continuation in
            let client = self.client
            Task { @MainActor in
                client.fetchProcessTimeline(
                    for: identity,
                    in: range,
                    bucketIntervalSeconds: bucketIntervalSeconds
                ) { timeline in
                    let rollups = timeline?.map(\.rollup) ?? []
                    continuation.resume(returning: rollups)
                }
            }
        }
    }

    func processSummary(
        for identity: PersistedProcessIdentity,
        in range: DateInterval,
        bucketIntervalSeconds: Int
    ) async -> PersistedProcessRollup? {
        await withCheckedContinuation { continuation in
            let client = self.client
            Task { @MainActor in
                client.fetchProcessSummary(
                    for: identity,
                    in: range,
                    bucketIntervalSeconds: bucketIntervalSeconds
                ) { summary in
                    guard let summary = summary else {
                        continuation.resume(returning: nil)
                        return
                    }
                    // Convert ProcessHistorySummary to PersistedProcessRollup
                    let rollup = PersistedProcessRollup(
                        identity: identity,
                        observedCount: summary.rollup.observedCount,
                        estimatedObservedSeconds: summary.rollup.estimatedObservedSeconds,
                        avgCPUPercent: summary.rollup.avgCPUPercent,
                        maxCPUPercent: summary.rollup.maxCPUPercent,
                        avgRAMMB: summary.rollup.avgRAMMB,
                        maxRAMMB: summary.rollup.maxRAMMB,
                        gpuActiveRatio: summary.rollup.gpuActiveRatio,
                        gpuActiveCount: summary.rollup.gpuActiveCount,
                        avgGPUTimeNS: summary.rollup.avgGPUTimeNS,
                        maxGPUTimeNS: summary.rollup.maxGPUTimeNS,
                        avgPowerScore: summary.rollup.avgPowerScore,
                        lastUptimeSeconds: summary.rollup.lastUptimeSeconds
                    )
                    continuation.resume(returning: rollup)
                }
            }
        }
    }

    func topProcesses(
        in range: DateInterval,
        limit: Int
    ) async -> [PersistedProcessRollup] {
        // Stub implementation - would need to fetch from client
        return []
    }
}

private actor RemoteHardwareEventReaderProxy: HardwareEventQuerying {
    private let client: HardwareMonitoringServiceClient

    init(client: HardwareMonitoringServiceClient) {
        self.client = client
    }

    func events(
        in range: DateInterval,
        categories: [HardwareEventCategory]?,
        limit: Int
    ) async -> [HardwareTimelineEvent] {
        await withCheckedContinuation { continuation in
            let client = self.client
            Task { @MainActor in
                client.fetchEvents(
                    in: range,
                    categories: categories,
                    limit: limit
                ) { events in
                    continuation.resume(returning: events ?? [])
                }
            }
        }
    }
}
