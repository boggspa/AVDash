import Foundation
import Combine
import Darwin
#if os(macOS)
import IOKit
import IOKit.graphics
#endif

/// Sandbox-safe GPU sampler using read-only IORegistry keys.
/// Publishes one entry per physical GPU (best-effort grouping).
public final class GPUStatsSampler: ObservableObject {

    public struct GPUUnit: Identifiable, Codable, Sendable {
        public let id: String              // stable-ish IORegistry path of the parent PCI device
        public var name: String
        public var usage: Float?
        public var usageHistory: [Float]
        public var vramTotalMB: Int?
        public var vramUsedMB: Int?
        public var vramFreeMB: Int?

        // Apple-silicon / IOAccelerator sub-metrics
        public var rendererUsage: Float?
        public var rendererHistory: [Float]
        public var tilerUsage: Float?
        public var tilerHistory: [Float]
        public var rendererAllocatedPageBufferMB: Int?
        public var tilerSceneKB: Int?

        public var gpuMemoryAllocatedMB: Int?
        public var gpuMemoryInUseMB: Int?
        public var gpuMemoryDriverInUseMB: Int?

        public var temperatureC: Int?
        public var fanRPM: Int?
        public var coreClockMHz: Int?
        public var memoryClockMHz: Int?
        public var totalPowerW: Int?
        public var coreCount: Int?
    }

    @Published public var gpus: [GPUUnit] = []
    @Published public private(set) var usageSeriesByGPU: [String: HardwareDeviceMetricSeries] = [:]
    @Published public private(set) var rendererSeriesByGPU: [String: HardwareDeviceMetricSeries] = [:]
    @Published public private(set) var tilerSeriesByGPU: [String: HardwareDeviceMetricSeries] = [:]
    @Published public private(set) var memoryUsageSeriesByGPU: [String: HardwareDeviceMetricSeries] = [:]
    @Published public private(set) var latestDeviceSnapshots: [HardwareDeviceSnapshot] = []

    // Legacy single-label kept for older UI code paths (now unused in HardwareStatsView).
    @Published public var gpuDisplayName: String = "GPU Usage"

    #if os(macOS)
    private var timer: DispatchSourceTimer?
    private var usageSeriesBuffers: [String: HardwareDeviceMetricSeries] = [:]
    private var rendererSeriesBuffers: [String: HardwareDeviceMetricSeries] = [:]
    private var tilerSeriesBuffers: [String: HardwareDeviceMetricSeries] = [:]
    private var memoryUsageSeriesBuffers: [String: HardwareDeviceMetricSeries] = [:]
    #endif

    private var historyLength: Int { HardwareCollectionSettings.liveSeriesCapacity() }

    private func preferredDedicatedVRAMTotalMB(existing: Int?, candidate: Int?) -> Int? {
        switch (existing, candidate) {
        case let (existing?, candidate?) where existing > 0 && candidate > 0:
            return max(existing, candidate)
        case let (existing?, _) where existing > 0:
            return existing
        case let (_, candidate?) where candidate > 0:
            return candidate
        default:
            return nil
        }
    }

    public init() {}

    public func initialize() {
        #if os(macOS)
        stop()
        usageSeriesBuffers.removeAll()
        rendererSeriesBuffers.removeAll()
        tilerSeriesBuffers.removeAll()
        memoryUsageSeriesBuffers.removeAll()
        DispatchQueue.main.async {
            self.gpus = []
            self.usageSeriesByGPU = [:]
            self.rendererSeriesByGPU = [:]
            self.tilerSeriesByGPU = [:]
            self.memoryUsageSeriesByGPU = [:]
            self.latestDeviceSnapshots = []
        }
        sample()
        #endif
    }

