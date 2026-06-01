import Foundation
import Combine
import Darwin
#if canImport(libproc)
import libproc
#else
// libproc symbols are available via Darwin on many SDKs; keep explicit import only if it compiles.
#endif

/// Best-effort sampler for this app's CPU + resident memory + GPU time.
/// CPU/RAM/disk are summed across the full PodcastPreview-owned process family
/// when multiple target PIDs are provided, and expressed as a % of total
/// system capacity (all logical cores).
/// GPU usage comes from an injected app-side source when sampling only the
/// current process, or a headless resolver when sampling a tracked process family.
public final class AppStatsSampler: ObservableObject {
    private struct SampleState {
        let processSnapshots: [Int32: ProcessSnapshot]
        let sampleTime: TimeInterval
    }

    private struct ProcessSnapshot {
        let cpuTimeNanoseconds: UInt64
        let residentMemoryBytes: UInt64
        let diskReadBytes: UInt64?
        let diskWriteBytes: UInt64?
    }

    public struct Metrics: Codable, Equatable, Sendable {
        public var cpuPercent: Double?
        public var residentMemoryBytes: UInt64?
        public var gpuPercent: Double?
        public var diskReadMBps: Double?
        public var diskWriteMBps: Double?

        public var cpuText: String {
            guard let cpuPercent else { return "—" }
            return String(format: "%.1f%%", cpuPercent)
        }

        public var memText: String {
            guard let residentMemoryBytes else { return "—" }
            return AppStatsSampler.formatBytes(residentMemoryBytes)
        }

        public var gpuText: String {
            guard let gpuPercent else { return "—" }
            return String(format: "%.1f%%", gpuPercent)
        }

        public var diskReadText: String {
            AppStatsSampler.formatRate(diskReadMBps)
        }

        public var diskWriteText: String {
            AppStatsSampler.formatRate(diskWriteMBps)
        }

        public init(
            cpuPercent: Double? = nil,
            residentMemoryBytes: UInt64? = nil,
            gpuPercent: Double? = nil,
            diskReadMBps: Double? = nil,
            diskWriteMBps: Double? = nil
        ) {
            self.cpuPercent = cpuPercent
            self.residentMemoryBytes = residentMemoryBytes
            self.gpuPercent = gpuPercent
            self.diskReadMBps = diskReadMBps
            self.diskWriteMBps = diskWriteMBps
        }

        private enum CodingKeys: String, CodingKey {
            case cpuPercent
            case residentMemoryBytes
            case gpuPercent
            case diskReadMBps
            case diskWriteMBps
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            cpuPercent = try container.decodeIfPresent(Double.self, forKey: .cpuPercent)
            residentMemoryBytes = try container.decodeIfPresent(UInt64.self, forKey: .residentMemoryBytes)
            gpuPercent = try container.decodeIfPresent(Double.self, forKey: .gpuPercent)
            diskReadMBps = try container.decodeIfPresent(Double.self, forKey: .diskReadMBps)
            diskWriteMBps = try container.decodeIfPresent(Double.self, forKey: .diskWriteMBps)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(cpuPercent, forKey: .cpuPercent)
            try container.encodeIfPresent(residentMemoryBytes, forKey: .residentMemoryBytes)
            try container.encodeIfPresent(gpuPercent, forKey: .gpuPercent)
            try container.encodeIfPresent(diskReadMBps, forKey: .diskReadMBps)
            try container.encodeIfPresent(diskWriteMBps, forKey: .diskWriteMBps)
        }
    }

    @Published public var cpuText: String = "—"
    @Published public var memText: String = "—"
    @Published public var gpuText: String = "—"
    @Published public var readText: String = "—"
    @Published public var writeText: String = "—"
    @Published public private(set) var latestMetrics = Metrics()
    @Published public private(set) var latestSnapshot: HardwareSnapshot? = nil
    @Published public private(set) var cpuSeries = MetricSeries(key: .appCPUUsageRatio, unit: .ratio)
    @Published public private(set) var memorySeries = MetricSeries(key: .appMemoryGB, unit: .gigabytes)
    @Published public private(set) var gpuSeries = MetricSeries(key: .appGPUUsageRatio, unit: .ratio)
    @Published public private(set) var readSeries = MetricSeries(key: .appDiskReadMBps, unit: .megabytesPerSecond)
    @Published public private(set) var writeSeries = MetricSeries(key: .appDiskWriteMBps, unit: .megabytesPerSecond)

