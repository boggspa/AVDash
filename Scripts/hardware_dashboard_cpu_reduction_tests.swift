import Foundation
import Darwin
@testable import PodcastPreviewCore

private enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure.failed(message)
    }
}

private func requireApprox(_ actual: Double?, _ expected: Double, accuracy: Double = 0.0001, _ message: String) throws {
    guard let actual, abs(actual - expected) <= accuracy else {
        throw TestFailure.failed("\(message) expected \(expected), got \(String(describing: actual))")
    }
}

private func minimalPollingSnapshot(app: AppStatsSamplerPollingSnapshot) -> HardwareCollectorPollingSnapshot {
    HardwareCollectorPollingSnapshot(
        status: HardwareCollectorStatusSnapshot(
            isCollectorInitialized: true,
            isMonitoringActive: true,
            collectorIntervalSeconds: 2,
            activeProfile: .dashboard,
            latestFrameTimestamp: app.latestSnapshot?.timestamp,
            hasGlobalSnapshot: app.latestSnapshot != nil,
            deviceSnapshotCount: 0
        ),
        latestTelemetryFrame: HardwareTelemetryFrame(),
        cpu: CPUSamplerPollingSnapshot(
            coreUsages: [],
            cpuDisplayName: "CPU",
            efficiencyCoreCount: 0,
            performanceCoreCount: 0,
            latestSnapshot: nil
        ),
        thermal: ThermalStatsSamplerPollingSnapshot(latestSnapshot: nil),
        gpu: GPUStatsSamplerPollingSnapshot(
            gpus: [],
            latestDeviceSnapshots: [],
            gpuDisplayName: "GPU"
        ),
        ram: RAMStatsSamplerPollingSnapshot(
            latestMemorySnapshot: nil,
            latestSnapshot: nil
        ),
        storage: StorageStatsSamplerLiveSnapshot(
            latestCapacitySnapshot: nil,
            storageLabel: "—",
            storageUsedRatio: 0,
            storageKindLabel: "Unknown Storage",
            storageSpeedLabel: "Speed unavailable",
            storageHealthLabel: "Health unavailable"
        ),
        ane: ANEStatsSamplerPollingSnapshot(
            latestStatusSnapshot: nil,
            latestSnapshot: nil
        ),
        app: app,
        runningApps: RunningAppsSamplerLiveSnapshot(topRows: []),
        gpuClients: nil,
        diskIO: DiskIOSamplerPollingSnapshot(latestSnapshot: nil),
        network: NetworkStatsSamplerPollingSnapshot(
            latestSnapshot: nil,
            sessionUploadMB: 0,
            sessionDownloadMB: 0,
            pingTargetLabel: "Gateway",
            pingLatencyMilliseconds: nil,
            pingPacketLossRatio: nil,
            lastPingSampleDate: nil
        ),
        mediaEngine: MediaEngineStatsSamplerPollingSnapshot(
            latestCapabilityState: nil,
            latestActivitySummary: nil,
            recentSessions: []
        ),
        power: PowerStatsSamplerPollingSnapshot(
            latestSystemSnapshot: nil,
            latestReadingsSnapshot: nil,
            latestSnapshot: nil
        )
    )
}