    public func start() {
        #if os(macOS)
        initialize()

        let interval = HardwareCollectionSettings.collectorIntervalSeconds()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
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

    #if os(macOS)
    func sample() {
        let timestamp = Date()
        // Enumerate accelerators and group by parent IOPCIDevice (best-effort)
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0

        let kr = IOServiceGetMatchingServices(Self.ioMainPort, matching, &iterator)
        guard kr == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        // Temporary aggregation by GPU id
        struct Partial {
            var name: String
            var usage: Float?
            var rendererUsage: Float?
            var rendererAllocatedPageBufferMB: Int?
            var tilerUsage: Float?
            var tilerSceneKB: Int?

            var vramTotalMB: Int?
            var vramUsedMB: Int?
            var vramFreeMB: Int?

            var gpuMemoryAllocatedMB: Int?
            var gpuMemoryInUseMB: Int?
            var gpuMemoryDriverInUseMB: Int?

            var temperatureC: Int?
            var fanRPM: Int?
            var coreClockMHz: Int?
            var memoryClockMHz: Int?
            var totalPowerW: Int?
            var coreCount: Int?

            // Keep one coherent snapshot per GPU bucket, chosen by highest device usage.
            var chosenScore: Float?
        }
        var buckets: [String: Partial] = [:]

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            // Group key: prefer stable PCI identity (vendor/device/subsystem) when available;
            // fallback to parent PCI registry path; then accelerator registry path.
            let gpuID = pciIdentityKey(for: service)
                ?? parentPCIDevicePath(for: service)
                ?? registryPath(for: service)
                ?? UUID().uuidString

            // Name: normalize to remove hidden/control chars.
            let name = normalizeGPUName(detectGPUName(for: service) ?? "GPU")

            // Usage + Apple-silicon sub-metrics from PerformanceStatistics.
            let performanceStatistics = performanceStatistics(for: service)
            let perf = readGPUPerformanceStats(from: performanceStatistics)
            let usage = perf.deviceUsage
            let submetricMemory = readAppleSiliconSubmetricMemoryStats(from: performanceStatistics)
            let envStats = readGPUThermalAndPowerStats(from: performanceStatistics)

            // VRAM / unified-memory stats: best-effort
            let vram = readVRAMStats(for: service, performanceStatistics: performanceStatistics)

            // GPU core count (Apple Silicon / some discrete GPUs)
            let coreCount = readGPUCoreCount(for: service)

            var p = buckets[gpuID] ?? Partial(
                name: name,
                usage: nil,
                rendererUsage: nil,
                rendererAllocatedPageBufferMB: nil,
                tilerSceneKB: nil,
                vramTotalMB: nil,
                vramUsedMB: nil,
                vramFreeMB: nil,
                gpuMemoryAllocatedMB: nil,
                gpuMemoryInUseMB: nil,
                gpuMemoryDriverInUseMB: nil,
                temperatureC: nil,
                fanRPM: nil,
                coreClockMHz: nil,
                memoryClockMHz: nil,
                totalPowerW: nil,
                coreCount: nil,
                chosenScore: nil
            )
            p.name = (p.name == "GPU") ? name : p.name
            p.vramTotalMB = self.preferredDedicatedVRAMTotalMB(existing: p.vramTotalMB, candidate: vram.totalMB)

            // Choose one coherent snapshot per GPU bucket so renderer/tiler/memory
            // values stay aligned to the same IOAccelerator service.
            let candidateScore = usage ?? -1
            if p.chosenScore == nil || candidateScore > p.chosenScore! {
                p.chosenScore = candidateScore
                p.usage = usage
                p.rendererUsage = perf.rendererUsage
                p.tilerUsage = perf.tilerUsage
                p.rendererAllocatedPageBufferMB = submetricMemory.rendererAllocatedPageBufferMB
                p.tilerSceneKB = submetricMemory.tilerSceneKB

                p.vramUsedMB = vram.usedMB
                p.vramFreeMB = vram.freeMB

                p.gpuMemoryAllocatedMB = vram.gpuMemoryAllocatedMB
                p.gpuMemoryInUseMB = vram.gpuMemoryInUseMB
                p.gpuMemoryDriverInUseMB = vram.gpuMemoryDriverInUseMB

                p.temperatureC = envStats.temperatureC
                p.fanRPM = envStats.fanRPM
                p.coreClockMHz = envStats.coreClockMHz
                p.memoryClockMHz = envStats.memoryClockMHz
                p.totalPowerW = envStats.totalPowerW
                p.coreCount = coreCount
            }

            buckets[gpuID] = p
        }

        // Merge into published models, preserving histories by id, and deduplicate by broadened key, omitting GPUs with no usage.
        DispatchQueue.main.async {
            let existingByID = Dictionary(uniqueKeysWithValues: self.gpus.map { ($0.id, $0) })

            // 1) Build updated units, but skip any entries with no usage (no card/graph).
            var built: [GPUUnit] = []
            built.reserveCapacity(buckets.count)

            for (id, p) in buckets {
                // Skip entries that have no usable utilization signal.
                guard let usage = p.usage else { continue }

                var unit = existingByID[id]
                    ?? GPUUnit(
                        id: id,
                        name: p.name,
                        usage: nil,
                        usageHistory: [],
                        vramTotalMB: nil,
                        vramUsedMB: nil,
                        vramFreeMB: nil,
                        rendererUsage: nil,
                        rendererHistory: [],
                        tilerUsage: nil,
                        tilerHistory: [],
                        gpuMemoryAllocatedMB: nil,
                        gpuMemoryInUseMB: nil,
                        gpuMemoryDriverInUseMB: nil,
                        temperatureC: nil,
                        fanRPM: nil,
                        coreClockMHz: nil,
                        memoryClockMHz: nil,
                        totalPowerW: nil,
                        coreCount: nil
                    )

                unit.name = p.name
                unit.usage = usage
                unit.vramTotalMB = self.preferredDedicatedVRAMTotalMB(
                    existing: unit.vramTotalMB,
                    candidate: p.vramTotalMB
                )
                unit.vramUsedMB  = p.vramUsedMB
                unit.vramFreeMB  = p.vramFreeMB

                unit.rendererUsage = p.rendererUsage
                unit.tilerUsage = p.tilerUsage
                unit.rendererAllocatedPageBufferMB = p.rendererAllocatedPageBufferMB
                unit.tilerSceneKB = p.tilerSceneKB

                unit.gpuMemoryAllocatedMB = p.gpuMemoryAllocatedMB
                unit.gpuMemoryInUseMB = p.gpuMemoryInUseMB
                unit.gpuMemoryDriverInUseMB = p.gpuMemoryDriverInUseMB

                unit.temperatureC = p.temperatureC
                unit.fanRPM = p.fanRPM
                unit.coreClockMHz = p.coreClockMHz
                unit.memoryClockMHz = p.memoryClockMHz
                unit.totalPowerW = p.totalPowerW
                unit.coreCount = p.coreCount

                built.append(unit)
            }

            // 2) De-duplicate by a broadened key.
            // Prefer PCI identity when present (encoded into `id`), else fall back to normalized name.
            // Keep the entry with (a) longer history, then (b) more VRAM fields populated.
            func vramScore(_ u: GPUUnit) -> Int {
                var s = 0
                if u.vramTotalMB != nil { s += 2 }
                if u.vramUsedMB  != nil { s += 1 }
                if u.vramFreeMB  != nil { s += 1 }
                return s
            }

            var byKey: [String: GPUUnit] = [:]
            for u in built {
                let key = u.id.isEmpty ? self.normalizeGPUName(u.name) : u.id
                if let existing = byKey[key] {
                    if u.usageHistory.count > existing.usageHistory.count {
                        byKey[key] = u
                    } else if u.usageHistory.count == existing.usageHistory.count {
                        if vramScore(u) > vramScore(existing) {
                            byKey[key] = u
                        }
                    }
                } else {
                    byKey[key] = u
                }
            }

            var next = Array(byKey.values)

            // Stable-ish ordering for UI: by name then id
            next.sort { a, b in
                if a.name == b.name { return a.id < b.id }
                return a.name < b.name
            }

            var nextUsageSeriesBuffers: [String: HardwareDeviceMetricSeries] = [:]
            var nextRendererSeriesBuffers: [String: HardwareDeviceMetricSeries] = [:]
            var nextTilerSeriesBuffers: [String: HardwareDeviceMetricSeries] = [:]
            var nextMemoryUsageSeriesBuffers: [String: HardwareDeviceMetricSeries] = [:]
            var deviceSnapshots: [HardwareDeviceSnapshot] = []
            deviceSnapshots.reserveCapacity(next.count)

            for index in next.indices {
                var unit = next[index]

                var usageSeries = self.usageSeriesBuffers[unit.id]
                    ?? Self.makeSeries(deviceID: unit.id, key: .utilizationRatio, unit: .ratio)
                usageSeries.append(unit.usage.map(Double.init), at: timestamp, capacity: self.historyLength)
                nextUsageSeriesBuffers[unit.id] = usageSeries
                unit.usageHistory = usageSeries.values().map(Float.init)

                var rendererSeries = self.rendererSeriesBuffers[unit.id]
                    ?? Self.makeSeries(deviceID: unit.id, key: .rendererUtilizationRatio, unit: .ratio)
                rendererSeries.append(unit.rendererUsage.map(Double.init), at: timestamp, capacity: self.historyLength)
                nextRendererSeriesBuffers[unit.id] = rendererSeries
                unit.rendererHistory = rendererSeries.observedValues().map(Float.init)

                var tilerSeries = self.tilerSeriesBuffers[unit.id]
                    ?? Self.makeSeries(deviceID: unit.id, key: .tilerUtilizationRatio, unit: .ratio)
                tilerSeries.append(unit.tilerUsage.map(Double.init), at: timestamp, capacity: self.historyLength)
                nextTilerSeriesBuffers[unit.id] = tilerSeries
                unit.tilerHistory = tilerSeries.observedValues().map(Float.init)

                let memoryMetricKey: HardwareDeviceMetricKey =
                    unit.gpuMemoryAllocatedMB != nil ? .memoryAllocatedMegabytes : .vramUsedMegabytes
                let memoryMetricValue = unit.gpuMemoryAllocatedMB.map(Double.init) ?? unit.vramUsedMB.map(Double.init)
                var memoryUsageSeries: HardwareDeviceMetricSeries
                if let existingSeries = self.memoryUsageSeriesBuffers[unit.id],
                   existingSeries.key == memoryMetricKey {
                    memoryUsageSeries = existingSeries
                } else {
                    memoryUsageSeries = Self.makeSeries(deviceID: unit.id, key: memoryMetricKey, unit: .megabytes)
                }
                memoryUsageSeries.append(memoryMetricValue, at: timestamp, capacity: self.historyLength)
                nextMemoryUsageSeriesBuffers[unit.id] = memoryUsageSeries

                var snapshot = HardwareDeviceSnapshot(deviceID: unit.id, deviceKind: .gpu, timestamp: timestamp)
                snapshot.setDimension(.name, value: unit.name)

                if let usage = unit.usage {
                    snapshot.setMetric(.utilizationRatio, value: Double(usage))
                }
                if let rendererUsage = unit.rendererUsage {
                    snapshot.setMetric(.rendererUtilizationRatio, value: Double(rendererUsage))
                }
                if let tilerUsage = unit.tilerUsage {
                    snapshot.setMetric(.tilerUtilizationRatio, value: Double(tilerUsage))
                }
                if let vramTotalMB = unit.vramTotalMB {
                    snapshot.setMetric(.vramTotalMegabytes, value: Double(vramTotalMB))
                }
                if let vramUsedMB = unit.vramUsedMB {
                    snapshot.setMetric(.vramUsedMegabytes, value: Double(vramUsedMB))
                }
                if let vramFreeMB = unit.vramFreeMB {
                    snapshot.setMetric(.vramFreeMegabytes, value: Double(vramFreeMB))
                }
                if let rendererAllocatedPageBufferMB = unit.rendererAllocatedPageBufferMB {
                    snapshot.setMetric(.rendererAllocatedPageBufferMegabytes, value: Double(rendererAllocatedPageBufferMB))
                }
                if let tilerSceneKB = unit.tilerSceneKB {
                    snapshot.setMetric(.tilerSceneKilobytes, value: Double(tilerSceneKB))
                }
                if let gpuMemoryAllocatedMB = unit.gpuMemoryAllocatedMB {
                    snapshot.setMetric(.memoryAllocatedMegabytes, value: Double(gpuMemoryAllocatedMB))
                }
                if let gpuMemoryInUseMB = unit.gpuMemoryInUseMB {
                    snapshot.setMetric(.memoryInUseMegabytes, value: Double(gpuMemoryInUseMB))
                }
                if let gpuMemoryDriverInUseMB = unit.gpuMemoryDriverInUseMB {
                    snapshot.setMetric(.memoryDriverInUseMegabytes, value: Double(gpuMemoryDriverInUseMB))
                }
                if let temperatureC = unit.temperatureC {
                    snapshot.setMetric(.temperatureCelsius, value: Double(temperatureC))
                }
                if let fanRPM = unit.fanRPM {
                    snapshot.setMetric(.fanRPM, value: Double(fanRPM))
                }
                if let coreClockMHz = unit.coreClockMHz {
                    snapshot.setMetric(.coreClockMegahertz, value: Double(coreClockMHz))
                }
                if let memoryClockMHz = unit.memoryClockMHz {
                    snapshot.setMetric(.memoryClockMegahertz, value: Double(memoryClockMHz))
                }
                if let totalPowerW = unit.totalPowerW {
                    snapshot.setMetric(.totalPowerWatts, value: Double(totalPowerW))
                }
                if let coreCount = unit.coreCount {
                    snapshot.setMetric(.coreCount, value: Double(coreCount))
                }

                if !snapshot.isEmpty {
                    deviceSnapshots.append(snapshot)
                }

                next[index] = unit
            }

            self.usageSeriesBuffers = nextUsageSeriesBuffers
            self.rendererSeriesBuffers = nextRendererSeriesBuffers
            self.tilerSeriesBuffers = nextTilerSeriesBuffers
            self.memoryUsageSeriesBuffers = nextMemoryUsageSeriesBuffers
            self.gpus = next
            self.usageSeriesByGPU = nextUsageSeriesBuffers
            self.rendererSeriesByGPU = nextRendererSeriesBuffers
            self.tilerSeriesByGPU = nextTilerSeriesBuffers
            self.memoryUsageSeriesByGPU = nextMemoryUsageSeriesBuffers
            self.latestDeviceSnapshots = deviceSnapshots
        }
    }

