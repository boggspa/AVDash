import Foundation
import Combine

/// Thermal pressure sampler.
///
/// **Apple Silicon / universal:** uses `ProcessInfo.thermalState` which the OS
/// updates whenever the SoC thermal management policy escalates or de-escalates.
///
/// **Intel supplement:** also reads `machdep.xcpm.cpu_thermal_level` (Intel XCPM —
/// Xeon CPU Power Management) as an additional thermal-pressure style signal.
/// On the Intel Macs observed here, `0` is nominal and higher values reflect
/// increasing pressure, so we normalise it directly instead of inverting it.
/// The graph uses the higher of the OS thermal state and the Intel pressure
/// signal so it stays responsive without showing the previous false 100% trace.
///
/// Intel XCPM signals consulted when available:
///   `machdep.xcpm.gpu_thermal_level`  — integrated GPU thermal throttle
///   `machdep.xcpm.io_thermal_level`   — I/O thermal throttle
public final class ThermalStatsSampler: ObservableObject {
    @Published public var thermalValue: Float? = nil
    @Published public var thermalLabel: String = "—"
    @Published public var thermalHistory: [Float] = []
    @Published public private(set) var thermalSeries = ThermalStatsSampler.makeThermalSeries()
    @Published public private(set) var latestSnapshot: HardwareSnapshot? = nil

    private var timer: DispatchSourceTimer?
    private var thermalSeriesBuffer = ThermalStatsSampler.makeThermalSeries()

    private static var historyCapacity: Int {
        HardwareCollectionSettings.liveSeriesCapacity()
    }

    public init() {}

    /// Resets state and runs an initial sample without creating a timer.
    /// Use when an external coordinator will call ``sample()`` on a shared cadence.
    public func initialize() {
        stop()
        thermalSeriesBuffer = Self.makeThermalSeries()
        DispatchQueue.main.async {
            self.thermalHistory = []
            self.thermalSeries = Self.makeThermalSeries()
            self.latestSnapshot = nil
        }
        sample()
    }

    /// Resets state, runs an initial sample, and starts an internal timer.
    /// Use for standalone operation; not needed when driven by a central timer.
    public func start() {
        initialize()

        let interval = HardwareCollectionSettings.collectorIntervalSeconds()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
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

    private static func makeThermalSeries() -> MetricSeries {
        MetricSeries(key: .thermalLevel, unit: .ratio)
    }

    // MARK: - Intel XCPM supplement

#if arch(x86_64)
    private static func readXCPMThermalLevel(named name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return Int(max(0, min(100, value)))
    }

    private static func readIntelThermalLevels() -> [String: Int] {
        [
            "CPU": readXCPMThermalLevel(named: "machdep.xcpm.cpu_thermal_level"),
            "GPU": readXCPMThermalLevel(named: "machdep.xcpm.gpu_thermal_level"),
            "I/O": readXCPMThermalLevel(named: "machdep.xcpm.io_thermal_level")
        ].compactMapValues { $0 }
    }
#endif

    // MARK: - Sampling

    func sample() {
        let timestamp = Date()
        let state = ProcessInfo.processInfo.thermalState

        // Map ProcessInfo state → normalised [0, 1]
        let stateLabel: String
        let stateValue: Float
        switch state {
        case .nominal:       (stateLabel, stateValue) = ("Nominal",  0.0)
        case .fair:          (stateLabel, stateValue) = ("Fair",     0.33)
        case .serious:       (stateLabel, stateValue) = ("Serious",  0.66)
        case .critical:      (stateLabel, stateValue) = ("Critical", 1.0)
        @unknown default:    (stateLabel, stateValue) = ("Unknown",  0.0)
        }

        var thermalValue = stateValue
        var thermalLabel = stateLabel

#if arch(x86_64)
        // On Intel, layer in the highest XCPM thermal level we can read.
        // These values behave like direct pressure levels on affected Macs,
        // so 0 stays cool/nominal and higher values indicate more pressure.
        let intelThermalLevels = Self.readIntelThermalLevels()
        if let hottest = intelThermalLevels.max(by: { $0.value < $1.value }) {
            let intelThermalValue = Float(hottest.value) / 100.0
            thermalValue = max(thermalValue, intelThermalValue)

            if hottest.value > 0 {
                thermalLabel = "\(stateLabel) · \(hottest.key) thermal \(hottest.value)%"
            }
        }
#endif

        thermalSeriesBuffer.append(Double(thermalValue), at: timestamp, capacity: Self.historyCapacity)
        let series = thermalSeriesBuffer

        var snapshot = HardwareSnapshot(timestamp: timestamp)
        snapshot.setMetric(.thermalLevel, value: Double(thermalValue))
        snapshot.setDimension(.thermalState, value: thermalLabel)

        DispatchQueue.main.async {
            self.latestSnapshot = snapshot
            self.thermalSeries = series
            self.thermalValue = Float(series.latestObservedValue ?? Double(thermalValue))
            self.thermalLabel = snapshot.dimension(.thermalState) ?? thermalLabel
            self.thermalHistory = series.values().map(Float.init)
        }
    }
}

extension ThermalStatsSampler {
    public var liveSnapshot: ThermalStatsSamplerLiveSnapshot {
        ThermalStatsSamplerLiveSnapshot(
            thermalValue: thermalValue,
            thermalLabel: thermalLabel,
            thermalHistory: thermalHistory,
            thermalSeries: thermalSeries,
            latestSnapshot: latestSnapshot
        )
    }

    public func applyRemoteSnapshot(_ snapshot: ThermalStatsSamplerLiveSnapshot) {
        thermalValue = snapshot.thermalValue
        thermalLabel = snapshot.thermalLabel
        thermalHistory = snapshot.thermalHistory
        thermalSeries = snapshot.thermalSeries
        latestSnapshot = snapshot.latestSnapshot
    }
}