    private var timer: DispatchSourceTimer?
    private let samplingQueue = DispatchQueue(label: "PodcastPreview.AppStatsSampler", qos: .utility)
    private let targetProcessResolver: @Sendable () -> Set<Int32>
    private let targetGPUPercentResolver: @Sendable (Set<Int32>) -> Double?
    private let gpuUsageProvider: HardwareAppGPUUsageProvider?
    private var lastSample: SampleState?
    static var samplingIntervalSeconds: Int {
        HardwareCollectionSettings.collectorIntervalSeconds()
    }
    static var liveSeriesCapacity: Int {
        HardwareCollectionSettings.liveSeriesCapacity(
            sampleIntervalSeconds: samplingIntervalSeconds
        )
    }

    public init(
        targetProcessResolver: @escaping @Sendable () -> Set<Int32> = {
            Set([Int32(ProcessInfo.processInfo.processIdentifier)])
        },
        targetGPUPercentResolver: @escaping @Sendable (Set<Int32>) -> Double? = { _ in nil },
        gpuUsageProvider: HardwareAppGPUUsageProvider? = nil
    ) {
        self.targetProcessResolver = targetProcessResolver
        self.targetGPUPercentResolver = targetGPUPercentResolver
        self.gpuUsageProvider = gpuUsageProvider
    }

