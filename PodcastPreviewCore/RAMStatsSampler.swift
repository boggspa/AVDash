import Foundation
import Combine
import Darwin
#if canImport(libproc)
import libproc
#else
// libproc symbols are available via Darwin on many SDKs; keep explicit import only if it compiles.
#endif

/// Sandbox-safe RAM sampler using host_statistics64.
public final class RAMStatsSampler: ObservableObject {
    public struct MemorySnapshot: Codable, Equatable, Sendable {
        public var usedBytes: UInt64
        public var totalBytes: UInt64
        public var freeBytes: UInt64
        public var cachedBytes: UInt64
        public var compressedBytes: UInt64
        public var wiredBytes: UInt64
        public var appMemoryBytes: UInt64?
        public var swapUsedBytes: UInt64?
        public var swapTotalBytes: UInt64?
        public var purgeableBytes: UInt64?
        public var reusableBytes: UInt64?
        public var pressureLevel: String
        public var pressureValue: Double

        public init(
            usedBytes: UInt64,
            totalBytes: UInt64,
            freeBytes: UInt64,
            cachedBytes: UInt64,
            compressedBytes: UInt64,
            wiredBytes: UInt64,
            appMemoryBytes: UInt64? = nil,
            swapUsedBytes: UInt64? = nil,
            swapTotalBytes: UInt64? = nil,
            purgeableBytes: UInt64? = nil,
            reusableBytes: UInt64? = nil,
            pressureLevel: String,
            pressureValue: Double
        ) {
            self.usedBytes = usedBytes
            self.totalBytes = totalBytes
            self.freeBytes = freeBytes
            self.cachedBytes = cachedBytes
            self.compressedBytes = compressedBytes
            self.wiredBytes = wiredBytes
            self.appMemoryBytes = appMemoryBytes
            self.swapUsedBytes = swapUsedBytes
            self.swapTotalBytes = swapTotalBytes
            self.purgeableBytes = purgeableBytes
            self.reusableBytes = reusableBytes
            self.pressureLevel = pressureLevel
            self.pressureValue = pressureValue
        }

        public var ramUsageRatio: Float {
            guard totalBytes > 0 else { return 0 }
            return Float(Double(usedBytes) / Double(totalBytes))
        }

        public var ramLabel: String {
            String(format: "%.1f / %.1f GB", Self.bytesToGigabytes(usedBytes), Self.bytesToGigabytes(totalBytes))
        }

        public var cachedFilesLabel: String {
            String(format: "Cached %.1f GB", Self.bytesToGigabytes(cachedBytes))
        }

        public var compressedLabel: String {
            String(format: "Compressed %.1f GB", Self.bytesToGigabytes(compressedBytes))
        }

        public var wiredLabel: String {
            String(format: "Wired %.1f GB", Self.bytesToGigabytes(wiredBytes))
        }

        public var appMemoryLabel: String {
            guard let appMemoryBytes else { return "Apps —" }
            return String(format: "Apps %.1f GB", Self.bytesToGigabytes(appMemoryBytes))
        }

        public var swapUsedRatio: Float {
            guard let swapUsedBytes, let swapTotalBytes, swapTotalBytes > 0 else { return 0 }
            return Float(Double(swapUsedBytes) / Double(swapTotalBytes))
        }

        public var swapUsedGB: Double? {
            swapUsedBytes.map(Self.bytesToGigabytes)
        }

        public var swapTotalGB: Double? {
            swapTotalBytes.map(Self.bytesToGigabytes)
        }

        public var swapLabel: String {
            guard let swapTotalBytes else { return "—" }
            if swapTotalBytes == 0 { return "Inactive" }
            guard let swapUsedGB, let swapTotalGB else { return "—" }
            return String(format: "%.1f / %.1f GB", swapUsedGB, swapTotalGB)
        }

        public var pressureLabel: String {
            pressureLevel
        }

