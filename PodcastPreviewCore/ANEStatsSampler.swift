import Foundation
import Combine
#if os(macOS)
import IOKit
#endif

/// Samples Apple Neural Engine statistics from IORegistry.
public final class ANEStatsSampler: ObservableObject {
    public struct StatusSnapshot: Codable, Equatable, Sendable {
        public var coreCount: Int?
        public var architecture: String?
        public var engineStatus: String
        public var clients: [String]
        public var activityState: ActivityState
        public var activityValue: Double
        public var activityStatus: String
        public var currentPowerMilliwatts: Double
        public var powerDeltaMilliwatts: Double
        public var peakPowerMilliwatts: Double
        public var clientCount: Int

        public init(
            coreCount: Int? = nil,
            architecture: String? = nil,
            engineStatus: String,
            clients: [String],
            activityState: ActivityState,
            activityValue: Double,
            activityStatus: String,
            currentPowerMilliwatts: Double,
            powerDeltaMilliwatts: Double,
            peakPowerMilliwatts: Double,
            clientCount: Int
        ) {
            self.coreCount = coreCount
            self.architecture = architecture
            self.engineStatus = engineStatus
            self.clients = clients
            self.activityState = activityState
            self.activityValue = activityValue
            self.activityStatus = activityStatus
            self.currentPowerMilliwatts = currentPowerMilliwatts
            self.powerDeltaMilliwatts = powerDeltaMilliwatts
            self.peakPowerMilliwatts = peakPowerMilliwatts
            self.clientCount = clientCount
        }

        public var hasNeuralEngine: Bool {
            guard let coreCount else { return false }
            return coreCount > 0
        }

        public var coreCountText: String {
            coreCount.map(String.init) ?? "—"
        }

        public var architectureText: String {
            architecture ?? "—"
        }

        public var statusText: String {
            activityStatus
        }

        public var powerText: String {
            guard currentPowerMilliwatts > 0 else { return "—" }
            return String(format: "%.3f W", currentPowerMilliwatts / 1000.0)
        }

        public var peakPowerText: String {
            guard peakPowerMilliwatts > 0 else { return "—" }
            return String(format: "%.3f W", peakPowerMilliwatts / 1000.0)
        }

        public var powerDeltaText: String {
            guard abs(powerDeltaMilliwatts) >= 0.1 else { return "—" }
            let sign = powerDeltaMilliwatts > 0 ? "+" : ""
            return String(format: "%@%.3f W", sign, powerDeltaMilliwatts / 1000.0)
        }
    }

    @Published public var coreCountText: String = "—"
    @Published public var architectureText: String = "—"
    @Published public var engineStatusText: String = "Idle"
    @Published public var clientsText: [String] = []

    @Published public var activityState: ActivityState = .idle
    @Published public var activityValue: Float = 0.0
    @Published public var activityHistory: [Float] = []
    @Published public var statusText: String = "Idle"
    @Published public var currentPowerMilliwatts: Double = 0.0
    @Published public var powerDeltaMilliwatts: Double = 0.0
    @Published public var peakPowerMilliwatts: Double = 0.0
    @Published public var peakPowerWattsText: String = "—"
    @Published public var powerDeltaWattsText: String = "—"
    @Published public var clientCount: Int = 0
    @Published public private(set) var activitySeries = ANEStatsSampler.makeActivitySeries()
    @Published public private(set) var powerSeries = ANEStatsSampler.makePowerSeries()
    @Published public private(set) var latestStatusSnapshot: StatusSnapshot? = nil
    @Published public private(set) var latestSnapshot: HardwareSnapshot? = nil

    #if os(macOS)
    private var timer: DispatchSourceTimer?
    private let samplingQueue = DispatchQueue(
        label: "PodcastPreview.ANEStatsSampler",
        qos: .userInitiated,
        attributes: [],
        autoreleaseFrequency: .workItem
    )
    private var previousBusyTime: UInt64?
    private var previousPowerMilliwatts: Double = 0.0
    private var sustainedActiveSeconds: Double = 0.0
    private weak var powerSampler: PowerStatsSampler?
    private var activitySeriesBuffer = ANEStatsSampler.makeActivitySeries()
    private var powerSeriesBuffer = ANEStatsSampler.makePowerSeries()
    #endif

