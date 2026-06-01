import Foundation
import Combine
#if os(macOS)
import Darwin
import IOKit
import IOKit.ps
#endif
#if canImport(libproc)
import libproc
#else
// libproc symbols are available via Darwin on many SDKs; keep explicit import only if it compiles.
#endif

public enum PowerSampleStatus: String, Codable, Equatable, Sendable {
    case warmup
    case live
    case stale
    case unavailable
}

/// Sandbox-safe uptime + battery sampler.
/// - Uptime: ProcessInfo.systemUptime
/// - Battery %: IOPowerSources (laptop only)
/// - Cycle count: AppleSmartBattery IORegistry (laptop only)
public final class PowerStatsSampler: ObservableObject {
    public struct SystemSnapshot: Codable, Equatable, Sendable {
        public var uptimeSeconds: TimeInterval
        public var batteryPercent: Int?
        public var cycleCount: Int?
        public var processCount: Int?

        public init(
            uptimeSeconds: TimeInterval,
            batteryPercent: Int? = nil,
            cycleCount: Int? = nil,
            processCount: Int? = nil
        ) {
            self.uptimeSeconds = uptimeSeconds
            self.batteryPercent = batteryPercent
            self.cycleCount = cycleCount
            self.processCount = processCount
        }

        public var uptimeText: String {
            PowerStatsSampler.formatUptime(uptimeSeconds)
        }
    }

    public struct ReadingsSnapshot: Codable, Equatable, Sendable {
        public var cpuPowerWatts: Double?
        public var gpuPowerWatts: Double?
        public var anePowerWatts: Double?
        public var combinedPowerWatts: Double?
        public var peakCombinedPowerWatts: Double
        public var cumulativeCombinedEnergyWh: Double
        public var gpuFrequencyMHz: Double?
        public var perCoreFrequenciesHz: [Double]
        public var anePowerMilliwatts: Double?
        public var sampleStatus: PowerSampleStatus
        public var lastPowerSampleDate: Date?
        public var lastUsablePowerSampleDate: Date?
        public var source: String?
        public var failureReason: String?

        public init(
            cpuPowerWatts: Double? = nil,
            gpuPowerWatts: Double? = nil,
            anePowerWatts: Double? = nil,
            combinedPowerWatts: Double? = nil,
            peakCombinedPowerWatts: Double = 0,
            cumulativeCombinedEnergyWh: Double = 0,
            gpuFrequencyMHz: Double? = nil,
            perCoreFrequenciesHz: [Double] = [],
            anePowerMilliwatts: Double? = nil,
            sampleStatus: PowerSampleStatus = .warmup,
            lastPowerSampleDate: Date? = nil,
            lastUsablePowerSampleDate: Date? = nil,
            source: String? = nil,
            failureReason: String? = nil
        ) {
            self.cpuPowerWatts = cpuPowerWatts
            self.gpuPowerWatts = gpuPowerWatts
            self.anePowerWatts = anePowerWatts
            self.combinedPowerWatts = combinedPowerWatts
            self.peakCombinedPowerWatts = peakCombinedPowerWatts
            self.cumulativeCombinedEnergyWh = cumulativeCombinedEnergyWh
            self.gpuFrequencyMHz = gpuFrequencyMHz
            self.perCoreFrequenciesHz = perCoreFrequenciesHz
            self.anePowerMilliwatts = anePowerMilliwatts
            self.sampleStatus = sampleStatus
            self.lastPowerSampleDate = lastPowerSampleDate
            self.lastUsablePowerSampleDate = lastUsablePowerSampleDate
            self.source = source
            self.failureReason = failureReason
        }

        public var cpuPowerWattsText: String { Self.formatWatts(cpuPowerWatts) }
        public var gpuPowerWattsText: String { Self.formatWatts(gpuPowerWatts) }
        public var anePowerWattsText: String { Self.formatWatts(anePowerWatts) }
        public var combinedPowerWattsText: String { Self.formatWatts(combinedPowerWatts) }
        public var peakCombinedPowerWattsText: String { peakCombinedPowerWatts > 0 ? String(format: "%.3f W", peakCombinedPowerWatts) : "—" }
        public var cumulativeCombinedEnergyText: String { Self.formatEnergy(cumulativeCombinedEnergyWh) }
        public var gpuFrequencyMHzText: String { gpuFrequencyMHz.map { String(format: "%.0f MHz", $0) } ?? "—" }
        public var livePowerReadingsText: String {
            [
                "CPU \(cpuPowerWattsText)",
                "GPU \(gpuPowerWattsText)",
                "ANE \(anePowerWattsText)",
                "Combined \(combinedPowerWattsText)",
                "GPU \(gpuFrequencyMHzText)"
            ].joined(separator: "  ·  ")
        }

        private static func formatWatts(_ watts: Double?) -> String {
            watts.map { String(format: "%.3f W", $0) } ?? "—"
        }

        private static func formatEnergy(_ wattHours: Double) -> String {
            guard wattHours >= 0 else { return "—" }
            if wattHours < 1.0 {
                return String(format: "%.0f mWh", wattHours * 1000.0)
            }
            return String(format: "%.2f Wh", wattHours)
        }