    private static func makeSeries(
        deviceID: String,
        key: HardwareDeviceMetricKey,
        unit: HardwareMetricUnit
    ) -> HardwareDeviceMetricSeries {
        HardwareDeviceMetricSeries(
            deviceID: deviceID,
            deviceKind: .gpu,
            key: key,
            unit: unit
        )
    }

    private func readGPUThermalAndPowerStats(for accelerator: io_registry_entry_t) -> (
        temperatureC: Int?,
        fanRPM: Int?,
        coreClockMHz: Int?,
        memoryClockMHz: Int?,
        totalPowerW: Int?
    ) {
        readGPUThermalAndPowerStats(from: performanceStatistics(for: accelerator))
    }

    private func readGPUThermalAndPowerStats(from performanceStatistics: [String: Any]?) -> (
        temperatureC: Int?,
        fanRPM: Int?,
        coreClockMHz: Int?,
        memoryClockMHz: Int?,
        totalPowerW: Int?
    ) {
        func numberToInt(_ v: Any) -> Int? {
            if let n = v as? NSNumber { return n.intValue }
            if let i = v as? Int { return i }
            if let i = v as? Int64 { return Int(i) }
            if let u = v as? UInt64 { return Int(u) }
            if let f = v as? Float { return Int(f.rounded()) }
            if let d = v as? Double { return Int(d.rounded()) }
            return nil
        }

        guard let dict = performanceStatistics else {
            return (nil, nil, nil, nil, nil)
        }

        func readAny(_ keys: [String]) -> Int? {
            for key in keys {
                if let raw = dict[key], let value = numberToInt(raw) {
                    return value
                }
            }
            return nil
        }

        let temperatureC = readAny([
            "Temperature(C)",
            "Temperature",
            "GPU Temperature(C)",
            "GPU Temperature"
        ])

        let fanRPM = readAny([
            "Fan Speed(RPM)",
            "Fan RPM",
            "Fan Speed"
        ])

        let coreClockMHz = readAny([
            "Core Clock(MHz)",
            "Core Clock",
            "GPU Clock(MHz)",
            "GPU Clock"
        ])

        let memoryClockMHz = readAny([
            "Memory Clock(MHz)",
            "Memory Clock",
            "VRAM Clock(MHz)",
            "VRAM Clock"
        ])

        let totalPowerW = readAny([
            "Total Power(W)",
            "Total Power",
            "Power(W)",
            "Power"
        ])

        return (temperatureC, fanRPM, coreClockMHz, memoryClockMHz, totalPowerW)
    }

