import Foundation
import Combine
import Darwin

/// Sandbox-safe CPU sampler using Mach APIs (read-only).
public final class CPUStatsSampler: ObservableObject {
    @Published public var coreUsages: [Float] = []
    @Published public var totalUsage: Float? = nil
    @Published public var usageHistory: [Float] = []
    @Published public var cpuDisplayName: String = "CPU Usage"
    @Published public var systemUsage: Float? = nil
    @Published public var userUsage: Float? = nil
    @Published public var idleUsage: Float? = nil

    @Published public var efficiencyUsage: Float? = nil
    @Published public var efficiencyHistory: [Float] = []
    @Published public var performanceUsage: Float? = nil
    @Published public var performanceHistory: [Float] = []
    @Published public var efficiencyCoreCount: Int = 0
    @Published public var performanceCoreCount: Int = 0
    @Published public private(set) var perCoreUsageSeries: [MetricSeries] = []
    @Published public private(set) var totalUsageSeries = CPUStatsSampler.makeSeries(for: .cpuTotalUsage)
    @Published public private(set) var efficiencyUsageSeries = CPUStatsSampler.makeSeries(for: .cpuEfficiencyUsage)
    @Published public private(set) var performanceUsageSeries = CPUStatsSampler.makeSeries(for: .cpuPerformanceUsage)
    @Published public private(set) var latestSnapshot: HardwareSnapshot? = nil

    #if os(macOS)
    private var timer: DispatchSourceTimer?
    private var previousInfo: [processor_cpu_load_info] = []
    #endif

    // Retain enough live samples to satisfy the requested graph window, with a sensible floor.
    private var historyLength: Int { HardwareCollectionSettings.liveSeriesCapacity() }

    #if os(macOS)
    private var perCoreUsageSeriesBuffers: [MetricSeries] = []
    private var totalUsageSeriesBuffer = CPUStatsSampler.makeSeries(for: .cpuTotalUsage)
    private var efficiencyUsageSeriesBuffer = CPUStatsSampler.makeSeries(for: .cpuEfficiencyUsage)
    private var performanceUsageSeriesBuffer = CPUStatsSampler.makeSeries(for: .cpuPerformanceUsage)

    private enum PerfLevelRole {
        case efficiency
        case performance
        case unknown
    }

    private struct PerfLevelDescriptor {
        let index: Int
        var role: PerfLevelRole
        let physicalCount: Int
        let logicalCount: Int

        var displayCount: Int {
            physicalCount > 0 ? physicalCount : logicalCount
        }

        var activeLogicalCount: Int {
            logicalCount > 0 ? logicalCount : displayCount
        }
    }
    #endif

    public init() {}

    public func initialize() {
        #if os(macOS)
        stop()
        perCoreUsageSeriesBuffers = []
        totalUsageSeriesBuffer = Self.makeSeries(for: .cpuTotalUsage)
        efficiencyUsageSeriesBuffer = Self.makeSeries(for: .cpuEfficiencyUsage)
        performanceUsageSeriesBuffer = Self.makeSeries(for: .cpuPerformanceUsage)
        previousInfo = []
        DispatchQueue.main.async {
            self.usageHistory = []
            self.efficiencyHistory = []
            self.performanceHistory = []
            self.coreUsages = []
            self.totalUsage = nil
            self.systemUsage = nil
            self.userUsage = nil
            self.idleUsage = nil
            self.efficiencyUsage = nil
            self.performanceUsage = nil
            self.perCoreUsageSeries = []
            self.totalUsageSeries = Self.makeSeries(for: .cpuTotalUsage)
            self.efficiencyUsageSeries = Self.makeSeries(for: .cpuEfficiencyUsage)
            self.performanceUsageSeries = Self.makeSeries(for: .cpuPerformanceUsage)
            self.latestSnapshot = nil
        }
        cpuDisplayName = CPUStatsSampler.buildCPUDisplayName()
        let perfLevels = CPUStatsSampler.detectPerfLevelClusterCounts()
        efficiencyCoreCount = perfLevels.efficiency
        performanceCoreCount = perfLevels.performance
        sample()
        #endif
    }

    public func start() {
        #if os(macOS)
        initialize()

        let interval = HardwareCollectionSettings.collectorIntervalSeconds()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        timer.setEventHandler { [weak self] in
            self?.sample()
        }
        timer.resume()
        self.timer = timer
        #endif
    }

    // MARK: - CPU sysctl helpers

    public static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func makeSeries(for key: HardwareMetricKey) -> MetricSeries {
        MetricSeries(key: key, unit: .ratio)
    }

    private static func makePerCoreUsageSeries() -> MetricSeries {
        MetricSeries(key: .cpuPerCoreUsage, unit: .ratio)
    }