    private static var historyCapacity: Int {
        HardwareCollectionSettings.liveSeriesCapacity()
    }

    /// Dynamic Y-axis ceiling for the ANE activity graph (watts), updated each
    /// sample. Starts at the 0.5 W floor and grows whenever a new peak is seen.
    /// 15 % headroom above the observed peak prevents the spike touching the top.
    private var sampleCeilingWatts: Double = 0.5

    public enum ActivityState: String, Codable, Sendable {
        case idle
        case active
        case busy
    }

    public var hasNeuralEngine: Bool {
        coreCountText != "—" && coreCountText != "0"
    }

    public var utilizationPercent: Double {
        let powerWatts = currentPowerMilliwatts / 1000.0
        guard powerWatts >= 0.020 else { return 0.0 }

        let busyThresholdW = 0.001
        // Mirror the dynamic ceiling used in sample() so this stays consistent.
        let maxGraphW = max(0.5, peakPowerMilliwatts / 1000.0 * 1.15)
        let powerRange = maxGraphW - busyThresholdW
        let powerAboveThreshold = powerWatts - busyThresholdW
        let percent = (powerAboveThreshold / powerRange) * 100.0

        return percent
    }

    public init(powerSampler: PowerStatsSampler? = nil) {
        #if os(macOS)
        self.powerSampler = powerSampler
        #endif
    }

    private static func makeActivitySeries() -> MetricSeries {
        MetricSeries(key: .aneActivityRatio, unit: .ratio)
    }

