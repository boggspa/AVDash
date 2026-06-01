import Foundation
import Combine
import Darwin
#if canImport(libproc)
import libproc
#endif

/// Best-effort sampler for other running apps using libproc.
/// NOTE: This is intended for non-sandboxed builds.
public final class RunningAppsSampler: ObservableObject {
    public static let topProcessLimit: Int = 25
    public static let topProcessCandidateLimit: Int = 60
    private static var samplingIntervalSeconds: Int {
        HardwareCollectionSettings.collectorIntervalSeconds()
    }

    public struct Row: Identifiable, Codable, Sendable {
        public let id: Int32
        public let pid: Int32
        public let name: String
        public let bundleIdentifier: String?
        public let cpuPercent: Double
        public let ramPercent: Double
        public let ramMB: Double
        public let uptimeSeconds: Double
        public let uptimeText: String
        public let diskReadMBps: Double
        public let diskWriteMBps: Double

        public var cpuText: String { String(format: "%4.1f%%", cpuPercent) }
        public var ramText: String { String(format: "%4.1f%% %4.0fMB", ramPercent, ramMB) }
        public var diskReadText: String { AppStatsSampler.formatRate(diskReadMBps) }
        public var diskWriteText: String { AppStatsSampler.formatRate(diskWriteMBps) }

        private enum CodingKeys: String, CodingKey {
            case id
            case pid
            case name
            case bundleIdentifier
            case cpuPercent
            case ramPercent
            case ramMB
            case uptimeSeconds
            case uptimeText
            case diskReadMBps
            case diskWriteMBps
        }