        private enum CodingKeys: String, CodingKey {
            case cpuPowerWatts
            case gpuPowerWatts
            case anePowerWatts
            case combinedPowerWatts
            case peakCombinedPowerWatts
            case cumulativeCombinedEnergyWh
            case gpuFrequencyMHz
            case perCoreFrequenciesHz
            case anePowerMilliwatts
            case sampleStatus
            case lastPowerSampleDate
            case lastUsablePowerSampleDate
            case source
            case failureReason
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                cpuPowerWatts: try container.decodeIfPresent(Double.self, forKey: .cpuPowerWatts),
                gpuPowerWatts: try container.decodeIfPresent(Double.self, forKey: .gpuPowerWatts),
                anePowerWatts: try container.decodeIfPresent(Double.self, forKey: .anePowerWatts),
                combinedPowerWatts: try container.decodeIfPresent(Double.self, forKey: .combinedPowerWatts),
                peakCombinedPowerWatts: try container.decodeIfPresent(Double.self, forKey: .peakCombinedPowerWatts) ?? 0,
                cumulativeCombinedEnergyWh: try container.decodeIfPresent(Double.self, forKey: .cumulativeCombinedEnergyWh) ?? 0,
                gpuFrequencyMHz: try container.decodeIfPresent(Double.self, forKey: .gpuFrequencyMHz),
                perCoreFrequenciesHz: try container.decodeIfPresent([Double].self, forKey: .perCoreFrequenciesHz) ?? [],
                anePowerMilliwatts: try container.decodeIfPresent(Double.self, forKey: .anePowerMilliwatts),
                sampleStatus: try container.decodeIfPresent(PowerSampleStatus.self, forKey: .sampleStatus) ?? .live,
                lastPowerSampleDate: try container.decodeIfPresent(Date.self, forKey: .lastPowerSampleDate),
                lastUsablePowerSampleDate: try container.decodeIfPresent(Date.self, forKey: .lastUsablePowerSampleDate),
                source: try container.decodeIfPresent(String.self, forKey: .source),
                failureReason: try container.decodeIfPresent(String.self, forKey: .failureReason)
            )
        }
    }

    @Published public var uptimeText: String = "—"
    @Published public var batteryPercent: Int? = nil
    @Published public var cycleCount: Int? = nil
    @Published public var processCount: Int? = nil
    @Published public var cpuPowerWattsText: String = "—"
    @Published public var gpuPowerWattsText: String = "—"
    @Published public var anePowerWattsText: String = "—"
    @Published public var combinedPowerWattsText: String = "—"
    @Published public var peakCombinedPowerWattsText: String = "—"
    @Published public var cumulativeCombinedEnergyText: String = "—"
    @Published public var cumulativeCombinedEnergyWh: Double = 0
    @Published public var gpuFrequencyMHzText: String = "—"
    @Published public var perCoreFrequenciesHz: [Double] = []
    @Published public private(set) var perCoreFrequencySeries: [MetricSeries] = []
    @Published public var livePowerReadingsText: String = "—"
    @Published public var anePowerMilliwatts: Double? = nil
    @Published public private(set) var sampleStatus: PowerSampleStatus = .warmup
    @Published public private(set) var lastPowerSampleDate: Date? = nil
    @Published public private(set) var lastUsablePowerSampleDate: Date? = nil
    @Published public private(set) var powerSampleSource: String? = nil
    @Published public private(set) var powerSampleFailureReason: String? = nil
    @Published public private(set) var monitoringSessionStartDate: Date? = nil
    @Published public private(set) var cpuPowerSeries = PowerStatsSampler.makeSeries(for: .cpuPowerWatts, unit: .watts)
    @Published public private(set) var gpuPowerSeries = PowerStatsSampler.makeSeries(for: .gpuPowerWatts, unit: .watts)
    @Published public private(set) var anePowerSeries = PowerStatsSampler.makeSeries(for: .anePowerWatts, unit: .watts)
    @Published public private(set) var combinedPowerSeries = PowerStatsSampler.makeSeries(for: .combinedPowerWatts, unit: .watts)
    @Published public private(set) var cumulativeEnergySeries = PowerStatsSampler.makeSeries(for: .cumulativeCombinedEnergyWh, unit: .wattHours)
    @Published public private(set) var gpuFrequencySeries = PowerStatsSampler.makeSeries(for: .gpuFrequencyMHz, unit: .megahertz)
    @Published public private(set) var latestSystemSnapshot: SystemSnapshot? = nil
    @Published public private(set) var latestReadingsSnapshot: ReadingsSnapshot? = nil
    @Published public private(set) var latestSnapshot: HardwareSnapshot? = nil
    @Published public private(set) var hardwareAgentUptimeSeconds: TimeInterval? = nil

    #if os(macOS)
    private var timer: DispatchSourceTimer?
    private let samplingQueue = DispatchQueue(label: "PodcastPreview.PowerStatsSampler", qos: .utility)
    private var lastCombinedPowerSampleTime: Date?
    private var peakCombinedPowerWatts: Double = 0
    private var cpuPowerSeriesBuffer = PowerStatsSampler.makeSeries(for: .cpuPowerWatts, unit: .watts)
    private var gpuPowerSeriesBuffer = PowerStatsSampler.makeSeries(for: .gpuPowerWatts, unit: .watts)
    private var anePowerSeriesBuffer = PowerStatsSampler.makeSeries(for: .anePowerWatts, unit: .watts)
    private var combinedPowerSeriesBuffer = PowerStatsSampler.makeSeries(for: .combinedPowerWatts, unit: .watts)
    private var cumulativeEnergySeriesBuffer = PowerStatsSampler.makeSeries(for: .cumulativeCombinedEnergyWh, unit: .wattHours)
    private var gpuFrequencySeriesBuffer = PowerStatsSampler.makeSeries(for: .gpuFrequencyMHz, unit: .megahertz)
    private var perCoreFrequencySeriesBuffers: [MetricSeries] = []
    private var lastSystemSnapshotRefreshDate: Date?
    private var cachedBatteryPercent: Int?
    private var cachedCycleCount: Int?
    private var cachedProcessCount: Int?
    private var cachedHardwareAgentStartDate: Date?
    private var isFetchingLivePowerReadings = false
    private var monitoringSessionID = UUID()
    private var lastUsableLivePowerReadings: LivePowerReadings?
    private var lastUsableLivePowerReadingsDate: Date?
    #endif
    private let powerMetricsProvider: HardwarePowerMetricsProvider?

    private static var historyCapacity: Int {
        HardwareCollectionSettings.liveSeriesCapacity()
    }
    private static let systemSnapshotRefreshInterval: TimeInterval = 15
    private static let stalePowerDisplayWindow: TimeInterval = 600
    private static let maxPowerWatts: Double = 1_000
    private static let maxCPUFrequencyHz: Double = 10_000_000_000
    private static let maxGPUFrequencyHz: Double = 10_000_000_000

    public init(powerMetricsProvider: HardwarePowerMetricsProvider? = nil) {
        self.powerMetricsProvider = powerMetricsProvider
    }

    public func start() {
        #if os(macOS)
        initializeForExternalClock()

        let interval = HardwareCollectionSettings.collectorIntervalSeconds()
        let t = DispatchSource.makeTimerSource(queue: samplingQueue)
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
        #endif
    }

    public func initializeForExternalClock() {
        #if os(macOS)
        stop()
        lastCombinedPowerSampleTime = nil
        peakCombinedPowerWatts = 0
        cumulativeCombinedEnergyWh = 0
        cumulativeCombinedEnergyText = "—"
        peakCombinedPowerWattsText = "—"
        cpuPowerSeriesBuffer = Self.makeSeries(for: .cpuPowerWatts, unit: .watts)
        gpuPowerSeriesBuffer = Self.makeSeries(for: .gpuPowerWatts, unit: .watts)
        anePowerSeriesBuffer = Self.makeSeries(for: .anePowerWatts, unit: .watts)
        combinedPowerSeriesBuffer = Self.makeSeries(for: .combinedPowerWatts, unit: .watts)
        cumulativeEnergySeriesBuffer = Self.makeSeries(for: .cumulativeCombinedEnergyWh, unit: .wattHours)
        gpuFrequencySeriesBuffer = Self.makeSeries(for: .gpuFrequencyMHz, unit: .megahertz)
        perCoreFrequencySeriesBuffers = []
        lastSystemSnapshotRefreshDate = nil
        cachedBatteryPercent = nil
        cachedCycleCount = nil
        cachedProcessCount = nil
        cachedHardwareAgentStartDate = Self.readCurrentHardwareAgentStartDate()
        isFetchingLivePowerReadings = false
        lastUsableLivePowerReadings = nil
        lastUsableLivePowerReadingsDate = nil
        sampleStatus = .warmup
        lastPowerSampleDate = nil
        lastUsablePowerSampleDate = nil
        powerSampleSource = nil
        powerSampleFailureReason = nil
        monitoringSessionID = UUID()
        let now = Date()
        let sessionStartDate = cachedHardwareAgentStartDate ?? now
        let initialHardwareAgentUptimeSeconds = cachedHardwareAgentStartDate.map {
            max(0, now.timeIntervalSince($0))
        }
        hardwareAgentUptimeSeconds = initialHardwareAgentUptimeSeconds
        monitoringSessionStartDate = sessionStartDate
        DispatchQueue.main.async {
            self.monitoringSessionStartDate = sessionStartDate
            self.cpuPowerSeries = Self.makeSeries(for: .cpuPowerWatts, unit: .watts)
            self.gpuPowerSeries = Self.makeSeries(for: .gpuPowerWatts, unit: .watts)
            self.anePowerSeries = Self.makeSeries(for: .anePowerWatts, unit: .watts)
            self.combinedPowerSeries = Self.makeSeries(for: .combinedPowerWatts, unit: .watts)
            self.cumulativeEnergySeries = Self.makeSeries(for: .cumulativeCombinedEnergyWh, unit: .wattHours)
            self.gpuFrequencySeries = Self.makeSeries(for: .gpuFrequencyMHz, unit: .megahertz)
            self.perCoreFrequencySeries = []
            self.latestSystemSnapshot = nil
            self.latestReadingsSnapshot = nil
            self.latestSnapshot = nil
            self.sampleStatus = .warmup
            self.lastPowerSampleDate = nil
            self.lastUsablePowerSampleDate = nil
            self.powerSampleSource = nil
            self.powerSampleFailureReason = nil
            self.hardwareAgentUptimeSeconds = initialHardwareAgentUptimeSeconds
        }
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

    public func stop() {
        #if os(macOS)
        timer?.cancel()
        timer = nil
        isFetchingLivePowerReadings = false
        sampleStatus = .unavailable
        monitoringSessionID = UUID()
        monitoringSessionStartDate = nil
        hardwareAgentUptimeSeconds = nil
        #endif
    }

    private static func makeSeries(for key: HardwareMetricKey, unit: HardwareMetricUnit) -> MetricSeries {
        MetricSeries(key: key, unit: unit)
    }

    private static func makePerCoreFrequencySeries() -> MetricSeries {
        MetricSeries(key: .cpuCoreFrequencyMHz, unit: .megahertz)
    }

    #if os(macOS)
    private func sample() {
        let uptime = ProcessInfo.processInfo.systemUptime
        let now = Date()
        let shouldRefreshSystemSnapshot =
            lastSystemSnapshotRefreshDate.map { now.timeIntervalSince($0) >= Self.systemSnapshotRefreshInterval }
            ?? true

        if shouldRefreshSystemSnapshot {
            cachedBatteryPercent = Self.readBatteryPercent()
            cachedCycleCount = Self.readBatteryCycleCount()
            cachedProcessCount = Self.readProcessCount()
            cachedHardwareAgentStartDate = Self.readCurrentHardwareAgentStartDate()
            lastSystemSnapshotRefreshDate = now
        }

        let systemSnapshot = SystemSnapshot(
            uptimeSeconds: uptime,
            batteryPercent: cachedBatteryPercent,
            cycleCount: cachedCycleCount,
            processCount: cachedProcessCount
        )

        DispatchQueue.main.async {
            self.latestSystemSnapshot = systemSnapshot
            self.uptimeText = systemSnapshot.uptimeText
            self.batteryPercent = systemSnapshot.batteryPercent
            self.cycleCount = systemSnapshot.cycleCount
            self.processCount = systemSnapshot.processCount

            // Update hardware agent uptime
            if let startDate = self.cachedHardwareAgentStartDate {
                let agentUptime = now.timeIntervalSince(startDate)
                self.hardwareAgentUptimeSeconds = max(0, agentUptime)
                self.monitoringSessionStartDate = startDate
            } else {
                self.hardwareAgentUptimeSeconds = nil
            }
        }

        guard !isFetchingLivePowerReadings else { return }
        isFetchingLivePowerReadings = true
        let sessionID = monitoringSessionID

        readLivePowerReadings { [weak self] livePowerReadings in
            guard let self else { return }
            self.samplingQueue.async { [weak self] in
                self?.isFetchingLivePowerReadings = false
            }
            DispatchQueue.main.async {
                guard self.monitoringSessionID == sessionID else { return }
                let timestamp = Date()

                var displayReadings = livePowerReadings
                if livePowerReadings.hasUsableReadings {
                    displayReadings.sampleStatus = .live
                    displayReadings.lastPowerSampleDate = timestamp
                    displayReadings.lastUsablePowerSampleDate = timestamp
                    self.lastUsableLivePowerReadings = displayReadings
                    self.lastUsableLivePowerReadingsDate = timestamp
                } else if let lastUsableLivePowerReadings = self.lastUsableLivePowerReadings,
                          let lastUsableLivePowerReadingsDate = self.lastUsableLivePowerReadingsDate,
                          timestamp.timeIntervalSince(lastUsableLivePowerReadingsDate) <= Self.stalePowerDisplayWindow {
                    displayReadings = lastUsableLivePowerReadings.markedStale(
                        observedAt: timestamp,
                        lastUsableDate: lastUsableLivePowerReadingsDate,
                        failureReason: livePowerReadings.failureReason
                    )
                } else {
                    displayReadings = Self.unavailableReadings(
                        source: livePowerReadings.source,
                        reason: livePowerReadings.failureReason ?? "power-sample-unavailable",
                        lastPowerSampleDate: timestamp,
                        lastUsablePowerSampleDate: self.lastUsableLivePowerReadingsDate
                    )
                }

                let shouldRecordLivePower = displayReadings.sampleStatus == .live
                self.sampleStatus = displayReadings.sampleStatus
                self.lastPowerSampleDate = displayReadings.lastPowerSampleDate
                self.lastUsablePowerSampleDate = displayReadings.lastUsablePowerSampleDate
                self.powerSampleSource = displayReadings.source
                self.powerSampleFailureReason = displayReadings.failureReason

                self.cpuPowerWattsText = displayReadings.cpuPowerWattsText
                self.gpuPowerWattsText = displayReadings.gpuPowerWattsText
                self.anePowerWattsText = displayReadings.anePowerWattsText
                self.combinedPowerWattsText = displayReadings.combinedPowerWattsText
                if shouldRecordLivePower, let combinedPowerWatts = displayReadings.combinedPowerWattsValue {
                    self.peakCombinedPowerWatts = max(self.peakCombinedPowerWatts, combinedPowerWatts)
                    self.peakCombinedPowerWattsText = String(format: "%.3f W", self.peakCombinedPowerWatts)
                    if let lastSampleTime = self.lastCombinedPowerSampleTime {
                        let deltaSeconds = timestamp.timeIntervalSince(lastSampleTime)
                        if deltaSeconds > 0, deltaSeconds <= 10 {
                            self.cumulativeCombinedEnergyWh += (combinedPowerWatts * deltaSeconds) / 3600.0
                        }
                    }
                    self.lastCombinedPowerSampleTime = timestamp
                    self.cumulativeCombinedEnergyText = Self.formatEnergy(self.cumulativeCombinedEnergyWh)
                }
                self.gpuFrequencyMHzText = displayReadings.gpuFrequencyMHzText
                self.perCoreFrequenciesHz = displayReadings.perCoreFrequenciesHz
                self.livePowerReadingsText = displayReadings.summaryText
                self.anePowerMilliwatts = displayReadings.anePowerMilliwatts

                let targetCoreCount = max(self.perCoreFrequencySeriesBuffers.count, displayReadings.perCoreFrequenciesHz.count)
                if self.perCoreFrequencySeriesBuffers.count != targetCoreCount {
                    var rebuilt = (0..<targetCoreCount).map { _ in Self.makePerCoreFrequencySeries() }
                    let reusableCount = min(self.perCoreFrequencySeriesBuffers.count, rebuilt.count)
                    if reusableCount > 0 {
                        for index in 0..<reusableCount {
                            rebuilt[index] = self.perCoreFrequencySeriesBuffers[index]
                        }
                    }
                    self.perCoreFrequencySeriesBuffers = rebuilt
                }

                for index in self.perCoreFrequencySeriesBuffers.indices {
                    let mhzValue = shouldRecordLivePower && index < displayReadings.perCoreFrequenciesHz.count
                        ? displayReadings.perCoreFrequenciesHz[index] / 1_000_000.0
                        : nil
                    self.perCoreFrequencySeriesBuffers[index].append(
                        mhzValue,
                        at: timestamp,
                        capacity: Self.historyCapacity
                    )
                }

                self.cpuPowerSeriesBuffer.append(shouldRecordLivePower ? displayReadings.cpuPowerWattsValue : nil, at: timestamp, capacity: Self.historyCapacity)
                self.gpuPowerSeriesBuffer.append(shouldRecordLivePower ? displayReadings.gpuPowerWattsValue : nil, at: timestamp, capacity: Self.historyCapacity)
                self.anePowerSeriesBuffer.append(shouldRecordLivePower ? displayReadings.anePowerWattsValue : nil, at: timestamp, capacity: Self.historyCapacity)
                self.combinedPowerSeriesBuffer.append(shouldRecordLivePower ? displayReadings.combinedPowerWattsValue : nil, at: timestamp, capacity: Self.historyCapacity)
                self.cumulativeEnergySeriesBuffer.append(
                    shouldRecordLivePower && (displayReadings.combinedPowerWattsValue != nil || self.cumulativeCombinedEnergyWh > 0)
                        ? self.cumulativeCombinedEnergyWh
                        : nil,
                    at: timestamp,
                    capacity: Self.historyCapacity
                )
                self.gpuFrequencySeriesBuffer.append(shouldRecordLivePower ? displayReadings.gpuFrequencyMHzValue : nil, at: timestamp, capacity: Self.historyCapacity)

                self.cpuPowerSeries = self.cpuPowerSeriesBuffer
                self.gpuPowerSeries = self.gpuPowerSeriesBuffer
                self.anePowerSeries = self.anePowerSeriesBuffer
                self.combinedPowerSeries = self.combinedPowerSeriesBuffer
                self.cumulativeEnergySeries = self.cumulativeEnergySeriesBuffer
                self.gpuFrequencySeries = self.gpuFrequencySeriesBuffer
                self.perCoreFrequencySeries = self.perCoreFrequencySeriesBuffers

                var snapshot = HardwareSnapshot(timestamp: timestamp)
                snapshot.setMetric(.systemUptimeSeconds, value: systemSnapshot.uptimeSeconds)
                if shouldRecordLivePower, let cpuPowerWatts = displayReadings.cpuPowerWattsValue {
                    snapshot.setMetric(.cpuPowerWatts, value: cpuPowerWatts)
                }
                if shouldRecordLivePower, let gpuPowerWatts = displayReadings.gpuPowerWattsValue {
                    snapshot.setMetric(.gpuPowerWatts, value: gpuPowerWatts)
                }
                if shouldRecordLivePower, let anePowerWatts = displayReadings.anePowerWattsValue {
                    snapshot.setMetric(.anePowerWatts, value: anePowerWatts)
                }
                if shouldRecordLivePower, let combinedPowerWatts = displayReadings.combinedPowerWattsValue {
                    snapshot.setMetric(.combinedPowerWatts, value: combinedPowerWatts)
                }
                if shouldRecordLivePower && (self.cumulativeCombinedEnergyWh > 0 || displayReadings.combinedPowerWattsValue != nil) {
                    snapshot.setMetric(.cumulativeCombinedEnergyWh, value: self.cumulativeCombinedEnergyWh)
                }
                if shouldRecordLivePower, let gpuFrequencyMHz = displayReadings.gpuFrequencyMHzValue {
                    snapshot.setMetric(.gpuFrequencyMHz, value: gpuFrequencyMHz)
                }
                let readingsSnapshot = ReadingsSnapshot(
                    cpuPowerWatts: displayReadings.cpuPowerWattsValue,
                    gpuPowerWatts: displayReadings.gpuPowerWattsValue,
                    anePowerWatts: displayReadings.anePowerWattsValue,
                    combinedPowerWatts: displayReadings.combinedPowerWattsValue,
                    peakCombinedPowerWatts: self.peakCombinedPowerWatts,
                    cumulativeCombinedEnergyWh: self.cumulativeCombinedEnergyWh,
                    gpuFrequencyMHz: displayReadings.gpuFrequencyMHzValue,
                    perCoreFrequenciesHz: displayReadings.perCoreFrequenciesHz,
                    anePowerMilliwatts: displayReadings.anePowerMilliwatts,
                    sampleStatus: displayReadings.sampleStatus,
                    lastPowerSampleDate: displayReadings.lastPowerSampleDate,
                    lastUsablePowerSampleDate: displayReadings.lastUsablePowerSampleDate,
                    source: displayReadings.source,
                    failureReason: displayReadings.failureReason
                )
                self.latestReadingsSnapshot = readingsSnapshot
                self.cpuPowerWattsText = readingsSnapshot.cpuPowerWattsText
                self.gpuPowerWattsText = readingsSnapshot.gpuPowerWattsText
                self.anePowerWattsText = readingsSnapshot.anePowerWattsText
                self.combinedPowerWattsText = readingsSnapshot.combinedPowerWattsText
                self.peakCombinedPowerWattsText = readingsSnapshot.peakCombinedPowerWattsText
                self.cumulativeCombinedEnergyText = readingsSnapshot.cumulativeCombinedEnergyText
                self.gpuFrequencyMHzText = readingsSnapshot.gpuFrequencyMHzText
                self.perCoreFrequenciesHz = readingsSnapshot.perCoreFrequenciesHz
                self.livePowerReadingsText = readingsSnapshot.livePowerReadingsText
                self.anePowerMilliwatts = readingsSnapshot.anePowerMilliwatts
                self.latestSnapshot = snapshot.isEmpty ? nil : snapshot
            }
        }
    }
    #endif

    public static func formatUptime(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let days = s / 86_400
        let hours = (s % 86_400) / 3_600
        let mins = (s % 3_600) / 60

        if days > 0 { return "\(days)d \(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    #if os(macOS)
    private static func readProcessCount() -> Int? {
        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytesNeeded > 0 else { return nil }

        let count = bytesNeeded / Int32(MemoryLayout<pid_t>.stride)
        var buffer = Array<pid_t>(repeating: 0, count: Int(count))

        let bytesFilled = buffer.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, raw.baseAddress, bytesNeeded)
        }
        guard bytesFilled > 0 else { return nil }

        let filledCount = Int(bytesFilled) / MemoryLayout<pid_t>.stride
        let nonZero = buffer.prefix(filledCount).filter { $0 != 0 }
        return nonZero.count
    }

    private static func readCurrentHardwareAgentStartDate() -> Date? {
        let currentPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard isHardwareAgentProcess(currentPID) else { return nil }
        return processStartDate(for: currentPID)
    }

    private static func isHardwareAgentProcess(_ pid: pid_t) -> Bool {
        guard let executableName = executableURL(for: pid)?.lastPathComponent else {
            return false
        }

        let knownExecutableNames: Set<String> = [
            HardwareMonitoringServiceConstants.modernHelperExecutableName,
            HardwareMonitoringServiceConstants.legacyHelperExecutableName,
            HardwareMonitoringServiceConstants.legacyLaunchAgentHelperExecutableName
        ]

        return knownExecutableNames.contains(executableName)
    }

    private static func executableURL(for pid: pid_t) -> URL? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: pathBuffer))
    }

    private static func processStartDate(for pid: pid_t) -> Date? {
        var bsdInfo = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, infoSize)
        guard result == infoSize else { return nil }

        let seconds = TimeInterval(bsdInfo.pbi_start_tvsec)
        let microseconds = TimeInterval(bsdInfo.pbi_start_tvusec) / 1_000_000.0
        return Date(timeIntervalSince1970: seconds + microseconds)
    }

    private static func readBatteryPercent() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let type = desc[kIOPSTypeKey as String] as? String,
               type != (kIOPSInternalBatteryType as String) {
                continue
            }

            let cur = (desc[kIOPSCurrentCapacityKey as String] as? NSNumber)?.intValue
            let maxCap = (desc[kIOPSMaxCapacityKey as String] as? NSNumber)?.intValue
            if let cur, let maxCap, maxCap > 0 {
                let pct = Int(round((Double(cur) / Double(maxCap)) * 100.0))
                return min(Swift.max(pct, 0), 100)
            }
        }

        return nil
    }

    private static func readBatteryCycleCount() -> Int? {
        let match = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMasterPortDefault, match)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        if let n = IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
            return n.intValue
        }

        return nil
    }

    private struct LivePowerReadings {
        var cpuPowerWattsValue: Double?
        var cpuPowerWattsText: String
        var gpuPowerWattsValue: Double?
        var gpuPowerWattsText: String
        var anePowerWattsValue: Double?
        var anePowerWattsText: String
        var combinedPowerWattsText: String
        var combinedPowerWattsValue: Double?
        var gpuFrequencyMHzText: String
        var gpuFrequencyMHzValue: Double?
        var perCoreFrequenciesHz: [Double]
        var summaryText: String
        var anePowerMilliwatts: Double?
        var sampleStatus: PowerSampleStatus
        var lastPowerSampleDate: Date?
        var lastUsablePowerSampleDate: Date?
        var source: String
        var failureReason: String?

        var hasUsableReadings: Bool {
            Self.hasUsableReadings(
                cpuPowerWatts: cpuPowerWattsValue,
                gpuPowerWatts: gpuPowerWattsValue,
                anePowerWatts: anePowerWattsValue,
                combinedPowerWatts: combinedPowerWattsValue,
                gpuFrequencyMHz: gpuFrequencyMHzValue,
                perCoreFrequenciesHz: perCoreFrequenciesHz
            )
        }

        static func hasUsableReadings(
            cpuPowerWatts: Double?,
            gpuPowerWatts: Double?,
            anePowerWatts: Double?,
            combinedPowerWatts: Double?,
            gpuFrequencyMHz: Double?,
            perCoreFrequenciesHz: [Double]
        ) -> Bool {
            [cpuPowerWatts, gpuPowerWatts, anePowerWatts, combinedPowerWatts]
                .compactMap { $0 }
                .contains { $0 > 0 }
                || (gpuFrequencyMHz ?? 0) > 0
                || perCoreFrequenciesHz.contains(where: { $0 > 0 })
        }

        func markedStale(
            observedAt date: Date,
            lastUsableDate: Date,
            failureReason: String?
        ) -> LivePowerReadings {
            var stale = self
            stale.sampleStatus = .stale
            stale.lastPowerSampleDate = date
            stale.lastUsablePowerSampleDate = lastUsableDate
            stale.failureReason = failureReason
            return stale
        }
    }

    private func readLivePowerReadings(completion: @escaping (LivePowerReadings) -> Void) {
        if #available(macOS 11.0, *), let powerMetricsProvider {
            powerMetricsProvider.fetchPowerMetricsSample { helperData in
                if let helperData,
                   let parsed = Self.parsePowerMetricsPlist(helperData, source: "PowerMetricsService") {
                    completion(parsed)
                    return
                }

                completion(Self.unavailableReadings(source: "PowerMetricsService", reason: "helper-unavailable-or-unusable"))
            }
        } else {
            if let directData = Self.readPowerMetricsPlistDataDirectly(),
               let parsed = Self.parsePowerMetricsPlist(directData, source: "powermetrics-direct") {
                completion(parsed)
            } else {
                completion(Self.unavailableReadings(source: "powermetrics-direct", reason: "direct-powermetrics-unavailable"))
            }
        }
    }

    private static func parsePowerMetricsPlist(_ data: Data, source: String = "PowerMetricsService") -> LivePowerReadings? {
        let normalizedData = data.trimmingTrailingNULBytes()
        guard let plist = try? PropertyListSerialization.propertyList(from: normalizedData, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        let processor = plist["processor"] as? [String: Any]
        let gpu = plist["gpu"] as? [String: Any]

        let cpuPowerMilliwatts: Double? = {
            if let power = Self.sanitizedPowerMilliwatts(processor?["cpu_power"]) {
                return power
            }
            if let packageWatts = Self.sanitizedPowerWatts(processor?["package_watts"]) {
                return packageWatts * 1000.0
            }
            return nil
        }()

        let gpuPowerMilliwatts = Self.sanitizedPowerMilliwatts(processor?["gpu_power"])
        let anePowerMilliwatts = Self.sanitizedPowerMilliwatts(processor?["ane_power"])

        let combinedPowerMilliwatts: Double? = {
            if let combined = Self.sanitizedPowerMilliwatts(processor?["combined_power"]) {
                return combined
            }
            if let packageWatts = Self.sanitizedPowerWatts(processor?["package_watts"]) {
                return packageWatts * 1000.0
            }
            let components = [cpuPowerMilliwatts, gpuPowerMilliwatts, anePowerMilliwatts].compactMap { $0 }
            if !components.isEmpty {
                let sum = components.reduce(0, +)
                return sanitizedPowerMilliwatts(sum)
            }
            return nil
        }()

        let gpuFrequencyMHz = Self.sanitizedFrequencyHz(gpu?["freq_hz"], maximumHz: maxGPUFrequencyHz)
            .map { $0 / 1_000_000.0 }

        let perCoreFrequenciesHz: [Double] = {
            if let values = processor?["per_core_frequencies_hz"] as? [Double] {
                let sanitized = values.map { Self.sanitizedFrequencyHz($0, maximumHz: maxCPUFrequencyHz) ?? 0.0 }
                return sanitized.contains(where: { $0 > 0 }) ? sanitized : []
            }
            if let values = processor?["per_core_frequencies_hz"] as? [NSNumber] {
                let sanitized = values.map { Self.sanitizedFrequencyHz($0, maximumHz: maxCPUFrequencyHz) ?? 0.0 }
                return sanitized.contains(where: { $0 > 0 }) ? sanitized : []
            }

            var frequencyByCPUIndex: [Int: Double] = [:]

            if let clusters = processor?["clusters"] as? [[String: Any]] {
                for cluster in clusters {
                    guard let cpus = cluster["cpus"] as? [[String: Any]] else { continue }
                    for cpu in cpus {
                        guard let cpuIndex = cpu["cpu"] as? Int else { continue }
                        if let freq = Self.sanitizedFrequencyHz(cpu["freq_hz"], maximumHz: maxCPUFrequencyHz) {
                            frequencyByCPUIndex[cpuIndex] = freq
                        }
                    }
                }
            } else if let packages = processor?["packages"] as? [[String: Any]] {
                for package in packages {
                    guard let cores = package["cores"] as? [[String: Any]] else { continue }
                    for core in cores {
                        guard let cpus = core["cpus"] as? [[String: Any]] else { continue }
                        for cpu in cpus {
                            guard let cpuIndex = cpu["cpu"] as? Int else { continue }
                            if let freq = Self.sanitizedFrequencyHz(cpu["freq_hz"], maximumHz: maxCPUFrequencyHz) {
                                frequencyByCPUIndex[cpuIndex] = freq
                            }
                        }
                    }
                }
            }

            guard let maxCPUIndex = frequencyByCPUIndex.keys.max() else {
                return []
            }

            let frequencies = (0...maxCPUIndex).map { frequencyByCPUIndex[$0] ?? 0.0 }
            return frequencies.contains(where: { $0 > 0 }) ? frequencies : []
        }()

        let cpuPowerWatts = cpuPowerMilliwatts.map { $0 / 1000.0 }
        let gpuPowerWatts = gpuPowerMilliwatts.map { $0 / 1000.0 }
        let anePowerWatts = anePowerMilliwatts.map { $0 / 1000.0 }
        let combinedPowerWatts = combinedPowerMilliwatts.map { $0 / 1000.0 }

        guard LivePowerReadings.hasUsableReadings(
            cpuPowerWatts: cpuPowerWatts,
            gpuPowerWatts: gpuPowerWatts,
            anePowerWatts: anePowerWatts,
            combinedPowerWatts: combinedPowerWatts,
            gpuFrequencyMHz: gpuFrequencyMHz,
            perCoreFrequenciesHz: perCoreFrequenciesHz
        ) else {
            return nil
        }

        let cpuText = cpuPowerWatts.map { String(format: "%.3f W", $0) } ?? "—"
        let gpuText = gpuPowerWatts.map { String(format: "%.3f W", $0) } ?? "—"
        let aneText = anePowerWatts.map { String(format: "%.3f W", $0) } ?? "—"
        let combinedText = combinedPowerWatts.map { String(format: "%.3f W", $0) } ?? "—"
        let gpuFreqText = gpuFrequencyMHz.map { String(format: "%.0f MHz", $0) } ?? "—"

        let summary = [
            "CPU \(cpuText)",
            "GPU \(gpuText)",
            "ANE \(aneText)",
            "Combined \(combinedText)",
            "GPU \(gpuFreqText)"
        ].joined(separator: "  ·  ")

        return LivePowerReadings(
            cpuPowerWattsValue: cpuPowerWatts,
            cpuPowerWattsText: cpuText,
            gpuPowerWattsValue: gpuPowerWatts,
            gpuPowerWattsText: gpuText,
            anePowerWattsValue: anePowerWatts,
            anePowerWattsText: aneText,
            combinedPowerWattsText: combinedText,
            combinedPowerWattsValue: combinedPowerWatts,
            gpuFrequencyMHzText: gpuFreqText,
            gpuFrequencyMHzValue: gpuFrequencyMHz,
            perCoreFrequenciesHz: perCoreFrequenciesHz,
            summaryText: summary,
            anePowerMilliwatts: anePowerMilliwatts,
            sampleStatus: .live,
            lastPowerSampleDate: Date(),
            lastUsablePowerSampleDate: Date(),
            source: source,
            failureReason: nil
        )
    }

    private static func unavailableReadings(
        source: String,
        reason: String,
        lastPowerSampleDate: Date? = Date(),
        lastUsablePowerSampleDate: Date? = nil
    ) -> LivePowerReadings {
        LivePowerReadings(
            cpuPowerWattsValue: nil,
            cpuPowerWattsText: "—",
            gpuPowerWattsValue: nil,
            gpuPowerWattsText: "—",
            anePowerWattsValue: nil,
            anePowerWattsText: "—",
            combinedPowerWattsText: "—",
            combinedPowerWattsValue: nil,
            gpuFrequencyMHzText: "—",
            gpuFrequencyMHzValue: nil,
            perCoreFrequenciesHz: [],
            summaryText: "Power: unavailable",
            anePowerMilliwatts: nil,
            sampleStatus: .unavailable,
            lastPowerSampleDate: lastPowerSampleDate,
            lastUsablePowerSampleDate: lastUsablePowerSampleDate,
            source: source,
            failureReason: reason
        )
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    private static func sanitizedPowerMilliwatts(_ value: Any?) -> Double? {
        guard let value = numericValue(value),
              value.isFinite,
              value >= 0 else { return nil }
        let watts = value / 1000.0
        guard watts <= maxPowerWatts else { return nil }
        return value
    }

    private static func sanitizedPowerWatts(_ value: Any?) -> Double? {
        guard let value = numericValue(value),
              value.isFinite,
              value >= 0,
              value <= maxPowerWatts else { return nil }
        return value
    }

    private static func sanitizedFrequencyHz(_ value: Any?, maximumHz: Double) -> Double? {
        guard let value = numericValue(value),
              value.isFinite,
              value >= 0,
              value <= maximumHz else { return nil }
        return value
    }

    private static func readPowerMetricsPlistDataDirectly() -> Data? {
        guard geteuid() == 0 else {
            return nil
        }

        var samplers = "cpu_power,gpu_power"

        #if arch(arm64)
        samplers += ",ane_power"
        #endif

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = [
            "--samplers", samplers,
            "-i", "1000",
            "-n", "1",
            "-f", "plist"
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()

            let timeoutTask = DispatchWorkItem { [weak process] in
                if process?.isRunning == true {
                    process?.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10.0, execute: timeoutTask)

            process.waitUntilExit()
            timeoutTask.cancel()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return data.isEmpty ? nil : data
    }
    #endif

    public static func hasUsableReadings(inPowerMetricsPayload data: Data) -> Bool {
        #if os(macOS)
        guard let parsed = parsePowerMetricsPlist(data) else {
            return false
        }

        return parsed.hasUsableReadings
        #else
        return false
        #endif
    }

    private static func formatEnergy(_ wattHours: Double) -> String {
        guard wattHours >= 0 else { return "—" }
        if wattHours < 1.0 {
            return String(format: "%.0f mWh", wattHours * 1000.0)
        }
        return String(format: "%.2f Wh", wattHours)
    }

    public static func formatCoreFrequency(_ hz: Double) -> String {
        guard hz > 0 else { return "—" }
        return String(format: "%.2f GHz", hz / 1_000_000_000.0)
    }
}

extension PowerStatsSampler {
    public var liveSnapshot: PowerStatsSamplerLiveSnapshot {
        PowerStatsSamplerLiveSnapshot(
            uptimeText: uptimeText,
            batteryPercent: batteryPercent,
            cycleCount: cycleCount,
            processCount: processCount,
            cpuPowerWattsText: cpuPowerWattsText,
            gpuPowerWattsText: gpuPowerWattsText,
            anePowerWattsText: anePowerWattsText,
            combinedPowerWattsText: combinedPowerWattsText,
            peakCombinedPowerWattsText: peakCombinedPowerWattsText,
            cumulativeCombinedEnergyText: cumulativeCombinedEnergyText,
            cumulativeCombinedEnergyWh: cumulativeCombinedEnergyWh,
            gpuFrequencyMHzText: gpuFrequencyMHzText,
            perCoreFrequenciesHz: perCoreFrequenciesHz,
            perCoreFrequencySeries: perCoreFrequencySeries,
            livePowerReadingsText: livePowerReadingsText,
            anePowerMilliwatts: anePowerMilliwatts,
            sampleStatus: sampleStatus,
            lastPowerSampleDate: lastPowerSampleDate,
            lastUsablePowerSampleDate: lastUsablePowerSampleDate,
            source: powerSampleSource,
            failureReason: powerSampleFailureReason,
            latestSystemSnapshot: latestSystemSnapshot,
            latestReadingsSnapshot: latestReadingsSnapshot,
            cpuPowerSeries: cpuPowerSeries,
            gpuPowerSeries: gpuPowerSeries,
            anePowerSeries: anePowerSeries,
            combinedPowerSeries: combinedPowerSeries,
            cumulativeEnergySeries: cumulativeEnergySeries,
            gpuFrequencySeries: gpuFrequencySeries,
            latestSnapshot: latestSnapshot,
            monitoringSessionStartDate: monitoringSessionStartDate,
            hardwareAgentUptimeSeconds: hardwareAgentUptimeSeconds
        )
    }

    public func applyRemoteSnapshot(_ snapshot: PowerStatsSamplerLiveSnapshot) {
        uptimeText = snapshot.uptimeText
        batteryPercent = snapshot.batteryPercent
        cycleCount = snapshot.cycleCount
        processCount = snapshot.processCount
        cpuPowerWattsText = snapshot.cpuPowerWattsText
        gpuPowerWattsText = snapshot.gpuPowerWattsText
        anePowerWattsText = snapshot.anePowerWattsText
        combinedPowerWattsText = snapshot.combinedPowerWattsText
        peakCombinedPowerWattsText = snapshot.peakCombinedPowerWattsText
        cumulativeCombinedEnergyText = snapshot.cumulativeCombinedEnergyText
        cumulativeCombinedEnergyWh = snapshot.cumulativeCombinedEnergyWh
        gpuFrequencyMHzText = snapshot.gpuFrequencyMHzText
        perCoreFrequenciesHz = snapshot.perCoreFrequenciesHz
        perCoreFrequencySeries = snapshot.perCoreFrequencySeries
        livePowerReadingsText = snapshot.livePowerReadingsText
        anePowerMilliwatts = snapshot.anePowerMilliwatts
        sampleStatus = snapshot.sampleStatus
        lastPowerSampleDate = snapshot.lastPowerSampleDate
        lastUsablePowerSampleDate = snapshot.lastUsablePowerSampleDate
        powerSampleSource = snapshot.source
        powerSampleFailureReason = snapshot.failureReason
        latestSystemSnapshot = snapshot.latestSystemSnapshot
        latestReadingsSnapshot = snapshot.latestReadingsSnapshot
        cpuPowerSeries = snapshot.cpuPowerSeries
        gpuPowerSeries = snapshot.gpuPowerSeries
        anePowerSeries = snapshot.anePowerSeries
        combinedPowerSeries = snapshot.combinedPowerSeries
        cumulativeEnergySeries = snapshot.cumulativeEnergySeries
        gpuFrequencySeries = snapshot.gpuFrequencySeries
        latestSnapshot = snapshot.latestSnapshot
        hardwareAgentUptimeSeconds = snapshot.hardwareAgentUptimeSeconds

        if let agentUptime = snapshot.hardwareAgentUptimeSeconds, agentUptime > 0 {
            monitoringSessionStartDate = Date().addingTimeInterval(-agentUptime)
        } else {
            monitoringSessionStartDate = snapshot.monitoringSessionStartDate
        }
    }
}

#if DEBUG
extension PowerStatsSampler {
    static func _testReadingsSnapshot(fromPowerMetricsPayload data: Data, source: String = "test") -> ReadingsSnapshot? {
        guard let readings = parsePowerMetricsPlist(data, source: source) else {
            return nil
        }
        return ReadingsSnapshot(
            cpuPowerWatts: readings.cpuPowerWattsValue,
            gpuPowerWatts: readings.gpuPowerWattsValue,
            anePowerWatts: readings.anePowerWattsValue,
            combinedPowerWatts: readings.combinedPowerWattsValue,
            gpuFrequencyMHz: readings.gpuFrequencyMHzValue,
            perCoreFrequenciesHz: readings.perCoreFrequenciesHz,
            anePowerMilliwatts: readings.anePowerMilliwatts,
            sampleStatus: readings.sampleStatus,
            lastPowerSampleDate: readings.lastPowerSampleDate,
            lastUsablePowerSampleDate: readings.lastUsablePowerSampleDate,
            source: readings.source,
            failureReason: readings.failureReason
        )
    }
}
#endif

private extension Data {
    func trimmingTrailingNULBytes() -> Data {
        var endIndex = count
        while endIndex > 0, self[endIndex - 1] == 0 {
            endIndex -= 1
        }
        guard endIndex < count else { return self }
        return Data(prefix(endIndex))
    }
}