    public func start() {
        stop()
        resetSamplingState()
        triggerSample()

        let interval = Self.samplingIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: samplingQueue)
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in
            self?.sample()
        }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func initializeForExternalClock() {
        stop()
        resetSamplingState()
        triggerSample()
    }

    public func triggerSample() {
        samplingQueue.async { [weak self] in
            self?.sample()
        }
    }

    private func sample() {
        let sampleDate = Date()
        let sampleTime = sampleDate.timeIntervalSince1970
        let currentProcessID = Int32(ProcessInfo.processInfo.processIdentifier)
        let targetPIDs = Set(targetProcessResolver().filter { $0 > 0 })
        let processSnapshots = Dictionary(uniqueKeysWithValues: targetPIDs.compactMap { pid in
            Self.readProcessSnapshot(pid: pid).map { (pid, $0) }
        })
        let previousSample = lastSample

        let cpu: Double? = {
            guard let previousSample = previousSample,
                  !processSnapshots.isEmpty else {
                return nil
            }

            let comparablePIDs = processSnapshots.keys.filter { previousSample.processSnapshots[$0] != nil }
            guard !comparablePIDs.isEmpty else { return nil }

            let elapsed = max(0.001, sampleTime - previousSample.sampleTime)
            let cpuDelta = comparablePIDs.reduce(UInt64(0)) { partialResult, pid in
                guard let currentSnapshot = processSnapshots[pid],
                      let previousSnapshot = previousSample.processSnapshots[pid] else {
                    return partialResult
                }

                let delta = currentSnapshot.cpuTimeNanoseconds >= previousSnapshot.cpuTimeNanoseconds
                    ? currentSnapshot.cpuTimeNanoseconds - previousSnapshot.cpuTimeNanoseconds
                    : 0
                return partialResult &+ delta
            }
            let logicalCPUCount = Self.sysctlInt("hw.logicalcpu") ?? Self.sysctlInt("hw.logicalcpu_max") ?? 1
            return (Double(cpuDelta) / 1_000_000_000.0 / elapsed) * (100.0 / Double(max(logicalCPUCount, 1)))
        }()

        if processSnapshots.isEmpty {
            lastSample = nil
        }

        let mem = processSnapshots.isEmpty
            ? nil
            : processSnapshots.values.reduce(UInt64(0)) { partialResult, snapshot in
                partialResult &+ snapshot.residentMemoryBytes
            }
        let gpu: Double? = {
            guard !targetPIDs.isEmpty else { return nil }

            if let resolvedGPUPercent = targetGPUPercentResolver(targetPIDs) {
                return resolvedGPUPercent
            }

            if targetPIDs.count == 1,
               targetPIDs.contains(currentProcessID),
               let currentProcessGPUPercent = gpuUsageProvider?.currentUsagePercent() {
                return currentProcessGPUPercent
            }

            return nil
        }()

        let diskRates: (read: Double?, write: Double?) = {
            guard let previousSample = previousSample,
                  !processSnapshots.isEmpty else {
                return (nil, nil)
            }

            let comparablePIDs = processSnapshots.keys.filter { previousSample.processSnapshots[$0] != nil }
            guard !comparablePIDs.isEmpty else { return (nil, nil) }

            let dt = max(0.001, sampleTime - previousSample.sampleTime)
            let deltas = comparablePIDs.reduce((read: UInt64(0), write: UInt64(0))) { partialResult, pid in
                guard let currentSnapshot = processSnapshots[pid],
                      let previousSnapshot = previousSample.processSnapshots[pid],
                      let currentReadBytes = currentSnapshot.diskReadBytes,
                      let currentWriteBytes = currentSnapshot.diskWriteBytes,
                      let previousReadBytes = previousSnapshot.diskReadBytes,
                      let previousWriteBytes = previousSnapshot.diskWriteBytes else {
                    return partialResult
                }

                let readDelta = currentReadBytes >= previousReadBytes
                    ? currentReadBytes - previousReadBytes
                    : 0
                let writeDelta = currentWriteBytes >= previousWriteBytes
                    ? currentWriteBytes - previousWriteBytes
                    : 0
                return (
                    read: partialResult.read &+ readDelta,
                    write: partialResult.write &+ writeDelta
                )
            }

            return (
                Double(deltas.read) / dt / 1_048_576.0,
                Double(deltas.write) / dt / 1_048_576.0
            )
        }()

        if !processSnapshots.isEmpty {
            lastSample = SampleState(
                processSnapshots: processSnapshots,
                sampleTime: sampleTime
            )
        }

        let metrics = Metrics(
            cpuPercent: cpu,
            residentMemoryBytes: mem,
            gpuPercent: gpu,
            diskReadMBps: diskRates.read,
            diskWriteMBps: diskRates.write
        )

        var snapshot = HardwareSnapshot(timestamp: sampleDate)
        if let cpu {
            snapshot.setMetric(.appCPUUsageRatio, value: min(max(cpu / 100.0, 0), 1))
        }
        if let mem {
            snapshot.setMetric(.appMemoryGB, value: Double(mem) / 1_073_741_824.0)
        }
        if let gpu {
            snapshot.setMetric(.appGPUUsageRatio, value: min(max(gpu / 100.0, 0), 1))
        }
        if let diskRead = diskRates.read {
            snapshot.setMetric(.appDiskReadMBps, value: max(0, diskRead))
        }
        if let diskWrite = diskRates.write {
            snapshot.setMetric(.appDiskWriteMBps, value: max(0, diskWrite))
        }
        let latestSnapshot = snapshot.isEmpty ? nil : snapshot

        DispatchQueue.main.async {
            self.latestMetrics = metrics
            self.latestSnapshot = latestSnapshot
            self.cpuText = metrics.cpuText
            self.memText = metrics.memText
            self.gpuText = metrics.gpuText
            self.readText = metrics.diskReadText
            self.writeText = metrics.diskWriteText
            self.cpuSeries.append(cpu.map { min(max($0 / 100.0, 0), 1) }, at: sampleDate, capacity: Self.liveSeriesCapacity)
            self.memorySeries.append(mem.map { Double($0) / 1_073_741_824.0 }, at: sampleDate, capacity: Self.liveSeriesCapacity)
            self.gpuSeries.append(gpu.map { min(max($0 / 100.0, 0), 1) }, at: sampleDate, capacity: Self.liveSeriesCapacity)
            self.readSeries.append(diskRates.read, at: sampleDate, capacity: Self.liveSeriesCapacity)
            self.writeSeries.append(diskRates.write, at: sampleDate, capacity: Self.liveSeriesCapacity)
        }
    }

    private func resetSamplingState() {
        let applyReset = {
            self.latestMetrics = Metrics()
            self.latestSnapshot = nil
            self.cpuText = "—"
            self.memText = "—"
            self.gpuText = "—"
            self.readText = "—"
            self.writeText = "—"
            self.cpuSeries = MetricSeries(key: .appCPUUsageRatio, unit: .ratio)
            self.memorySeries = MetricSeries(key: .appMemoryGB, unit: .gigabytes)
            self.gpuSeries = MetricSeries(key: .appGPUUsageRatio, unit: .ratio)
            self.readSeries = MetricSeries(key: .appDiskReadMBps, unit: .megabytesPerSecond)
            self.writeSeries = MetricSeries(key: .appDiskWriteMBps, unit: .megabytesPerSecond)
        }
        if Thread.isMainThread {
            applyReset()
        } else {
            DispatchQueue.main.sync(execute: applyReset)
        }
        lastSample = nil
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func readProcessSnapshot(pid: Int32) -> ProcessSnapshot? {
        #if os(macOS)
        var taskInfo = proc_taskinfo()
        let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let taskInfoResult = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskInfoSize)
        guard taskInfoResult == taskInfoSize else { return nil }

        let diskCounters = readProcessDiskIOCounters(pid: pid)
        return ProcessSnapshot(
            cpuTimeNanoseconds: UInt64(taskInfo.pti_total_user) &+ UInt64(taskInfo.pti_total_system),
            residentMemoryBytes: UInt64(taskInfo.pti_resident_size),
            diskReadBytes: diskCounters?.readBytes,
            diskWriteBytes: diskCounters?.writeBytes
        )
        #else
        return nil
        #endif
    }

    private static func readProcessDiskIOCounters(pid: Int32) -> (readBytes: UInt64, writeBytes: UInt64)? {
        #if os(macOS)
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPointer in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, reboundPointer)
            }
        }
        guard result == 0 else { return nil }
        return (
            readBytes: info.ri_diskio_bytesread,
            writeBytes: info.ri_diskio_byteswritten
        )
        #else
        return nil
        #endif
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        if mb < 1024 {
            return String(format: "%.0f MB", mb)
        }
        let gb = mb / 1024.0
        return String(format: "%.2f GB", gb)
    }

    public static func formatRate(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 0.1 {
            return String(format: "%.2f MB/s", value)
        }
        return String(format: "%.1f MB/s", value)
    }
}