    #if os(macOS)
    private static func buildCPUDisplayName() -> String {
        // Prefer Intel brand string when available; fallback to hw.model.
        let rawName = sysctlString("machdep.cpu.brand_string")
            ?? sysctlString("hw.model")
            ?? "CPU"

        let name = rawName.trimmingCharacters(in: .controlCharacters)

        let physical = sysctlInt("hw.physicalcpu") ?? sysctlInt("hw.physicalcpu_max")
        let logical = sysctlInt("hw.logicalcpu") ?? sysctlInt("hw.logicalcpu_max")
        let perfLevels = detectPerfLevelClusterCounts()

        if let p = physical, let l = logical, p > 0, l > 0 {
            if perfLevels.performance > 0 || perfLevels.efficiency > 0 {
                return "CPU — \(name) — P:\(perfLevels.performance) E:\(perfLevels.efficiency) — \(p)C/\(l)T"
            }
            return "CPU — \(name) — \(p)C/\(l)T"
        } else {
            return "CPU — \(name)"
        }
    }

    public static func detectPerfLevelClusterCounts() -> (efficiency: Int, performance: Int) {
        let levels = detectedPerfLevels()
        let efficiency = levels
            .filter { $0.role == .efficiency }
            .reduce(0) { $0 + $1.displayCount }
        let performance = levels
            .filter { $0.role == .performance }
            .reduce(0) { $0 + $1.displayCount }
        return (efficiency: efficiency, performance: performance)
    }

    private static func perfLevelRole(for rawName: String?) -> PerfLevelRole {
        let normalizedName = rawName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        guard !normalizedName.isEmpty else { return .unknown }

        if normalizedName.contains("efficiency") || normalizedName.contains("low") {
            return .efficiency
        }

        if normalizedName.contains("performance") || normalizedName.contains("high") || normalizedName.contains("perf") {
            return .performance
        }

        return .unknown
    }

    private static func detectedPerfLevels() -> [PerfLevelDescriptor] {
        var levels: [PerfLevelDescriptor] = []

        for index in 0..<4 {
            let name = sysctlString("hw.perflevel\(index).name")
            let physicalCount = sysctlInt("hw.perflevel\(index).physicalcpu")
                ?? sysctlInt("hw.perflevel\(index).physicalcpu_max")
                ?? 0
            let logicalCount = sysctlInt("hw.perflevel\(index).logicalcpu")
                ?? sysctlInt("hw.perflevel\(index).logicalcpu_max")
                ?? 0

            guard name != nil || physicalCount > 0 || logicalCount > 0 else { continue }

            levels.append(
                PerfLevelDescriptor(
                    index: index,
                    role: perfLevelRole(for: name),
                    physicalCount: max(physicalCount, 0),
                    logicalCount: max(logicalCount, 0)
                )
            )
        }

        guard !levels.isEmpty else { return [] }

        if levels.allSatisfy({ $0.role == .unknown }) {
            if levels.count == 1 {
                levels[0].role = .performance
            } else {
                levels[0].role = .performance
                if levels.indices.contains(1) {
                    levels[1].role = .efficiency
                }
            }
        } else if levels.count == 2 {
            if levels[0].role == .unknown && levels[1].role == .efficiency {
                levels[0].role = .performance
            }
            if levels[0].role == .performance && levels[1].role == .unknown {
                levels[1].role = .efficiency
            }
            if levels[0].role == .unknown && levels[1].role == .performance {
                levels[0].role = .efficiency
            }
            if levels[0].role == .efficiency && levels[1].role == .unknown {
                levels[1].role = .performance
            }
        }

        return levels.sorted { $0.index < $1.index }
    }

    private static func splitCoreUsages(_ usages: [Float]) -> (efficiency: [Float], performance: [Float]) {
        guard !usages.isEmpty else { return ([], []) }
        let levels = detectedPerfLevels()
        guard !levels.isEmpty else { return ([], []) }

        var efficiency: [Float] = []
        var performance: [Float] = []
        var cursor = 0

        for level in levels {
            let remainingCount = usages.count - cursor
            guard remainingCount > 0 else { break }

            let levelCount = max(0, min(level.activeLogicalCount, remainingCount))
            guard levelCount > 0 else { continue }

            let slice = Array(usages[cursor..<(cursor + levelCount)])
            cursor += levelCount

            switch level.role {
            case .efficiency:
                efficiency.append(contentsOf: slice)
            case .performance:
                performance.append(contentsOf: slice)
            case .unknown:
                break
            }
        }

        return (efficiency, performance)
    }
    #endif

    public func stop() {
        #if os(macOS)
        timer?.cancel()
        timer = nil
        #endif
    }