        public var pressureSubtext: String {
            [
                purgeableBytes.map { String(format: "Purgeable %.1f GB", Self.bytesToGigabytes($0)) } ?? "Purgeable —",
                reusableBytes.map { String(format: "Reusable %.1f GB", Self.bytesToGigabytes($0)) } ?? "Reusable —"
            ].joined(separator: "  ·  ")
        }

        private static func bytesToGigabytes(_ bytes: UInt64) -> Double {
            Double(bytes) / 1_073_741_824.0
        }
    }

    @Published public var ramUsage: Float? = nil // used/total ratio 0..1
    @Published public var usageHistory: [Float] = []
    @Published public var ramLabel: String? = nil
    @Published public var swapLabel: String = "—"     // e.g. "0.2 / 2.0 GB"
    @Published public var swapUsedRatio: Float = 0    // 0..1
    @Published public var swapUsageHistory: [Float] = []
    @Published public var swapUsedGB: Double? = nil
    @Published public var swapTotalGB: Double? = nil
    @Published public var cachedFilesLabel: String = "—"
    @Published public var compressedLabel: String = "—"
    @Published public var wiredLabel: String = "—"
    @Published public var appMemoryLabel: String = "—"

    // Estimated memory pressure (heuristic; not an OS-provided enum)
    @Published public var pressureLabel: String = "—"   // Low/Moderate/High/Critical
    @Published public var pressureSubtext: String = "Purgeable —  ·  Reusable —"
    @Published public var pressureValue: Float = 0      // 0..1
    @Published public var pressureHistory: [Float] = []
    @Published public private(set) var usageSeries = RAMStatsSampler.makeSeries(for: .ramUsageRatio)
    @Published public private(set) var swapUsageSeries = RAMStatsSampler.makeSeries(for: .swapUsageRatio)
    @Published public private(set) var pressureSeries = RAMStatsSampler.makeSeries(for: .memoryPressureRatio)
    @Published public private(set) var latestMemorySnapshot: MemorySnapshot? = nil
    @Published public private(set) var latestSnapshot: HardwareSnapshot? = nil

    #if os(macOS)
    private var timer: DispatchSourceTimer?
    private var usageSeriesBuffer = RAMStatsSampler.makeSeries(for: .ramUsageRatio)
    private var swapUsageSeriesBuffer = RAMStatsSampler.makeSeries(for: .swapUsageRatio)
    private var pressureSeriesBuffer = RAMStatsSampler.makeSeries(for: .memoryPressureRatio)
    #endif
    private var historyLength: Int { HardwareCollectionSettings.liveSeriesCapacity() }
    private let targetProcessResolver: @Sendable () -> Set<Int32>

    public init(
        targetProcessResolver: @escaping @Sendable () -> Set<Int32> = {
            Set([Int32(ProcessInfo.processInfo.processIdentifier)])
        }
    ) {
        self.targetProcessResolver = targetProcessResolver
    }

