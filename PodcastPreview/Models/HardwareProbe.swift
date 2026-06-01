#if DEBUG && os(macOS)
import Foundation
import IOKit
import IOKit.graphics
import PodcastPreviewCore

/// Manual diagnostic utility for inspecting hardware capability availability.
///
/// This is compiled only in debug macOS builds and is intentionally not wired
/// into normal app startup. Invoke from a debugger or temporary debug action
/// when validating hardware telemetry access on a local machine.
enum HardwareProbe {
    private static let prefix = "[HardwareProbe]"

    private static var ioMainPort: mach_port_t {
        if #available(macOS 12.0, *) {
            return kIOMainPortDefault
        } else {
            return kIOMasterPortDefault
        }
    }

    static func runAllProbes() {
        log("Starting hardware capability diagnostics")

        probeSystemInfo()
        probeSwapRate()
        probeThermalCapabilities()
        probeFanAccess()
        probeMediaEngineAccess()
        probeMemoryBandwidthAccess()
        probeIOReportChannels()

        log("Hardware capability diagnostics complete")
    }

    // MARK: - System Info

    private static func probeSystemInfo() {
        logSection("System Info")

        let model = sysctlString("hw.model") ?? "Unknown"
        let cpu = sysctlString("machdep.cpu.brand_string") ?? "Unknown"
        let isAppleSilicon = sysctlInt("hw.optional.arm64") == 1
        let perfLevelCounts = CPUStatsSampler.detectPerfLevelClusterCounts()
        let perfCores = perfLevelCounts.performance > 0 ? perfLevelCounts.performance : nil
        let effCores = perfLevelCounts.efficiency > 0 ? perfLevelCounts.efficiency : nil

        log("model=\(model)")
        log("cpu=\(cpu)")
        log("architecture=\(isAppleSilicon ? "Apple Silicon" : "Intel")")

        if isAppleSilicon {
            let pCores = perfCores.map(String.init) ?? "nil"
            let eCores = effCores.map(String.init) ?? "nil"
            log("performanceCores=\(pCores) efficiencyCores=\(eCores)")
        }
    }

    // MARK: - Swap Rate

    private static func probeSwapRate() {
        logSection("Swap Rate Tracking")

        // Local mirror of xsw_usage from sys/sysctl.h for vm.swapusage.
        struct SwapUsage {
            var xsu_total: UInt64
            var xsu_avail: UInt64
            var xsu_used: UInt64
            var xsu_pagesize: UInt32
            var xsu_encrypted: Bool
        }

        var usage = SwapUsage(
            xsu_total: 0,
            xsu_avail: 0,
            xsu_used: 0,
            xsu_pagesize: 0,
            xsu_encrypted: false
        )
        var size = MemoryLayout<SwapUsage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)

        if result == 0 {
            log("available vm.swapusage")
            log("swapTotalGB=\(Double(usage.xsu_total) / 1_073_741_824.0)")
            log("swapUsedGB=\(Double(usage.xsu_used) / 1_073_741_824.0)")
        } else {
            log("unavailable vm.swapusage error=\(String(cString: strerror(errno)))")
        }

        let swapins = sysctlUInt64("vm.swapins")
        let swapouts = sysctlUInt64("vm.swapouts")

        if let ins = swapins, let outs = swapouts {
            log("available vm.swapins/vm.swapouts")
            log("swapinsPages=\(ins)")
            log("swapoutsPages=\(outs)")
            log("note=swap rate can be tracked by delta sampling these counters")
        } else {
            log("unavailable vm.swapins/vm.swapouts")
            log("fallback=parse vm_stat output via Process")
        }
    }

    // MARK: - Thermal Capabilities

    private static func probeThermalCapabilities() {
        logSection("Thermal Tracking")

        let thermalState = ProcessInfo.processInfo.thermalState
        log("available ProcessInfo.thermalState value=\(thermalStateString(thermalState))")
        log("available ProcessInfo.thermalStateDidChangeNotification")
        log("note=thermal transitions can be counted during an app session")

        if let pressure = sysctlInt("vm.memory_pressure") {
            log("available vm.memory_pressure value=\(pressure)")
        }

        let service = IOServiceGetMatchingService(ioMainPort, IOServiceMatching("IOPlatformMonitor"))
        if service != 0 {
            log("available IOPlatformMonitor")
            log("note=thermal sensors may be readable via IOKit")
            IOObjectRelease(service)
        } else {
            log("unavailable IOPlatformMonitor")
        }

        log("unavailable direct thermal throttle event counters")
        log("fallback=track ProcessInfo thermal state transitions")
    }

    // MARK: - Fan Speed

    private static func probeFanAccess() {
        logSection("Fan Speed")

        let smcService = IOServiceGetMatchingService(ioMainPort, IOServiceMatching("AppleSMC"))
        if smcService != 0 {
            log("available AppleSMC")
            log("restricted direct SMC access requires user-client entitlement or helper")
            IOObjectRelease(smcService)
        } else {
            log("unavailable AppleSMC")
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            ioMainPort,
            IOServiceMatching("IOHWSensor"),
            &iterator
        )

        if result == KERN_SUCCESS {
            var service = IOIteratorNext(iterator)
            var foundFan = false

            while service != 0 {
                var properties: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let values = properties?.takeRetainedValue() as? [String: Any],
                   let type = values["type"] as? String,
                   type.lowercased().contains("fan") {
                    foundFan = true
                    log("available IOHWSensor fanSensorProperties=\(values)")
                }

                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            IOObjectRelease(iterator)

            if !foundFan {
                log("limited IOHWSensor exists but no fan sensors were found")
            }
        } else {
            log("unavailable IOHWSensor result=\(result)")
        }

        log("recommendation=use an optional SMC helper with user consent or thermal state as a fan proxy")
    }

    // MARK: - Media Engine

    private static func probeMediaEngineAccess() {
        logSection("Media Engine")

        let isAppleSilicon = sysctlInt("hw.optional.arm64") == 1
        if !isAppleSilicon {
            log("skipped Media Engine because host architecture is not Apple Silicon")
            return
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            ioMainPort,
            IOServiceMatching("AppleAVE"),
            &iterator
        )

        if result == KERN_SUCCESS {
            let service = IOIteratorNext(iterator)
            if service != 0 {
                log("available AppleAVE hardware encoder service")
                IOObjectRelease(service)
            } else {
                log("unavailable AppleAVE hardware encoder service")
            }
            IOObjectRelease(iterator)
        } else {
            log("unavailable AppleAVE lookup result=\(result)")
        }

        let mediaKeys = ["hw.optional.neon", "hw.optional.arm.FEAT_DotProd"]
        for key in mediaKeys {
            if let value = sysctlInt(key) {
                log("available \(key) value=\(value)")
            }
        }

        log("note=media engine utilization requires IOReport integration")
        log("probeHint=look for channels named MediaEngine or VideoCodec")
    }

    // MARK: - Memory Bandwidth

    private static func probeMemoryBandwidthAccess() {
        logSection("Memory Bandwidth")

        let isAppleSilicon = sysctlInt("hw.optional.arm64") == 1
        if !isAppleSilicon {
            log("skipped Memory Bandwidth because host architecture is not Apple Silicon")
            return
        }

        let memsize = sysctlUInt64("hw.memsize")
        let pagesize = sysctlInt("hw.pagesize")

        log("available hw.memsize valueGB=\(Double(memsize ?? 0) / 1_073_741_824.0)")
        log("available hw.pagesize valueBytes=\(pagesize ?? 0)")
        log("note=memory bandwidth requires IOReport framework")
        log("probeHint=look for DRAM or AMC Apple Memory Controller channels")
    }

    // MARK: - IOReport Channels

    private static func probeIOReportChannels() {
        logSection("IOReport Framework")
        log("restricted IOReport requires a private framework or powermetrics")
        log("probeCommand=sudo powermetrics --show-all -n 1 | grep -E '(media|bandwidth|thermal|fan)'")
        log("probeHint=Energy Model reports CPU/GPU power")
        log("probeHint=CPU Stats reports per-core activity")
        log("probeHint=GPU Stats reports GPU activity")
        log("probeHint=Memory Bandwidth or DRAM reports memory throughput")
        log("probeHint=Media Engine or Video reports codec acceleration")
    }

    // MARK: - Helpers

    private static func logSection(_ title: String) {
        log("-- \(title) --")
    }

    private static func log(_ message: String) {
        print("\(prefix) \(message)")
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return nil }

        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal (0)"
        case .fair: return "Fair (1)"
        case .serious: return "Serious (2)"
        case .critical: return "Critical (3)"
        @unknown default: return "Unknown"
        }
    }
}
#endif