    #if os(macOS)
    func sample() {
        let timestamp = Date()
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        var numCPUs: natural_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )

        guard result == KERN_SUCCESS, let cpuInfo else { return }

        let infoCount = Int(numCPUs)
        let cpuLoadInfo = cpuInfo.withMemoryRebound(to: processor_cpu_load_info.self, capacity: infoCount) {
            Array(UnsafeBufferPointer(start: $0, count: infoCount))
        }

        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: cpuInfo),
                vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let hasCompleteBaseline = previousInfo.count == infoCount && !previousInfo.isEmpty

        var usages: [Float] = []
        usages.reserveCapacity(infoCount)

        var aggregateDeltaUser: Float = 0
        var aggregateDeltaSystem: Float = 0
        var aggregateDeltaIdle: Float = 0
        var aggregateDeltaNice: Float = 0

        for i in 0..<infoCount {
            let info = cpuLoadInfo[i]
            let user = Float(info.cpu_ticks.0)
            let system = Float(info.cpu_ticks.1)
            let idle = Float(info.cpu_ticks.2)
            let nice = Float(info.cpu_ticks.3)

            if previousInfo.indices.contains(i) {
                let prev = previousInfo[i]

                let deltaUser = user - Float(prev.cpu_ticks.0)
                let deltaSystem = system - Float(prev.cpu_ticks.1)
                let deltaIdle = idle - Float(prev.cpu_ticks.2)
                let deltaNice = nice - Float(prev.cpu_ticks.3)
                let deltaTotal = deltaUser + deltaSystem + deltaIdle + deltaNice

                aggregateDeltaUser += max(deltaUser, 0)
                aggregateDeltaSystem += max(deltaSystem, 0)
                aggregateDeltaIdle += max(deltaIdle, 0)
                aggregateDeltaNice += max(deltaNice, 0)

                let usage = deltaTotal > 0 ? (deltaTotal - deltaIdle) / deltaTotal : 0
                usages.append(min(max(usage, 0), 1))
            } else {
                usages.append(0)
            }
        }

        previousInfo = cpuLoadInfo

        let total: Float? = usages.isEmpty ? nil : (usages.reduce(0, +) / Float(usages.count))

        let aggregateDeltaTotal = aggregateDeltaUser + aggregateDeltaSystem + aggregateDeltaIdle + aggregateDeltaNice
        let systemTotal: Float? = aggregateDeltaTotal > 0 ? min(max(aggregateDeltaSystem / aggregateDeltaTotal, 0), 1) : nil
        let userTotal: Float? = aggregateDeltaTotal > 0 ? min(max((aggregateDeltaUser + aggregateDeltaNice) / aggregateDeltaTotal, 0), 1) : nil
        let idleTotal: Float? = aggregateDeltaTotal > 0 ? min(max(aggregateDeltaIdle / aggregateDeltaTotal, 0), 1) : nil

        let split = Self.splitCoreUsages(usages)
        let efficiencyTotal: Float? = split.efficiency.isEmpty ? nil : (split.efficiency.reduce(0, +) / Float(split.efficiency.count))
        let performanceTotal: Float? = split.performance.isEmpty ? nil : (split.performance.reduce(0, +) / Float(split.performance.count))

        if perCoreUsageSeriesBuffers.count != usages.count {
            var rebuilt = (0..<usages.count).map { _ in Self.makePerCoreUsageSeries() }
            let reusableCount = min(perCoreUsageSeriesBuffers.count, rebuilt.count)
            if reusableCount > 0 {
                for index in 0..<reusableCount {
                    rebuilt[index] = perCoreUsageSeriesBuffers[index]
                }
            }
            perCoreUsageSeriesBuffers = rebuilt
        }

        for index in usages.indices {
            perCoreUsageSeriesBuffers[index].append(
                hasCompleteBaseline ? Double(usages[index]) : nil,
                at: timestamp,
                capacity: historyLength
            )
        }

        totalUsageSeriesBuffer.append(hasCompleteBaseline ? total.map(Double.init) : nil, at: timestamp, capacity: historyLength)
        efficiencyUsageSeriesBuffer.append(hasCompleteBaseline ? efficiencyTotal.map(Double.init) : nil, at: timestamp, capacity: historyLength)
        performanceUsageSeriesBuffer.append(hasCompleteBaseline ? performanceTotal.map(Double.init) : nil, at: timestamp, capacity: historyLength)

        let perCoreSeries = perCoreUsageSeriesBuffers
        let totalSeries = totalUsageSeriesBuffer
        let efficiencySeries = efficiencyUsageSeriesBuffer
        let performanceSeries = performanceUsageSeriesBuffer

        var snapshot = HardwareSnapshot(timestamp: timestamp)
        snapshot.setDimension(.cpuDisplayName, value: cpuDisplayName)
        snapshot.setMetric(.cpuEfficiencyCoreCount, value: Double(efficiencyCoreCount))
        snapshot.setMetric(.cpuPerformanceCoreCount, value: Double(performanceCoreCount))

        if hasCompleteBaseline {
            if let total {
                snapshot.setMetric(.cpuTotalUsage, value: Double(total))
            }
            if let systemTotal {
                snapshot.setMetric(.cpuSystemUsage, value: Double(systemTotal))
            }
            if let userTotal {
                snapshot.setMetric(.cpuUserUsage, value: Double(userTotal))
            }
            if let idleTotal {
                snapshot.setMetric(.cpuIdleUsage, value: Double(idleTotal))
            }
            if let efficiencyTotal {
                snapshot.setMetric(.cpuEfficiencyUsage, value: Double(efficiencyTotal))
            }
            if let performanceTotal {
                snapshot.setMetric(.cpuPerformanceUsage, value: Double(performanceTotal))
            }
        }

        DispatchQueue.main.async {
            self.latestSnapshot = snapshot
            self.perCoreUsageSeries = perCoreSeries
            self.totalUsageSeries = totalSeries
            self.efficiencyUsageSeries = efficiencySeries
            self.performanceUsageSeries = performanceSeries
            self.coreUsages = usages
            self.totalUsage = total
            self.systemUsage = systemTotal
            self.userUsage = userTotal
            self.idleUsage = idleTotal
            self.efficiencyUsage = efficiencyTotal
            self.performanceUsage = performanceTotal
            self.usageHistory = totalSeries.values().map(Float.init)
            self.efficiencyHistory = efficiencySeries.values().map(Float.init)
            self.performanceHistory = performanceSeries.values().map(Float.init)
        }
    }
    #endif

    private static func detectCPUName() -> String? {
        #if arch(x86_64)
        // Intel Macs: machdep.cpu.brand_string
        var size: size_t = 0
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 {
                return String(cString: buffer)
            }
        }
        #endif

        // Apple Silicon / generic fallback: hw.model
        var modelSize: size_t = 0
        if sysctlbyname("hw.model", nil, &modelSize, nil, 0) == 0 {
            var buffer = [CChar](repeating: 0, count: modelSize)
            if sysctlbyname("hw.model", &buffer, &modelSize, nil, 0) == 0 {
                return String(cString: buffer)
            }
        }

        return nil
    }
}