    public func initialize() {
        #if os(macOS)
        stop()
        usageSeriesBuffer = Self.makeSeries(for: .ramUsageRatio)
        swapUsageSeriesBuffer = Self.makeSeries(for: .swapUsageRatio)
        pressureSeriesBuffer = Self.makeSeries(for: .memoryPressureRatio)
        DispatchQueue.main.async {
            self.usageHistory = []
            self.swapUsageHistory = []
            self.pressureHistory = []
            self.ramUsage = nil
            self.ramLabel = nil
            self.swapLabel = "—"
            self.swapUsedRatio = 0
            self.swapUsedGB = nil
            self.swapTotalGB = nil
            self.cachedFilesLabel = "—"
            self.compressedLabel = "—"
            self.wiredLabel = "—"
            self.appMemoryLabel = "—"
            self.pressureLabel = "—"
            self.pressureSubtext = "Purgeable —  ·  Reusable —"
            self.pressureValue = 0
            self.usageSeries = Self.makeSeries(for: .ramUsageRatio)
            self.swapUsageSeries = Self.makeSeries(for: .swapUsageRatio)
            self.pressureSeries = Self.makeSeries(for: .memoryPressureRatio)
            self.latestMemorySnapshot = nil
            self.latestSnapshot = nil
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

    private static func makeSeries(for key: HardwareMetricKey) -> MetricSeries {
        MetricSeries(key: key, unit: .ratio)
    }

    #if os(macOS)
    func sample() {
        let timestamp = Date()
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let kerr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard kerr == KERN_SUCCESS else { return }

        let usedPages = UInt64(stats.active_count)
            + UInt64(stats.inactive_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)

        let usedBytes = usedPages * UInt64(pageSize)
        let totalBytes = ProcessInfo.processInfo.physicalMemory

        let ratio: Float = totalBytes > 0 ? Float(Double(usedBytes) / Double(totalBytes)) : 0

        let freeBytes = UInt64(stats.free_count) * UInt64(pageSize)
        let cachedBytes = UInt64(stats.inactive_count) * UInt64(pageSize)
        let compressedBytes = UInt64(stats.compressor_page_count) * UInt64(pageSize)
        let wiredBytes = UInt64(stats.wire_count) * UInt64(pageSize)
        let appMemoryBytes = Self.readAppMemoryBytes(for: targetProcessResolver())

        let swap = Self.readSwapUsage()

        // --- Estimated pressure (heuristic + kernel hints)
        let totalPages = UInt64(stats.active_count)
            + UInt64(stats.inactive_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.free_count)
            + UInt64(stats.compressor_page_count)

        let kernelSignals = Self.readKernelMemoryPressureSignals()

        let purgeableBytes = kernelSignals.purgeableBytes ?? 0
        let reusableBytes = kernelSignals.reusableBytes ?? 0

        let availableBytes = freeBytes + cachedBytes
        let reclaimableBytes = purgeableBytes + reusableBytes

        let availableRatio: Float = totalBytes > 0
            ? Float(Double(availableBytes) / Double(totalBytes))
            : 0

        // Count purgeable/reusable memory as a partial headroom boost rather than fully free memory.
        // This avoids overstating available RAM while still reflecting reclaimable memory.
        let reclaimableRatio: Float = totalBytes > 0
            ? Float(Double(reclaimableBytes) / Double(totalBytes))
            : 0
        let adjustedAvailableRatio = min(max(availableRatio + (reclaimableRatio * 0.5), 0), 1)

        let compressedRatio: Float = totalPages > 0 ? Float(Double(stats.compressor_page_count) / Double(totalPages)) : 0
        let wiredRatio: Float = totalPages > 0 ? Float(Double(stats.wire_count) / Double(totalPages)) : 0

        let pressure = Self.estimatePressure(
            availableRatio: adjustedAvailableRatio,
            compressedRatio: compressedRatio,
            wiredRatio: wiredRatio,
            swapUsedRatio: swap.usedRatio,
            vmPressure: kernelSignals.vmPressure,
            memorystatusLevel: kernelSignals.memorystatusLevel,
            vmPressureTransitionThreshold: kernelSignals.vmPressureTransitionThreshold
        )

        usageSeriesBuffer.append(Double(min(max(ratio, 0), 1)), at: timestamp, capacity: historyLength)
        let observedSwapRatio = swap.totalBytes != nil ? Double(swap.usedRatio) : nil
        swapUsageSeriesBuffer.append(observedSwapRatio, at: timestamp, capacity: historyLength)
        pressureSeriesBuffer.append(Double(pressure.value), at: timestamp, capacity: historyLength)

        let usageSeries = usageSeriesBuffer
        let swapSeries = swapUsageSeriesBuffer
        let pressureSeries = pressureSeriesBuffer
        let memorySnapshot = MemorySnapshot(
            usedBytes: usedBytes,
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            cachedBytes: cachedBytes,
            compressedBytes: compressedBytes,
            wiredBytes: wiredBytes,
            appMemoryBytes: appMemoryBytes,
            swapUsedBytes: swap.usedBytes,
            swapTotalBytes: swap.totalBytes,
            purgeableBytes: kernelSignals.purgeableBytes,
            reusableBytes: kernelSignals.reusableBytes,
            pressureLevel: pressure.label,
            pressureValue: Double(pressure.value)
        )

        var snapshot = HardwareSnapshot(timestamp: timestamp)
        snapshot.setMetric(.ramUsageRatio, value: Double(min(max(ratio, 0), 1)))
        snapshot.setMetric(.ramUsedGB, value: Double(usedBytes) / 1_073_741_824.0)
        snapshot.setMetric(.ramTotalGB, value: Double(totalBytes) / 1_073_741_824.0)
        snapshot.setMetric(.cachedMemoryGB, value: Double(cachedBytes) / 1_073_741_824.0)
        snapshot.setMetric(.compressedMemoryGB, value: Double(compressedBytes) / 1_073_741_824.0)
        snapshot.setMetric(.wiredMemoryGB, value: Double(wiredBytes) / 1_073_741_824.0)
        if let swapUsedBytes = swap.usedBytes {
            snapshot.setMetric(.swapUsedGB, value: Double(swapUsedBytes) / 1_073_741_824.0)
        }
        if let swapTotalBytes = swap.totalBytes {
            snapshot.setMetric(.swapTotalGB, value: Double(swapTotalBytes) / 1_073_741_824.0)
            snapshot.setMetric(.swapUsageRatio, value: Double(swap.usedRatio))
        }
        snapshot.setMetric(.memoryPressureRatio, value: Double(pressure.value))
        snapshot.setDimension(.memoryPressureLevel, value: pressure.label)

        DispatchQueue.main.async {
            self.latestMemorySnapshot = memorySnapshot
            self.latestSnapshot = snapshot
            self.usageSeries = usageSeries
            self.swapUsageSeries = swapSeries
            self.pressureSeries = pressureSeries
            self.ramUsage = Float(usageSeries.latestObservedValue ?? Double(min(max(ratio, 0), 1)))
            self.ramLabel = memorySnapshot.ramLabel
            self.cachedFilesLabel = memorySnapshot.cachedFilesLabel
            self.compressedLabel = memorySnapshot.compressedLabel
            self.wiredLabel = memorySnapshot.wiredLabel
            self.appMemoryLabel = memorySnapshot.appMemoryLabel
            self.swapLabel = memorySnapshot.swapLabel
            self.swapUsedRatio = memorySnapshot.swapUsedRatio
            self.swapUsedGB = memorySnapshot.swapUsedGB
            self.swapTotalGB = memorySnapshot.swapTotalGB
            self.usageHistory = usageSeries.values().map(Float.init)
            self.swapUsageHistory = swapSeries.values().map(Float.init)
            self.pressureLabel = memorySnapshot.pressureLabel
            self.pressureSubtext = memorySnapshot.pressureSubtext
            self.pressureValue = Float(pressureSeries.latestObservedValue ?? Double(pressure.value))
            self.pressureHistory = pressureSeries.values().map(Float.init)
        }
    }

    private static func readAppMemoryBytes(for pids: Set<Int32>) -> UInt64? {
        let residentSizes = pids.compactMap { pid -> UInt64? in
            guard pid > 0 else { return nil }

            var taskInfo = proc_taskinfo()
            let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskInfoSize)
            guard result == taskInfoSize else { return nil }

            return UInt64(taskInfo.pti_resident_size)
        }

        guard !residentSizes.isEmpty else { return nil }
        return residentSizes.reduce(0, &+)
    }

    private struct PressureEstimate {
        var label: String
        var value: Float // 0..1
    }

    private struct KernelMemoryPressureSignals {
        var vmPressure: Int?
        var memorystatusLevel: Int?
        var vmPressureTransitionThreshold: Int?
        var purgeableBytes: UInt64?
        var reusableBytes: UInt64?
    }

    /// Heuristic pressure estimate (best-effort). This is NOT the Activity Monitor pressure value.
    ///
    /// The estimate combines:
    /// - immediately available + partially reclaimable RAM
    /// - compressed memory ratio
    /// - wired memory ratio
    /// - swap usage
    /// - kernel pressure hints when available (`vm.memory_pressure`, `kern.memorystatus_level`)
    private static func estimatePressure(
        availableRatio: Float,
        compressedRatio: Float,
        wiredRatio: Float,
        swapUsedRatio: Float,
        vmPressure: Int?,
        memorystatusLevel: Int?,
        vmPressureTransitionThreshold: Int?
    ) -> PressureEstimate {
        let a = min(max(availableRatio, 0), 1)
        let c = min(max(compressedRatio, 0), 1)
        let w = min(max(wiredRatio, 0), 1)
        let s = min(max(swapUsedRatio, 0), 1)

        // Base heuristic:
        // - low available/reclaimable memory drives pressure strongly
        // - compression indicates pressure building
        // - wired indicates less reclaimable memory
        // - swap usage is a strong late-stage pressure indicator
        let heuristic = min(max((1 - a) * 0.55 + c * 0.20 + w * 0.10 + s * 0.15, 0), 1)

        // `vm.memory_pressure` appears to be a low-is-better pressure scalar.
        // Normalize using the kernel transition threshold when available.
        let kernelPressureNormalized: Float? = {
            guard let vmPressure else { return nil }
            let threshold = max(1, vmPressureTransitionThreshold ?? 30)
            return min(max(Float(vmPressure) / Float(threshold), 0), 1)
        }()

        // `kern.memorystatus_level` appears to be a high-is-better availability score.
        // Invert it so higher means more pressure.
        let memorystatusPressureNormalized: Float? = {
            guard let memorystatusLevel else { return nil }
            let clamped = min(max(Float(memorystatusLevel), 0), 100)
            return 1 - (clamped / 100)
        }()

        var combined = heuristic

        // Let kernel-reported pressure raise the estimate when it becomes non-zero,
        // without allowing a zero reading to completely suppress the heuristic.
        if let kernelPressureNormalized, kernelPressureNormalized > 0 {
            combined = max(combined, kernelPressureNormalized)
        }

        // Blend in memorystatus as a softer secondary signal.
        if let memorystatusPressureNormalized {
            combined = (combined * 0.85) + (memorystatusPressureNormalized * 0.15)
        }

        combined = min(max(combined, 0), 1)

        switch combined {
        case ..<0.20:
            return PressureEstimate(label: "Low", value: combined)
        case 0.20..<0.45:
            return PressureEstimate(label: "Moderate", value: combined)
        case 0.45..<0.75:
            return PressureEstimate(label: "High", value: combined)
        default:
            return PressureEstimate(label: "Critical", value: combined)
        }
    }

    private static func readKernelMemoryPressureSignals() -> KernelMemoryPressureSignals {
        func sysctlInt(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            let rc = sysctlbyname(name, &value, &size, nil, 0)
            guard rc == 0, size == MemoryLayout<Int32>.size else { return nil }
            return Int(value)
        }

        func sysctlUInt64(_ name: String) -> UInt64? {
            var value64: UInt64 = 0
            var size64 = MemoryLayout<UInt64>.size
            if sysctlbyname(name, &value64, &size64, nil, 0) == 0, size64 == MemoryLayout<UInt64>.size {
                return value64
            }

            var value32: UInt32 = 0
            var size32 = MemoryLayout<UInt32>.size
            if sysctlbyname(name, &value32, &size32, nil, 0) == 0, size32 == MemoryLayout<UInt32>.size {
                return UInt64(value32)
            }

            var signed32: Int32 = 0
            var sizeSigned32 = MemoryLayout<Int32>.size
            if sysctlbyname(name, &signed32, &sizeSigned32, nil, 0) == 0, sizeSigned32 == MemoryLayout<Int32>.size, signed32 >= 0 {
                return UInt64(signed32)
            }

            var signed64: Int64 = 0
            var sizeSigned64 = MemoryLayout<Int64>.size
            if sysctlbyname(name, &signed64, &sizeSigned64, nil, 0) == 0, sizeSigned64 == MemoryLayout<Int64>.size, signed64 >= 0 {
                return UInt64(signed64)
            }

            return nil
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let purgeablePages = sysctlUInt64("vm.page_purgeable_count")
        let reusablePages = sysctlUInt64("vm.page_reusable_count")

        let purgeableBytes = purgeablePages.map { $0 * pageSize }
        let reusableBytes = reusablePages.map { $0 * pageSize }

        return KernelMemoryPressureSignals(
            vmPressure: sysctlInt("vm.memory_pressure"),
            memorystatusLevel: sysctlInt("kern.memorystatus_level"),
            vmPressureTransitionThreshold: sysctlInt("kern.vm_pressure_level_transition_threshold"),
            purgeableBytes: purgeableBytes,
            reusableBytes: reusableBytes
        )
    }

    private struct SwapInfo {
        var totalBytes: UInt64?
        var usedBytes: UInt64?
        var usedRatio: Float
    }

    private static func readSwapUsage() -> SwapInfo {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride

        let rc = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        // sysctl failure → no data at all (nil keeps the graph sparse rather than flat-zero)
        guard rc == 0, size == MemoryLayout<xsw_usage>.stride else {
            return SwapInfo(totalBytes: nil, usedBytes: nil, usedRatio: 0)
        }
        // xsu_total == 0 means macOS hasn't allocated any swap files yet (common on
        // well-provisioned machines). Record 0/0 so the graph shows a flat line and
        // the label can read "Inactive" rather than "—".
        guard usage.xsu_total > 0 else {
            return SwapInfo(totalBytes: 0, usedBytes: 0, usedRatio: 0)
        }
        let ratio: Float = Float(Double(usage.xsu_used) / Double(usage.xsu_total))

        return SwapInfo(
            totalBytes: usage.xsu_total,
            usedBytes: usage.xsu_used,
            usedRatio: min(max(ratio, 0), 1)
        )
    }
    #endif
}

extension RAMStatsSampler {
    public var liveSnapshot: RAMStatsSamplerLiveSnapshot {
        RAMStatsSamplerLiveSnapshot(
            ramUsage: ramUsage,
            usageHistory: usageHistory,
            ramLabel: ramLabel,
            swapLabel: swapLabel,
            swapUsedRatio: swapUsedRatio,
            swapUsageHistory: swapUsageHistory,
            swapUsedGB: swapUsedGB,
            swapTotalGB: swapTotalGB,
            cachedFilesLabel: cachedFilesLabel,
            compressedLabel: compressedLabel,
            wiredLabel: wiredLabel,
            appMemoryLabel: appMemoryLabel,
            pressureLabel: pressureLabel,
            pressureSubtext: pressureSubtext,
            pressureValue: pressureValue,
            pressureHistory: pressureHistory,
            usageSeries: usageSeries,
            swapUsageSeries: swapUsageSeries,
            pressureSeries: pressureSeries,
            latestMemorySnapshot: latestMemorySnapshot,
            latestSnapshot: latestSnapshot
        )
    }

    public func applyRemoteSnapshot(_ snapshot: RAMStatsSamplerLiveSnapshot) {
        ramUsage = snapshot.ramUsage
        usageHistory = snapshot.usageHistory
        ramLabel = snapshot.ramLabel
        swapLabel = snapshot.swapLabel
        swapUsedRatio = snapshot.swapUsedRatio
        swapUsageHistory = snapshot.swapUsageHistory
        swapUsedGB = snapshot.swapUsedGB
        swapTotalGB = snapshot.swapTotalGB
        cachedFilesLabel = snapshot.cachedFilesLabel
        compressedLabel = snapshot.compressedLabel
        wiredLabel = snapshot.wiredLabel
        appMemoryLabel = snapshot.appMemoryLabel
        pressureLabel = snapshot.pressureLabel
        pressureSubtext = snapshot.pressureSubtext
        pressureValue = snapshot.pressureValue
        pressureHistory = snapshot.pressureHistory
        usageSeries = snapshot.usageSeries
        swapUsageSeries = snapshot.swapUsageSeries
        pressureSeries = snapshot.pressureSeries
        latestMemorySnapshot = snapshot.latestMemorySnapshot
        latestSnapshot = snapshot.latestSnapshot
    }
}
