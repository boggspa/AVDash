import Foundation
import Combine
#if os(macOS)
import IOKit
#endif

/// Enumerates per-process GPU client entries via IOKit to identify apps
/// with non-zero GPU time. Excludes the collector process itself and WindowServer.
///
/// On Apple Silicon, active app clients are exposed as `AGXDeviceUserClient`
/// entries beneath the AGX accelerator stack. Older systems may still surface
/// client entries under `IOGPUDevice`. We prefer the direct AGX user-client
/// path and fall back to the legacy child walk when needed.
public final class GPUClientsSampler: ObservableObject {
    private static var samplingIntervalSeconds: Int {
        HardwareCollectionSettings.collectorIntervalSeconds()
    }

    public struct GPUClientApp: Identifiable, Codable, Equatable, Sendable {
        public let id: Int32       // PID
        public let pid: Int32
        public let name: String
        public let bundleIdentifier: String?
        /// Cumulative GPU time in nanoseconds observed at last sample.
        public let gpuTimeNS: UInt64
        /// Per-sample delta GPU time in nanoseconds observed during the latest cycle.
        public let gpuDeltaTimeNS: UInt64?
        /// True when the process had non-zero delta GPU time this sample cycle.
        public let isActive: Bool

        public init(
            pid: Int32,
            name: String,
            bundleIdentifier: String?,
            gpuTimeNS: UInt64,
            gpuDeltaTimeNS: UInt64? = nil,
            isActive: Bool
        ) {
            self.id = pid
            self.pid = pid
            self.name = name
            self.bundleIdentifier = bundleIdentifier
            self.gpuTimeNS = gpuTimeNS
            self.gpuDeltaTimeNS = gpuDeltaTimeNS
            self.isActive = isActive
        }
    }

    /// Apps with non-zero GPU time (excluding self + WindowServer), sorted by
    /// descending GPU time. Only includes apps observed in the current sample.
    @Published public private(set) var activeApps: [GPUClientApp] = []

    /// Convenience set of PIDs that had non-zero delta GPU time this sample.
    @Published public private(set) var activeGPUPIDs: Set<Int32> = []

    #if os(macOS)
    private var timer: DispatchSourceTimer?
    private let samplingQueue = DispatchQueue(label: "PodcastPreview.GPUClientsSampler", qos: .utility)
    private var previousGPUTime: [Int32: UInt64] = [:]
    #endif
    private let runningApplicationProvider: HardwareRunningApplicationProvider?

    private static let excludedNames: Set<String> = [
        "WindowServer",
        "windowserver",
    ]

    public init(runningApplicationProvider: HardwareRunningApplicationProvider? = nil) {
        self.runningApplicationProvider = runningApplicationProvider
    }

