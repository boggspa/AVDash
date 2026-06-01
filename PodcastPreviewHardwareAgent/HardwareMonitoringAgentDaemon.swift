import Foundation
import os.log
#if !HARDWARE_JOBBLESS_EMBEDS_CORE
import PodcastPreviewCore
#endif

final class HardwareMonitoringAgentDaemon: NSObject, HardwareMonitoringXPCProtocol {
    static let shared = HardwareMonitoringAgentDaemon()

    #if HARDWARE_JOBBLESS_EMBEDS_CORE
    private static let loggingSubsystem = HardwareMonitoringServiceConstants.legacyHelperBundleID
    #else
    private static let loggingSubsystem = HardwareMonitoringServiceConstants.modernHelperBundleID
    #endif

    private let logger = Logger(
        subsystem: HardwareMonitoringAgentDaemon.loggingSubsystem,
        category: "Daemon"
    )
    private let encoder: PropertyListEncoder = {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }()
    private let decoder = PropertyListDecoder()

    @MainActor
    private var collectorService: HardwareCollectorService?

    private override init() {
        super.init()
    }

    func bootstrapMonitoringOnLaunch() {
        Task { [weak self] in
            guard let self else { return }
            let service = await collectorService(createIfNeeded: true)
            await MainActor.run {
                service?.startHardwareStatsMonitoring(profile: .historyOnly)
            }
            logger.log("Hardware monitoring auto-started on launch")
        }
    }

    func fetchStatus(_ reply: @escaping (Data?) -> Void) {
        Task {
            let service = await collectorService(createIfNeeded: false)
            let snapshot = await statusSnapshot(using: service)
            reply(encode(snapshot))
        }
    }

    func startMonitoring(_ reply: @escaping (Data?) -> Void) {
        Task {
            let service = await collectorService(createIfNeeded: true)
            await MainActor.run {
                service?.startHardwareStatsMonitoring()
            }
            logger.log("Hardware monitoring requested to start")
            let snapshot = await statusSnapshot(using: service)
            reply(encode(snapshot))
        }
    }

    func stopMonitoring(_ reply: @escaping (Data?) -> Void) {
        Task {
            let service = await collectorService(createIfNeeded: false)
            await MainActor.run {
                service?.stopHardwareStatsMonitoring()
            }
            logger.log("Hardware monitoring requested to stop")
            let snapshot = await statusSnapshot(using: service)
            reply(encode(snapshot))
        }
    }

    func setCollectionProfile(_ requestData: Data, reply: @escaping (Data?) -> Void) {
        Task {
            guard let request = decode(HardwareCollectionProfileRequest.self, from: requestData) else {
                reply(nil)
                return
            }
            let service = await collectorService(createIfNeeded: true)
            await MainActor.run {
                service?.startHardwareStatsMonitoring(profile: request.profile)
            }
            let snapshot = await statusSnapshot(using: service)
            reply(encode(snapshot))
        }
    }

    func fetchCollectorSnapshot(_ reply: @escaping (Data?) -> Void) {
        Task {
            let service = await collectorService(createIfNeeded: false)
            let snapshot = await MainActor.run {
                if let service {
                    return service.liveSnapshot
                }
                return HardwareCollectorLiveSnapshot(
                    status: HardwareCollectorStatusSnapshot(
                        isCollectorInitialized: false,
                        isMonitoringActive: false,
                        collectorIntervalSeconds: HardwareCollectionSettings.collectorIntervalSeconds(),
                        latestFrameTimestamp: nil,
                        hasGlobalSnapshot: false,
                        deviceSnapshotCount: 0
                    ),
                    latestTelemetryFrame: HardwareTelemetryFrame(),
                    cpu: CPUStatsSampler().liveSnapshot,
                    thermal: ThermalStatsSampler().liveSnapshot,
                    gpu: GPUStatsSampler().liveSnapshot,
                    ram: RAMStatsSampler().liveSnapshot,
                    storage: StorageStatsSampler().liveSnapshot,
                    ane: ANEStatsSampler().liveSnapshot,
                    app: AppStatsSampler().liveSnapshot,
                    runningApps: RunningAppsSampler().liveSnapshot,
                    diskIO: DiskIOSampler().liveSnapshot,
                    network: NetworkStatsSampler().liveSnapshot,
                    mediaEngine: MediaEngineStatsSampler().liveSnapshot,
                    power: PowerStatsSampler().liveSnapshot
                )
            }
            reply(encode(snapshot))
        }
    }