private func runHardwareDashboardCPUReductionTests() throws {
    try require(
        HardwareCollectionProfile.highest([.historyOnly, .toolbar, .dashboard]) == .dashboard,
        "Demand precedence should choose dashboard over toolbar/history"
    )
    try require(
        HardwareCollectionProfile.highest([.dashboard, .focusedHighResolution, .toolbar]) == .focusedHighResolution,
        "Focused high-resolution demand should win while active"
    )
    try require(
        HardwareCollectionProfile.highest([HardwareCollectionProfile]()) == .historyOnly,
        "No active demands should resolve to history-only"
    )

    try require(
        HardwareSamplerCadencePolicy.heartbeatIntervalSeconds(for: .historyOnly) == 15,
        "History-only heartbeat should not run at 1 Hz"
    )
    try require(
        HardwareSamplerCadencePolicy.heartbeatIntervalSeconds(for: .dashboard) == 2,
        "Dashboard heartbeat should be adaptive 2s"
    )
    try require(
        HardwareSamplerCadencePolicy.heartbeatIntervalSeconds(for: .focusedHighResolution) == 1,
        "Focused profile should retain 1s precision"
    )
    try require(
        HardwareSamplerCadencePolicy.sampleIntervalSeconds(for: .power, profile: .dashboard) == 5,
        "Dashboard power sampling should not run every second"
    )
    try require(
        HardwareSamplerCadencePolicy.sampleIntervalSeconds(for: .networkInterface, profile: .historyOnly) == 120,
        "Hidden/background network identity should be cold"
    )

    let legacyStatusData = try PropertyListSerialization.data(
        fromPropertyList: [
            "isCollectorInitialized": true,
            "isMonitoringActive": true,
            "collectorIntervalSeconds": 1,
            "hasGlobalSnapshot": false,
            "deviceSnapshotCount": 0
        ],
        format: .xml,
        options: 0
    )
    let decodedLegacyStatus = try PropertyListDecoder().decode(HardwareCollectorStatusSnapshot.self, from: legacyStatusData)
    try require(decodedLegacyStatus.activeProfile == .dashboard, "Legacy status payloads should decode with dashboard profile")

    let sampleDate = Date(timeIntervalSinceReferenceDate: 12_345)
    var appLatest = HardwareSnapshot(timestamp: sampleDate)
    appLatest.setMetric(.appCPUUsageRatio, value: 0.125)
    appLatest.setMetric(.appMemoryGB, value: 1.5)
    let appSnapshot = AppStatsSamplerPollingSnapshot(
        metrics: AppStatsSampler.Metrics(
            cpuPercent: 12.5,
            residentMemoryBytes: 1_610_612_736,
            gpuPercent: 3.25,
            diskReadMBps: 1.5,
            diskWriteMBps: 2.5
        ),
        cpuText: "12.5%",
        memText: "1.50 GB",
        gpuText: "3.2%",
        readText: "1.5 MB/s",
        writeText: "2.5 MB/s",
        latestSnapshot: appLatest
    )
    let frame = HardwareDashboardFrame(
        sequenceNumber: 42,
        generatedAt: sampleDate,
        pollingSnapshot: minimalPollingSnapshot(app: appSnapshot)
    )
    let encodedFrame = try PropertyListEncoder().encode(frame)
    let plist = try PropertyListSerialization.propertyList(from: encodedFrame, options: [], format: nil)
    guard
        let root = plist as? [String: Any],
        let pollingSnapshot = root["pollingSnapshot"] as? [String: Any],
        let appPayload = pollingSnapshot["app"] as? [String: Any]
    else {
        throw TestFailure.failed("Encoded dashboard frame should expose an app payload")
    }
    for forbiddenKey in ["cpuSeries", "memorySeries", "gpuSeries", "readSeries", "writeSeries"] {
        try require(appPayload[forbiddenKey] == nil, "Dashboard frame should not encode \(forbiddenKey)")
    }

    let decodedFrame = try PropertyListDecoder().decode(HardwareDashboardFrame.self, from: encodedFrame)
    try require(decodedFrame.sequenceNumber == 42, "Dashboard frame sequence should round-trip")
    try require(decodedFrame.pollingSnapshot.app.cpuText == "12.5%", "Dashboard frame should preserve app text values")
    try requireApprox(decodedFrame.pollingSnapshot.app.metrics.cpuPercent, 12.5, "Dashboard frame should preserve app CPU percent")
    try requireApprox(decodedFrame.pollingSnapshot.app.latestSnapshot?.metric(.appCPUUsageRatio), 0.125, "Dashboard frame should preserve latest app snapshot")

    let baselineSignature = HardwareDashboardFrameSignature(snapshot: frame.pollingSnapshot)

    var appChangedSnapshot = frame.pollingSnapshot
    var changedAppLatest = HardwareSnapshot(timestamp: sampleDate.addingTimeInterval(1))
    changedAppLatest.setMetric(.appCPUUsageRatio, value: 0.25)
    appChangedSnapshot.app = AppStatsSamplerPollingSnapshot(
        metrics: AppStatsSampler.Metrics(
            cpuPercent: 25,
            residentMemoryBytes: 2_147_483_648,
            gpuPercent: 4.5,
            diskReadMBps: 3,
            diskWriteMBps: 4
        ),
        cpuText: "25.0%",
        memText: "2.00 GB",
        gpuText: "4.5%",
        readText: "3.0 MB/s",
        writeText: "4.0 MB/s",
        latestSnapshot: changedAppLatest
    )
    try require(
        HardwareDashboardFrameSignature(snapshot: appChangedSnapshot) != baselineSignature,
        "Dashboard frame signature should change when This App sidebar metrics arrive"
    )

    var storageChangedSnapshot = frame.pollingSnapshot
    storageChangedSnapshot.storage = StorageStatsSamplerLiveSnapshot(
        latestCapacitySnapshot: StorageStatsSampler.CapacitySnapshot(
            freeBytes: 10_000,
            usedBytes: 90_000,
            totalBytes: 100_000,
            kindLabel: "Internal SSD",
            speedLabel: "R 500 MB/s · W 400 MB/s",
            healthLabel: "Verified"
        ),
        storageLabel: "10 KB free",
        storageUsedRatio: 0.9,
        storageKindLabel: "Internal SSD",
        storageSpeedLabel: "R 500 MB/s · W 400 MB/s",
        storageHealthLabel: "Verified"
    )
    try require(
        HardwareDashboardFrameSignature(snapshot: storageChangedSnapshot) != baselineSignature,
        "Dashboard frame signature should change when storage sidebar values arrive"
    )

    var identityChangedSnapshot = frame.pollingSnapshot
    identityChangedSnapshot.gpuIdentityUnits = [
        GPUUnitMetadata(
            id: "gpu-0",
            name: "Apple M Test",
            vendor: "Apple",
            bus: "Built-In",
            gpuType: "Integrated",
            metalFamily: "Metal 4",
            coreCount: 32,
            connectedDisplayCount: 2
        )
    ]
    identityChangedSnapshot.memoryIdentityUnit = MemoryUnitMetadata(
        id: "memory-0",
        totalMemory: "64 GB",
        architecture: "Unified",
        type: "LPDDR5",
        chip: "Apple M Test"
    )
    try require(
        HardwareDashboardFrameSignature(snapshot: identityChangedSnapshot) != baselineSignature,
        "Dashboard frame signature should change when static sidebar identity values arrive"
    )

    var runningAppsChangedSnapshot = frame.pollingSnapshot
    runningAppsChangedSnapshot.runningApps = RunningAppsSamplerLiveSnapshot(topRows: [
        RunningAppsSampler.Row(
            id: 101,
            pid: 101,
            name: "Test App",
            bundleIdentifier: "com.example.TestApp",
            cpuPercent: 12.3,
            ramPercent: 4.5,
            ramMB: 256,
            uptimeSeconds: 60,
            uptimeText: "1m",
            diskReadMBps: 1.2,
            diskWriteMBps: 0.4
        )
    ])
    try require(
        HardwareDashboardFrameSignature(snapshot: runningAppsChangedSnapshot) != baselineSignature,
        "Dashboard frame signature should change when Top Apps sidebar rows arrive"
    )

    var powerChangedSnapshot = frame.pollingSnapshot
    powerChangedSnapshot.power = PowerStatsSamplerPollingSnapshot(
        latestSystemSnapshot: PowerStatsSampler.SystemSnapshot(
            uptimeSeconds: 1234,
            batteryPercent: nil,
            cycleCount: nil,
            processCount: 321
        ),
        latestReadingsSnapshot: PowerStatsSampler.ReadingsSnapshot(
            cpuPowerWatts: 1.25,
            gpuPowerWatts: 0.75,
            anePowerWatts: 0.1,
            combinedPowerWatts: 2.1,
            cumulativeCombinedEnergyWh: 0.5,
            gpuFrequencyMHz: 750,
            sampleStatus: .live,
            lastPowerSampleDate: sampleDate,
            lastUsablePowerSampleDate: sampleDate,
            source: "test"
        ),
        latestSnapshot: nil,
        sampleStatus: .live,
        lastPowerSampleDate: sampleDate,
        lastUsablePowerSampleDate: sampleDate,
        source: "test"
    )
    try require(
        HardwareDashboardFrameSignature(snapshot: powerChangedSnapshot) != baselineSignature,
        "Dashboard frame signature should change when power sidebar values arrive"
    )
}

do {
    try runHardwareDashboardCPUReductionTests()
    print("Hardware dashboard CPU reduction tests passed")
} catch {
    fputs("Hardware dashboard CPU reduction tests failed: \(error)\n", stderr)
    exit(1)
}
