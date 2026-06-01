//
//  RemoteMachineHardwareBridge.swift
//  PodcastPreview
//
//  Bridges a RemoteMachineConnection's polling snapshots into local sampler
//  instances so that HardwareStatsGraphColumn / HardwareStatsSidebar can
//  consume them identically to the local hardware case.
//

import Foundation
import Combine
import PodcastPreviewCore
import PodcastPreviewShared

@MainActor
final class RemoteMachineHardwareBridge: ObservableObject {
    private static var liveSeriesCapacity: Int {
        HardwareCollectionSettings.liveSeriesCapacity()
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
    let networkInterfaceSampler: NetworkInterfaceSampler
    let mediaEngineSampler = MediaEngineStatsSampler()
    let powerStatsSampler = PowerStatsSampler()
    let historyDatabase: HardwareHistoryDatabase
    lazy var historyReader = HardwareHistoryReader(database: historyDatabase)
    lazy var insightsService = HardwareInsightsService(historyReader: historyReader)
    let otherAppsSampler: OtherAppsSampler
    private let historyStore: HardwareHistoryStore

    @Published private(set) var latestTelemetryFrame = HardwareTelemetryFrame()
    @Published private(set) var isActive = false

    private var cancellables = Set<AnyCancellable>()
    private weak var connection: RemoteMachineConnection?

    init(connection: RemoteMachineConnection) {
        let database = try! HardwareHistoryDatabase(rootURL: Self.isolatedHistoryRootURL(for: connection.id))
        self.historyDatabase = database
        self.historyStore = HardwareHistoryStore(database: database)
        self.networkInterfaceSampler = NetworkInterfaceSampler(autoRefresh: false)
        self.connection = connection
        self.otherAppsSampler = OtherAppsSampler(
            sampler: runningAppsSampler,
            gpuSampler: gpuSampler,
            gpuClientsSampler: gpuClientsSampler,
            iconProvider: AppRunningApplicationProvider.live
        )

        // Subscribe to polling snapshots from the network connection
        connection.$latestPollingSnapshot
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.apply(snapshot)
            }
            .store(in: &cancellables)

        // Subscribe to telemetry frames
        connection.$latestTelemetryFrame
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame in
                self?.applyTelemetryFrame(frame)
            }
            .store(in: &cancellables)
    }

    func isBound(to connection: RemoteMachineConnection) -> Bool {
        self.connection === connection
    }

    // MARK: - Apply Polling Snapshot

    private func apply(_ snapshot: HardwareCollectorPollingSnapshot) {
        latestTelemetryFrame = snapshot.latestTelemetryFrame
        persistHistoryFrame(snapshot.latestTelemetryFrame, estimatedObservedSeconds: max(1, snapshot.status.collectorIntervalSeconds))

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
        powerStatsSampler.applyRemoteSnapshot(makePowerSnapshot(from: snapshot.power))
        applyIdentityMetadata(from: snapshot)
    }

    private func applyTelemetryFrame(_ frame: HardwareTelemetryFrame) {
        latestTelemetryFrame = frame
        isActive = true
        persistHistoryFrame(frame)

        if frame.deviceSnapshots.isEmpty == false {
            gpuSampler.applyRemoteSnapshot(makeGPUTelemetrySnapshot(from: frame.deviceSnapshots))
        }

        guard let snapshot = frame.snapshot else { return }

        cpuSampler.applyRemoteSnapshot(makeCPUTelemetrySnapshot(from: snapshot))
        thermalSampler.applyRemoteSnapshot(makeThermalTelemetrySnapshot(from: snapshot))
        ramSampler.applyRemoteSnapshot(makeRAMTelemetrySnapshot(from: snapshot))
        aneSampler.applyRemoteSnapshot(makeANETelemetrySnapshot(from: snapshot))
        diskIOSampler.applyRemoteSnapshot(makeDiskIOTelemetrySnapshot(from: snapshot))
        networkSampler.applyRemoteSnapshot(makeNetworkTelemetrySnapshot(from: snapshot))
        powerStatsSampler.applyRemoteSnapshot(makePowerTelemetrySnapshot(from: snapshot))
    }

    private func applyIdentityMetadata(from snapshot: HardwareCollectorPollingSnapshot) {
        if let gpuIdentityUnits = snapshot.gpuIdentityUnits, !gpuIdentityUnits.isEmpty {
            gpuIdentityProber.gpuUnits = gpuIdentityUnits
        } else if gpuIdentityProber.gpuUnits.isEmpty, snapshot.gpu.gpus.isEmpty == false {
            let machineIdentity = connection?.identity
            gpuIdentityProber.gpuUnits = snapshot.gpu.gpus.map {
                makeFallbackGPUIdentity(from: $0, machineIdentity: machineIdentity)
            }
        }

        if let memoryIdentityUnit = snapshot.memoryIdentityUnit {
            memoryIdentityProber.memoryUnit = memoryIdentityUnit
        } else if memoryIdentityProber.memoryUnit == nil,
                  let fallbackMemoryUnit = makeFallbackMemoryIdentity(
                    from: snapshot.ram,
                    machineIdentity: connection?.identity
                  ) {
            memoryIdentityProber.memoryUnit = fallbackMemoryUnit
        }

        if let networkInterfaceSnapshot = snapshot.networkInterfaceSnapshot {
            let liveSnapshot = NetworkInterfaceSamplerLiveSnapshot(
                ipv4Address: networkInterfaceSnapshot.ipv4Address ?? "",
                routerAddress: networkInterfaceSnapshot.routerAddress ?? "",
                dnsServers: networkInterfaceSnapshot.dnsServers.joined(separator: ", "),
                interfaceName: networkInterfaceSnapshot.interfaceName ?? "",
                isVPNActive: networkInterfaceSnapshot.isVPNActive,
                latestSnapshot: networkInterfaceSnapshot
            )
            networkInterfaceSampler.applyRemoteSnapshot(liveSnapshot)
        }
    }

    private func makeFallbackGPUIdentity(
        from gpu: GPUStatsSampler.GPUUnit,
        machineIdentity: RemoteMachineIdentity?
    ) -> GPUUnitMetadata {
        let inferredArchitecture = inferredMemoryArchitecture(from: machineIdentity)
        let inferredGPUType: String?
        if inferredArchitecture == "Unified" {
            inferredGPUType = "Integrated"
        } else if gpu.vramTotalMB != nil || gpu.vramUsedMB != nil || gpu.vramFreeMB != nil {
            inferredGPUType = "Discrete"
        } else {
            inferredGPUType = nil
        }

        return GPUUnitMetadata(
            id: gpu.id,
            name: gpu.name,
            vendor: inferredGPUVendor(from: gpu.name),
            bus: nil,
            gpuType: inferredGPUType,
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

    private func makeFallbackMemoryIdentity(
        from snapshot: RAMStatsSamplerPollingSnapshot,
        machineIdentity: RemoteMachineIdentity?
    ) -> MemoryUnitMetadata? {
        let totalBytes = snapshot.latestMemorySnapshot?.totalBytes ?? bytes(fromGigabytes: machineIdentity?.totalRAMGB)
        let totalMemory = totalBytes.map { formatGigabytes(Double($0) / 1_073_741_824.0) }
        let architecture = inferredMemoryArchitecture(from: machineIdentity)
        let chip = machineIdentity?.chipType ?? machineIdentity?.cpuName

        guard totalMemory != nil || chip != nil || machineIdentity?.modelIdentifier != nil else { return nil }

        return MemoryUnitMetadata(
            id: machineIdentity.map { "remote-memory-\($0.machineID)" } ?? "remote-memory-unit",
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
            chip: chip,
            machineModel: machineIdentity?.modelIdentifier,
            modules: []
        )
    }

    private func inferredMemoryArchitecture(from machineIdentity: RemoteMachineIdentity?) -> String? {
        let hints = [
            machineIdentity?.chipType?.lowercased(),
            machineIdentity?.cpuName?.lowercased()
        ].compactMap { $0 }

        if hints.contains(where: {
            $0.contains("apple") ||
            $0.contains("m1") ||
            $0.contains("m2") ||
            $0.contains("m3") ||
            $0.contains("m4")
        }) {
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

    // MARK: - Snapshot Builders (mirroring RemoteHardwareMonitoringBridge)

    private func timestamp(latestSnapshot: HardwareSnapshot?, fallback: Date) -> Date {
        latestSnapshot?.timestamp ?? fallback
    }

    private func metric(_ snapshot: HardwareSnapshot?, _ key: HardwareMetricKey) -> Double? {
        snapshot?.metric(key)
    }

    private func metric(_ snapshot: HardwareDeviceSnapshot, _ key: HardwareDeviceMetricKey) -> Double? {
        snapshot.metric(key)
    }

    private func persistHistoryFrame(_ frame: HardwareTelemetryFrame, estimatedObservedSeconds: Int = 1) {
        guard frame.isEmpty == false else { return }
        let historyStore = self.historyStore
        Task(priority: .utility) {
            await historyStore.append(frame, estimatedObservedSeconds: max(1, estimatedObservedSeconds))
        }
    }

    private static func isolatedHistoryRootURL(for machineID: String) -> URL {
        let machineComponent = machineID.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
        }.joined()
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastPreviewRemoteHistory", isDirectory: true)
            .appendingPathComponent(machineComponent, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func appendSeriesValue(_ value: Double?, to currentSeries: MetricSeries, at timestamp: Date) -> MetricSeries {
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

    private func normalizedHistory(from series: MetricSeries, ceiling: Double) -> [Float] {
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

    private func formatWatts(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.3f W", value)
    }

    private func formatEnergy(_ wattHours: Double) -> String {
        guard wattHours >= 0 else { return "—" }
        if wattHours < 1.0 {
            return String(format: "%.0f mWh", wattHours * 1000.0)
        }
        return String(format: "%.2f Wh", wattHours)
    }

    private func bytes(fromGigabytes value: Double?) -> UInt64? {
        guard let value else { return nil }
        return UInt64(max(value, 0) * 1_073_741_824.0)
    }

    private func formatGigabytes(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f GB", value)
    }

    private func formatPair(used: Double?, total: Double?) -> String {
        guard let used, let total else { return "—" }
        return String(format: "%.1f / %.1f GB", used, total)
    }

    private func aneActivityState(for activityRatio: Double) -> ANEStatsSampler.ActivityState {
        switch activityRatio {
        case let ratio where ratio >= 0.66:
            return .busy
        case let ratio where ratio >= 0.08:
            return .active
        default:
            return .idle
        }
    }

    private func makeCPUTelemetrySnapshot(from snapshot: HardwareSnapshot) -> CPUSamplerLiveSnapshot {
        let sampleTimestamp = snapshot.timestamp
        let totalSeries = appendSeriesValue(metric(snapshot, .cpuTotalUsage), to: cpuSampler.totalUsageSeries, at: sampleTimestamp)
        let efficiencySeries = appendSeriesValue(metric(snapshot, .cpuEfficiencyUsage), to: cpuSampler.efficiencyUsageSeries, at: sampleTimestamp)
        let performanceSeries = appendSeriesValue(metric(snapshot, .cpuPerformanceUsage), to: cpuSampler.performanceUsageSeries, at: sampleTimestamp)

        return CPUSamplerLiveSnapshot(
            coreUsages: cpuSampler.coreUsages,
            totalUsage: metric(snapshot, .cpuTotalUsage).map(Float.init),
            usageHistory: totalSeries.values().map(Float.init),
            cpuDisplayName: snapshot.dimension(.cpuDisplayName) ?? cpuSampler.cpuDisplayName,
            systemUsage: metric(snapshot, .cpuSystemUsage).map(Float.init),
            userUsage: metric(snapshot, .cpuUserUsage).map(Float.init),
            idleUsage: metric(snapshot, .cpuIdleUsage).map(Float.init),
            efficiencyUsage: metric(snapshot, .cpuEfficiencyUsage).map(Float.init),
            efficiencyHistory: efficiencySeries.values().map(Float.init),
            performanceUsage: metric(snapshot, .cpuPerformanceUsage).map(Float.init),
            performanceHistory: performanceSeries.values().map(Float.init),
            efficiencyCoreCount: max(cpuSampler.efficiencyCoreCount, Int(metric(snapshot, .cpuEfficiencyCoreCount) ?? 0)),
            performanceCoreCount: max(cpuSampler.performanceCoreCount, Int(metric(snapshot, .cpuPerformanceCoreCount) ?? 0)),
            perCoreUsageSeries: cpuSampler.perCoreUsageSeries,
            totalUsageSeries: totalSeries,
            efficiencyUsageSeries: efficiencySeries,
            performanceUsageSeries: performanceSeries,
            latestSnapshot: snapshot
        )
    }

    private func makeThermalTelemetrySnapshot(from snapshot: HardwareSnapshot) -> ThermalStatsSamplerLiveSnapshot {
        let sampleTimestamp = snapshot.timestamp
        let thermalSeries = appendSeriesValue(metric(snapshot, .thermalLevel), to: thermalSampler.thermalSeries, at: sampleTimestamp)
        return ThermalStatsSamplerLiveSnapshot(
            thermalValue: metric(snapshot, .thermalLevel).map(Float.init),
            thermalLabel: snapshot.dimension(.thermalState) ?? thermalSampler.thermalLabel,
            thermalHistory: thermalSeries.values().map(Float.init),
            thermalSeries: thermalSeries,
            latestSnapshot: snapshot
        )
    }

    private func makeGPUTelemetrySnapshot(from deviceSnapshots: [HardwareDeviceSnapshot]) -> GPUStatsSamplerLiveSnapshot {
        var usageSeriesByGPU = gpuSampler.usageSeriesByGPU
        var rendererSeriesByGPU = gpuSampler.rendererSeriesByGPU
        var tilerSeriesByGPU = gpuSampler.tilerSeriesByGPU
        var memoryUsageSeriesByGPU = gpuSampler.memoryUsageSeriesByGPU
        var gpus = gpuSampler.gpus

        let gpuDeviceSnapshots: [HardwareDeviceSnapshot] = deviceSnapshots.compactMap { deviceSnapshot in
            deviceSnapshot.deviceKind == .gpu ? deviceSnapshot : nil
        }

        for deviceSnapshot in gpuDeviceSnapshots {
            let sampleTimestamp = deviceSnapshot.timestamp
            let deviceID = deviceSnapshot.deviceID

            usageSeriesByGPU[deviceID] = appendDeviceSeriesValue(
                metric(deviceSnapshot, .utilizationRatio),
                to: usageSeriesByGPU[deviceID],
                deviceID: deviceID,
                key: .utilizationRatio,
                at: sampleTimestamp
            )
            rendererSeriesByGPU[deviceID] = appendDeviceSeriesValue(
                metric(deviceSnapshot, .rendererUtilizationRatio),
                to: rendererSeriesByGPU[deviceID],
                deviceID: deviceID,
                key: .rendererUtilizationRatio,
                at: sampleTimestamp
            )
            tilerSeriesByGPU[deviceID] = appendDeviceSeriesValue(
                metric(deviceSnapshot, .tilerUtilizationRatio),
                to: tilerSeriesByGPU[deviceID],
                deviceID: deviceID,
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

            memoryUsageSeriesByGPU[deviceID] = appendDeviceSeriesValue(
                memoryMetricValue,
                to: memoryUsageSeriesByGPU[deviceID],
                deviceID: deviceID,
                key: memoryMetricKey,
                unit: .megabytes,
                at: sampleTimestamp
            )

            guard let existingIndex = gpus.firstIndex(where: { $0.id == deviceID }) else { continue }
            gpus[existingIndex].name = deviceSnapshot.dimension(.name) ?? gpus[existingIndex].name
            gpus[existingIndex].usage = metric(deviceSnapshot, .utilizationRatio).map(Float.init)
            gpus[existingIndex].usageHistory = usageSeriesByGPU[deviceID]?.values().map(Float.init) ?? gpus[existingIndex].usageHistory
            gpus[existingIndex].rendererUsage = metric(deviceSnapshot, .rendererUtilizationRatio).map(Float.init)
            gpus[existingIndex].rendererHistory = rendererSeriesByGPU[deviceID]?.values().map(Float.init) ?? gpus[existingIndex].rendererHistory
            gpus[existingIndex].tilerUsage = metric(deviceSnapshot, .tilerUtilizationRatio).map(Float.init)
            gpus[existingIndex].tilerHistory = tilerSeriesByGPU[deviceID]?.values().map(Float.init) ?? gpus[existingIndex].tilerHistory
            let reportedVRAMTotalMB = metric(deviceSnapshot, .vramTotalMegabytes).map(Int.init)
            if let reportedVRAMTotalMB, reportedVRAMTotalMB > 0 {
                let existingVRAMTotalMB = gpus[existingIndex].vramTotalMB ?? 0
                gpus[existingIndex].vramTotalMB = max(existingVRAMTotalMB, reportedVRAMTotalMB)
            }
            gpus[existingIndex].vramUsedMB = metric(deviceSnapshot, .vramUsedMegabytes).map(Int.init)
            gpus[existingIndex].vramFreeMB = metric(deviceSnapshot, .vramFreeMegabytes).map(Int.init)
            gpus[existingIndex].rendererAllocatedPageBufferMB = metric(deviceSnapshot, .rendererAllocatedPageBufferMegabytes).map(Int.init)
            gpus[existingIndex].tilerSceneKB = metric(deviceSnapshot, .tilerSceneKilobytes).map(Int.init)
            gpus[existingIndex].gpuMemoryAllocatedMB = metric(deviceSnapshot, .memoryAllocatedMegabytes).map(Int.init)
            gpus[existingIndex].gpuMemoryInUseMB = metric(deviceSnapshot, .memoryInUseMegabytes).map(Int.init)
            gpus[existingIndex].gpuMemoryDriverInUseMB = metric(deviceSnapshot, .memoryDriverInUseMegabytes).map(Int.init)
            gpus[existingIndex].temperatureC = metric(deviceSnapshot, .temperatureCelsius).map(Int.init)
            gpus[existingIndex].fanRPM = metric(deviceSnapshot, .fanRPM).map(Int.init)
            gpus[existingIndex].coreClockMHz = metric(deviceSnapshot, .coreClockMegahertz).map(Int.init)
            gpus[existingIndex].memoryClockMHz = metric(deviceSnapshot, .memoryClockMegahertz).map(Int.init)
            gpus[existingIndex].totalPowerW = metric(deviceSnapshot, .totalPowerWatts).map(Int.init)
            gpus[existingIndex].coreCount = metric(deviceSnapshot, .coreCount).map(Int.init)
        }

        return GPUStatsSamplerLiveSnapshot(
            gpus: gpus,
            usageSeriesByGPU: usageSeriesByGPU,
            rendererSeriesByGPU: rendererSeriesByGPU,
            tilerSeriesByGPU: tilerSeriesByGPU,
            memoryUsageSeriesByGPU: memoryUsageSeriesByGPU,
            latestDeviceSnapshots: deviceSnapshots,
            gpuDisplayName: gpus.first?.name ?? gpuSampler.gpuDisplayName
        )
    }

    private func makeRAMTelemetrySnapshot(from snapshot: HardwareSnapshot) -> RAMStatsSamplerLiveSnapshot {
        let sampleTimestamp = snapshot.timestamp
        let usageSeries = appendSeriesValue(metric(snapshot, .ramUsageRatio), to: ramSampler.usageSeries, at: sampleTimestamp)
        let swapSeries = appendSeriesValue(metric(snapshot, .swapUsageRatio), to: ramSampler.swapUsageSeries, at: sampleTimestamp)
        let pressureSeries = appendSeriesValue(metric(snapshot, .memoryPressureRatio), to: ramSampler.pressureSeries, at: sampleTimestamp)

        let totalGB = metric(snapshot, .ramTotalGB)
        let usedGB = metric(snapshot, .ramUsedGB)
        let cachedGB = metric(snapshot, .cachedMemoryGB)
        let compressedGB = metric(snapshot, .compressedMemoryGB)
        let wiredGB = metric(snapshot, .wiredMemoryGB)
        let appGB = metric(snapshot, .appMemoryGB)
        let swapUsedGB = metric(snapshot, .swapUsedGB)
        let swapTotalGB = metric(snapshot, .swapTotalGB)
        let pressureLevel = snapshot.dimension(.memoryPressureLevel) ?? ramSampler.pressureLabel
        let pressureValue = metric(snapshot, .memoryPressureRatio) ?? Double(ramSampler.pressureValue)

        let memorySnapshot = RAMStatsSampler.MemorySnapshot(
            usedBytes: bytes(fromGigabytes: usedGB) ?? ramSampler.latestMemorySnapshot?.usedBytes ?? 0,
            totalBytes: bytes(fromGigabytes: totalGB) ?? ramSampler.latestMemorySnapshot?.totalBytes ?? 0,
            freeBytes: ramSampler.latestMemorySnapshot?.freeBytes ?? 0,
            cachedBytes: bytes(fromGigabytes: cachedGB) ?? ramSampler.latestMemorySnapshot?.cachedBytes ?? 0,
            compressedBytes: bytes(fromGigabytes: compressedGB) ?? ramSampler.latestMemorySnapshot?.compressedBytes ?? 0,
            wiredBytes: bytes(fromGigabytes: wiredGB) ?? ramSampler.latestMemorySnapshot?.wiredBytes ?? 0,
            appMemoryBytes: bytes(fromGigabytes: appGB) ?? ramSampler.latestMemorySnapshot?.appMemoryBytes,
            swapUsedBytes: bytes(fromGigabytes: swapUsedGB) ?? ramSampler.latestMemorySnapshot?.swapUsedBytes,
            swapTotalBytes: bytes(fromGigabytes: swapTotalGB) ?? ramSampler.latestMemorySnapshot?.swapTotalBytes,
            purgeableBytes: ramSampler.latestMemorySnapshot?.purgeableBytes,
            reusableBytes: ramSampler.latestMemorySnapshot?.reusableBytes,
            pressureLevel: pressureLevel,
            pressureValue: pressureValue
        )

        return RAMStatsSamplerLiveSnapshot(
            ramUsage: metric(snapshot, .ramUsageRatio).map(Float.init),
            usageHistory: usageSeries.values().map(Float.init),
            ramLabel: totalGB != nil || usedGB != nil ? formatPair(used: usedGB, total: totalGB) : ramSampler.ramLabel,
            swapLabel: formatPair(used: swapUsedGB, total: swapTotalGB),
            swapUsedRatio: metric(snapshot, .swapUsageRatio).map(Float.init) ?? ramSampler.swapUsedRatio,
            swapUsageHistory: swapSeries.values().map(Float.init),
            swapUsedGB: swapUsedGB,
            swapTotalGB: swapTotalGB,
            cachedFilesLabel: cachedGB != nil ? "Cached \(formatGigabytes(cachedGB))" : ramSampler.cachedFilesLabel,
            compressedLabel: compressedGB != nil ? "Compressed \(formatGigabytes(compressedGB))" : ramSampler.compressedLabel,
            wiredLabel: wiredGB != nil ? "Wired \(formatGigabytes(wiredGB))" : ramSampler.wiredLabel,
            appMemoryLabel: appGB != nil ? "Apps \(formatGigabytes(appGB))" : ramSampler.appMemoryLabel,
            pressureLabel: pressureLevel,
            pressureSubtext: memorySnapshot.pressureSubtext,
            pressureValue: Float(pressureValue),
            pressureHistory: pressureSeries.values().map(Float.init),
            usageSeries: usageSeries,
            swapUsageSeries: swapSeries,
            pressureSeries: pressureSeries,
            latestMemorySnapshot: memorySnapshot,
            latestSnapshot: snapshot
        )
    }

    private func makeANETelemetrySnapshot(from snapshot: HardwareSnapshot) -> ANEStatsSamplerLiveSnapshot {
        let sampleTimestamp = snapshot.timestamp
        let activitySeries = appendSeriesValue(metric(snapshot, .aneActivityRatio), to: aneSampler.activitySeries, at: sampleTimestamp)
        let powerWatts = metric(snapshot, .anePowerWatts)
        let powerSeries = appendSeriesValue(powerWatts, to: aneSampler.powerSeries, at: sampleTimestamp)
        let activityRatio = metric(snapshot, .aneActivityRatio) ?? 0
        let clientCount = Int(metric(snapshot, .aneClientCount) ?? 0)
        let statusSnapshot = ANEStatsSampler.StatusSnapshot(
            coreCount: metric(snapshot, .aneCoreCount).map(Int.init) ?? aneSampler.latestStatusSnapshot?.coreCount,
            architecture: snapshot.dimension(.aneArchitecture) ?? aneSampler.latestStatusSnapshot?.architecture,
            engineStatus: snapshot.dimension(.aneEngineStatus) ?? aneSampler.engineStatusText,
            clients: aneSampler.clientsText,
            activityState: aneActivityState(for: activityRatio),
            activityValue: activityRatio,
            activityStatus: snapshot.dimension(.aneActivityStatus) ?? aneSampler.statusText,
            currentPowerMilliwatts: (powerWatts ?? 0) * 1000.0,
            powerDeltaMilliwatts: aneSampler.powerDeltaMilliwatts,
            peakPowerMilliwatts: max(aneSampler.peakPowerMilliwatts, (powerWatts ?? 0) * 1000.0),
            clientCount: clientCount
        )

        return ANEStatsSamplerLiveSnapshot(
            coreCountText: statusSnapshot.coreCountText,
            architectureText: statusSnapshot.architectureText,
            engineStatusText: statusSnapshot.engineStatus,
            clientsText: statusSnapshot.clients,
            activityState: statusSnapshot.activityState,
            activityValue: Float(statusSnapshot.activityValue),
            activityHistory: activitySeries.values().map(Float.init),
            statusText: statusSnapshot.statusText,
            currentPowerMilliwatts: statusSnapshot.currentPowerMilliwatts,
            powerDeltaMilliwatts: statusSnapshot.powerDeltaMilliwatts,
            peakPowerMilliwatts: statusSnapshot.peakPowerMilliwatts,
            peakPowerWattsText: statusSnapshot.peakPowerText,
            powerDeltaWattsText: statusSnapshot.powerDeltaText,
            clientCount: statusSnapshot.clientCount,
            activitySeries: activitySeries,
            powerSeries: powerSeries,
            latestStatusSnapshot: statusSnapshot,
            latestSnapshot: snapshot
        )
    }

    private func makeDiskIOTelemetrySnapshot(from snapshot: HardwareSnapshot) -> DiskIOSamplerLiveSnapshot {
        let sampleTimestamp = snapshot.timestamp
        let readSeries = appendSeriesValue(metric(snapshot, .diskReadMBps), to: diskIOSampler.readSeries, at: sampleTimestamp)
        let writeSeries = appendSeriesValue(metric(snapshot, .diskWriteMBps), to: diskIOSampler.writeSeries, at: sampleTimestamp)
        let readValue = metric(snapshot, .diskReadMBps)
        let writeValue = metric(snapshot, .diskWriteMBps)
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
            latestSnapshot: snapshot
        )
    }

    private func makeNetworkTelemetrySnapshot(from snapshot: HardwareSnapshot) -> NetworkStatsSamplerLiveSnapshot {
        let sampleTimestamp = snapshot.timestamp
        let uploadSeries = appendSeriesValue(metric(snapshot, .networkUploadMBps), to: networkSampler.uploadSeries, at: sampleTimestamp)
        let downloadSeries = appendSeriesValue(metric(snapshot, .networkDownloadMBps), to: networkSampler.downloadSeries, at: sampleTimestamp)
        let uploadValue = metric(snapshot, .networkUploadMBps)
        let downloadValue = metric(snapshot, .networkDownloadMBps)
        return NetworkStatsSamplerLiveSnapshot(
            uploadMBps: uploadValue.map(Float.init),
            downloadMBps: downloadValue.map(Float.init),
            uploadText: formatRate(uploadValue),
            downloadText: formatRate(downloadValue),
            uploadPeakText: formatPeakRate(uploadSeries.peakObservedValue),
            downloadPeakText: formatPeakRate(downloadSeries.peakObservedValue),
            uploadHistory: normalizedHistory(from: uploadSeries, ceiling: Self.networkHistoryNormalizationCeilingMBps),
            downloadHistory: normalizedHistory(from: downloadSeries, ceiling: Self.networkHistoryNormalizationCeilingMBps),
            pingLatencyHistory: networkSampler.pingLatencyHistory,
            pingPacketLossHistory: networkSampler.pingPacketLossHistory,
            uploadSeries: uploadSeries,
            downloadSeries: downloadSeries,
            pingLatencySeries: networkSampler.pingLatencySeries,
            pingPacketLossSeries: networkSampler.pingPacketLossSeries,
            latestSnapshot: snapshot,
            sessionUploadMB: networkSampler.sessionUploadMB,
            sessionDownloadMB: networkSampler.sessionDownloadMB,
            pingTargetLabel: networkSampler.pingTargetLabel,
            pingLatencyMilliseconds: networkSampler.pingLatencyMilliseconds,
            pingPacketLossRatio: networkSampler.pingPacketLossRatio,
            pingLatencyText: networkSampler.pingLatencyText,
            pingPacketLossText: networkSampler.pingPacketLossText,
            lastPingSampleDate: networkSampler.lastPingSampleDate
        )
    }

    private func makePowerTelemetrySnapshot(from snapshot: HardwareSnapshot) -> PowerStatsSamplerLiveSnapshot {
        let sampleTimestamp = snapshot.timestamp
        let cpuPowerWatts = metric(snapshot, .cpuPowerWatts)
        let gpuPowerWatts = metric(snapshot, .gpuPowerWatts)
        let anePowerWatts = metric(snapshot, .anePowerWatts)
        let combinedPowerWatts = metric(snapshot, .combinedPowerWatts)
        let cumulativeCombinedEnergyWh = metric(snapshot, .cumulativeCombinedEnergyWh) ?? powerStatsSampler.cumulativeCombinedEnergyWh
        let gpuFrequencyMHz = metric(snapshot, .gpuFrequencyMHz)

        let cpuPowerSeries = appendSeriesValue(cpuPowerWatts, to: powerStatsSampler.cpuPowerSeries, at: sampleTimestamp)
        let gpuPowerSeries = appendSeriesValue(gpuPowerWatts, to: powerStatsSampler.gpuPowerSeries, at: sampleTimestamp)
        let anePowerSeries = appendSeriesValue(anePowerWatts, to: powerStatsSampler.anePowerSeries, at: sampleTimestamp)
        let combinedPowerSeries = appendSeriesValue(combinedPowerWatts, to: powerStatsSampler.combinedPowerSeries, at: sampleTimestamp)
        let cumulativeEnergySeries = appendSeriesValue(cumulativeCombinedEnergyWh, to: powerStatsSampler.cumulativeEnergySeries, at: sampleTimestamp)
        let gpuFrequencySeries = appendSeriesValue(gpuFrequencyMHz, to: powerStatsSampler.gpuFrequencySeries, at: sampleTimestamp)

        let systemSnapshot = PowerStatsSampler.SystemSnapshot(
            uptimeSeconds: metric(snapshot, .systemUptimeSeconds) ?? powerStatsSampler.latestSystemSnapshot?.uptimeSeconds ?? 0,
            batteryPercent: powerStatsSampler.latestSystemSnapshot?.batteryPercent,
            cycleCount: powerStatsSampler.latestSystemSnapshot?.cycleCount,
            processCount: powerStatsSampler.latestSystemSnapshot?.processCount
        )
        let readingsSnapshot = PowerStatsSampler.ReadingsSnapshot(
            cpuPowerWatts: cpuPowerWatts,
            gpuPowerWatts: gpuPowerWatts,
            anePowerWatts: anePowerWatts,
            combinedPowerWatts: combinedPowerWatts,
            peakCombinedPowerWatts: max(powerStatsSampler.combinedPowerSeries.peakObservedValue ?? 0, combinedPowerSeries.peakObservedValue ?? 0),
            cumulativeCombinedEnergyWh: cumulativeCombinedEnergyWh,
            gpuFrequencyMHz: gpuFrequencyMHz,
            perCoreFrequenciesHz: powerStatsSampler.perCoreFrequenciesHz,
            anePowerMilliwatts: anePowerWatts.map { $0 * 1000.0 },
            sampleStatus: .live,
            lastPowerSampleDate: sampleTimestamp,
            lastUsablePowerSampleDate: sampleTimestamp,
            source: "remote-telemetry",
            failureReason: nil
        )

        return PowerStatsSamplerLiveSnapshot(
            uptimeText: systemSnapshot.uptimeText,
            batteryPercent: systemSnapshot.batteryPercent,
            cycleCount: systemSnapshot.cycleCount,
            processCount: systemSnapshot.processCount,
            cpuPowerWattsText: formatWatts(cpuPowerWatts),
            gpuPowerWattsText: formatWatts(gpuPowerWatts),
            anePowerWattsText: formatWatts(anePowerWatts),
            combinedPowerWattsText: formatWatts(combinedPowerWatts),
            peakCombinedPowerWattsText: formatWatts(readingsSnapshot.peakCombinedPowerWatts),
            cumulativeCombinedEnergyText: formatEnergy(cumulativeCombinedEnergyWh),
            cumulativeCombinedEnergyWh: cumulativeCombinedEnergyWh,
            gpuFrequencyMHzText: gpuFrequencyMHz.map { String(format: "%.0f MHz", $0) } ?? powerStatsSampler.gpuFrequencyMHzText,
            perCoreFrequenciesHz: readingsSnapshot.perCoreFrequenciesHz,
            perCoreFrequencySeries: powerStatsSampler.perCoreFrequencySeries,
            livePowerReadingsText: readingsSnapshot.livePowerReadingsText,
            anePowerMilliwatts: readingsSnapshot.anePowerMilliwatts,
            sampleStatus: readingsSnapshot.sampleStatus,
            lastPowerSampleDate: readingsSnapshot.lastPowerSampleDate,
            lastUsablePowerSampleDate: readingsSnapshot.lastUsablePowerSampleDate,
            source: readingsSnapshot.source,
            failureReason: readingsSnapshot.failureReason,
            latestSystemSnapshot: systemSnapshot,
            latestReadingsSnapshot: readingsSnapshot,
            cpuPowerSeries: cpuPowerSeries,
            gpuPowerSeries: gpuPowerSeries,
            anePowerSeries: anePowerSeries,
            combinedPowerSeries: combinedPowerSeries,
            cumulativeEnergySeries: cumulativeEnergySeries,
            gpuFrequencySeries: gpuFrequencySeries,
            latestSnapshot: snapshot,
            monitoringSessionStartDate: powerStatsSampler.monitoringSessionStartDate,
            hardwareAgentUptimeSeconds: powerStatsSampler.hardwareAgentUptimeSeconds
        )
    }

    private func makeCPUSnapshot(from snapshot: CPUSamplerPollingSnapshot) -> CPUSamplerLiveSnapshot {
        let sampleTimestamp = timestamp(latestSnapshot: snapshot.latestSnapshot, fallback: latestTelemetryFrame.timestamp)
        let totalSeries = appendSeriesValue(metric(snapshot.latestSnapshot, .cpuTotalUsage), to: cpuSampler.totalUsageSeries, at: sampleTimestamp)
        let efficiencySeries = appendSeriesValue(metric(snapshot.latestSnapshot, .cpuEfficiencyUsage), to: cpuSampler.efficiencyUsageSeries, at: sampleTimestamp)
        let performanceSeries = appendSeriesValue(metric(snapshot.latestSnapshot, .cpuPerformanceUsage), to: cpuSampler.performanceUsageSeries, at: sampleTimestamp)
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
        let sampleTimestamp = timestamp(latestSnapshot: snapshot.latestSnapshot, fallback: latestTelemetryFrame.timestamp)
        let thermalSeries = appendSeriesValue(metric(snapshot.latestSnapshot, .thermalLevel), to: thermalSampler.thermalSeries, at: sampleTimestamp)
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
                metric(deviceSnapshot, .utilizationRatio), to: usageSeriesByGPU[deviceSnapshot.deviceID],
                deviceID: deviceSnapshot.deviceID, key: .utilizationRatio, at: sampleTimestamp
            )
            rendererSeriesByGPU[deviceSnapshot.deviceID] = appendDeviceSeriesValue(
                metric(deviceSnapshot, .rendererUtilizationRatio), to: rendererSeriesByGPU[deviceSnapshot.deviceID],
                deviceID: deviceSnapshot.deviceID, key: .rendererUtilizationRatio, at: sampleTimestamp
            )
            tilerSeriesByGPU[deviceSnapshot.deviceID] = appendDeviceSeriesValue(
                metric(deviceSnapshot, .tilerUtilizationRatio), to: tilerSeriesByGPU[deviceSnapshot.deviceID],
                deviceID: deviceSnapshot.deviceID, key: .tilerUtilizationRatio, at: sampleTimestamp
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
            gpus: snapshot.gpus, usageSeriesByGPU: usageSeriesByGPU,
            rendererSeriesByGPU: rendererSeriesByGPU, tilerSeriesByGPU: tilerSeriesByGPU,
            memoryUsageSeriesByGPU: memoryUsageSeriesByGPU,
            latestDeviceSnapshots: snapshot.latestDeviceSnapshots, gpuDisplayName: snapshot.gpuDisplayName
        )
    }

    private func makeRAMSnapshot(from snapshot: RAMStatsSamplerPollingSnapshot) -> RAMStatsSamplerLiveSnapshot {
        let sampleTimestamp = timestamp(latestSnapshot: snapshot.latestSnapshot, fallback: latestTelemetryFrame.timestamp)
        let usageSeries = appendSeriesValue(metric(snapshot.latestSnapshot, .ramUsageRatio), to: ramSampler.usageSeries, at: sampleTimestamp)
        let swapSeries = appendSeriesValue(metric(snapshot.latestSnapshot, .swapUsageRatio), to: ramSampler.swapUsageSeries, at: sampleTimestamp)
        let pressureSeries = appendSeriesValue(metric(snapshot.latestSnapshot, .memoryPressureRatio), to: ramSampler.pressureSeries, at: sampleTimestamp)
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
        let sampleTimestamp = timestamp(latestSnapshot: snapshot.latestSnapshot, fallback: latestTelemetryFrame.timestamp)
        let statusSnapshot = snapshot.latestStatusSnapshot
        let activitySeries = appendSeriesValue(
            metric(snapshot.latestSnapshot, .aneActivityRatio), to: aneSampler.activitySeries, at: sampleTimestamp
        )
        let powerSeries = appendSeriesValue(
            statusSnapshot.map { $0.currentPowerMilliwatts > 0 ? $0.currentPowerMilliwatts / 1000.0 : nil } ?? nil,
            to: aneSampler.powerSeries, at: sampleTimestamp
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
        let sampleTimestamp = timestamp(latestSnapshot: snapshot.latestSnapshot, fallback: latestTelemetryFrame.timestamp)
        let readSeries = appendSeriesValue(metric(snapshot.latestSnapshot, .diskReadMBps), to: diskIOSampler.readSeries, at: sampleTimestamp)
        let writeSeries = appendSeriesValue(metric(snapshot.latestSnapshot, .diskWriteMBps), to: diskIOSampler.writeSeries, at: sampleTimestamp)
        let readValue = metric(snapshot.latestSnapshot, .diskReadMBps)
        let writeValue = metric(snapshot.latestSnapshot, .diskWriteMBps)
        return DiskIOSamplerLiveSnapshot(
            readMBps: readValue.map(Float.init), writeMBps: writeValue.map(Float.init),
            readText: formatRate(readValue), writeText: formatRate(writeValue),
            readPeakText: formatPeakRate(readSeries.peakObservedValue), writePeakText: formatPeakRate(writeSeries.peakObservedValue),
            readHistory: normalizedHistory(from: readSeries, ceiling: Self.diskHistoryNormalizationCeilingMBps),
            writeHistory: normalizedHistory(from: writeSeries, ceiling: Self.diskHistoryNormalizationCeilingMBps),
            readSeries: readSeries, writeSeries: writeSeries,
            latestSnapshot: snapshot.latestSnapshot
        )
    }

    private func makeNetworkSnapshot(from snapshot: NetworkStatsSamplerPollingSnapshot) -> NetworkStatsSamplerLiveSnapshot {
        let sampleTimestamp = timestamp(latestSnapshot: snapshot.latestSnapshot, fallback: latestTelemetryFrame.timestamp)
        let uploadSeries = appendSeriesValue(metric(snapshot.latestSnapshot, .networkUploadMBps), to: networkSampler.uploadSeries, at: sampleTimestamp)
        let downloadSeries = appendSeriesValue(metric(snapshot.latestSnapshot, .networkDownloadMBps), to: networkSampler.downloadSeries, at: sampleTimestamp)
        let shouldAppendPingSample =
            snapshot.lastPingSampleDate != nil &&
            snapshot.lastPingSampleDate != networkSampler.lastPingSampleDate
        let pingSampleTimestamp = snapshot.lastPingSampleDate ?? sampleTimestamp
        let pingLatencySeries = shouldAppendPingSample
            ? appendSeriesValue(snapshot.pingLatencyMilliseconds, to: networkSampler.pingLatencySeries, at: pingSampleTimestamp)
            : networkSampler.pingLatencySeries
        let pingPacketLossSeries = shouldAppendPingSample
            ? appendSeriesValue(snapshot.pingPacketLossRatio, to: networkSampler.pingPacketLossSeries, at: pingSampleTimestamp)
            : networkSampler.pingPacketLossSeries
        let uploadValue = metric(snapshot.latestSnapshot, .networkUploadMBps)
        let downloadValue = metric(snapshot.latestSnapshot, .networkDownloadMBps)
        return NetworkStatsSamplerLiveSnapshot(
            uploadMBps: uploadValue.map(Float.init), downloadMBps: downloadValue.map(Float.init),
            uploadText: formatRate(uploadValue), downloadText: formatRate(downloadValue),
            uploadPeakText: formatPeakRate(uploadSeries.peakObservedValue), downloadPeakText: formatPeakRate(downloadSeries.peakObservedValue),
            uploadHistory: normalizedHistory(from: uploadSeries, ceiling: Self.networkHistoryNormalizationCeilingMBps),
            downloadHistory: normalizedHistory(from: downloadSeries, ceiling: Self.networkHistoryNormalizationCeilingMBps),
            pingLatencyHistory: pingLatencySeries.values().map {
                Float(min(max($0 / 200.0, 0.0), 1.0))
            },
            pingPacketLossHistory: pingPacketLossSeries.values().map {
                Float(min(max($0, 0.0), 1.0))
            },
            uploadSeries: uploadSeries, downloadSeries: downloadSeries,
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
        let sampleTimestamp = timestamp(latestSnapshot: snapshot.latestSnapshot, fallback: latestTelemetryFrame.timestamp)
        let systemSnapshot = snapshot.latestSystemSnapshot
        let readingsSnapshot = snapshot.latestReadingsSnapshot
        let shouldRecordLivePower = (readingsSnapshot?.sampleStatus ?? snapshot.sampleStatus) == .live
        let cpuPowerSeries = appendSeriesValue(shouldRecordLivePower ? readingsSnapshot?.cpuPowerWatts : nil, to: powerStatsSampler.cpuPowerSeries, at: sampleTimestamp)
        let gpuPowerSeries = appendSeriesValue(shouldRecordLivePower ? readingsSnapshot?.gpuPowerWatts : nil, to: powerStatsSampler.gpuPowerSeries, at: sampleTimestamp)
        let anePowerSeries = appendSeriesValue(shouldRecordLivePower ? readingsSnapshot?.anePowerWatts : nil, to: powerStatsSampler.anePowerSeries, at: sampleTimestamp)
        let combinedPowerSeries = appendSeriesValue(shouldRecordLivePower ? readingsSnapshot?.combinedPowerWatts : nil, to: powerStatsSampler.combinedPowerSeries, at: sampleTimestamp)
        let cumulativeEnergySeries = appendSeriesValue(shouldRecordLivePower ? readingsSnapshot?.cumulativeCombinedEnergyWh : nil, to: powerStatsSampler.cumulativeEnergySeries, at: sampleTimestamp)
        let gpuFrequencySeries = appendSeriesValue(shouldRecordLivePower ? readingsSnapshot?.gpuFrequencyMHz : nil, to: powerStatsSampler.gpuFrequencySeries, at: sampleTimestamp)
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