        public init(
            id: Int32,
            pid: Int32,
            name: String,
            bundleIdentifier: String?,
            cpuPercent: Double,
            ramPercent: Double,
            ramMB: Double,
            uptimeSeconds: Double,
            uptimeText: String,
            diskReadMBps: Double = 0,
            diskWriteMBps: Double = 0
        ) {
            self.id = id
            self.pid = pid
            self.name = name
            self.bundleIdentifier = bundleIdentifier
            self.cpuPercent = cpuPercent
            self.ramPercent = ramPercent
            self.ramMB = ramMB
            self.uptimeSeconds = uptimeSeconds
            self.uptimeText = uptimeText
            self.diskReadMBps = diskReadMBps
            self.diskWriteMBps = diskWriteMBps
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int32.self, forKey: .id)
            pid = try container.decode(Int32.self, forKey: .pid)
            name = try container.decode(String.self, forKey: .name)
            bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
            cpuPercent = try container.decode(Double.self, forKey: .cpuPercent)
            ramPercent = try container.decode(Double.self, forKey: .ramPercent)
            ramMB = try container.decode(Double.self, forKey: .ramMB)
            uptimeSeconds = try container.decode(Double.self, forKey: .uptimeSeconds)
            uptimeText = try container.decode(String.self, forKey: .uptimeText)
            diskReadMBps = try container.decodeIfPresent(Double.self, forKey: .diskReadMBps) ?? 0
            diskWriteMBps = try container.decodeIfPresent(Double.self, forKey: .diskWriteMBps) ?? 0
        }
    }

    @Published public private(set) var topRows: [Row] = []

    private var timer: DispatchSourceTimer?
    private let samplingQueue = DispatchQueue(label: "PodcastPreview.RunningAppsSampler", qos: .utility)
    private struct SampleState {
        let cpuNS: UInt64
        let diskReadBytes: UInt64?
        let diskWriteBytes: UInt64?
        let time: TimeInterval
    }

    private var lastSample: [Int32: SampleState] = [:]
    private let runningApplicationProvider: HardwareRunningApplicationProvider?

    public init(runningApplicationProvider: HardwareRunningApplicationProvider? = nil) {
        self.runningApplicationProvider = runningApplicationProvider
    }

    public func start() {
        #if os(macOS)
        stop()
        initializeSamplingState()
        triggerSample()

        let interval = Self.samplingIntervalSeconds
        let timer = DispatchSource.makeTimerSource(queue: samplingQueue)
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        timer.setEventHandler { [weak self] in
            self?.sample()
        }
        timer.resume()
        self.timer = timer
        #endif
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func initializeForExternalClock() {
        #if os(macOS)
        stop()
        initializeSamplingState()
        triggerSample()
        #endif
    }

    public func triggerSample() {
        #if os(macOS)
        samplingQueue.async { [weak self] in
            self?.sample()
        }
        #endif
    }

    private func initializeSamplingState() {
        lastSample = [:]
        DispatchQueue.main.async {
            self.topRows = []
        }
    }

    private func sample() {
        #if os(macOS)
        let now = Date().timeIntervalSince1970
        let selfPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let physicalBytes = ProcessInfo.processInfo.physicalMemory
        let logical = Self.sysctlInt("hw.logicalcpu") ?? Self.sysctlInt("hw.logicalcpu_max") ?? 1

        let pids = Self.listAllPIDs()
        guard !pids.isEmpty else {
            DispatchQueue.main.async {
                self.topRows = []
            }
            return
        }

        var rows: [Row] = []
        rows.reserveCapacity(32)
        var sampledPIDs = Set<Int32>()

        for pid in pids {
            if pid == 0 || pid == selfPID { continue }
            guard let taskInfo = Self.readTaskInfo(pid: pid) else { continue }

            sampledPIDs.insert(pid)

            let rss = Double(taskInfo.resident)
            let ramPercent = physicalBytes > 0 ? (rss / Double(physicalBytes)) * 100.0 : 0
            let ramMB = rss / 1_048_576.0

            let cpuNS = taskInfo.userNS &+ taskInfo.systemNS
            let diskCounters = Self.readDiskIOCounters(pid: pid)
            let previousSample = lastSample[pid]
            var cpuPercent: Double = 0
            if let previousSample {
                let dt = max(0.001, now - previousSample.time)
                let deltaCPUSeconds = Double(cpuNS >= previousSample.cpuNS ? (cpuNS - previousSample.cpuNS) : 0) / 1_000_000_000.0
                cpuPercent = (deltaCPUSeconds / dt) * (100.0 / Double(max(logical, 1)))
            }
            let diskRates: (read: Double, write: Double) = {
                guard let previousSample,
                      let diskCounters,
                      let previousReadBytes = previousSample.diskReadBytes,
                      let previousWriteBytes = previousSample.diskWriteBytes else {
                    return (0, 0)
                }
                let dt = max(0.001, now - previousSample.time)
                let readDelta = diskCounters.readBytes >= previousReadBytes
                    ? diskCounters.readBytes - previousReadBytes
                    : 0
                let writeDelta = diskCounters.writeBytes >= previousWriteBytes
                    ? diskCounters.writeBytes - previousWriteBytes
                    : 0
                return (
                    Double(readDelta) / dt / 1_048_576.0,
                    Double(writeDelta) / dt / 1_048_576.0
                )
            }()
            lastSample[pid] = SampleState(
                cpuNS: cpuNS,
                diskReadBytes: diskCounters?.readBytes,
                diskWriteBytes: diskCounters?.writeBytes,
                time: now
            )

            let applicationInfo = runningApplicationProvider?.applicationInfo(for: pid)
            let name = applicationInfo?.localizedName
                ?? applicationInfo?.bundleIdentifier
                ?? "PID \(pid)"
            let uptimeSeconds = Self.uptimeSeconds(since: applicationInfo?.launchDate)
            let uptimeText = Self.formatUptime(seconds: uptimeSeconds)

            rows.append(Row(
                id: pid,
                pid: pid,
                name: name,
                bundleIdentifier: applicationInfo?.bundleIdentifier,
                cpuPercent: max(0, cpuPercent),
                ramPercent: max(0, ramPercent),
                ramMB: max(0, ramMB),
                uptimeSeconds: uptimeSeconds,
                uptimeText: uptimeText,
                diskReadMBps: max(0, diskRates.read),
                diskWriteMBps: max(0, diskRates.write)
            ))
        }

        lastSample = lastSample.filter { sampledPIDs.contains($0.key) }

        let cpuRankedRows = rows.sorted {
            if $0.cpuPercent == $1.cpuPercent { return $0.ramPercent > $1.ramPercent }
            return $0.cpuPercent > $1.cpuPercent
        }
        let ramRankedRows = rows.sorted {
            if $0.ramPercent == $1.ramPercent {
                if $0.ramMB == $1.ramMB {
                    return $0.cpuPercent > $1.cpuPercent
                }
                return $0.ramMB > $1.ramMB
            }
            return $0.ramPercent > $1.ramPercent
        }

        var candidateRowsByPID: [Int32: Row] = [:]
        candidateRowsByPID.reserveCapacity(Self.topProcessCandidateLimit * 2)
        for row in cpuRankedRows.prefix(Self.topProcessCandidateLimit) {
            candidateRowsByPID[row.pid] = row
        }
        for row in ramRankedRows.prefix(Self.topProcessCandidateLimit) {
            candidateRowsByPID[row.pid] = row
        }

        var top = Array(candidateRowsByPID.values)
        top.sort {
            if $0.ramPercent == $1.ramPercent {
                if $0.ramMB == $1.ramMB {
                    return $0.cpuPercent > $1.cpuPercent
                }
                return $0.ramMB > $1.ramMB
            }
            return $0.ramPercent > $1.ramPercent
        }
        if top.count > Self.topProcessCandidateLimit {
            top.removeSubrange(Self.topProcessCandidateLimit...)
        }

        DispatchQueue.main.async {
            self.topRows = top
        }
        #endif
    }

    private struct TaskInfo {
        var userNS: UInt64
        var systemNS: UInt64
        var resident: UInt64
    }

    private static func readTaskInfo(pid: Int32) -> TaskInfo? {
        #if os(macOS)
        var taskInfo = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)

        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, size)
        guard result == size else { return nil }

        return TaskInfo(
            userNS: UInt64(taskInfo.pti_total_user),
            systemNS: UInt64(taskInfo.pti_total_system),
            resident: UInt64(taskInfo.pti_resident_size)
        )
        #else
        return nil
        #endif
    }

    private static func readDiskIOCounters(pid: Int32) -> (readBytes: UInt64, writeBytes: UInt64)? {
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

    private static func listAllPIDs() -> [Int32] {
        #if os(macOS)
        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        if bytesNeeded <= 0 { return [] }

        let count = bytesNeeded / Int32(MemoryLayout<pid_t>.stride)
        var buffer = Array<pid_t>(repeating: 0, count: Int(count))

        let bytesFilled = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, rawBuffer.baseAddress, bytesNeeded)
        }
        if bytesFilled <= 0 { return [] }

        let filledCount = Int(bytesFilled) / MemoryLayout<pid_t>.stride
        return buffer.prefix(filledCount).map { Int32($0) }
        #else
        return []
        #endif
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func uptimeSeconds(since launchDate: Date?) -> Double {
        guard let launchDate else { return 0 }
        return max(0, Date().timeIntervalSince(launchDate))
    }

    private static func formatUptime(seconds dt: Double) -> String {
        let seconds = Int(max(0, dt))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return String(format: "%dh %dm", hours, minutes) }
        return String(format: "%dm", minutes)
    }
}

extension RunningAppsSampler {
    public var liveSnapshot: RunningAppsSamplerLiveSnapshot {
        RunningAppsSamplerLiveSnapshot(topRows: topRows)
    }

    public func applyRemoteSnapshot(_ snapshot: RunningAppsSamplerLiveSnapshot) {
        topRows = snapshot.topRows
    }
}