extension CPUStatsSampler {
    public var liveSnapshot: CPUSamplerLiveSnapshot {
        CPUSamplerLiveSnapshot(
            coreUsages: coreUsages,
            totalUsage: totalUsage,
            usageHistory: usageHistory,
            cpuDisplayName: cpuDisplayName,
            systemUsage: systemUsage,
            userUsage: userUsage,
            idleUsage: idleUsage,
            efficiencyUsage: efficiencyUsage,
            efficiencyHistory: efficiencyHistory,
            performanceUsage: performanceUsage,
            performanceHistory: performanceHistory,
            efficiencyCoreCount: efficiencyCoreCount,
            performanceCoreCount: performanceCoreCount,
            perCoreUsageSeries: perCoreUsageSeries,
            totalUsageSeries: totalUsageSeries,
            efficiencyUsageSeries: efficiencyUsageSeries,
            performanceUsageSeries: performanceUsageSeries,
            latestSnapshot: latestSnapshot
        )
    }

    public func applyRemoteSnapshot(_ snapshot: CPUSamplerLiveSnapshot) {
        coreUsages = snapshot.coreUsages
        totalUsage = snapshot.totalUsage
        usageHistory = snapshot.usageHistory
        cpuDisplayName = snapshot.cpuDisplayName
        systemUsage = snapshot.systemUsage
        userUsage = snapshot.userUsage
        idleUsage = snapshot.idleUsage
        efficiencyUsage = snapshot.efficiencyUsage
        efficiencyHistory = snapshot.efficiencyHistory
        performanceUsage = snapshot.performanceUsage
        performanceHistory = snapshot.performanceHistory
        efficiencyCoreCount = snapshot.efficiencyCoreCount
        performanceCoreCount = snapshot.performanceCoreCount
        perCoreUsageSeries = snapshot.perCoreUsageSeries
        totalUsageSeries = snapshot.totalUsageSeries
        efficiencyUsageSeries = snapshot.efficiencyUsageSeries
        performanceUsageSeries = snapshot.performanceUsageSeries
        latestSnapshot = snapshot.latestSnapshot
    }
}