    func fetchPollingSnapshot(_ reply: @escaping (Data?) -> Void) {
        Task {
            let service = await collectorService(createIfNeeded: false)
            let snapshot = await MainActor.run {
                if let service {
                    return service.pollingSnapshot
                }
                return HardwareCollectorPollingSnapshot(
                    status: HardwareCollectorStatusSnapshot(
                        isCollectorInitialized: false,
                        isMonitoringActive: false,
                        collectorIntervalSeconds: HardwareCollectionSettings.collectorIntervalSeconds(),
                        latestFrameTimestamp: nil,
                        hasGlobalSnapshot: false,
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
                    thermal: ThermalStatsSamplerPollingSnapshot(
                        latestSnapshot: nil
                    ),
                    gpu: GPUStatsSamplerPollingSnapshot(
                        gpus: [],
                        latestDeviceSnapshots: [],
                        gpuDisplayName: "GPU Usage"
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
                    app: AppStatsSamplerPollingSnapshot(
                        metrics: AppStatsSampler.Metrics(
                            cpuPercent: nil,
                            residentMemoryBytes: nil,
                            gpuPercent: nil,
                            diskReadMBps: nil,
                            diskWriteMBps: nil
                        ),
                        cpuText: "—",
                        memText: "—",
                        gpuText: "—",
                        readText: "—",
                        writeText: "—",
                        latestSnapshot: nil
                    ),
                    runningApps: RunningAppsSamplerLiveSnapshot(topRows: []),
                    gpuClients: nil,
                    diskIO: DiskIOSamplerPollingSnapshot(
                        latestSnapshot: nil
                    ),
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
            reply(encode(snapshot))
        }
    }

    func fetchDashboardFrame(_ reply: @escaping (Data?) -> Void) {
        Task {
            let service = await collectorService(createIfNeeded: false)
            let frame = await MainActor.run {
                service?.dashboardFrame
            }
            guard let frame else {
                reply(nil)
                return
            }
            reply(encode(frame))
        }
    }

    func fetchLatestTelemetryFrame(_ reply: @escaping (Data?) -> Void) {
        Task {
            let service = await collectorService(createIfNeeded: false)
            let frame = await MainActor.run {
                service?.latestTelemetryFrame ?? HardwareTelemetryFrame()
            }
            reply(encode(frame))
        }
    }

    func fetchAvailableDevices(_ requestData: Data, reply: @escaping (Data?) -> Void) {
        Task {
            guard let request = decode(HardwareAvailableDevicesRequest.self, from: requestData),
                  let service = await collectorService(createIfNeeded: true) else {
                reply(nil)
                return
            }

            let historyReader = await MainActor.run { service.historyReader }
            let devices = await historyReader.availableDevices(
                ofKind: request.deviceKind,
                in: request.range.dateInterval
            )
            reply(encode(devices))
        }
    }

    func fetchMetricTimeline(_ requestData: Data, reply: @escaping (Data?) -> Void) {
        Task {
            guard let request = decode(HardwareMetricTimelineRequest.self, from: requestData),
                  let service = await collectorService(createIfNeeded: true) else {
                reply(nil)
                return
            }

            let historyReader = await MainActor.run { service.historyReader }
            let timeline = await historyReader.metricTimeline(
                for: request.key,
                in: request.range.dateInterval,
                bucketIntervalSeconds: request.bucketIntervalSeconds
            )
            reply(encode(timeline))
        }
    }

    func fetchDeviceMetricTimeline(_ requestData: Data, reply: @escaping (Data?) -> Void) {
        Task {
            guard let request = decode(HardwareDeviceMetricTimelineRequest.self, from: requestData),
                  let service = await collectorService(createIfNeeded: true) else {
                reply(nil)
                return
            }

            let historyReader = await MainActor.run { service.historyReader }
            let timeline = await historyReader.deviceMetricTimeline(
                for: request.key,
                deviceID: request.deviceID,
                deviceKind: request.deviceKind,
                in: request.range.dateInterval,
                bucketIntervalSeconds: request.bucketIntervalSeconds
            )
            reply(encode(timeline))
        }
    }

    func fetchMetricInsight(_ requestData: Data, reply: @escaping (Data?) -> Void) {
        Task {
            guard let request = decode(HardwareMetricInsightRequest.self, from: requestData),
                  let service = await collectorService(createIfNeeded: true) else {
                reply(nil)
                return
            }

            let insightsService = await MainActor.run { service.insightsService }
            let insight = await insightsService.metricInsight(
                for: request.key,
                in: request.range.dateInterval,
                summaryBucketIntervalSeconds: request.summaryBucketIntervalSeconds
            )
            reply(encode(insight))
        }
    }

    func fetchDeviceMetricInsight(_ requestData: Data, reply: @escaping (Data?) -> Void) {
        Task {
            guard let request = decode(HardwareDeviceMetricInsightRequest.self, from: requestData),
                  let service = await collectorService(createIfNeeded: true) else {
                reply(nil)
                return
            }

            let insightsService = await MainActor.run { service.insightsService }
            let insight = await insightsService.deviceMetricInsight(
                for: request.key,
                deviceID: request.deviceID,
                deviceKind: request.deviceKind,
                in: request.range.dateInterval,
                summaryBucketIntervalSeconds: request.summaryBucketIntervalSeconds
            )
            reply(encode(insight))
        }
    }

    func fetchProcessTimeline(_ requestData: Data, reply: @escaping (Data?) -> Void) {
        Task {
            guard let request = decode(HardwareProcessTimelineRequest.self, from: requestData),
                  let service = await collectorService(createIfNeeded: true) else {
                reply(nil)
                return
            }

            let processHistoryReader = await MainActor.run { service.processHistoryReader }
            let timeline = await processHistoryReader.processTimeline(
                for: request.identity,
                in: request.range.dateInterval,
                bucketIntervalSeconds: request.bucketIntervalSeconds
            )
            reply(encode(timeline))
        }
    }

    func fetchProcessSummary(_ requestData: Data, reply: @escaping (Data?) -> Void) {
        Task {
            guard let request = decode(HardwareProcessSummaryRequest.self, from: requestData),
                  let service = await collectorService(createIfNeeded: true) else {
                reply(nil)
                return
            }

            let processHistoryReader = await MainActor.run { service.processHistoryReader }
            let summary = await processHistoryReader.processSummary(
                for: request.identity,
                in: request.range.dateInterval,
                bucketIntervalSeconds: request.bucketIntervalSeconds
            )
            reply(encode(summary))
        }
    }

    func fetchEvents(_ requestData: Data, reply: @escaping (Data?) -> Void) {
        Task {
            guard let request = decode(HardwareEventsRequest.self, from: requestData),
                  let service = await collectorService(createIfNeeded: true) else {
                reply(nil)
                return
            }

            let eventReader = await MainActor.run { service.eventReader }
            let events = await eventReader.events(
                in: request.range.dateInterval,
                categories: request.categories,
                limit: request.limit
            )
            reply(encode(events))
        }
    }

    private func collectorService(createIfNeeded: Bool) async -> HardwareCollectorService? {
        await MainActor.run {
            if let collectorService {
                return collectorService
            }

            guard createIfNeeded else {
                return nil
            }

            let service = HardwareCollectorService(
                powerMetricsProvider: HardwareAgentPowerMetricsProvider.live
            )
            collectorService = service
            return service
        }
    }

    private func statusSnapshot(using service: HardwareCollectorService?) async -> HardwareCollectorStatusSnapshot {
        guard let service else {
            return HardwareCollectorStatusSnapshot(
                isCollectorInitialized: false,
                isMonitoringActive: false,
                collectorIntervalSeconds: HardwareCollectionSettings.collectorIntervalSeconds(),
                activeProfile: .historyOnly,
                latestFrameTimestamp: nil,
                hasGlobalSnapshot: false,
                deviceSnapshotCount: 0
            )
        }

        return await MainActor.run { service.statusSnapshot }
    }

    private func encode<T: Encodable>(_ value: T) -> Data? {
        try? encoder.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder.decode(T.self, from: data)
    }
}