    public func start() {
        #if os(macOS)
        stop()
        initializeSamplingState()
        triggerSample()

        let interval = Self.samplingIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: samplingQueue)
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in
            self?.sample()
        }
        t.resume()
        timer = t
        #endif
    }

    public func stop() {
        #if os(macOS)
        timer?.cancel()
        timer = nil
        #endif
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
        #if os(macOS)
        previousGPUTime = [:]
        DispatchQueue.main.async {
            self.activeApps = []
            self.activeGPUPIDs = []
        }
        #endif
    }

    #if os(macOS)
    private func sample() {
        let selfPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let clients = sampleGPUClientEntries()

        // Aggregate by PID (a process may have multiple IOGPUClient entries).
        var byPID: [Int32: UInt64] = [:]
        for c in clients {
            byPID[c.pid, default: 0] += c.gpuTimeNS
        }

        // Build output, computing deltas from previous sample.
        var apps: [GPUClientApp] = []
        var newActiveSet = Set<Int32>()

        for (pid, totalTime) in byPID {
            if pid == selfPID || pid == 0 { continue }

            let delta: UInt64
            if let prev = previousGPUTime[pid], totalTime >= prev {
                delta = totalTime - prev
            } else {
                // First sample for this PID — report as active if totalTime > 0.
                delta = totalTime > 0 ? 1 : 0
            }

            let appInfo = runningApplicationProvider?.applicationInfo(for: pid)
            let name = appInfo?.localizedName ?? appInfo?.bundleIdentifier ?? "PID \(pid)"
            let bundleID = appInfo?.bundleIdentifier

            // Exclude WindowServer. The collector process is already skipped by PID,
            // so app bundle IDs should remain visible in headless mode.
            if Self.excludedNames.contains(name) { continue }

            let isActive = delta > 0

            apps.append(GPUClientApp(
                pid: pid,
                name: name,
                bundleIdentifier: bundleID,
                gpuTimeNS: totalTime,
                gpuDeltaTimeNS: delta,
                isActive: isActive
            ))

            if isActive {
                newActiveSet.insert(pid)
            }
        }

        previousGPUTime = byPID

        // Sort by GPU time descending, then alphabetically.
        apps.sort {
            if $0.gpuTimeNS != $1.gpuTimeNS { return $0.gpuTimeNS > $1.gpuTimeNS }
            return $0.name < $1.name
        }

        DispatchQueue.main.async {
            self.activeApps = apps
            self.activeGPUPIDs = newActiveSet
        }
    }

    private func sampleGPUClientEntries() -> [(pid: Int32, gpuTimeNS: UInt64)] {
        let agxClients = sampleDirectClientEntries(matching: "AGXDeviceUserClient")
        if !agxClients.isEmpty {
            return agxClients
        }

        let agxChildClients = sampleChildClientEntries(rootClass: "AGXAccelerator")
        if !agxChildClients.isEmpty {
            return agxChildClients
        }

        return sampleChildClientEntries(rootClass: "IOGPUDevice")
    }

    private func sampleDirectClientEntries(matching serviceClass: String) -> [(pid: Int32, gpuTimeNS: UInt64)] {
        let matching = IOServiceMatching(serviceClass)
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(Self.ioMainPort, matching, &iterator)
        guard kr == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var clients: [(pid: Int32, gpuTimeNS: UInt64)] = []
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }

            guard let clientInfo = readGPUClientInfo(from: entry) else { continue }
            clients.append(clientInfo)
        }
        return clients
    }

    private func sampleChildClientEntries(rootClass: String) -> [(pid: Int32, gpuTimeNS: UInt64)] {
        let matching = IOServiceMatching(rootClass)
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(Self.ioMainPort, matching, &iterator)
        guard kr == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var clients: [(pid: Int32, gpuTimeNS: UInt64)] = []
        while true {
            let device = IOIteratorNext(iterator)
            if device == 0 { break }
            defer { IOObjectRelease(device) }

            var childIterator: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &childIterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(childIterator) }

            while true {
                let child = IOIteratorNext(childIterator)
                if child == 0 { break }
                defer { IOObjectRelease(child) }

                guard let clientInfo = readGPUClientInfo(from: child) else { continue }
                clients.append(clientInfo)
            }
        }

        return clients
    }

    // MARK: - IOKit helpers

    /// Reads PID and GPU time from an AGX / IOGPU user-client entry.
    private func readGPUClientInfo(from entry: io_registry_entry_t) -> (pid: Int32, gpuTimeNS: UInt64)? {
        // Try to read PID from the "IOUserClientCreator" string (format: "pid NNNN, AppName").
        guard let pid = readClientPID(from: entry), pid > 0 else { return nil }

        // GPU time: prefer AppUsage accumulated GPU time on Apple Silicon,
        // then fall back to older / alternate scalar keys when present.
        let gpuTimeNS = readGPUTime(from: entry)

        return (pid: pid, gpuTimeNS: gpuTimeNS)
    }

    private func readClientPID(from entry: io_registry_entry_t) -> Int32? {
        // Method 1: "IOUserClientCreator" string contains "pid NNNN, ..."
        if let creatorStr = cfProperty(entry, "IOUserClientCreator") as? String {
            // Parse "pid 12345, AppName" or "pid 12345"
            let components = creatorStr.components(separatedBy: ",")
            if let pidPart = components.first?.trimmingCharacters(in: .whitespaces) {
                let pidStr = pidPart.replacingOccurrences(of: "pid ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if let pid = Int32(pidStr) {
                    return pid
                }
            }
        }

        // Method 2: Explicit "pid" or "ClientPID" property.
        if let n = cfProperty(entry, "pid") as? NSNumber { return n.int32Value }
        if let n = cfProperty(entry, "ClientPID") as? NSNumber { return n.int32Value }

        return nil
    }

    private func readGPUTime(from entry: io_registry_entry_t) -> UInt64 {
        if let appUsageTime = readAppUsageGPUTime(from: entry), appUsageTime > 0 {
            return appUsageTime
        }

        let keys = [
            "IOGPUClientGPUTime",
            "GPUTime",
            "gpu-time",
            "IOAccelClientGPUTime",
        ]

        for key in keys {
            if let n = cfProperty(entry, key) as? NSNumber {
                return n.uint64Value
            }
        }

        // Fallback: look in a PerformanceStatistics sub-dictionary on the entry.
        if let stats = cfProperty(entry, "PerformanceStatistics") as? [String: Any] {
            for key in keys {
                if let n = stats[key] as? NSNumber {
                    return n.uint64Value
                }
            }
        }

        return 0
    }

    private func readAppUsageGPUTime(from entry: io_registry_entry_t) -> UInt64? {
        guard let rawAppUsage = cfProperty(entry, "AppUsage") else { return nil }

        let dictionaries: [NSDictionary]
        if let bridged = rawAppUsage as? [NSDictionary] {
            dictionaries = bridged
        } else if let bridged = rawAppUsage as? NSArray {
            dictionaries = bridged.compactMap { $0 as? NSDictionary }
        } else {
            return nil
        }

        guard !dictionaries.isEmpty else { return nil }

        var total: UInt64 = 0
        var foundValue = false
        for dictionary in dictionaries {
            if let numericValue = dictionary["accumulatedGPUTime"] as? NSNumber {
                total &+= numericValue.uint64Value
                foundValue = true
            } else if let numericValue = dictionary["GPUTime"] as? NSNumber {
                total &+= numericValue.uint64Value
                foundValue = true
            }
        }

        return foundValue ? total : nil
    }

    private func cfProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }
    #endif

    private func publishEmpty() {
        DispatchQueue.main.async {
            self.activeApps = []
            self.activeGPUPIDs = []
        }
    }

    #if os(macOS)
    private static var ioMainPort: mach_port_t {
        if #available(macOS 12.0, *) {
            return kIOMainPortDefault
        } else {
            return kIOMasterPortDefault
        }
    }
    #endif
}

// MARK: - Live snapshot support

public struct GPUClientsSamplerLiveSnapshot: Codable, Sendable {
    public var activeApps: [GPUClientsSampler.GPUClientApp]

    public init(activeApps: [GPUClientsSampler.GPUClientApp]) {
        self.activeApps = activeApps
    }
}

extension GPUClientsSampler {
    public var liveSnapshot: GPUClientsSamplerLiveSnapshot {
        GPUClientsSamplerLiveSnapshot(activeApps: activeApps)
    }

    public func applyRemoteSnapshot(_ snapshot: GPUClientsSamplerLiveSnapshot) {
        DispatchQueue.main.async {
            self.activeApps = snapshot.activeApps
            self.activeGPUPIDs = Set(snapshot.activeApps.filter(\.isActive).map(\.pid))
        }
    }
}