    private func readAppleSiliconSubmetricMemoryStats(for accelerator: io_registry_entry_t) -> (
        rendererAllocatedPageBufferMB: Int?,
        tilerSceneKB: Int?
    ) {
        readAppleSiliconSubmetricMemoryStats(from: performanceStatistics(for: accelerator))
    }

    private func readAppleSiliconSubmetricMemoryStats(from performanceStatistics: [String: Any]?) -> (
        rendererAllocatedPageBufferMB: Int?,
        tilerSceneKB: Int?
    ) {
        func numToInt64(_ any: Any) -> Int64? {
            if let n = any as? NSNumber { return n.int64Value }
            if let i = any as? Int64 { return i }
            if let i = any as? Int { return Int64(i) }
            if let u = any as? UInt64 { return Int64(u) }
            return nil
        }

        guard let stats = performanceStatistics else {
            return (nil, nil)
        }

        func readMB(_ keys: [String]) -> Int? {
            for key in keys {
                if let raw = stats[key], let bytes = numToInt64(raw), bytes >= 0 {
                    return Int(bytes / 1_048_576)
                }
            }
            return nil
        }

        func readKB(_ keys: [String]) -> Int? {
            for key in keys {
                if let raw = stats[key], let bytes = numToInt64(raw), bytes >= 0 {
                    return Int(bytes / 1_024)
                }
            }
            return nil
        }

        let rendererAllocatedPageBufferMB = readMB([
            "Allocated PB Size",
            "Allocated Page Buffer Size",
            "Allocated Page Buffer Bytes",
            "Allocated Page Buffer",
            "Allocated Page Buffers"
        ])

        let tilerSceneKB = readKB([
            "TiledSceneBytes",
            "Tiled Scene Bytes",
            "Tiled Scene Size",
            "Tiled Scene",
            "Tiled Scene Memory"
        ])

        return (rendererAllocatedPageBufferMB, tilerSceneKB)
    }

    private func nextIDs(from units: [GPUUnit]) -> [String] {
        units.map { $0.id }
    }