    private static func makePowerSeries() -> MetricSeries {
        MetricSeries(key: .anePowerWatts, unit: .watts)
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

    public func initialize() {
        #if os(macOS)
        stop()
        previousBusyTime = nil
        previousPowerMilliwatts = 0.0
        sustainedActiveSeconds = 0.0
        activitySeriesBuffer = Self.makeActivitySeries()
        powerSeriesBuffer = Self.makePowerSeries()
        sampleCeilingWatts = 0.5
        DispatchQueue.main.async {
            self.activityHistory = []
            self.activityValue = 0.0
            self.activityState = .idle
            self.statusText = "Idle"
            self.currentPowerMilliwatts = 0.0
            self.powerDeltaMilliwatts = 0.0
            self.peakPowerMilliwatts = 0.0
            self.peakPowerWattsText = "—"
            self.powerDeltaWattsText = "—"
            self.clientCount = 0
            self.activitySeries = Self.makeActivitySeries()
            self.powerSeries = Self.makePowerSeries()
            self.latestStatusSnapshot = nil
            self.latestSnapshot = nil
        }
        sample()
        #endif
    }

    public func start() {
        #if os(macOS)
        initialize()

        let interval = HardwareCollectionSettings.collectorIntervalSeconds()
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

    public func resetPeak() {
        #if os(macOS)
        DispatchQueue.main.async {
            self.peakPowerMilliwatts = 0.0
            self.peakPowerWattsText = "—"
            if var latestStatusSnapshot = self.latestStatusSnapshot {
                latestStatusSnapshot.peakPowerMilliwatts = 0.0
                self.latestStatusSnapshot = latestStatusSnapshot
            }
        }
        #endif
    }

    #if os(macOS)
    func sample() {
        let timestamp = Date()
        let staticInfo = readStaticInfo()
        let busyTime = readBusyTime()
        let clients = readClients()

        let busyRatio: Double? = {
            guard let busyTime else { return nil }
            guard let previousBusyTime else { return nil }

            let sampleSeconds = HardwareCollectionSettings.collectorIntervalSeconds()
            let delta = busyTime >= previousBusyTime ? (busyTime - previousBusyTime) : 0
            let windowNanos = UInt64(sampleSeconds) * 1_000_000_000
            return windowNanos > 0 ? Double(delta) / Double(windowNanos) : 0
        }()

        let engineStatus: String = {
            guard let busyRatio else { return "Idle" }

            switch busyRatio {
            case ..<0.03: return "Idle"
            case 0.03..<0.20: return "Active"
            default: return "Busy"
            }
        }()

        previousBusyTime = busyTime

        let observedPowerMilliwatts = powerSampler?.anePowerMilliwatts
        let anePowerMW = observedPowerMilliwatts ?? 0.0
        let observedPowerWatts = observedPowerMilliwatts.map { $0 / 1000.0 }
        let sampleSeconds = Double(HardwareCollectionSettings.collectorIntervalSeconds())
        let delta = anePowerMW - previousPowerMilliwatts
        previousPowerMilliwatts = anePowerMW
        let peak = max(anePowerMW, 0.0)
        let activityClientCount = clients.count

        let activityState: ActivityState
        let activityValue: Float
        let activityStatusText: String

        let anePowerWatts = anePowerMW / 1000.0

        if anePowerWatts <= 0.0 {
            activityState = .idle
            activityValue = 0.0
            activityStatusText = "Idle"
            sustainedActiveSeconds = 0.0
        } else if anePowerWatts < 0.020 {
            activityState = .active
            activityValue = 0.0
            activityStatusText = "Active"
            sustainedActiveSeconds = 0.0
        } else {
            activityState = .busy

            // Grow the ceiling whenever a new peak is observed.
            // 15 % headroom keeps the peak from touching the graph top edge.
            // 0.5 W floor prevents noise amplification at near-idle loads.
            if anePowerWatts > sampleCeilingWatts / 1.15 {
                sampleCeilingWatts = max(0.5, anePowerWatts * 1.15)
            }

            let busyThresholdW = 0.001
            let maxGraphW = sampleCeilingWatts
            let powerRange = maxGraphW - busyThresholdW
            let powerAboveThreshold = max(anePowerWatts - busyThresholdW, 0.0)
            let graphPercent = min(powerAboveThreshold / powerRange, 1.0)

            activityValue = Float(graphPercent)
            activityStatusText = "Busy"
            sustainedActiveSeconds += sampleSeconds
        }

        activitySeriesBuffer.append(Double(activityValue), at: timestamp, capacity: Self.historyCapacity)
        powerSeriesBuffer.append(observedPowerWatts, at: timestamp, capacity: Self.historyCapacity)

        // Create fresh copies to ensure SwiftUI detects the change on every sample,
        // not just when there's activity. This prevents the graph from appearing frozen
        // during idle periods.
        let activitySeries = MetricSeries(
            key: activitySeriesBuffer.key,
            unit: activitySeriesBuffer.unit,
            samples: activitySeriesBuffer.samples
        )
        let powerSeries = MetricSeries(
            key: powerSeriesBuffer.key,
            unit: powerSeriesBuffer.unit,
            samples: powerSeriesBuffer.samples
        )

        var snapshot = HardwareSnapshot(timestamp: timestamp)
        if let coreCount = Int(staticInfo.coreCountText) {
            snapshot.setMetric(.aneCoreCount, value: Double(coreCount))
        }
        snapshot.setMetric(.aneClientCount, value: Double(activityClientCount))
        snapshot.setMetric(.aneActivityRatio, value: Double(activityValue))
        if let busyRatio {
            snapshot.setMetric(.aneBusyRatio, value: busyRatio)
        }
        if let observedPowerWatts {
            snapshot.setMetric(.anePowerWatts, value: observedPowerWatts)
        }
        if staticInfo.architectureText != "—" {
            snapshot.setDimension(.aneArchitecture, value: staticInfo.architectureText)
        }
        snapshot.setDimension(.aneEngineStatus, value: engineStatus)
        snapshot.setDimension(.aneActivityStatus, value: activityStatusText)
        let statusSnapshot = StatusSnapshot(
            coreCount: Int(staticInfo.coreCountText),
            architecture: staticInfo.architectureText == "—" ? nil : staticInfo.architectureText,
            engineStatus: engineStatus,
            clients: clients,
            activityState: activityState,
            activityValue: Double(activityValue),
            activityStatus: activityStatusText,
            currentPowerMilliwatts: anePowerMW,
            powerDeltaMilliwatts: delta,
            peakPowerMilliwatts: max(peakPowerMilliwatts, peak),
            clientCount: activityClientCount
        )

        DispatchQueue.main.async {
            self.latestStatusSnapshot = statusSnapshot
            self.latestSnapshot = snapshot
            self.activitySeries = activitySeries
            self.powerSeries = powerSeries
            self.coreCountText = statusSnapshot.coreCountText
            self.architectureText = statusSnapshot.architectureText
            self.engineStatusText = statusSnapshot.engineStatus
            self.clientsText = statusSnapshot.clients
            self.activityState = statusSnapshot.activityState
            self.activityValue = Float(statusSnapshot.activityValue)
            self.statusText = statusSnapshot.statusText
            self.activityHistory = activitySeries.values().map(Float.init)
            self.currentPowerMilliwatts = statusSnapshot.currentPowerMilliwatts
            self.powerDeltaMilliwatts = statusSnapshot.powerDeltaMilliwatts

            if peak > self.peakPowerMilliwatts {
                self.peakPowerMilliwatts = peak
                self.peakPowerWattsText = statusSnapshot.peakPowerText
            }

            self.powerDeltaWattsText = statusSnapshot.powerDeltaText

            self.clientCount = statusSnapshot.clientCount
        }
    }

    private func readStaticInfo() -> (coreCountText: String, architectureText: String) {
        let service = IOServiceGetMatchingService(Self.ioMainPort, IOServiceMatching("H11ANEIn"))
        guard service != 0 else { return ("—", "—") }
        defer { IOObjectRelease(service) }

        guard let props = IORegistryEntryCreateCFProperty(
            service,
            "DeviceProperties" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any] else {
            return ("—", "—")
        }

        let cores: String = {
            if let n = props["ANEDevicePropertyNumANECores"] as? NSNumber { return "\(n.intValue)" }
            if let n = props["ANEDevicePropertyNumANECores"] as? Int { return "\(n)" }
            return "—"
        }()

        let arch: String = {
            if let s = props["ANEDevicePropertyTypeANEArchitectureTypeStr"] as? String, !s.isEmpty {
                return s
            }
            return "—"
        }()

        return (cores, arch)
    }

    private func readBusyTime() -> UInt64? {
        let service = IOServiceGetMatchingService(Self.ioMainPort, IOServiceMatching("H11ANEIn"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        if let busy = IORegistryEntryCreateCFProperty(
            service,
            "IOServiceBusyTime" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber {
            return busy.uint64Value
        }

        return nil
    }

    private func readClients() -> [String] {
        var loadBalancer: io_service_t = 0

        loadBalancer = IOServiceGetMatchingService(
            Self.ioMainPort,
            IOServiceNameMatching("ANEDriverRoot")
        )

        if loadBalancer == 0 {
            let loadBalancerClasses = [
                "H11ANELoadBalancer",
                "H13ANELoadBalancer",
                "H14ANELoadBalancer",
                "H15ANELoadBalancer",
                "H16ANELoadBalancer",
                "H1xANELoadBalancer"
            ]

            for className in loadBalancerClasses {
                loadBalancer = IOServiceGetMatchingService(Self.ioMainPort, IOServiceMatching(className))
                if loadBalancer != 0 {
                    break
                }
            }
        }

        guard loadBalancer != 0 else {
            #if DEBUG && !HARDWARE_JOBBLESS_EMBEDS_CORE
            Task { @MainActor in
                AppDebugConsole.log("[ANE] Could not find ANEDriverRoot or H1xANELoadBalancer service", category: "ANE")
            }
            #endif
            return []
        }
        defer { IOObjectRelease(loadBalancer) }

        var processNames: [String] = []

        var iterator: io_iterator_t = 0
        let result = IORegistryEntryGetChildIterator(loadBalancer, kIOServicePlane, &iterator)
        guard result == KERN_SUCCESS else {
            #if DEBUG && !HARDWARE_JOBBLESS_EMBEDS_CORE
            Task { @MainActor in
                AppDebugConsole.log("[ANE] Failed to get child iterator: \(result)", category: "ANE")
            }
            #endif
            return []
        }
        defer { IOObjectRelease(iterator) }

        var child = IOIteratorNext(iterator)
        var childCount = 0
        while child != 0 {
            defer { IOObjectRelease(child) }
            childCount += 1

            if let creatorValue = IORegistryEntryCreateCFProperty(
                child,
                "IOUserClientCreator" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? String {
                #if DEBUG && !HARDWARE_JOBBLESS_EMBEDS_CORE
                Task { @MainActor in
                    AppDebugConsole.log("[ANE] Found client: \(creatorValue)", category: "ANE")
                }
                #endif

                if let processName = parseProcessNameFromCreator(creatorValue) {
                    processNames.append(processName)
                }
            }

            child = IOIteratorNext(iterator)
        }

        #if DEBUG && !HARDWARE_JOBBLESS_EMBEDS_CORE
        let loggedChildCount = childCount
        let loggedProcessCount = processNames.count
        Task { @MainActor in
            AppDebugConsole.log("[ANE] Scanned \(loggedChildCount) children, found \(loggedProcessCount) clients", category: "ANE")
        }
        #endif

        return Array(Set(processNames)).sorted()
    }

    private func parseProcessNameFromCreator(_ creator: String) -> String? {
        let components = creator.split(separator: ",", maxSplits: 1)
        guard components.count == 2 else { return nil }

        let processName = components[1].trimmingCharacters(in: .whitespaces)
        guard !processName.isEmpty else { return nil }
        return processName
    }
    #endif

    /// Maps ANE service process names to human-readable descriptions for better visibility
    public static func readableServiceName(for processName: String) -> String {
        // Known ANE inference/ML services
        if processName.contains("InferenceProvider") || processName.contains("TGOn") {
            return "Inference Service"
        }
        if processName.contains("Translation") {
            return "Translation Service"
        }
        if processName.contains("Language") || processName.contains("LanguageModel") {
            return "Language Service"
        }
        if processName.contains("Transcription") {
            return "Transcription Service"
        }
        if processName.contains("Vision") {
            return "Vision Service"
        }
        // Return original name if not recognized
        return processName
    }
}

extension ANEStatsSampler {
    public var liveSnapshot: ANEStatsSamplerLiveSnapshot {
        ANEStatsSamplerLiveSnapshot(
            coreCountText: coreCountText,
            architectureText: architectureText,
            engineStatusText: engineStatusText,
            clientsText: clientsText,
            activityState: activityState,
            activityValue: activityValue,
            activityHistory: activityHistory,
            statusText: statusText,
            currentPowerMilliwatts: currentPowerMilliwatts,
            powerDeltaMilliwatts: powerDeltaMilliwatts,
            peakPowerMilliwatts: peakPowerMilliwatts,
            peakPowerWattsText: peakPowerWattsText,
            powerDeltaWattsText: powerDeltaWattsText,
            clientCount: clientCount,
            activitySeries: activitySeries,
            powerSeries: powerSeries,
            latestStatusSnapshot: latestStatusSnapshot,
            latestSnapshot: latestSnapshot
        )
    }

    public func applyRemoteSnapshot(_ snapshot: ANEStatsSamplerLiveSnapshot) {
        coreCountText = snapshot.coreCountText
        architectureText = snapshot.architectureText
        engineStatusText = snapshot.engineStatusText
        clientsText = snapshot.clientsText
        activityState = snapshot.activityState
        activityValue = snapshot.activityValue
        activityHistory = snapshot.activityHistory
        statusText = snapshot.statusText
        currentPowerMilliwatts = snapshot.currentPowerMilliwatts
        powerDeltaMilliwatts = snapshot.powerDeltaMilliwatts
        peakPowerMilliwatts = snapshot.peakPowerMilliwatts
        peakPowerWattsText = snapshot.peakPowerWattsText
        powerDeltaWattsText = snapshot.powerDeltaWattsText
        clientCount = snapshot.clientCount
        activitySeries = snapshot.activitySeries
        powerSeries = snapshot.powerSeries
        latestStatusSnapshot = snapshot.latestStatusSnapshot
        latestSnapshot = snapshot.latestSnapshot
    }
}