extension AppStatsSampler {
    public var pollingSnapshot: AppStatsSamplerPollingSnapshot {
        AppStatsSamplerPollingSnapshot(
            metrics: latestMetrics,
            cpuText: cpuText,
            memText: memText,
            gpuText: gpuText,
            readText: readText,
            writeText: writeText,
            latestSnapshot: latestSnapshot
        )
    }

    public var liveSnapshot: AppStatsSamplerLiveSnapshot {
        AppStatsSamplerLiveSnapshot(
            metrics: latestMetrics,
            cpuText: cpuText,
            memText: memText,
            gpuText: gpuText,
            readText: readText,
            writeText: writeText,
            cpuSeries: cpuSeries,
            memorySeries: memorySeries,
            gpuSeries: gpuSeries,
            readSeries: readSeries,
            writeSeries: writeSeries
        )
    }

    public func applyRemoteSnapshot(_ snapshot: AppStatsSamplerPollingSnapshot) {
        latestMetrics = snapshot.metrics
        latestSnapshot = snapshot.latestSnapshot
        cpuText = snapshot.cpuText
        memText = snapshot.memText
        gpuText = snapshot.gpuText
        readText = snapshot.readText
        writeText = snapshot.writeText

        let sampleDate = snapshot.latestSnapshot?.timestamp ?? Date()
        cpuSeries.append(snapshot.metrics.cpuPercent.map { min(max($0 / 100.0, 0), 1) }, at: sampleDate, capacity: Self.liveSeriesCapacity)
        memorySeries.append(snapshot.metrics.residentMemoryBytes.map { Double($0) / 1_073_741_824.0 }, at: sampleDate, capacity: Self.liveSeriesCapacity)
        gpuSeries.append(snapshot.metrics.gpuPercent.map { min(max($0 / 100.0, 0), 1) }, at: sampleDate, capacity: Self.liveSeriesCapacity)
        readSeries.append(snapshot.metrics.diskReadMBps, at: sampleDate, capacity: Self.liveSeriesCapacity)
        writeSeries.append(snapshot.metrics.diskWriteMBps, at: sampleDate, capacity: Self.liveSeriesCapacity)
    }

    public func applyRemoteSnapshot(_ snapshot: AppStatsSamplerLiveSnapshot) {
        latestMetrics = snapshot.metrics
        cpuText = snapshot.cpuText
        memText = snapshot.memText
        gpuText = snapshot.gpuText
        readText = snapshot.readText
        writeText = snapshot.writeText
        cpuSeries = snapshot.cpuSeries
        memorySeries = snapshot.memorySeries
        gpuSeries = snapshot.gpuSeries
        readSeries = snapshot.readSeries
        writeSeries = snapshot.writeSeries
    }
}