    /// `kIOMainPortDefault` is macOS 12+; for Big Sur and earlier use `kIOMasterPortDefault`.
    private static var ioMainPort: mach_port_t {
        if #available(macOS 12.0, *) {
            return kIOMainPortDefault
        } else {
            return kIOMasterPortDefault
        }
    }

    private func registryPath(for entry: io_registry_entry_t) -> String? {
        var path = [CChar](repeating: 0, count: 1024)
        let kr = IORegistryEntryGetPath(entry, kIOServicePlane, &path)
        guard kr == KERN_SUCCESS else { return nil }
        return String(cString: path)
    }

    private func normalizeGPUName(_ s: String) -> String {
        // Remove hidden/control characters and anything after a NUL terminator.
        var out = s
        if let nul = out.firstIndex(of: "\0") {
            out = String(out[..<nul])
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        out = out.trimmingCharacters(in: .controlCharacters)

        // Collapse consecutive whitespace
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return out
    }

    private func stringFromIORegData(_ data: Data) -> String? {
        // Many IOReg strings are NUL-terminated byte arrays.
        if data.isEmpty { return nil }
        let bytes = [UInt8](data)
        let end = bytes.firstIndex(of: 0) ?? bytes.count
        let slice = bytes[0..<end]
        if slice.isEmpty { return nil }

        // Try UTF-8 first, then ASCII.
        if let s = String(bytes: slice, encoding: .utf8) {
            let n = normalizeGPUName(s)
            return n.isEmpty ? nil : n
        }
        if let s = String(bytes: slice, encoding: .ascii) {
            let n = normalizeGPUName(s)
            return n.isEmpty ? nil : n
        }
        return nil
    }

    private func stringProperty(_ entry: io_registry_entry_t, _ key: String) -> String? {
        if let s = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
            let n = normalizeGPUName(s)
            return n.isEmpty ? nil : n
        }
        if let data = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
            return stringFromIORegData(data)
        }
        return nil
    }

    private func vendorName(forVendorID vid: UInt32) -> String {
        switch vid {
        case 0x8086: return "Intel"
        case 0x1002: return "AMD"
        case 0x10DE: return "NVIDIA"
        case 0x106B: return "Apple"
        default: return String(format: "0x%08X", vid)
        }
    }

    private func friendlyGPUName(vendorID: UInt32?, deviceID: UInt32?) -> String? {
        guard let vendorID, let deviceID else { return nil }

        switch vendorID {
        case 0x8086:
            switch deviceID {
            case 0x0166, 0x0162, 0x016A:
                return "Intel HD Graphics 4000"
            case 0x0412, 0x0416, 0x0A16:
                return "Intel HD Graphics 4600"
            case 0x0D26, 0x0D22:
                return "Intel Iris Pro Graphics 5200"
            case 0x1616, 0x161E:
                return "Intel HD Graphics 5500"
            case 0x1626, 0x162B:
                return "Intel HD Graphics 6000"
            case 0x1622, 0x162D:
                return "Intel Iris Pro Graphics 6200"
            case 0x1912, 0x1916, 0x191B:
                return "Intel HD Graphics 530"
            case 0x1926, 0x1927:
                return "Intel Iris Graphics 540"
            case 0x192B:
                return "Intel Iris Graphics 550"
            case 0x1932:
                return "Intel Iris Pro Graphics 580"
            case 0x5912, 0x5916, 0x591B:
                return "Intel HD Graphics 630"
            case 0x5926:
                return "Intel Iris Plus Graphics 640"
            case 0x5927:
                return "Intel Iris Plus Graphics 650"
            case 0x3E9B:
                return "Intel UHD Graphics 630"
            default:
                return "Intel Graphics"
            }

        case 0x1002:
            switch deviceID {
            case 0x67DF:
                return "AMD Radeon RX 580"
            case 0x67EF:
                return "AMD Radeon RX 560"
            case 0x731F:
                return "AMD Radeon RX 5700 XT"
            case 0x7340:
                return "AMD Radeon RX 6800"
            case 0x7341:
                return "AMD Radeon RX 6800 XT"
            case 0x73BF:
                return "AMD Radeon RX 6900 XT"
            default:
                return nil
            }

        case 0x10DE:
            return "NVIDIA GPU"

        case 0x106B:
            return "Apple GPU"

        default:
            return nil
        }
    }

    private func pciVendorDeviceIDs(for accelerator: io_registry_entry_t) -> (vendor: UInt32?, device: UInt32?) {
        guard let pci = parentPCIDeviceEntry(for: accelerator) else { return (nil, nil) }
        defer { IOObjectRelease(pci) }

        func readID(_ key: String) -> UInt32? {
            if let data = IORegistryEntryCreateCFProperty(pci, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
                if data.count >= 4 { return data.withUnsafeBytes { $0.load(as: UInt32.self) } }
            }
            if let n = IORegistryEntryCreateCFProperty(pci, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                return n.uint32Value
            }
            return nil
        }

        return (readID("vendor-id"), readID("device-id"))
    }

    /// Best-effort PCI identity key: vendor-id/device-id/subsystem-id from the parent IOPCIDevice.
    /// Returns nil on Apple Silicon / non-PCI accelerators.
    private func pciIdentityKey(for accelerator: io_registry_entry_t) -> String? {
        guard let pci = parentPCIDeviceEntry(for: accelerator) else { return nil }
        defer { IOObjectRelease(pci) }

        func readID(_ key: String) -> UInt32? {
            if let data = IORegistryEntryCreateCFProperty(pci, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data {
                // Most IORegistry ids are 4-byte little-endian.
                if data.count >= 4 {
                    return data.withUnsafeBytes { $0.load(as: UInt32.self) }
                }
            }
            if let n = IORegistryEntryCreateCFProperty(pci, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                return n.uint32Value
            }
            return nil
        }

        let vid = readID("vendor-id")
        let did = readID("device-id")
        let sid = readID("subsystem-id")

        guard let vid, let did else { return nil }
        if let sid {
            return String(format: "pci:%08X:%08X:%08X", vid, did, sid)
        } else {
            return String(format: "pci:%08X:%08X", vid, did)
        }
    }

    private func parentPCIDevicePath(for accelerator: io_registry_entry_t) -> String? {
        var current: io_registry_entry_t = accelerator
        var ownedCurrent: io_registry_entry_t = 0 // 0 means not owning `current` (the original accelerator)

        defer {
            if ownedCurrent != 0 {
                IOObjectRelease(ownedCurrent)
            }
        }

        while true {
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if kr != KERN_SUCCESS || parent == 0 { return nil }

            // Check IOClass
            if let cls = IORegistryEntryCreateCFProperty(parent, "IOClass" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               cls == "IOPCIDevice" {
                let p = registryPath(for: parent)
                IOObjectRelease(parent)
                return p
            }

            // Move up one level. Release previously-owned entry (but never release the original accelerator).
            if ownedCurrent != 0 {
                IOObjectRelease(ownedCurrent)
            }
            ownedCurrent = parent
            current = parent
        }
    }

    private func detectGPUName(for accelerator: io_registry_entry_t) -> String? {
        // Priority-based GPU naming strategy:
        // 1. Prefer explicit human-readable PCI `model` names when valid
        // 2. Prefer vendor/device-id based OEM-friendly names when we know them
        // 3. For AMD GPUs, build name from ATY family + device fields
        // 4. Try additional readable PCI / accelerator properties
        // 5. Only use driver/plugin-derived names as a last resort

        // Try parent PCI device properties first (discrete GPUs, eGPUs, Intel iGPU parent)
        if let pci = parentPCIDeviceEntry(for: accelerator) {
            defer { IOObjectRelease(pci) }

            let ids = pciVendorDeviceIDs(for: accelerator)

            // Priority 1: explicit model field from the PCI device
            if let model = stringProperty(pci, "model"), !isDriverName(model) {
                let normalized = normalizeGPUName(model)
                if !normalized.isEmpty { return normalized }
            }

            // Priority 2: vendor/device mapping for cleaner OEM names on GPUs whose registry
            // nodes otherwise expose plugin / framebuffer names.
            if let friendly = friendlyGPUName(vendorID: ids.vendor, deviceID: ids.device) {
                return friendly
            }

            // Priority 3: AMD-specific naming from ATY properties.
            if let amdName = buildAMDGPUName(from: pci) {
                return amdName
            }

            // Priority 4: additional readable PCI name fields.
            let pciNameKeys = ["device-name", "name", "IOName", "IONameMatched"]
            for key in pciNameKeys {
                if let value = stringProperty(pci, key), !isDriverName(value) {
                    let normalized = normalizeGPUName(value)
                    if !normalized.isEmpty { return normalized }
                }
            }
        }

        // Accelerator properties (Apple Silicon / some integrated GPUs)
        if let model = stringProperty(accelerator, "model"), !isDriverName(model) {
            let normalized = normalizeGPUName(model)
            if !normalized.isEmpty { return normalized }
        }

        if let amdName = buildAMDGPUName(from: accelerator) {
            return amdName
        }

        let acceleratorNameKeys = ["device-name", "name", "IOName", "IONameMatched"]
        for key in acceleratorNameKeys {
            if let value = stringProperty(accelerator, key), !isDriverName(value) {
                let normalized = normalizeGPUName(value)
                if !normalized.isEmpty { return normalized }
            }
        }

        // Last resort: driver/plugin names (sanitized fallback)
        if let driverName = extractCleanDriverName(from: accelerator) {
            return driverName
        }

        // Final fallback: vendor/device IDs
        let ids = pciVendorDeviceIDs(for: accelerator)
        if let friendly = friendlyGPUName(vendorID: ids.vendor, deviceID: ids.device) {
            return friendly
        }
        if let v = ids.vendor, let d = ids.device {
            return "GPU — \(vendorName(forVendorID: v)) (0x\(String(format: "%08X", d)))"
        }

        return nil
    }

    /// Builds a clean AMD GPU name from ATY family + device fields.
    /// Example: "Radeon Pro" + "580" → "Radeon Pro 580"
    private func buildAMDGPUName(from entry: io_registry_entry_t) -> String? {
        guard let family = stringProperty(entry, "ATY,FamilyName") else { return nil }

        // Optional device number/name
        if let device = stringProperty(entry, "ATY,DeviceName") {
            return "\(family) \(device)".trimmingCharacters(in: .whitespaces)
        }

        // Family alone is valid if specific (e.g., "Radeon Pro Vega II")
        if family.count > 6 { // More than just "Radeon"
            return family
        }

        return nil
    }

    /// Checks if a string looks like a driver/plugin name rather than a real GPU model.
    private func isDriverName(_ name: String) -> Bool {
        let lower = name.lowercased()

        // Common driver/plugin patterns
        let driverPatterns = [
            "driver", "mtldriver", "gldriver", "plugin", "bundle",
            "appleintel", "appleamd", "applem", "com.apple"
        ]

        for pattern in driverPatterns {
            if lower.contains(pattern) {
                return true
            }
        }

        return false
    }

    /// Extracts a cleaner name from driver/plugin strings when used as fallback.
    /// Example: "AppleIntelHD4000GraphicsMTLDriver" → "Intel HD Graphics 4000"
    private func extractCleanDriverName(from entry: io_registry_entry_t) -> String? {
        // Try plugin/bundle names in order
        let keys = ["IOGLBundleName", "MetalPluginName", "CFBundleIdentifier", "IONameMatched"]

        for key in keys {
            guard let raw = stringProperty(entry, key) else { continue }

            // Attempt to parse Intel integrated GPU names
            if let cleaned = parseIntelDriverName(raw) {
                return cleaned
            }

            // If no better parse available, return sanitized raw name
            // (remove common prefixes/suffixes)
            if let sanitized = sanitizeDriverName(raw) {
                return sanitized
            }
        }

        return nil
    }

    /// Parses Intel driver names into cleaner display names.
    /// Example: "AppleIntelHD4000GraphicsMTLDriver" → "Intel HD Graphics 4000"
    private func parseIntelDriverName(_ raw: String) -> String? {
        let lower = raw.lowercased()

        // Pattern: AppleIntelHD4000Graphics...
        if lower.contains("appleintel") && lower.contains("graphics") {
            // Extract the model identifier (e.g., "HD4000", "HD5000", "IrisPlus")
            let pattern = "appleintel([a-z0-9]+)graphics"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
               let modelRange = Range(match.range(at: 1), in: raw) {
                let modelCode = String(raw[modelRange])

                // Parse common Intel GPU naming patterns
                if modelCode.lowercased().hasPrefix("hd") {
                    let number = modelCode.dropFirst(2) // Remove "HD"
                    return "Intel HD Graphics \(number)"
                } else if modelCode.lowercased().hasPrefix("iris") {
                    if modelCode.lowercased().contains("plus") {
                        return "Intel Iris Plus Graphics"
                    }
                    return "Intel Iris Graphics"
                } else if modelCode.lowercased().contains("uhd") {
                    return "Intel UHD Graphics"
                }

                // Generic fallback for Intel
                return "Intel Graphics \(modelCode)"
            }
        }

        return nil
    }

    /// Sanitizes raw driver names by removing common technical prefixes/suffixes.
    private func sanitizeDriverName(_ raw: String) -> String? {
        var cleaned = raw

        // Remove common prefixes
        let prefixes = ["Apple", "com.apple.driver.", "com.apple."]
        for prefix in prefixes {
            if cleaned.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count))
            }
        }

        // Remove common suffixes
        let suffixes = ["MTLDriver", "GLDriver", "Driver", "Graphics", "Plugin"]
        for suffix in suffixes {
            if cleaned.hasSuffix(suffix) {
                cleaned = String(cleaned.dropLast(suffix.count))
            }
        }

        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Only return if still meaningful (more than 3 chars)
        return cleaned.count > 3 ? cleaned : nil
    }

    private func parentPCIDeviceEntry(for accelerator: io_registry_entry_t) -> io_registry_entry_t? {
        var current: io_registry_entry_t = accelerator
        var ownedCurrent: io_registry_entry_t = 0

        while true {
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            if kr != KERN_SUCCESS || parent == 0 {
                if ownedCurrent != 0 { IOObjectRelease(ownedCurrent) }
                return nil
            }

            if let cls = IORegistryEntryCreateCFProperty(parent, "IOClass" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               cls == "IOPCIDevice" {
                // Release any intermediate owned node (not the original accelerator).
                if ownedCurrent != 0 { IOObjectRelease(ownedCurrent) }
                // caller releases `parent`
                return parent
            }

            // Move up; release previously-owned node (never the original accelerator).
            if ownedCurrent != 0 {
                IOObjectRelease(ownedCurrent)
            }
            ownedCurrent = parent
            current = parent
        }
    }

    private func performanceStatistics(for accelerator: io_registry_entry_t) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(
            accelerator,
            "PerformanceStatistics" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any]
    }

    private func readGPUPerformanceStats(for accelerator: io_registry_entry_t) -> (deviceUsage: Float?, rendererUsage: Float?, tilerUsage: Float?) {
        readGPUPerformanceStats(from: performanceStatistics(for: accelerator))
    }

    private func readGPUPerformanceStats(from performanceStatistics: [String: Any]?) -> (deviceUsage: Float?, rendererUsage: Float?, tilerUsage: Float?) {
        func numberToFloat(_ v: Any) -> Float? {
            if let n = v as? NSNumber { return n.floatValue }
            if let i = v as? Int { return Float(i) }
            if let u = v as? UInt64 { return Float(u) }
            return nil
        }

        func normalize(_ raw: Float, forKey key: String) -> Float? {
            guard raw.isFinite else { return nil }

            let isPercentKey = key.contains("%") || key.contains("(%)")
            var v = raw
            if isPercentKey {
                v = v / 100.0
            } else if v > 1.5 {
                v = v / 100.0
            }

            guard v.isFinite else { return nil }
            return min(max(v, 0), 1)
        }

        guard let dict = performanceStatistics else {
            return (nil, nil, nil)
        }

        func readAny(_ keys: [String]) -> Float? {
            var best: Float? = nil
            for key in keys {
                guard let rawAny = dict[key], let raw = numberToFloat(rawAny) else { continue }
                guard let v = normalize(raw, forKey: key) else { continue }
                if best == nil || v > best! { best = v }
            }
            return best
        }

        let deviceUsage = readAny([
            "GPU Activity(%)",
            "GPU Activity",
            "Device Utilization %",
            "Device Utilization % at cur p-state",
            "Device Utilization",
            "GPU Utilization",
            "Accelerator Utilization",
            "Device Unit 0 Utilization %",
            "Device Unit 1 Utilization %",
            "Device Unit 2 Utilization %"
        ])

        let rendererUsage = readAny([
            "Renderer Utilization %",
            "Renderer Utilization"
        ])

        let tilerUsage = readAny([
            "Tiler Utilization %",
            "Tiler Utilization"
        ])

        return (deviceUsage, rendererUsage, tilerUsage)
    }

    private func readVRAMStats(for accelerator: io_registry_entry_t) -> (
        totalMB: Int?,
        usedMB: Int?,
        freeMB: Int?,
        gpuMemoryAllocatedMB: Int?,
        gpuMemoryInUseMB: Int?,
        gpuMemoryDriverInUseMB: Int?
    ) {
        readVRAMStats(for: accelerator, performanceStatistics: performanceStatistics(for: accelerator))
    }

    private func readVRAMStats(
        for accelerator: io_registry_entry_t,
        performanceStatistics: [String: Any]?
    ) -> (
        totalMB: Int?,
        usedMB: Int?,
        freeMB: Int?,
        gpuMemoryAllocatedMB: Int?,
        gpuMemoryInUseMB: Int?,
        gpuMemoryDriverInUseMB: Int?
    ) {
        func numToInt64(_ any: Any) -> Int64? {
            if let n = any as? NSNumber { return n.int64Value }
            if let i = any as? Int64 { return i }
            if let i = any as? Int { return Int64(i) }
            if let u = any as? UInt64 { return Int64(u) }
            if let data = any as? Data {
                let bytes = [UInt8](data)
                guard !bytes.isEmpty else { return nil }
                let maxReasonableBytes = UInt64(2_199_023_255_552)
                let bigEndian = bytes.reduce(UInt64(0)) { partial, byte in
                    (partial << 8) | UInt64(byte)
                }
                let littleEndian = bytes.enumerated().reduce(UInt64(0)) { partial, pair in
                    partial | (UInt64(pair.element) << (pair.offset * 8))
                }
                let candidates = [bigEndian, littleEndian].filter { value in
                    value > 0 && value < maxReasonableBytes
                }
                return candidates.max().map(Int64.init)
            }
            return nil
        }

        func registryProperty(_ entry: io_registry_entry_t, key: String) -> Any? {
            IORegistryEntryCreateCFProperty(
                entry,
                key as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue()
        }

        func readRegistryValueMB(
            entry: io_registry_entry_t,
            megabyteKeys: [String],
            byteKeys: [String]
        ) -> Int? {
            for key in megabyteKeys {
                if let value = registryProperty(entry, key: key),
                   let megabytes = numToInt64(value),
                   megabytes > 0 {
                    return Int(megabytes)
                }
            }

            for key in byteKeys {
                if let value = registryProperty(entry, key: key),
                   let bytes = numToInt64(value),
                   bytes > 0 {
                    return Int(bytes / 1_048_576)
                }
            }

            return nil
        }

        var usedMB: Int? = nil
        var freeMB: Int? = nil
        var totalMB: Int? = nil
        var gpuMemoryAllocatedMB: Int? = nil
        var gpuMemoryInUseMB: Int? = nil
        var gpuMemoryDriverInUseMB: Int? = nil

        // PerformanceStatistics may include vidmem counters.
        if let stats = performanceStatistics {
            if let usedAny = stats["inUseVidMemoryBytes"], let usedBytes = numToInt64(usedAny) {
                usedMB = Int(usedBytes / 1_048_576)
            }
            if let freeAny = stats["vramFreeBytes"], let freeBytes = numToInt64(freeAny) {
                freeMB = Int(freeBytes / 1_048_576)
            }
            if let allocAny = stats["Alloc system memory"], let allocBytes = numToInt64(allocAny) {
                gpuMemoryAllocatedMB = Int(allocBytes / 1_048_576)
            }
            if let inUseAny = stats["In use system memory"], let inUseBytes = numToInt64(inUseAny) {
                gpuMemoryInUseMB = Int(inUseBytes / 1_048_576)
            }
            if let driverAny = stats["In use system memory (driver)"], let driverBytes = numToInt64(driverAny) {
                gpuMemoryDriverInUseMB = Int(driverBytes / 1_048_576)
            }
        }

        let totalMegabyteKeys = [
            "VRAM,totalMB"
        ]
        let totalByteKeys = [
            "VRAM,totalsize",
            "VRAM,totalSize",
            "VRAM,totalbytes",
            "VRAM,totalBytes",
            "VRAM,memsize",
            "ATY,VRAM,totalsize",
            "ATY,VRAM,totalSize",
            "ATY,VRAM,memsize"
        ]

        totalMB = readRegistryValueMB(
            entry: accelerator,
            megabyteKeys: totalMegabyteKeys,
            byteKeys: totalByteKeys
        )

        // If not on accelerator, try parent PCI device.
        if totalMB == nil, let pci = parentPCIDeviceEntry(for: accelerator) {
            defer { IOObjectRelease(pci) }
            totalMB = readRegistryValueMB(
                entry: pci,
                megabyteKeys: totalMegabyteKeys,
                byteKeys: totalByteKeys
            )
        }

        return (totalMB, usedMB, freeMB, gpuMemoryAllocatedMB, gpuMemoryInUseMB, gpuMemoryDriverInUseMB)
    }

    /// Reads GPU core count from IORegistry.
    /// - Prefers `gpu-core-count` (static Apple Silicon GPU core count source)
    /// - Falls back to `GPUConfigurationVariable.num_cores` if available
    private func readGPUCoreCount(for accelerator: io_registry_entry_t) -> Int? {
        func numberToInt(_ any: Any) -> Int? {
            if let n = any as? NSNumber { return n.intValue }
            if let i = any as? Int { return i }
            if let i = any as? Int64 { return Int(i) }
            if let u = any as? UInt64 { return Int(u) }
            return nil
        }

        // Try gpu-core-count first (preferred for Apple Silicon)
        if let coreCountAny = IORegistryEntryCreateCFProperty(
            accelerator,
            "gpu-core-count" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue(),
           let count = numberToInt(coreCountAny), count > 0 {
            return count
        }

        // Fallback: GPUConfigurationVariable.num_cores
        if let configVar = IORegistryEntryCreateCFProperty(
            accelerator,
            "GPUConfigurationVariable" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any],
           let numCoresAny = configVar["num_cores"],
           let count = numberToInt(numCoresAny), count > 0 {
            return count
        }

        return nil
    }

#if DEBUG && !HARDWARE_JOBBLESS_EMBEDS_CORE
    /// Prints a sorted list of keys seen in IOAccelerator PerformanceStatistics to the Xcode console and AppDebugConsole.
    public func debugDumpPerformanceStatisticsKeys() {
        func log(_ message: String) {
            Task { @MainActor in
                AppDebugConsole.log(message, category: "GPU")
            }
        }
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(Self.ioMainPort, matching, &iterator)
        guard kr == KERN_SUCCESS else {
            log("[GPUStatsSampler] IOServiceGetMatchingServices failed: \(kr)")
            return
        }
        defer { IOObjectRelease(iterator) }

        var allKeys = Set<String>()
        var deviceCount = 0

        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            deviceCount += 1

            if let dict = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any] {
                for k in dict.keys { allKeys.insert(k) }
            }
        }

        let sorted = allKeys.sorted()
        log("[GPUStatsSampler] PerformanceStatistics keys (\(sorted.count)) across \(deviceCount) IOAccelerator services:")
        for k in sorted {
            log("  • \(k)")
        }
        log("")
    }

    /// Best-effort DEBUG probe for temperature / power / wattage related keys in IORegistry.
    /// This is discovery tooling only; keys and meanings may vary across Macs / macOS versions.
    public func debugDumpTemperatureAndPowerKeys() {
        func log(_ message: String) {
            Task { @MainActor in
                AppDebugConsole.log(message, category: "POWER")
            }
        }
        let acceleratorClasses = [
            "IOAccelerator",
            "IOGPU",
            "AGXAccelerator"
        ]

        let interestingFragments = [
            "temp", "temperature", "thermal", "therm",
            "power", "watt", "watts", "energy",
            "voltage", "volt", "current", "amp", "amps",
            "sensor", "fan",
            "freq", "frequency", "clock", "hz",
            "package", "pstate", "state",
            "util", "utilization", "activity", "busy",
            "renderer", "render", "tiler", "tile",
            "gpu", "device", "mem", "memory", "alloc", "driver"
        ]

        func matchesInterestingKey(_ key: String) -> Bool {
            let lower = key.lowercased()
            return interestingFragments.contains { lower.contains($0) }
        }

        func formatInterestingValue(_ value: Any) -> String {
            if let n = value as? NSNumber {
                return n.stringValue
            }
            if let s = value as? String {
                return s
            }
            if let data = value as? Data {
                if data.isEmpty { return "<empty data>" }
                if let str = self.stringFromIORegData(data) {
                    return "\"\(str)\""
                }
                let prefix = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                return "Data[\(data.count)] \(prefix)"
            }
            if let arr = value as? [Any] {
                return "Array(count: \(arr.count))"
            }
            if let dict = value as? [String: Any] {
                return "Dictionary(count: \(dict.count))"
            }
            return String(describing: value)
        }

        func extractInterestingEntries(from dict: [String: Any], prefix: String = "") -> [(String, String)] {
            var out: [(String, String)] = []
            for key in dict.keys.sorted() {
                let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
                let value = dict[key]!

                if let sub = value as? [String: Any] {
                    if matchesInterestingKey(key) || matchesInterestingKey(fullKey) {
                        out.append((fullKey, "Dictionary(count: \(sub.count))"))
                    }
                    out.append(contentsOf: extractInterestingEntries(from: sub, prefix: fullKey))
                } else if matchesInterestingKey(key) || matchesInterestingKey(fullKey) {
                    out.append((fullKey, formatInterestingValue(value)))
                }
            }
            return out
        }

        func printInterestingEntries(_ entries: [(String, String)], indent: String = "    ") {
            if entries.isEmpty {
                log("\(indent)<no matching keys>")
                return
            }
            for (key, value) in entries.sorted(by: { $0.0 < $1.0 }) {
                log("\(indent)• \(key): \(value)")
            }
        }

        func dumpProperties(forClass className: String) {
            let matching = IOServiceMatching(className)
            var iterator: io_iterator_t = 0
            let kr = IOServiceGetMatchingServices(Self.ioMainPort, matching, &iterator)
            guard kr == KERN_SUCCESS else {
                log("[GPUStatsSampler] \(className): IOServiceGetMatchingServices failed: \(kr)")
                return
            }
            defer { IOObjectRelease(iterator) }

            var count = 0
            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 { break }
                defer { IOObjectRelease(service) }
                count += 1

                let name = detectGPUName(for: service) ?? normalizeGPUName(stringProperty(service, "IOClass") ?? className)
                let path = registryPath(for: service) ?? "<no path>"
                log("[GPUStatsSampler] \(className) service #\(count): \(name)")
                log("  path: \(path)")

                if let perf = IORegistryEntryCreateCFProperty(
                    service,
                    "PerformanceStatistics" as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue() as? [String: Any] {
                    log("  PerformanceStatistics matching entries:")
                    printInterestingEntries(extractInterestingEntries(from: perf))

                    let deviceKeys = [
                        "GPU Activity(%)",
                        "GPU Activity",
                        "Device Utilization %",
                        "Device Utilization % at cur p-state",
                        "Device Utilization",
                        "GPU Utilization",
                        "Accelerator Utilization",
                        "Device Unit 0 Utilization %",
                        "Device Unit 1 Utilization %",
                        "Device Unit 2 Utilization %"
                    ]
                    let rendererKeys = [
                        "Renderer Utilization %",
                        "Renderer Utilization"
                    ]
                    let tilerKeys = [
                        "Tiler Utilization %",
                        "Tiler Utilization"
                    ]

                    log("  PerformanceStatistics spotlight:")
                    for key in deviceKeys {
                        if let value = perf[key] {
                            log("    [device] \(key): \(formatInterestingValue(value))")
                        }
                    }
                    for key in rendererKeys {
                        if let value = perf[key] {
                            log("    [renderer] \(key): \(formatInterestingValue(value))")
                        }
                    }
                    for key in tilerKeys {
                        if let value = perf[key] {
                            log("    [tiler] \(key): \(formatInterestingValue(value))")
                        }
                    }
                }

                var servicePropsRef: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &servicePropsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let serviceProps = servicePropsRef?.takeRetainedValue() as? [String: Any] {
                    log("  Matching top-level properties:")
                    printInterestingEntries(extractInterestingEntries(from: serviceProps))
                }

                if let pci = parentPCIDeviceEntry(for: service) {
                    defer { IOObjectRelease(pci) }
                    var pciPropsRef: Unmanaged<CFMutableDictionary>?
                    if IORegistryEntryCreateCFProperties(pci, &pciPropsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                       let pciProps = pciPropsRef?.takeRetainedValue() as? [String: Any] {
                        log("  Parent PCI matching properties:")
                        printInterestingEntries(extractInterestingEntries(from: pciProps))
                    }
                }
            }

            log("[GPUStatsSampler] \(className): inspected \(count) service(s)")
        }

        let model = CPUStatsSampler.sysctlString("hw.model") ?? "Unknown Model"
        let thermal = ProcessInfo.processInfo.thermalState
        log("[GPUStatsSampler] Temp/Power probe — model: \(model)")
        log("[GPUStatsSampler] Thermal state: \(thermal.rawValue)")

        log("[GPUStatsSampler] Published GPU snapshot(s):")
        if self.gpus.isEmpty {
            log("  <no published GPUs>")
        } else {
            for gpu in self.gpus {
                let usageText = gpu.usage.map { String(format: "%.3f", $0) } ?? "nil"
                let rendererText = gpu.rendererUsage.map { String(format: "%.3f", $0) } ?? "nil"
                let tilerText = gpu.tilerUsage.map { String(format: "%.3f", $0) } ?? "nil"
                log("  • \(gpu.name) [\(gpu.id)]")
                log("    usage=\(usageText) renderer=\(rendererText) tiler=\(tilerText)")
                log("    vramTotalMB=\(String(describing: gpu.vramTotalMB)) vramUsedMB=\(String(describing: gpu.vramUsedMB)) vramFreeMB=\(String(describing: gpu.vramFreeMB))")
                log("    allocMB=\(String(describing: gpu.gpuMemoryAllocatedMB)) inUseMB=\(String(describing: gpu.gpuMemoryInUseMB)) driverMB=\(String(describing: gpu.gpuMemoryDriverInUseMB))")
                log("    tempC=\(String(describing: gpu.temperatureC)) fanRPM=\(String(describing: gpu.fanRPM)) coreMHz=\(String(describing: gpu.coreClockMHz)) memMHz=\(String(describing: gpu.memoryClockMHz)) powerW=\(String(describing: gpu.totalPowerW))")
            }
        }
        log("")

        for className in acceleratorClasses {
            dumpProperties(forClass: className)
        }

        log("[GPUStatsSampler] Temp/Power probe complete.")
    }
#endif
    #endif
}

extension GPUStatsSampler {
    public var liveSnapshot: GPUStatsSamplerLiveSnapshot {
        GPUStatsSamplerLiveSnapshot(
            gpus: gpus,
            usageSeriesByGPU: usageSeriesByGPU,
            rendererSeriesByGPU: rendererSeriesByGPU,
            tilerSeriesByGPU: tilerSeriesByGPU,
            memoryUsageSeriesByGPU: memoryUsageSeriesByGPU,
            latestDeviceSnapshots: latestDeviceSnapshots,
            gpuDisplayName: gpuDisplayName
        )
    }

    public func applyRemoteSnapshot(_ snapshot: GPUStatsSamplerLiveSnapshot) {
        gpus = snapshot.gpus
        usageSeriesByGPU = snapshot.usageSeriesByGPU
        rendererSeriesByGPU = snapshot.rendererSeriesByGPU
        tilerSeriesByGPU = snapshot.tilerSeriesByGPU
        memoryUsageSeriesByGPU = snapshot.memoryUsageSeriesByGPU
        latestDeviceSnapshots = snapshot.latestDeviceSnapshots
        gpuDisplayName = snapshot.gpuDisplayName
    }
}
