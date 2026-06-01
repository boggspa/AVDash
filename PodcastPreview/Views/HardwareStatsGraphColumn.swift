import SwiftUI
import PodcastPreviewShared
import Combine
import PodcastPreviewCore

private final class HardwareGraphLiveBucketCache: ObservableObject {
    private struct Entry {
        let signature: Int
        let values: [Double?]
    }

    private var entries: [String: Entry] = [:]
    private let maximumEntryCount = 96

    func values(
        cacheKey: String,
        samples: [MetricSample],
        range: DateInterval,
        bucketIntervalSeconds: Int,
        aggregation: MetricBucketAggregation,
        build: () -> [Double?]
    ) -> [Double?] {
        let signature = signature(
            samples: samples,
            range: range,
            bucketIntervalSeconds: bucketIntervalSeconds,
            aggregation: aggregation
        )
        if let entry = entries[cacheKey], entry.signature == signature {
            return entry.values
        }

        let values = build()
        entries[cacheKey] = Entry(signature: signature, values: values)
        if entries.count > maximumEntryCount {
            entries.removeValue(forKey: entries.keys.first ?? cacheKey)
        }
        return values
    }

    private func signature(
        samples: [MetricSample],
        range: DateInterval,
        bucketIntervalSeconds: Int,
        aggregation: MetricBucketAggregation
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(samples.count)
        hasher.combine(Int(range.start.timeIntervalSinceReferenceDate.rounded()))
        hasher.combine(Int(range.end.timeIntervalSinceReferenceDate.rounded()))
        hasher.combine(bucketIntervalSeconds)
        hasher.combine(String(describing: aggregation))
        if let latestSample = samples.last {
            hasher.combine(Int(latestSample.timestamp.timeIntervalSinceReferenceDate.rounded()))
            hasher.combine(latestSample.value.map { Int(($0 * 10_000).rounded()) } ?? Int.min)
        }
        return hasher.finalize()
    }
}

struct HardwareStatsGraphColumn: View {
    @Environment(\.appUIScale) private var appUIScale
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("graphSectionCollapsed_cpu") private var cpuSectionCollapsed = false
    @AppStorage("graphSectionCollapsed_gpu") private var gpuSectionCollapsed = false
    @AppStorage("graphSectionCollapsed_memory") private var memorySectionCollapsed = false
    @AppStorage("graphSectionCollapsed_disk") private var diskSectionCollapsed = false
    @AppStorage("graphSectionCollapsed_network") private var networkSectionCollapsed = false
    @AppStorage("graphSectionCollapsed_system") private var systemSectionCollapsed = false
    @StateObject private var historyBackfillStore = HardwareGraphHistoryBackfillStore()
    @StateObject private var liveBucketCache = HardwareGraphLiveBucketCache()
    @State private var networkSettingsActionID: String?
    @State private var graphRefreshDate = Date()
    @AppStorage("networkPingIntervalSeconds") private var selectedPingInterval = 300
    @AppStorage("networkPingTarget") private var customPingTarget = ""
    let historyReader: any HardwareHistoryQuerying
    @ObservedObject var cpuSampler: CPUStatsSampler
    @ObservedObject var thermalSampler: ThermalStatsSampler
    @ObservedObject var gpuSampler: GPUStatsSampler
    @ObservedObject var gpuIdentityProber: GPUIdentityProber
    @ObservedObject var ramSampler: RAMStatsSampler
    @ObservedObject var memoryIdentityProber: MemoryIdentityProber
    @ObservedObject var aneSampler: ANEStatsSampler
    @ObservedObject var diskIOSampler: DiskIOSampler
    @ObservedObject var networkSampler: NetworkStatsSampler
    @ObservedObject var networkInterfaceSampler: NetworkInterfaceSampler
    @ObservedObject var mediaEngineSampler: MediaEngineStatsSampler
    @ObservedObject var powerSampler: PowerStatsSampler

    @Binding var graphWindowSeconds: Int
    @Binding var graphDisplayIntervalSeconds: Int
    @Binding var compactLayout: Bool
    @Binding var sidebarVisible: Bool
    @Binding var hiddenCPU: Bool
    @Binding var hiddenEfficiencyCores: Bool
    @Binding var hiddenPerformanceCores: Bool
    @Binding var hiddenGPUEmpty: Bool
    @Binding var hiddenGPUs: [String: Bool]
    @Binding var hiddenGPURenderer: [String: Bool]
    @State private var mediaEngineHistory: [Float] = []
    @Binding var hiddenGPUTiler: [String: Bool]
    @Binding var hiddenRAM: Bool
    @Binding var hiddenMemoryPressure: Bool
    @Binding var hiddenSwap: Bool
    @Binding var hiddenDiskRead: Bool
    @Binding var hiddenDiskWrite: Bool
    @Binding var hiddenNetworkUpload: Bool
    @Binding var hiddenNetworkDownload: Bool
    @Binding var hiddenANE: Bool
    @Binding var hiddenMediaEngine: Bool
    @Binding var hiddenThermals: Bool
    @Binding var hiddenEnergy: Bool
    var floatingSource: FloatingMonitorCardSource? = nil
    var onFocusGraph: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedGraphChange: ((HardwareGraphFocusState) -> Void)? = nil

    private var graphDisplayAnchor: Date {
        let refreshReferenceDate = graphRefreshDate
        let timestamps =
            [
                cpuSampler.latestSnapshot?.timestamp,
                thermalSampler.latestSnapshot?.timestamp,
                ramSampler.latestSnapshot?.timestamp,
                aneSampler.latestSnapshot?.timestamp,
                diskIOSampler.latestSnapshot?.timestamp,
                networkSampler.latestSnapshot?.timestamp,
                powerSampler.latestSnapshot?.timestamp,
                mediaEngineSampler.latestSnapshot?.timestamp
            ].compactMap { $0 }
            + gpuSampler.latestDeviceSnapshots.map(\.timestamp)
        let latestTimestamp = timestamps.max() ?? refreshReferenceDate
        return alignedGraphBucketUpperBound(
            for: latestTimestamp,
            bucketIntervalSeconds: max(1, graphDisplayIntervalSeconds)
        )
    }
    private var graphDisplayRange: DateInterval {
        DateInterval(
            start: graphDisplayAnchor.addingTimeInterval(-TimeInterval(max(1, graphWindowSeconds))),
            end: graphDisplayAnchor
        )
    }
    private var historyBackfillTaskID: String {
        // Persisted history is stored at minute-or-coarser buckets. Refreshing
        // backfill every live tick creates overlapping database work while the
        // in-memory sampler is already keeping the visible graph current.
        let refreshInterval = TimeInterval(max(60, graphDisplayIntervalSeconds))
        let anchorToken = Int(graphDisplayAnchor.timeIntervalSinceReferenceDate / refreshInterval)
        let gpuIDs = gpuSampler.gpus.map(\.id).sorted().joined(separator: "|")
        return "\(graphWindowSeconds)-\(graphDisplayIntervalSeconds)-\(anchorToken)-\(gpuIDs)"
    }
    private var longHorizonHistoryRefreshToken: String {
        let minuteToken = Int(graphDisplayAnchor.timeIntervalSinceReferenceDate / 60)
        let gpuIDs = gpuSampler.gpus.map(\.id).sorted().joined(separator: "|")
        return "\(minuteToken)-\(gpuIDs)-\(aneSampler.hasNeuralEngine ? "ane" : "no-ane")"
    }
    private var ramSnapshot: RAMStatsSampler.MemorySnapshot? { ramSampler.latestMemorySnapshot }
    private var aneStatusSnapshot: ANEStatsSampler.StatusSnapshot? { aneSampler.latestStatusSnapshot }
    private var powerReadingsSnapshot: PowerStatsSampler.ReadingsSnapshot? { powerSampler.latestReadingsSnapshot }
    private var shouldShowMediaEngineUsageCard: Bool { mediaEngineSampler.shouldShowCard }
    private var networkFocusLinePanels: [HardwareGraphFocusLinePanelSnapshot] {
        [
            networkPingLatencyLinePanel,
            networkPacketLossLinePanel
        ].compactMap { $0 }
    }
    private var isRemoteContext: Bool {
        switch floatingSource {
        case .some(.remote(_)):
            return true
        default:
            return false
        }
    }
    private var panelBackgroundFill: Color {
        GraphiteSlateTheme.cardFill
    }

    private var graphRefreshTimer: Publishers.Autoconnect<Timer.TimerPublisher> {
        Timer.publish(
            every: TimeInterval(max(1, graphDisplayIntervalSeconds)),
            on: .main,
            in: .common
        ).autoconnect()
    }

    private func alignedGraphBucketUpperBound(
        for timestamp: Date,
        bucketIntervalSeconds: Int
    ) -> Date {
        let interval = TimeInterval(max(1, bucketIntervalSeconds))
        let rawBoundary = (timestamp.timeIntervalSinceReferenceDate / interval).rounded(.up) * interval
        return Date(timeIntervalSinceReferenceDate: rawBoundary)
    }

    private func displayHistory(
        from series: MetricSeries,
        aggregation: MetricBucketAggregation = .average,
        mapValue: (Double) -> Float = { Float($0) }
    ) -> [Float] {
        let liveValues = liveBucketCache.values(
            cacheKey: "metric:\(series.key.rawValue)",
            samples: series.samples,
            range: graphDisplayRange,
            bucketIntervalSeconds: max(1, graphDisplayIntervalSeconds),
            aggregation: aggregation
        ) {
            alignedLiveValuesUncached(
                from: series.samples,
                in: graphDisplayRange,
                bucketIntervalSeconds: max(1, graphDisplayIntervalSeconds),
                aggregation: aggregation
            )
        }
        let historyValues = historyBackfillStore.alignedMetricValues(
            for: series.key,
            in: graphDisplayRange,
            bucketIntervalSeconds: max(1, graphDisplayIntervalSeconds),
            aggregation: aggregation
        )
        return mergedDisplayValues(
            persisted: historyValues,
            live: liveValues,
            mapValue: mapValue
        )
    }

    private func displayHistory(
        from series: HardwareDeviceMetricSeries?,
        aggregation: MetricBucketAggregation = .average,
        mapValue: (Double) -> Float = { Float($0) }
    ) -> [Float] {
        guard let series else { return [] }
        let liveValues = liveBucketCache.values(
            cacheKey: "device:\(series.deviceKind.rawValue):\(series.deviceID):\(series.key.rawValue)",
            samples: series.samples,
            range: graphDisplayRange,
            bucketIntervalSeconds: max(1, graphDisplayIntervalSeconds),
            aggregation: aggregation
        ) {
            alignedLiveValuesUncached(
                from: series.samples,
                in: graphDisplayRange,
                bucketIntervalSeconds: max(1, graphDisplayIntervalSeconds),
                aggregation: aggregation
            )
        }
        let historyValues = historyBackfillStore.alignedDeviceValues(
            for: series.key,
            deviceID: series.deviceID,
            deviceKind: series.deviceKind,
            in: graphDisplayRange,
            bucketIntervalSeconds: max(1, graphDisplayIntervalSeconds),
            aggregation: aggregation
        )
        return mergedDisplayValues(
            persisted: historyValues,
            live: liveValues,
            mapValue: mapValue
        )
    }

    private func mergedDisplayValues(
        persisted: [Double?],
        live: [Double?],
        mapValue: (Double) -> Float
    ) -> [Float] {
        let count = max(persisted.count, live.count)
        guard count > 0 else { return [] }

        let values = (0..<count).map { index -> Double? in
            let persistedValue = index < persisted.count ? persisted[index] : nil
            let liveValue = index < live.count ? live[index] : nil
            return liveValue ?? persistedValue
        }

        guard values.contains(where: { $0 != nil }) else { return [] }
        return values.map { mapValue($0 ?? 0) }
    }

    private func alignedLiveValuesUncached(
        from samples: [MetricSample],
        in range: DateInterval,
        bucketIntervalSeconds: Int,
        aggregation: MetricBucketAggregation
    ) -> [Double?] {
        let interval = TimeInterval(max(1, bucketIntervalSeconds))
        let bucketCount = max(1, Int(ceil(range.duration / interval)))
        struct Aggregate {
            var lastValue: Double?
            var maxValue: Double?
            var sum: Double = 0
            var count: Int = 0
        }
        var aggregates = Array<Aggregate?>(repeating: nil, count: bucketCount)

        for sample in samples {
            guard sample.timestamp >= range.start, sample.timestamp <= range.end else { continue }
            guard let value = sample.value else { continue }

            let rawIndex = Int((sample.timestamp.timeIntervalSince(range.start)) / interval)
            let index = min(max(rawIndex, 0), bucketCount - 1)
            var aggregate = aggregates[index] ?? Aggregate()
            aggregate.lastValue = value
            aggregate.maxValue = max(aggregate.maxValue ?? value, value)
            aggregate.sum += value
            aggregate.count += 1
            aggregates[index] = aggregate
        }

        return aggregates.map { aggregate in
            guard let aggregate else { return nil }
            switch aggregation {
            case .latest:
                return aggregate.lastValue
            case .average:
                guard aggregate.count > 0 else { return nil }
                return aggregate.sum / Double(aggregate.count)
            case .maximum:
                return aggregate.maxValue
            @unknown default:
                return aggregate.lastValue
            }
        }
    }

    private func normalizedRateHistory(from series: MetricSeries, maxRate: Double) -> [Float] {
        displayHistory(from: series) { value in
            Float(min(max(value / maxRate, 0), 1))
        }
    }

    private var cpuScatterSnapshots: [HardwareGraphFocusScatterSnapshot] {
        [
            cpuPowerScatterSnapshot,
            cpuThermalScatterSnapshot
        ].compactMap { $0 }
    }

    private var powerScatterSnapshots: [HardwareGraphFocusScatterSnapshot] {
        [cpuPowerScatterSnapshot].compactMap { $0 }
    }

    private var pingIntervalDisplayText: String {
        formatPingInterval(selectedPingInterval > 0 ? selectedPingInterval : 300)
    }

    private var pingTargetDisplayText: String {
        customPingTarget.isEmpty ? "Router (auto)" : "Custom \(customPingTarget)"
    }

    @ViewBuilder
    private func floatingCardMenu<Content: View>(
        _ cardKind: FloatingMonitorCardKind,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let floatingSource {
            content().floatingMonitorContextMenu(cardKind: cardKind, source: floatingSource)
        } else {
            content()
        }
    }

    private var networkPingLatencyLinePanel: HardwareGraphFocusLinePanelSnapshot? {
        guard networkSampler.lastPingSampleDate != nil else { return nil }
        let history = displayHistory(from: networkSampler.pingLatencySeries) { value in
            Float(min(max(value / 200.0, 0.0), 1.0))
        }
        guard history.contains(where: { $0 > 0 }) else { return nil }

        return HardwareGraphFocusLinePanelSnapshot(
            id: "network-ping-latency",
            title: "Ping Latency",
            chipTitle: "RTT",
            subtitle: "Round-trip time from the current 30-minute network-quality probes.",
            detailText: "Uses \(networkSampler.pingTargetLabel.lowercased()) as the current probe target.",
            series: [
                HardwareGraphFocusSeries(
                    id: "network-ping-latency-series",
                    label: networkSampler.pingTargetLabel,
                    color: Color(red: 0.80, green: 0.58, blue: 0.22),
                    values: history.map { Optional(Double($0)) }
                )
            ]
        )
    }

    private var networkPacketLossLinePanel: HardwareGraphFocusLinePanelSnapshot? {
        guard networkSampler.lastPingSampleDate != nil else { return nil }
        let history = displayHistory(from: networkSampler.pingPacketLossSeries)
        guard history.contains(where: { $0 > 0 }) || !networkSampler.pingPacketLossSeries.samples.isEmpty else { return nil }

        return HardwareGraphFocusLinePanelSnapshot(
            id: "network-packet-loss",
            title: "Packet Loss",
            chipTitle: "Loss",
            subtitle: "Packet loss ratio from the same 30-minute network-quality probes.",
            detailText: "Loss stays at zero on a clean path and spikes quickly when the link, router, or upstream path misbehaves.",
            series: [
                HardwareGraphFocusSeries(
                    id: "network-packet-loss-series",
                    label: "Packet Loss",
                    color: Color(red: 0.92, green: 0.33, blue: 0.33),
                    values: history.map { Optional(Double($0)) }
                )
            ]
        )
    }

    private var cpuPowerScatterSnapshot: HardwareGraphFocusScatterSnapshot? {
        makeScatterSnapshot(
            id: "cpu-vs-power",
            title: "CPU vs Power",
            subtitle: "Visible display buckets of CPU load against combined system power.",
            accentColor: .orange,
            xAxisLabel: "CPU Usage",
            yAxisLabel: "Combined Power",
            xValues: displayHistory(from: cpuSampler.totalUsageSeries),
            yValues: displayHistory(from: powerSampler.combinedPowerSeries),
            xTransform: { $0 * 100.0 },
            yTransform: { $0 },
            xMaximumFloor: 100,
            yMaximumFloor: 1,
            xMinimumLabel: "0%",
            xMaximumLabel: "100%",
            yMinimumLabel: "0 W",
            yMaximumFormatter: { String(format: "%.1f W", $0) },
            detailText: "Upper-left outliers can hint at disproportionate power draw for relatively modest CPU activity."
        )
    }

    private var cpuThermalScatterSnapshot: HardwareGraphFocusScatterSnapshot? {
        makeScatterSnapshot(
            id: "cpu-vs-thermals",
            title: "CPU vs Thermals",
            subtitle: "CPU load against thermal pressure across the visible display window.",
            accentColor: Color(red: 0.02, green: 0.65, blue: 0.65),
            xAxisLabel: "CPU Usage",
            yAxisLabel: "Thermal Pressure",
            xValues: displayHistory(from: cpuSampler.totalUsageSeries),
            yValues: displayHistory(from: thermalSampler.thermalSeries, aggregation: .latest),
            xTransform: { $0 * 100.0 },
            yTransform: { $0 * 100.0 },
            xMaximumFloor: 100,
            yMaximumFloor: 100,
            xMinimumLabel: "0%",
            xMaximumLabel: "100%",
            yMinimumLabel: "0%",
            yMaximumFormatter: { _ in "100%" },
            detailText: "A shallow pattern here usually means the system stayed cool even when CPU usage climbed."
        )
    }

    private func makeScatterSnapshot(
        id: String,
        title: String,
        subtitle: String,
        accentColor: Color,
        xAxisLabel: String,
        yAxisLabel: String,
        xValues: [Float],
        yValues: [Float],
        xTransform: (Double) -> Double,
        yTransform: (Double) -> Double,
        xMaximumFloor: Double,
        yMaximumFloor: Double,
        xMinimumLabel: String,
        xMaximumLabel: String,
        yMinimumLabel: String,
        yMaximumFormatter: (Double) -> String,
        detailText: String
    ) -> HardwareGraphFocusScatterSnapshot? {
        let points = makeScatterPoints(
            xValues: xValues,
            yValues: yValues,
            xTransform: xTransform,
            yTransform: yTransform
        )
        guard points.count >= 4 else { return nil }

        let xMaxObserved = points.map(\.x).max() ?? 0
        let yMaxObserved = points.map(\.y).max() ?? 0
        let xRange = 0.0...max(xMaximumFloor, xMaxObserved * 1.05)
        let yRange = 0.0...max(yMaximumFloor, yMaxObserved * 1.05)
        let correlationText = correlationCoefficient(for: points).map { correlation -> String in
            String(format: "r %.2f", correlation)
        }

        return HardwareGraphFocusScatterSnapshot(
            id: id,
            title: title,
            subtitle: subtitle,
            accentColor: accentColor,
            xAxisLabel: xAxisLabel,
            yAxisLabel: yAxisLabel,
            xMinimumLabel: xMinimumLabel,
            xMaximumLabel: xMaximumLabel,
            yMinimumLabel: yMinimumLabel,
            yMaximumLabel: yMaximumFormatter(yRange.upperBound),
            correlationLabel: correlationText,
            detailText: detailText,
            points: points,
            xRange: xRange,
            yRange: yRange
        )
    }

    private func makeScatterPoints(
        xValues: [Float],
        yValues: [Float],
        xTransform: (Double) -> Double,
        yTransform: (Double) -> Double
    ) -> [HardwareGraphFocusScatterPoint] {
        let count = min(xValues.count, yValues.count)
        guard count > 0 else { return [] }

        return (0..<count).compactMap { index in
            let x = xTransform(Double(xValues[index]))
            let y = yTransform(Double(yValues[index]))
            guard x.isFinite, y.isFinite else { return nil }
            return HardwareGraphFocusScatterPoint(
                id: index,
                x: x,
                y: y,
                emphasis: Double(index + 1) / Double(count)
            )
        }
    }

    private func correlationCoefficient(for points: [HardwareGraphFocusScatterPoint]) -> Double? {
        guard points.count >= 2 else { return nil }
        let xMean = points.map(\.x).reduce(0, +) / Double(points.count)
        let yMean = points.map(\.y).reduce(0, +) / Double(points.count)

        var numerator = 0.0
        var xVariance = 0.0
        var yVariance = 0.0

        for point in points {
            let dx = point.x - xMean
            let dy = point.y - yMean
            numerator += dx * dy
            xVariance += dx * dx
            yVariance += dy * dy
        }

        let denominator = sqrt(xVariance * yVariance)
        guard denominator > 0.0001 else { return nil }
        return numerator / denominator
    }

    /// Compares the trailing quarter of the display window against the preceding quarter.
    /// Returns "↑N%" or "↓N%" when the change exceeds 12%, nil otherwise.
    private func deltaBadge(from series: MetricSeries) -> String? {
        let history = displayHistory(from: series)
        guard history.count >= 8 else { return nil }
        let quarter = max(1, history.count / 4)
        let recent = history.suffix(quarter)
        let preceding = history.dropLast(quarter).suffix(quarter)
        guard !recent.isEmpty, !preceding.isEmpty else { return nil }
        let recentAvg = Double(recent.reduce(0, +)) / Double(recent.count)
        let prevAvg = Double(preceding.reduce(0, +)) / Double(preceding.count)
        guard prevAvg > 0.01 else { return nil }
        let change = (recentAvg - prevAvg) / prevAvg
        guard abs(change) >= 0.12 else { return nil }
        let pct = Int((abs(change) * 100).rounded())
        return change > 0 ? "↑\(pct)%" : "↓\(pct)%"
    }

    private func deltaBadge(from series: HardwareDeviceMetricSeries?) -> String? {
        guard let series else { return nil }
        let history = displayHistory(from: series)
        guard history.count >= 8 else { return nil }
        let quarter = max(1, history.count / 4)
        let recent = history.suffix(quarter)
        let preceding = history.dropLast(quarter).suffix(quarter)
        guard !recent.isEmpty, !preceding.isEmpty else { return nil }
        let recentAvg = Double(recent.reduce(0, +)) / Double(recent.count)
        let prevAvg = Double(preceding.reduce(0, +)) / Double(preceding.count)
        guard prevAvg > 0.01 else { return nil }
        let change = (recentAvg - prevAvg) / prevAvg
        guard abs(change) >= 0.12 else { return nil }
        let pct = Int((abs(change) * 100).rounded())
        return change > 0 ? "↑\(pct)%" : "↓\(pct)%"
    }

    /// Rounds `value` up to the nearest "nice" number (1.5 × 10ⁿ, 2, 3, 5, 10 …)
    /// so the inferred Y-axis ceiling stays human-readable.
    private func niceMax(_ value: Double) -> Double {
        guard value > 0 else { return 1.0 }
        let magnitude = pow(10.0, floor(log10(value)))
        let n = value / magnitude
        if n <= 1.5 { return 1.5 * magnitude }
        if n <= 2.0 { return 2.0 * magnitude }
        if n <= 3.0 { return 3.0 * magnitude }
        if n <= 5.0 { return 5.0 * magnitude }
        return 10.0 * magnitude
    }

    /// Normalises both `current` and the display-window history against the
    /// peak value seen in that window, floored at `floor` to prevent noise
    /// amplification when a metric is near-zero.
    ///
    /// The effective max is rounded to a "nice" number so the graph Y-axis
    /// ceiling stays stable under gradual load changes.
    private func peakScaled(
        series: MetricSeries,
        current: Float?,
        floor: Double,
        aggregation: MetricBucketAggregation = .average
    ) -> (current: Float?, history: [Float]) {
        let rawHistory  = displayHistory(from: series, aggregation: aggregation)
        let windowPeak  = rawHistory.map(Double.init).max() ?? 0
        let effectiveMax = niceMax(max(floor, max(Double(current ?? 0), windowPeak)))
        let normHistory  = rawHistory.map { Float(min(Double($0) / effectiveMax, 1.0)) }
        let normCurrent  = current.map { Float(min(Double($0) / effectiveMax, 1.0)) }
        return (normCurrent, normHistory)
    }

    private func trailingAlignedValue(in history: [Float], at index: Int, targetCount: Int) -> Float {
        let leadingPadding = max(0, targetCount - history.count)
        let alignedIndex = index - leadingPadding
        guard history.indices.contains(alignedIndex) else { return 0 }
        return history[alignedIndex]
    }

    private func blendedEnergyHistory(
        cpuHistory: [Float],
        gpuHistory: [Float],
        ramHistory: [Float]
    ) -> [Float] {
        let historyCount = max(cpuHistory.count, max(gpuHistory.count, ramHistory.count))
        guard historyCount > 0 else { return [] }

        return (0..<historyCount).map { index in
            let cpu = trailingAlignedValue(in: cpuHistory, at: index, targetCount: historyCount)
            let gpu = trailingAlignedValue(in: gpuHistory, at: index, targetCount: historyCount)
            let ram = trailingAlignedValue(in: ramHistory, at: index, targetCount: historyCount)
            let score = (cpu * 0.55) + (gpu * 0.30) + (ram * 0.15)
            return min(max(score, 0), 1)
        }
    }

    private var ramCurrentText: String? {
        guard let ramSnapshot else { return nil }
        return [
            ramSnapshot.cachedFilesLabel,
            ramSnapshot.compressedLabel,
            ramSnapshot.wiredLabel,
            ramSnapshot.appMemoryLabel
        ].joined(separator: "  ·  ")
    }

    private var memoryUnitExtraStats: [HardwareGraphFocusStat] {
        guard let unit = memoryIdentityProber.memoryUnit else { return [] }
        return sharedMemoryHardwareRows(for: unit).map { .init(label: $0.label, value: $0.value) }
    }

    private var memoryUnitExtraDetailLines: [String] {
        guard let unit = memoryIdentityProber.memoryUnit else { return [] }
        return sharedMemoryDetailLines(for: unit)
    }

    private func gpuHardwareExtraStats(for gpu: GPUStatsSampler.GPUUnit) -> [HardwareGraphFocusStat] {
        let identity = sharedResolvedGPUIdentity(for: gpu, liveGPUs: gpuSampler.gpus, metadataUnits: gpuIdentityProber.gpuUnits)
        var stats: [HardwareGraphFocusStat] = []
        if let cores = identity.coreCount { stats.append(.init(label: "Cores", value: "\(cores)")) }
        if let memorySummary = sharedGPUMemorySummary(
            liveGPU: identity.liveGPU,
            metadata: identity.metadata,
            memorySnapshot: ramSnapshot,
            cpuDisplayName: cpuSampler.cpuDisplayName
        ) {
            stats.append(.init(label: memorySummary.label, value: memorySummary.value))
        }
        if let displays = identity.metadata?.connectedDisplayCount { stats.append(.init(label: "Displays", value: "\(displays)")) }
        if let bus = identity.metadata?.bus { stats.append(.init(label: "Bus", value: bus)) }
        if let gpuType = identity.metadata?.gpuType { stats.append(.init(label: "Type", value: gpuType)) }
        if let metal = identity.metadata?.metalFamily { stats.append(.init(label: "Metal", value: metal)) }
        return stats
    }

    private func gpuHardwareExtraDetailLines(for gpu: GPUStatsSampler.GPUUnit) -> [String] {
        let identity = sharedResolvedGPUIdentity(for: gpu, liveGPUs: gpuSampler.gpus, metadataUnits: gpuIdentityProber.gpuUnits)
        var lines: [String] = []
        if let bus = identity.metadata?.bus { lines.append("Bus: \(bus)") }
        if let gpuType = identity.metadata?.gpuType { lines.append("Type: \(gpuType)") }
        if let metal = identity.metadata?.metalFamily { lines.append("Metal: \(metal)") }
        if let cores = identity.coreCount { lines.append("Cores: \(cores)") }
        if let memorySummary = sharedGPUMemorySummary(
            liveGPU: identity.liveGPU,
            metadata: identity.metadata,
            memorySnapshot: ramSnapshot,
            cpuDisplayName: cpuSampler.cpuDisplayName
        ) {
            lines.append("\(memorySummary.label): \(memorySummary.value)")
        }
        lines.append(contentsOf: sharedGPUMemorySupplementalRows(
            liveGPU: identity.liveGPU,
            metadata: identity.metadata,
            memorySnapshot: ramSnapshot,
            cpuDisplayName: cpuSampler.cpuDisplayName
        ).map { "\($0.label): \($0.value)" })
        if let displays = identity.metadata?.connectedDisplayCount { lines.append("Displays: \(displays)") }
        return lines
    }

    private var networkInterfaceExtraStats: [HardwareGraphFocusStat] {
        guard let snapshot = networkInterfaceSampler.latestSnapshot else { return [] }
        var stats: [HardwareGraphFocusStat] = []
        stats.append(.init(label: "Interfaces", value: "\(snapshot.interfaces.count)"))
        stats.append(.init(label: "Active", value: "\(snapshot.interfaces.filter { $0.isActive }.count)"))
        stats.append(.init(label: "Types", value: "\(snapshot.connectionTypes.count)"))
        if let dnsCount = snapshot.primaryInterface?.dnsServers.count {
            stats.append(.init(label: "DNS", value: "\(dnsCount)"))
        }
        return stats
    }

    private var networkInterfaceExtraDetailLines: [String] {
        guard let snapshot = networkInterfaceSampler.latestSnapshot else { return [] }
        var lines: [String] = []
        if let primaryIP = snapshot.primaryInterface?.primaryLocalIP {
            lines.append("Primary IP: \(primaryIP)")
        }
        if let subnet = snapshot.primaryInterface?.primarySubnetMask {
            lines.append("Subnet: \(subnet)")
        }
        if let mac = snapshot.primaryInterface?.macAddress {
            lines.append("MAC: \(mac)")
        }
        lines.append("Interfaces: \(snapshot.interfaces.count)")
        lines.append("Active: \(snapshot.interfaces.filter { $0.isActive }.count)")
        return lines
    }

    private var swapUsedText: String? {
        guard let swapUsedGB = ramSnapshot?.swapUsedGB else { return nil }
        return String(format: "%.1f GB", swapUsedGB)
    }

    private var thermalLabelText: String {
        thermalSampler.latestSnapshot?.dimension(.thermalState) ?? thermalSampler.thermalLabel
    }

    private func mediaEngineDisplayHistory() -> [Float] {
        let history = displayHistory(from: mediaEngineSampler.activitySeries)
        return history.isEmpty ? mediaEngineSampler.activityHistory : history
    }

    private var mediaEngineUnitLabel: String? {
        mediaEngineSampler.latestActivitySummary?.statusText ?? mediaEngineSampler.statusText
    }

    private var mediaEngineCurrentText: String? {
        let parts = [
            mediaEngineSampler.codecText == "—" ? nil : "Codec \(mediaEngineSampler.codecText)",
            mediaEngineSampler.latestActivitySummary?.lastActiveText == "—" ? nil : "Last \(mediaEngineSampler.latestActivitySummary?.lastActiveText ?? "")"
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var mediaEngineSecondaryText: String? {
        let encodeCount = mediaEngineSampler.recentSessions.filter { $0.role == .encode }.count
        let decodeCount = mediaEngineSampler.recentSessions.filter { $0.role == .decode }.count
        var parts: [String] = []
        if encodeCount > 0 {
            parts.append("\(encodeCount) enc")
        }
        if decodeCount > 0 {
            parts.append("\(decodeCount) dec")
        }
        if let frames = mediaEngineSampler.latestActivitySummary?.recentProcessedFrames, frames > 0 {
            parts.append("\(frames) frames")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var mediaEngineCardTitle: String {
        mediaEngineSampler.latestCapabilityState?.displayTitle ?? "Media Engines"
    }

    @ViewBuilder
    private var mediaEngineUsageCard: some View {
        if shouldShowMediaEngineUsageCard {
            UsageHistoryCard(
                title: mediaEngineCardTitle,
                current: mediaEngineSampler.activityValue,
                history: mediaEngineHistory,
                useMetalGraph: true,
                metalLineColor: SIMD4<Float>(0.37, 0.36, 0.90, 1.0),
                unitLabel: mediaEngineUnitLabel,
                currentText: mediaEngineCurrentText,
                secondaryText: mediaEngineSecondaryText,
                currentTextLineLimit: 1,
                secondaryTextLineLimit: 1,
                cardHeight: 110,
                graphHeight: 46,
                showPercentageValue: false,
                isHidden: $hiddenMediaEngine,
                onFocus: onFocusGraph,
                activeFocusID: activeFocusID,
                onFocusedStateChange: onFocusedGraphChange
            )
            .onAppear {
                mediaEngineHistory = mediaEngineDisplayHistory()
            }
            .onReceive(mediaEngineSampler.$activitySeries.dropFirst().debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)) { _ in
                mediaEngineHistory = mediaEngineDisplayHistory()
            }
            .onReceive(mediaEngineSampler.$activityHistory.dropFirst().debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)) { _ in
                mediaEngineHistory = mediaEngineDisplayHistory()
            }
        }
    }

    @ViewBuilder
    private var aneUsageCard: some View {
        let aneFocusState = makeSharedNeuralEngineFocusState(
            statusSnapshot: aneStatusSnapshot,
            activitySeries: aneSampler.activitySeries,
            powerSeries: aneSampler.powerSeries,
            title: "Neural Engine",
            subtitle: "Shared focused view for the visible Neural Engine history window."
        )

        UsageHistoryCard(
            title: "ANE Activity",
            current: aneSampler.activityValue,
            history: displayHistory(from: aneSampler.activitySeries),
            useMetalGraph: true,
            metalLineColor: SIMD4<Float>(0.65, 0.00, 0.65, 1.0),
            unitLabel: aneStatusSnapshot?.statusText ?? aneSampler.statusText,
            currentText: {
                var parts: [String] = []
                if let powerText = aneStatusSnapshot?.powerText, powerText != "—" {
                    parts.append("Power \(powerText)")
                }
                if let powerDeltaText = aneStatusSnapshot?.powerDeltaText, powerDeltaText != "—" {
                    parts.append("Δ \(powerDeltaText)")
                }
                return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
            }(),
            secondaryText: {
                var parts: [String] = []
                if let peakPowerText = aneStatusSnapshot?.peakPowerText, peakPowerText != "—" {
                    parts.append("Peak \(peakPowerText)")
                }
                let clientCount = aneStatusSnapshot?.clientCount ?? aneSampler.clientCount
                if clientCount > 0 {
                    parts.append("\(clientCount) client\(clientCount == 1 ? "" : "s")")
                }
                return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
            }(),
            currentTextLineLimit: 1,
            secondaryTextLineLimit: 1,
            cardHeight: 110,
            graphHeight: 46,
            isHidden: $hiddenANE,
            deltaText: deltaBadge(from: aneSampler.activitySeries),
            onFocus: onFocusGraph,
            activeFocusID: activeFocusID,
            onFocusedStateChange: onFocusedGraphChange,
            insightTarget: .ane,
            focusStateOverride: aneFocusState
        )
    }

    @ViewBuilder
    private var thermalUsageCard: some View {
        UsageHistoryCard(
            title: "Thermals",
            current: thermalSampler.thermalValue,
            history: displayHistory(from: thermalSampler.thermalSeries, aggregation: .latest),
            useMetalGraph: true,
            metalLineColor: SIMD4<Float>(0.02, 0.65, 0.65, 1.0),
            unitLabel: "",
            currentText: thermalLabelText,
            isHidden: $hiddenThermals,
            onFocus: onFocusGraph,
            activeFocusID: activeFocusID,
            onFocusedStateChange: onFocusedGraphChange,
            insightTarget: .thermals
        )
    }

    @ViewBuilder
    private var energyUsageCard: some View {
        EnergyUsageCard(
            current: energyCurrent,
            history: energyHistory,
            cpu: cpuEnergyCurrent,
            gpu: gpuEnergyCurrent,
            ram: ramEnergyCurrent,
            cpuPowerText: powerSampler.cpuPowerWattsText,
            gpuPowerText: powerSampler.gpuPowerWattsText,
            anePowerText: powerSampler.anePowerWattsText,
            combinedPowerText: powerSampler.combinedPowerWattsText,
            peakCombinedPowerText: powerSampler.peakCombinedPowerWattsText,
            isHidden: $hiddenEnergy,
            onFocus: onFocusGraph,
            activeFocusID: activeFocusID,
            onFocusedStateChange: onFocusedGraphChange,
            focusScatterSnapshots: powerScatterSnapshots
        )
    }

    private func hiddenBinding(
        for id: String,
        in state: Binding<[String: Bool]>
    ) -> Binding<Bool> {
        Binding(
            get: { state.wrappedValue[id] ?? false },
            set: { state.wrappedValue[id] = $0 }
        )
    }

    private func gpuDetailText(for gpu: GPUStatsSampler.GPUUnit) -> String? {
        let identity = sharedResolvedGPUIdentity(for: gpu, liveGPUs: gpuSampler.gpus, metadataUnits: gpuIdentityProber.gpuUnits)
        return sharedGPUMemoryDetailText(
            liveGPU: gpu,
            metadata: identity.metadata,
            memorySnapshot: ramSnapshot,
            cpuDisplayName: cpuSampler.cpuDisplayName
        )
    }

    private func gpuMemoryCeilingMB(for gpu: GPUStatsSampler.GPUUnit) -> Double? {
        let identity = sharedResolvedGPUIdentity(for: gpu, liveGPUs: gpuSampler.gpus, metadataUnits: gpuIdentityProber.gpuUnits)
        return sharedGPUMemoryCeilingMB(
            liveGPU: gpu,
            metadata: identity.metadata,
            memorySnapshot: ramSnapshot,
            cpuDisplayName: cpuSampler.cpuDisplayName
        )
    }

    private func usesUnifiedMemoryCeilingEstimate(for gpu: GPUStatsSampler.GPUUnit) -> Bool {
        let identity = sharedResolvedGPUIdentity(for: gpu, liveGPUs: gpuSampler.gpus, metadataUnits: gpuIdentityProber.gpuUnits)
        return sharedUsesUnifiedGPUMemoryEstimate(
            liveGPU: gpu,
            metadata: identity.metadata,
            memorySnapshot: ramSnapshot,
            cpuDisplayName: cpuSampler.cpuDisplayName
        )
    }

    private func gpuMemoryPressureValueMB(for gpu: GPUStatsSampler.GPUUnit) -> Double? {
        if usesUnifiedMemoryCeilingEstimate(for: gpu) {
            return gpu.gpuMemoryAllocatedMB.map(Double.init) ?? gpu.vramUsedMB.map(Double.init)
        }
        return gpu.vramUsedMB.map(Double.init)
    }

    private func gpuMemoryPressureTitle(for gpu: GPUStatsSampler.GPUUnit) -> String {
        let usesUnifiedEstimate = usesUnifiedMemoryCeilingEstimate(for: gpu)
        let baseTitle = usesUnifiedEstimate ? "GPU Mem" : "VRAM Pressure"
        let identity = sharedResolvedGPUIdentity(for: gpu, liveGPUs: gpuSampler.gpus, metadataUnits: gpuIdentityProber.gpuUnits)
        guard gpuSampler.gpus.count > 1 else { return baseTitle }
        return "\(baseTitle) — \(identity.displayName)"
    }

    private func gpuMemoryPressureDetailText(for gpu: GPUStatsSampler.GPUUnit) -> String {
        if usesUnifiedMemoryCeilingEstimate(for: gpu) {
            return "Estimated against the current unified-memory budget for this GPU."
        }
        return "Tracks VRAM used against the current dedicated VRAM ceiling."
    }

    private func gpuMemoryPressureEntry(for gpu: GPUStatsSampler.GPUUnit) -> FloatingCustomMonitorCardEntry? {
        guard let source = floatingSource else { return nil }

        let usesUnifiedEstimate = usesUnifiedMemoryCeilingEstimate(for: gpu)
        let usedMB = gpu.vramUsedMB.map(Double.init)
        let allocatedMB = usesUnifiedEstimate ? gpu.gpuMemoryAllocatedMB.map(Double.init) : nil
        guard usedMB != nil || allocatedMB != nil else { return nil }
        let ceilingMB = gpuMemoryCeilingMB(for: gpu)
        let detailText = gpuMemoryPressureDetailText(for: gpu)

        return FloatingCustomMonitorCardEntry(
            key: "\(source.key).gpu-memory-pressure.\(gpu.id)",
            title: gpuMemoryPressureTitle(for: gpu),
            windowTitle: "\(gpuMemoryPressureTitle(for: gpu)) — \(source.displayName)",
            defaultContentSize: CGSize(width: 360, height: 126),
            minimumContentSize: CGSize(width: 300, height: 94),
            prefersFullWidthInCustomStack: false,
            content: AnyView(
                GPUMemoryPressureFloatingCard(
                    usedMB: usedMB,
                    ceilingMB: ceilingMB,
                    allocatedMB: allocatedMB,
                    isUnifiedCeilingEstimate: usesUnifiedEstimate,
                    detailText: detailText
                )
            )
        )
    }

    private func gpuMemoryPressureCardSignature(for gpu: GPUStatsSampler.GPUUnit) -> Int {
        var hasher = Hasher()
        hasher.combine(gpu.id)
        hasher.combine(gpu.name)
        hasher.combine(floatingSource?.key ?? "no-floating-source")
        hasher.combine(usesUnifiedMemoryCeilingEstimate(for: gpu))
        if let usedMB = gpu.vramUsedMB {
            hasher.combine(usedMB)
        } else {
            hasher.combine(-1)
        }
        if let allocatedMB = gpu.gpuMemoryAllocatedMB {
            hasher.combine(allocatedMB)
        } else {
            hasher.combine(-1)
        }
        if let ceilingMB = gpuMemoryCeilingMB(for: gpu) {
            hasher.combine(Int(ceilingMB.rounded()))
        } else {
            hasher.combine(-1)
        }
        return hasher.finalize()
    }

    private func registerGPUMemoryPressureCardIfAvailable(for gpu: GPUStatsSampler.GPUUnit) {
        guard let entry = gpuMemoryPressureEntry(for: gpu) else { return }
        FloatingCustomMonitorRegistry.shared.upsert(entry)
    }

    private func openGPUMemoryPressureCard(for gpu: GPUStatsSampler.GPUUnit) {
        guard let entry = gpuMemoryPressureEntry(for: gpu) else { return }
        FloatingMonitorWindowController.shared.openCustomCard(entry)
    }

    private func addGPUMemoryPressureToStack(for gpu: GPUStatsSampler.GPUUnit) {
        guard let source = floatingSource,
              let entry = gpuMemoryPressureEntry(for: gpu) else { return }
        CustomMonitorStackWindowController.shared.addCustomCard(entry, source: source)
    }

    private func gpuMemoryPressureBar(for gpu: GPUStatsSampler.GPUUnit) -> some View {
        let usesUnifiedEstimate = usesUnifiedMemoryCeilingEstimate(for: gpu)
        let signature = gpuMemoryPressureCardSignature(for: gpu)
        return GPUMemoryPressureBar(
            usedMB: gpu.vramUsedMB.map(Double.init),
            ceilingMB: gpuMemoryCeilingMB(for: gpu),
            allocatedMB: usesUnifiedEstimate ? gpu.gpuMemoryAllocatedMB.map(Double.init) : nil,
            isUnifiedCeilingEstimate: usesUnifiedEstimate
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            if floatingSource != nil {
                Button("Add to Custom Stack") {
                    addGPUMemoryPressureToStack(for: gpu)
                }

                Button("Open Floating Card") {
                    openGPUMemoryPressureCard(for: gpu)
                }
            }
        }
        .onAppear {
            registerGPUMemoryPressureCardIfAvailable(for: gpu)
        }
        .onChange(of: signature) { _ in
            registerGPUMemoryPressureCardIfAvailable(for: gpu)
        }
    }

    private func pingLatencyCardSignature() -> Int {
        var hasher = Hasher()
        hasher.combine(floatingSource?.key ?? "no-floating-source")
        hasher.combine(selectedPingInterval)
        hasher.combine(customPingTarget)
        if let currentLatency = networkSampler.pingLatencyMilliseconds {
            hasher.combine(currentLatency)
        } else {
            hasher.combine(-1)
        }
        if let packetLossRatio = networkSampler.pingPacketLossRatio {
            hasher.combine(packetLossRatio)
        } else {
            hasher.combine(-1)
        }
        if let lastPingSampleDate = networkSampler.lastPingSampleDate {
            hasher.combine(lastPingSampleDate.timeIntervalSinceReferenceDate)
        } else {
            hasher.combine(-1)
        }
        return hasher.finalize()
    }

    private func pingLatencyCardEntry() -> FloatingCustomMonitorCardEntry? {
        guard let source = floatingSource else { return nil }
        return FloatingCustomMonitorCardEntry(
            key: "\(source.key).network-ping-latency",
            title: "Ping",
            windowTitle: "Ping — \(source.displayName)",
            defaultContentSize: CGSize(width: 352, height: 150),
            minimumContentSize: CGSize(width: 300, height: 124),
            prefersFullWidthInCustomStack: false,
            content: AnyView(
                PingLatencyFloatingCard(
                    currentLatency: networkSampler.pingLatencyMilliseconds,
                    packetLossRatio: networkSampler.pingPacketLossRatio,
                    targetLabel: pingTargetDisplayText,
                    intervalText: pingIntervalDisplayText
                )
            )
        )
    }

    private func registerPingLatencyCardIfAvailable() {
        guard let entry = pingLatencyCardEntry() else { return }
        FloatingCustomMonitorRegistry.shared.upsert(entry)
    }

    private func openPingLatencyCard() {
        guard let entry = pingLatencyCardEntry() else { return }
        FloatingMonitorWindowController.shared.openCustomCard(entry)
    }

    private func addPingLatencyToStack() {
        guard let source = floatingSource,
              let entry = pingLatencyCardEntry() else { return }
        CustomMonitorStackWindowController.shared.addCustomCard(entry, source: source)
    }

    @ViewBuilder
    private func pingLatencyMeterBar() -> some View {
        let signature = pingLatencyCardSignature()
        let bar = PingLatencyMeterBar(
            currentLatency: networkSampler.pingLatencyMilliseconds
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        if floatingSource != nil {
            bar
                .contentShape(Rectangle())
                .contextMenu {
                    Button("Add to Custom Stack") {
                        addPingLatencyToStack()
                    }

                    Button("Open Floating Window") {
                        openPingLatencyCard()
                    }
                }
                .onAppear {
                    registerPingLatencyCardIfAvailable()
                }
                .onChange(of: signature) { _ in
                    registerPingLatencyCardIfAvailable()
                }
        } else {
            bar
        }
    }

    private func networkSettingsDetailVisual() -> HardwareGraphFocusDetailVisual? {
        let pingIntervalRow = HardwareGraphFocusActionRowSnapshot(
            id: "network-ping-interval",
            name: "Ping Interval",
            statusText: pingIntervalDisplayText,
            subtitleText: "Frequency of network health checks",
            detailText: nil,
            tone: .neutral,
            actionTitle: "Change",
            isActionEnabled: true,
            isActionInProgress: false
        )

        let pingTargetRow = HardwareGraphFocusActionRowSnapshot(
            id: "network-ping-target",
            name: "Ping Target",
            statusText: pingTargetDisplayText,
            subtitleText: "Destination for latency measurements",
            detailText: nil,
            tone: .neutral,
            actionTitle: "Change",
            isActionEnabled: true,
            isActionInProgress: false
        )

        let snapshot = HardwareGraphFocusActionsSnapshot(
            id: "network-settings",
            title: "Network Settings",
            subtitle: "Configure network monitoring parameters",
            rows: [pingIntervalRow, pingTargetRow]
        )

        return .actions(snapshot)
    }

    private func formatPingInterval(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            return String(format: "%.1f min", Double(seconds) / 60.0).trimmingCharacters(in: CharacterSet(charactersIn: ".0"))
        } else {
            return String(format: "%.1f h", Double(seconds) / 3600.0).trimmingCharacters(in: CharacterSet(charactersIn: ".0"))
        }
    }

    private var networkSettingsActionHandler: ((String) -> Void)? {
        { actionID in
            // Post a notification that HardwareGraphFocusView will listen to
            NotificationCenter.default.post(name: NSNotification.Name("NetworkSettingsActionTriggered"), object: actionID)
        }
    }

    private let pingIntervalOptions: [(seconds: Int, label: String)] = [
        (1, "1s"),
        (5, "5s"),
        (10, "10s"),
        (15, "15s"),
        (20, "20s"),
        (30, "30s"),
        (60, "1m"),
        (300, "5m"),
        (600, "10m"),
        (900, "15m"),
        (1200, "20m"),
        (1800, "30m"),
        (2700, "45m"),
        (3600, "60m")
    ]

    private func gpuMemoryUsageSeries(for gpu: GPUStatsSampler.GPUUnit) -> HardwareDeviceMetricSeries? {
        gpuSampler.memoryUsageSeriesByGPU[gpu.id]
    }

    private func gpuMemoryFocusInlineMeter(for gpu: GPUStatsSampler.GPUUnit) -> HardwareGraphFocusInlineMeter? {
        let usedMB = gpu.vramUsedMB.map(Double.init)
        let usesUnifiedEstimate = usesUnifiedMemoryCeilingEstimate(for: gpu)
        let allocatedMB = usesUnifiedEstimate ? gpu.gpuMemoryAllocatedMB.map(Double.init) : nil
        guard usedMB != nil || allocatedMB != nil else { return nil }

        // Use the proper estimated ceiling calculation for unified memory systems
        let ceilingMB = gpuMemoryCeilingMB(for: gpu)

        let detailText: String? = {
            let parts: [String?] = [
                usedMB.map { String(format: "%.1f GB", $0 / 1024.0) },
                allocatedMB.map { String(format: "Alloc %.1f GB", $0 / 1024.0) }
            ]
            let joined = parts.compactMap { $0 }.joined(separator: " · ")
            return joined.isEmpty ? nil : joined
        }()

        return HardwareGraphFocusInlineMeter(
            id: "gpu-memory-\(gpu.id)",
            usedMB: usedMB,
            ceilingMB: ceilingMB,
            allocatedMB: allocatedMB,
            isUnifiedCeilingEstimate: usesUnifiedEstimate,
            detailText: detailText
        )
    }

    private func gpuMemoryLinePanel(for gpu: GPUStatsSampler.GPUUnit) -> HardwareGraphFocusLinePanelSnapshot? {
        guard let memorySeries = gpuMemoryUsageSeries(for: gpu) else { return nil }
        let usesUnifiedEstimate = usesUnifiedMemoryCeilingEstimate(for: gpu)
        let identity = sharedResolvedGPUIdentity(for: gpu, liveGPUs: gpuSampler.gpus, metadataUnits: gpuIdentityProber.gpuUnits)

        // Use the proper estimated ceiling calculation
        guard let normalizationCeilingMB = gpuMemoryCeilingMB(for: gpu), normalizationCeilingMB > 0 else { return nil }

        let normalizedSeries = memorySeries.samples.map { sample in
            let value = sample.value ?? 0
            return min(value, normalizationCeilingMB) / normalizationCeilingMB
        }

        let gpuTitle = sharedGPUDisplayTitle(for: identity)

        return HardwareGraphFocusLinePanelSnapshot(
            id: "gpu-memory-\(gpu.id)",
            title: "GPU Memory",
            chipTitle: gpuTitle,
            subtitle: usesUnifiedEstimate
                ? "Visible GPU memory allocation normalized against the current estimated unified-memory ceiling."
                : "Visible VRAM usage normalized against the current VRAM ceiling.",
            detailText: usesUnifiedEstimate
                ? "Uses allocated GPU memory on unified-memory Macs, so the line reflects graphics allocation pressure rather than a fixed dedicated pool."
                : "Uses VRAM used over the visible window, normalized to the current dedicated VRAM ceiling.",
            series: [
                HardwareGraphFocusSeries(
                    id: "gpu-memory-history",
                    label: "GPU Memory",
                    color: Color(red: 0.85, green: 0.20, blue: 0.20),
                    values: normalizedSeries.map { Optional($0) }
                )
            ]
        )
    }

    private func gpuHardwareDetailVisual(for gpu: GPUStatsSampler.GPUUnit) -> HardwareGraphFocusDetailVisual? {
        let identity = sharedResolvedGPUIdentity(for: gpu, liveGPUs: gpuSampler.gpus, metadataUnits: gpuIdentityProber.gpuUnits)
        let memorySummary = sharedGPUMemorySummary(
            liveGPU: gpu,
            metadata: identity.metadata,
            memorySnapshot: ramSnapshot,
            cpuDisplayName: cpuSampler.cpuDisplayName
        )

        let snapshot = HardwareGraphFocusGPUHardwareSnapshot(
            id: "gpu-hardware-\(gpu.id)",
            name: identity.displayName,
            bus: identity.metadata?.bus,
            gpuType: identity.metadata?.gpuType,
            metalFamily: identity.metadata?.metalFamily,
            coreCount: identity.coreCount,
            memoryLabel: memorySummary?.label,
            memoryText: memorySummary?.value,
            connectedDisplayCount: identity.metadata?.connectedDisplayCount,
            deviceID: identity.metadata?.deviceID,
            revisionID: identity.metadata?.revisionID,
            pcieWidth: identity.metadata?.pcieWidth,
            isRemovable: identity.metadata?.isRemovable
        )

        return .gpuHardware(snapshot)
    }

    private func gpuEnvironmentText(for gpu: GPUStatsSampler.GPUUnit) -> String? {
        let parts: [String?] = [
            {
                if let temperatureC = gpu.temperatureC {
                    return "Temp \(temperatureC)°C"
                }
                return nil
            }(),
            {
                if let fanRPM = gpu.fanRPM {
                    return "Fan \(fanRPM) RPM"
                }
                return nil
            }(),
            {
                if let coreClockMHz = gpu.coreClockMHz {
                    return "Core \(coreClockMHz) MHz"
                }
                return nil
            }(),
            powerReadingsSnapshot?.gpuFrequencyMHzText == "—" ? nil : "GPU \(powerReadingsSnapshot?.gpuFrequencyMHzText ?? "—")",
            {
                if let memoryClockMHz = gpu.memoryClockMHz {
                    return "Mem \(memoryClockMHz) MHz"
                }
                return nil
            }(),
            {
                if let totalPowerW = gpu.totalPowerW {
                    return "Power \(totalPowerW) W"
                }
                return nil
            }(),
            powerReadingsSnapshot?.gpuPowerWattsText == "—" ? nil : "GPU \(powerReadingsSnapshot?.gpuPowerWattsText ?? "—")"
        ]

        let joined = parts.compactMap { $0 }.joined(separator: "  ·  ")
        return joined.isEmpty ? nil : joined
    }

    private var cpuEnergyCurrent: Float? { cpuSampler.totalUsage }
    private var gpuEnergyCurrent: Float? { gpuSampler.gpus.compactMap(\.usage).max() }
    private var ramEnergyCurrent: Float? { ramSampler.ramUsage }

    private var energyCurrent: Float? {
        let cpu = cpuEnergyCurrent ?? 0
        let gpu = gpuEnergyCurrent ?? 0
        let ram = ramEnergyCurrent ?? 0

        if cpuEnergyCurrent == nil && gpuEnergyCurrent == nil && ramEnergyCurrent == nil {
            return nil
        }

        let score = (cpu * 0.55) + (gpu * 0.30) + (ram * 0.15)
        return min(max(score, 0), 1)
    }

    private var energyHistory: [Float] {
        let cpuEnergyHistory = displayHistory(from: cpuSampler.totalUsageSeries)
        let ramEnergyHistory = displayHistory(from: ramSampler.usageSeries)
        let primaryGPUUsageSeries = gpuSampler.gpus.first.flatMap { gpuSampler.usageSeriesByGPU[$0.id] }
        let gpuEnergyHistory = displayHistory(from: primaryGPUUsageSeries)
        return blendedEnergyHistory(
            cpuHistory: cpuEnergyHistory,
            gpuHistory: gpuEnergyHistory,
            ramHistory: ramEnergyHistory
        )
    }

    private var cpuCurrentText: String? {
        let parts: [String?] = [
            cpuSampler.systemUsage.map { String(format: "System %3.0f%%", $0 * 100) },
            cpuSampler.userUsage.map { String(format: "User %3.0f%%", $0 * 100) },
            cpuSampler.idleUsage.map { String(format: "Idle %3.0f%%", $0 * 100) },
            powerReadingsSnapshot?.cpuPowerWattsText == "—" ? nil : "CPU \(powerReadingsSnapshot?.cpuPowerWattsText ?? "—")"
        ]
        let joined = parts.compactMap { $0 }.joined(separator: "  ·  ")
        return joined.isEmpty ? nil : joined
    }

    // MARK: - Layout Toggle

    private var layoutToggleControl: some View {
        HStack(spacing: 8 * appUIScale) {
            HStack(spacing: 4 * appUIScale) {
                layoutModeButton(icon: "rectangle.stack", isCompact: false)
                layoutModeButton(icon: "square.grid.2x2", isCompact: true)
            }
            .padding(3 * appUIScale)
            .background(
                ThemeRoundedRectangle(cornerRadius: 8 * appUIScale, style: .continuous)
                    .fill(GraphiteSlateTheme.controlFill)
            )

            sidebarToggleButton
        }
    }

    private func layoutModeButton(icon: String, isCompact: Bool) -> some View {
        let isActive = compactLayout == isCompact
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                compactLayout = isCompact
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11 * appUIScale))
                .foregroundColor(isActive ? .primary : .secondary)
                .frame(width: 24 * appUIScale, height: 20 * appUIScale)
                .background(
                    ThemeRoundedRectangle(cornerRadius: 6 * appUIScale, style: .continuous)
                        .fill(isActive ? GraphiteSlateTheme.controlActiveFill : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private var sidebarToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                sidebarVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 11 * appUIScale))
                .foregroundColor(sidebarVisible ? .primary : .secondary)
                .frame(width: 24 * appUIScale, height: 20 * appUIScale)
                .background(
                    ThemeRoundedRectangle(cornerRadius: 6 * appUIScale, style: .continuous)
                        .fill(sidebarVisible ? GraphiteSlateTheme.controlActiveFill : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .padding(3 * appUIScale)
        .background(
            ThemeRoundedRectangle(cornerRadius: 8 * appUIScale, style: .continuous)
                .fill(GraphiteSlateTheme.controlFill)
        )
        .help(sidebarVisible ? "Hide sidebar cards" : "Show sidebar cards")
    }

    // MARK: - Body

    var body: some View {
        Group {
            let settingsCard = GraphSettingsCard(
                timeWindowSeconds: $graphWindowSeconds,
                displayIntervalSeconds: $graphDisplayIntervalSeconds
            )

            let graphSections = VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "Graph History")
                        .padding(.horizontal, 4)
                        .padding(.bottom, 2)
                    Spacer()
                    layoutToggleControl
                }

                CollapsibleGraphSection(
                    title: "CPU",
                    subtitle: cpuSampler.cpuDisplayName,
                    isCollapsed: $cpuSectionCollapsed
                ) {
                    ObservedSubtree2(primary: cpuSampler, secondary: powerSampler) {
                        cpuSection
                    }
                }

                CollapsibleGraphSection(
                    title: "GPU",
                    subtitle: nil,
                    isCollapsed: $gpuSectionCollapsed
                ) {
                    ObservedSubtree4(
                        object1: gpuSampler,
                        object2: gpuIdentityProber,
                        object3: ramSampler,
                        object4: cpuSampler
                    ) {
                        gpuSection
                    }
                }

                CollapsibleGraphSection(
                    title: "Memory",
                    subtitle: nil,
                    isCollapsed: $memorySectionCollapsed
                ) {
                    ObservedSubtree2(primary: ramSampler, secondary: memoryIdentityProber) {
                        memorySection
                    }
                }

                CollapsibleGraphSection(
                    title: "Disk",
                    subtitle: nil,
                    isCollapsed: $diskSectionCollapsed
                ) {
                    ObservedSubtree(primary: diskIOSampler) {
                        diskSection
                    }
                }

                CollapsibleGraphSection(
                    title: "Network",
                    subtitle: nil,
                    isCollapsed: $networkSectionCollapsed
                ) {
                    ObservedSubtree2(primary: networkSampler, secondary: networkInterfaceSampler) {
                        networkSection
                    }
                }

                CollapsibleGraphSection(
                    title: "System",
                    subtitle: nil,
                    isCollapsed: $systemSectionCollapsed
                ) {
                    ObservedSubtree6(
                        object1: thermalSampler,
                        object2: gpuSampler,
                        object3: ramSampler,
                        object4: aneSampler,
                        object5: mediaEngineSampler,
                        object6: powerSampler
                    ) {
                        systemSection
                    }
                }

                ObservedSubtree2(primary: gpuSampler, secondary: aneSampler) {
                    periodicAveragesSection
                }
            }
            .padding(16 * appUIScale)
            .background(
                ThemeRoundedRectangle(cornerRadius: 24 * appUIScale, style: .continuous)
                    .fill(panelBackgroundFill)
            )

            let content = VStack(alignment: .leading, spacing: 16) {
                settingsCard
                    .padding(.bottom, 2)

                graphSections
            }
            .environment(\.floatingMonitorSource, floatingSource)
            .onReceive(graphRefreshTimer) { tick in
                graphRefreshDate = tick
            }

            if #available(macOS 12.0, *) {
                content
                    .task(id: historyBackfillTaskID) {
                        await refreshHistoryBackfill()
                    }
                    .onChange(of: selectedPingInterval) { interval in
                        networkSampler.updatePingInterval(interval)
                    }
                    .onChange(of: customPingTarget) { target in
                        networkSampler.updatePingTarget(target)
                    }
            } else {
                content
                    .onAppear {
                        Task { await refreshHistoryBackfill() }
                    }
                    .onChange(of: historyBackfillTaskID) { _ in
                        Task { await refreshHistoryBackfill() }
                    }
                    .onChange(of: selectedPingInterval) { interval in
                        networkSampler.updatePingInterval(interval)
                    }
                    .onChange(of: customPingTarget) { target in
                        networkSampler.updatePingTarget(target)
                    }
            }
        }
    }

    private func refreshHistoryBackfill() async {
        await historyBackfillStore.refresh(
            historyReader: historyReader,
            range: graphDisplayRange,
            displayIntervalSeconds: max(1, graphDisplayIntervalSeconds),
            metricKeys: historyBackfillMetricKeys,
            deviceRequests: historyBackfillDeviceRequests
        )
    }

    private var historyBackfillMetricKeys: [HardwareMetricKey] {
        [
            .cpuTotalUsage,
            .cpuEfficiencyUsage,
            .cpuPerformanceUsage,
            .ramUsageRatio,
            .memoryPressureRatio,
            .swapUsageRatio,
            .diskReadMBps,
            .diskWriteMBps,
            .networkUploadMBps,
            .networkDownloadMBps,
            .networkPingLatencyMilliseconds,
            .networkPingPacketLossRatio,
            .aneActivityRatio,
            .thermalLevel,
            .combinedPowerWatts,
            .mediaEngineActivityRatio
        ]
    }

    private var historyBackfillDeviceRequests: [HardwareGraphHistoryBackfillStore.DeviceRequest] {
        gpuSampler.gpus.flatMap { gpu in
            [
                HardwareGraphHistoryBackfillStore.DeviceRequest(
                    key: .utilizationRatio,
                    deviceID: gpu.id,
                    deviceKind: .gpu
                ),
                HardwareGraphHistoryBackfillStore.DeviceRequest(
                    key: .rendererUtilizationRatio,
                    deviceID: gpu.id,
                    deviceKind: .gpu
                ),
                HardwareGraphHistoryBackfillStore.DeviceRequest(
                    key: .tilerUtilizationRatio,
                    deviceID: gpu.id,
                    deviceKind: .gpu
                )
            ]
        }
    }

    // MARK: - CPU Section

    @ViewBuilder private var cpuSection: some View {
        let hasCoreBreakdown = cpuSampler.efficiencyCoreCount > 0 || cpuSampler.performanceCoreCount > 0

        if compactLayout && hasCoreBreakdown {
            HStack(alignment: .top, spacing: 16) {
                UsageHistoryCard(
                    title: "CPU",
                    current: cpuSampler.totalUsage,
                    history: displayHistory(from: cpuSampler.totalUsageSeries),
                    useMetalGraph: true,
                    currentText: cpuCurrentText,
                    cardHeight: 92,
                    graphHeight: 46,
                    isHidden: $hiddenCPU,
                    deltaText: deltaBadge(from: cpuSampler.totalUsageSeries),
                    onFocus: onFocusGraph,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphChange,
                    insightTarget: .cpu,
                    focusScatterSnapshots: cpuScatterSnapshots
                )

                if cpuSampler.efficiencyCoreCount > 0 {
                    UsageHistoryCard(
                        title: "Efficiency Cores",
                        current: cpuSampler.efficiencyUsage,
                        history: displayHistory(from: cpuSampler.efficiencyUsageSeries),
                        useMetalGraph: true,
                        metalLineColor: SIMD4<Float>(0.05, 0.48, 0.70, 1.0),
                        cardHeight: 92,
                        graphHeight: 46,
                        isHidden: $hiddenEfficiencyCores,
                        onFocus: onFocusGraph,
                        activeFocusID: activeFocusID,
                        onFocusedStateChange: onFocusedGraphChange,
                        insightTarget: .cpu
                    )
                }

                if cpuSampler.performanceCoreCount > 0 {
                    UsageHistoryCard(
                        title: "Performance Cores",
                        current: cpuSampler.performanceUsage,
                        history: displayHistory(from: cpuSampler.performanceUsageSeries),
                        useMetalGraph: true,
                        metalLineColor: SIMD4<Float>(0.22, 0.16, 0.80, 1.0),
                        cardHeight: 92,
                        graphHeight: 46,
                        isHidden: $hiddenPerformanceCores,
                        onFocus: onFocusGraph,
                        activeFocusID: activeFocusID,
                        onFocusedStateChange: onFocusedGraphChange,
                        insightTarget: .cpu
                    )
                }
            }
        } else {
            UsageHistoryCard(
                title: "CPU",
                current: cpuSampler.totalUsage,
                history: displayHistory(from: cpuSampler.totalUsageSeries),
                useMetalGraph: true,
                currentText: cpuCurrentText,
                cardHeight: 92,
                graphHeight: 46,
                isHidden: $hiddenCPU,
                deltaText: deltaBadge(from: cpuSampler.totalUsageSeries),
                onFocus: onFocusGraph,
                activeFocusID: activeFocusID,
                onFocusedStateChange: onFocusedGraphChange,
                insightTarget: .cpu,
                focusScatterSnapshots: cpuScatterSnapshots
            )

            if cpuSampler.efficiencyCoreCount > 0 {
                UsageHistoryCard(
                    title: "Efficiency Cores",
                    current: cpuSampler.efficiencyUsage,
                    history: displayHistory(from: cpuSampler.efficiencyUsageSeries),
                    useMetalGraph: true,
                    metalLineColor: SIMD4<Float>(0.05, 0.48, 0.70, 1.0),
                    cardHeight: 78,
                    graphHeight: 40,
                    isHidden: $hiddenEfficiencyCores,
                    onFocus: onFocusGraph,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphChange,
                    insightTarget: .cpu
                )
            }

            if cpuSampler.performanceCoreCount > 0 {
                UsageHistoryCard(
                    title: "Performance Cores",
                    current: cpuSampler.performanceUsage,
                    history: displayHistory(from: cpuSampler.performanceUsageSeries),
                    useMetalGraph: true,
                    metalLineColor: SIMD4<Float>(0.22, 0.16, 0.80, 1.0),
                    cardHeight: 78,
                    graphHeight: 40,
                    isHidden: $hiddenPerformanceCores,
                    onFocus: onFocusGraph,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphChange,
                    insightTarget: .cpu
                )
            }
        }
    }

    // MARK: - GPU Section

    @ViewBuilder private var gpuSection: some View {
        if gpuSampler.gpus.isEmpty {
            UsageHistoryCard(
                title: "GPU",
                current: nil,
                history: [],
                useMetalGraph: true,
                metalLineColor: SIMD4<Float>(0.85, 0.20, 0.20, 1.0),
                unitLabel: "No GPU data",
                isHidden: $hiddenGPUEmpty,
                onFocus: onFocusGraph,
                activeFocusID: activeFocusID,
                onFocusedStateChange: onFocusedGraphChange,
                insightTarget: .gpu
            )
        } else {
            ForEach(gpuSampler.gpus) { gpu in
                let resolvedGPUIdentity = sharedResolvedGPUIdentity(
                    for: gpu,
                    liveGPUs: gpuSampler.gpus,
                    metadataUnits: gpuIdentityProber.gpuUnits
                )
                let gpuTitle = sharedGPUDisplayTitle(for: resolvedGPUIdentity)
                let gpuFocusContext = HardwareGraphFocusGPUContext(deviceID: gpu.id, modelName: gpuTitle)
                let allowsGPUAttribution = gpuSampler.gpus.count <= 1
                let gpuFocusInlineMeters = gpuMemoryFocusInlineMeter(for: gpu).map { [$0] } ?? []
                let gpuFocusLinePanels = gpuMemoryLinePanel(for: gpu).map { [$0] } ?? []
                let gpuFocusDetailVisuals = gpuHardwareDetailVisual(for: gpu).map { [$0] } ?? []

                let hasRenderer = gpu.rendererUsage != nil && !gpu.rendererHistory.isEmpty
                let hasTiler = gpu.tilerUsage != nil && !gpu.tilerHistory.isEmpty
                let hasSubCards = hasRenderer || hasTiler

                SectionHeader(title: gpuTitle)

                if compactLayout && hasSubCards {
                    // Compact: GPU + Renderer + Tiler side-by-side in one row.
                    // The VRAM / GPU Mem bar spans the full row width beneath the cards.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 16) {
                            UsageHistoryCard(
                                title: "GPU",
                                current: gpu.usage,
                                history: displayHistory(from: gpuSampler.usageSeriesByGPU[gpu.id]),
                                useMetalGraph: true,
                                metalLineColor: SIMD4<Float>(0.85, 0.20, 0.20, 1.0),
                                currentText: gpuDetailText(for: gpu),
                                secondaryText: gpuEnvironmentText(for: gpu),
                                currentTextLineLimit: 2,
                                secondaryTextLineLimit: 2,
                                cardHeight: 110,
                                graphHeight: 46,
                                isHidden: hiddenBinding(for: gpu.id, in: $hiddenGPUs),
                                deltaText: deltaBadge(from: gpuSampler.usageSeriesByGPU[gpu.id]),
                                onFocus: onFocusGraph,
                                activeFocusID: activeFocusID,
                                onFocusedStateChange: onFocusedGraphChange,
                                insightTarget: .gpu,
                                focusSubtitle: "\(gpuTitle) · Focused view of the visible history window",
                                focusAttributionEnabled: allowsGPUAttribution,
                                focusGPUContext: gpuFocusContext,
                                focusInlineMeters: gpuFocusInlineMeters,
                                focusLinePanels: gpuFocusLinePanels,
                                focusDetailVisuals: gpuFocusDetailVisuals,
                                focusExtraStats: gpuHardwareExtraStats(for: gpu),
                                focusExtraDetailLines: gpuHardwareExtraDetailLines(for: gpu)
                            )

                            if hasRenderer {
                                UsageHistoryCard(
                                    title: "Renderer",
                                    current: gpu.rendererUsage,
                                    history: displayHistory(from: gpuSampler.rendererSeriesByGPU[gpu.id]),
                                    useMetalGraph: true,
                                    metalLineColor: SIMD4<Float>(0.55, 0.12, 0.12, 1.0),
                                    currentText: {
                                        if let allocatedMB = gpu.rendererAllocatedPageBufferMB {
                                            return String(format: "Allocated PB %d MB", allocatedMB)
                                        }
                                        return nil
                                    }(),
                                    currentTextLineLimit: 1,
                                    cardHeight: 110,
                                    graphHeight: 46,
                                    isHidden: hiddenBinding(for: gpu.id, in: $hiddenGPURenderer),
                                    onFocus: onFocusGraph,
                                    activeFocusID: activeFocusID,
                                    onFocusedStateChange: onFocusedGraphChange,
                                    insightTarget: .gpu,
                                    focusSubtitle: "\(gpuTitle) · Focused view of GPU activity and memory",
                                    focusAttributionEnabled: allowsGPUAttribution,
                                    focusGPUContext: gpuFocusContext,
                                    focusInlineMeters: gpuFocusInlineMeters,
                                    focusLinePanels: gpuFocusLinePanels,
                                    focusDetailVisuals: gpuFocusDetailVisuals
                                )
                            }

                            if hasTiler {
                                UsageHistoryCard(
                                    title: "Tiler",
                                    current: gpu.tilerUsage,
                                    history: displayHistory(from: gpuSampler.tilerSeriesByGPU[gpu.id]),
                                    useMetalGraph: true,
                                    metalLineColor: SIMD4<Float>(0.55, 0.12, 0.12, 1.0),
                                    currentText: {
                                        if let tiledSceneKB = gpu.tilerSceneKB {
                                            return String(format: "Tiled Scene %d KB", tiledSceneKB)
                                        }
                                        return nil
                                    }(),
                                    currentTextLineLimit: 1,
                                    cardHeight: 110,
                                    graphHeight: 46,
                                    isHidden: hiddenBinding(for: gpu.id, in: $hiddenGPUTiler),
                                    onFocus: onFocusGraph,
                                    activeFocusID: activeFocusID,
                                    onFocusedStateChange: onFocusedGraphChange,
                                    insightTarget: .gpu,
                                    focusSubtitle: "\(gpuTitle) · Focused view of GPU activity and memory",
                                    focusAttributionEnabled: allowsGPUAttribution,
                                    focusGPUContext: gpuFocusContext,
                                    focusInlineMeters: gpuFocusInlineMeters,
                                    focusLinePanels: gpuFocusLinePanels,
                                    focusDetailVisuals: gpuFocusDetailVisuals
                                )
                            }
                        }

                        gpuMemoryPressureBar(for: gpu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    // Stacked (or compact with no sub-cards — GPU card stays full width).
                    UsageHistoryCard(
                        title: "GPU",
                        current: gpu.usage,
                        history: displayHistory(from: gpuSampler.usageSeriesByGPU[gpu.id]),
                        useMetalGraph: true,
                        metalLineColor: SIMD4<Float>(0.85, 0.20, 0.20, 1.0),
                        currentText: gpuDetailText(for: gpu),
                        secondaryText: gpuEnvironmentText(for: gpu),
                        currentTextLineLimit: 2,
                        secondaryTextLineLimit: 2,
                        cardHeight: 126,
                        graphHeight: 60,
                        isHidden: hiddenBinding(for: gpu.id, in: $hiddenGPUs),
                        deltaText: deltaBadge(from: gpuSampler.usageSeriesByGPU[gpu.id]),
                        onFocus: onFocusGraph,
                        activeFocusID: activeFocusID,
                        onFocusedStateChange: onFocusedGraphChange,
                        insightTarget: .gpu,
                        focusSubtitle: "\(gpuTitle) · Focused view of the visible history window",
                        focusAttributionEnabled: allowsGPUAttribution,
                        focusGPUContext: gpuFocusContext,
                        focusInlineMeters: gpuFocusInlineMeters,
                        focusLinePanels: gpuFocusLinePanels,
                        focusDetailVisuals: gpuFocusDetailVisuals,
                        focusExtraStats: gpuHardwareExtraStats(for: gpu),
                        focusExtraDetailLines: gpuHardwareExtraDetailLines(for: gpu)
                    )
                    gpuMemoryPressureBar(for: gpu)

                    if hasRenderer {
                        UsageHistoryCard(
                            title: "Renderer",
                            current: gpu.rendererUsage,
                            history: displayHistory(from: gpuSampler.rendererSeriesByGPU[gpu.id]),
                            useMetalGraph: true,
                            metalLineColor: SIMD4<Float>(0.55, 0.12, 0.12, 1.0),
                            currentText: {
                                if let allocatedMB = gpu.rendererAllocatedPageBufferMB {
                                    return String(format: "Allocated PB %d MB", allocatedMB)
                                }
                                return nil
                            }(),
                            currentTextLineLimit: 1,
                            cardHeight: 92,
                            graphHeight: 40,
                            isHidden: hiddenBinding(for: gpu.id, in: $hiddenGPURenderer),
                            onFocus: onFocusGraph,
                            activeFocusID: activeFocusID,
                            onFocusedStateChange: onFocusedGraphChange,
                            insightTarget: .gpu,
                            focusSubtitle: "\(gpuTitle) · Focused view of GPU activity and memory",
                            focusAttributionEnabled: allowsGPUAttribution,
                            focusGPUContext: gpuFocusContext,
                            focusInlineMeters: gpuFocusInlineMeters,
                            focusLinePanels: gpuFocusLinePanels,
                            focusDetailVisuals: gpuFocusDetailVisuals
                        )
                    }

                    if hasTiler {
                        UsageHistoryCard(
                            title: "Tiler",
                            current: gpu.tilerUsage,
                            history: displayHistory(from: gpuSampler.tilerSeriesByGPU[gpu.id]),
                            useMetalGraph: true,
                            metalLineColor: SIMD4<Float>(0.55, 0.12, 0.12, 1.0),
                            currentText: {
                                if let tiledSceneKB = gpu.tilerSceneKB {
                                    return String(format: "Tiled Scene %d KB", tiledSceneKB)
                                }
                                return nil
                            }(),
                            currentTextLineLimit: 1,
                            cardHeight: 92,
                            graphHeight: 40,
                            isHidden: hiddenBinding(for: gpu.id, in: $hiddenGPUTiler),
                            onFocus: onFocusGraph,
                            activeFocusID: activeFocusID,
                            onFocusedStateChange: onFocusedGraphChange,
                            insightTarget: .gpu,
                            focusSubtitle: "\(gpuTitle) · Focused view of GPU activity and memory",
                            focusAttributionEnabled: allowsGPUAttribution,
                            focusGPUContext: gpuFocusContext,
                            focusInlineMeters: gpuFocusInlineMeters,
                            focusLinePanels: gpuFocusLinePanels,
                            focusDetailVisuals: gpuFocusDetailVisuals
                        )
                    }
                }
            }
        }
    }

    // MARK: - Memory Section

    @ViewBuilder private var memorySection: some View {
        if compactLayout {
            HStack(alignment: .top, spacing: 16) {
                UsageHistoryCard(
                    title: "RAM",
                    current: ramSampler.ramUsage,
                    history: displayHistory(from: ramSampler.usageSeries),
                    useMetalGraph: true,
                    metalLineColor: SIMD4<Float>(0.10, 0.65, 0.28, 1.0),
                    unitLabel: ramSnapshot?.ramLabel ?? ramSampler.ramLabel,
                    currentText: ramCurrentText,
                    cardHeight: 110,
                    graphHeight: 60,
                    isHidden: $hiddenRAM,
                    deltaText: deltaBadge(from: ramSampler.usageSeries),
                    onFocus: onFocusGraph,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphChange,
                    insightTarget: .memory,
                    focusExtraStats: memoryUnitExtraStats,
                    focusExtraDetailLines: memoryUnitExtraDetailLines
                )

                UsageHistoryCard(
                    title: "Memory Pressure",
                    current: ramSampler.pressureValue,
                    history: displayHistory(from: ramSampler.pressureSeries),
                    useMetalGraph: true,
                    metalLineColor: SIMD4<Float>(0.35, 0.65, 0.05, 1.0),
                    unitLabel: ramSnapshot?.pressureLabel ?? ramSampler.pressureLabel,
                    currentText: ramSnapshot?.pressureSubtext ?? ramSampler.pressureSubtext,
                    currentTextLineLimit: 2,
                    isHidden: $hiddenMemoryPressure,
                    deltaText: deltaBadge(from: ramSampler.pressureSeries),
                    onFocus: onFocusGraph,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphChange,
                    insightTarget: .memory
                )

                UsageHistoryCard(
                    title: "Swap",
                    current: ramSampler.swapUsedRatio,
                    history: displayHistory(from: ramSampler.swapUsageSeries),
                    useMetalGraph: true,
                    metalLineColor: SIMD4<Float>(0.10, 0.55, 0.25, 1.0),
                    unitLabel: ramSnapshot?.swapLabel ?? ramSampler.swapLabel,
                    currentText: swapUsedText,
                    isHidden: $hiddenSwap,
                    onFocus: onFocusGraph,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphChange,
                    insightTarget: .memory
                )
            }
        } else {
            UsageHistoryCard(
                title: "RAM",
                current: ramSampler.ramUsage,
                history: displayHistory(from: ramSampler.usageSeries),
                useMetalGraph: true,
                metalLineColor: SIMD4<Float>(0.10, 0.65, 0.28, 1.0),
                unitLabel: ramSnapshot?.ramLabel ?? ramSampler.ramLabel,
                currentText: ramCurrentText,
                cardHeight: 110,
                graphHeight: 60,
                isHidden: $hiddenRAM,
                deltaText: deltaBadge(from: ramSampler.usageSeries),
                onFocus: onFocusGraph,
                activeFocusID: activeFocusID,
                onFocusedStateChange: onFocusedGraphChange,
                insightTarget: .memory,
                focusExtraStats: memoryUnitExtraStats,
                focusExtraDetailLines: memoryUnitExtraDetailLines
            )

            UsageHistoryCard(
                title: "Memory Pressure",
                current: ramSampler.pressureValue,
                history: displayHistory(from: ramSampler.pressureSeries),
                useMetalGraph: true,
                metalLineColor: SIMD4<Float>(0.35, 0.65, 0.05, 1.0),
                unitLabel: ramSnapshot?.pressureLabel ?? ramSampler.pressureLabel,
                currentText: ramSnapshot?.pressureSubtext ?? ramSampler.pressureSubtext,
                currentTextLineLimit: 2,
                isHidden: $hiddenMemoryPressure,
                deltaText: deltaBadge(from: ramSampler.pressureSeries),
                onFocus: onFocusGraph,
                activeFocusID: activeFocusID,
                onFocusedStateChange: onFocusedGraphChange,
                insightTarget: .memory
            )

            UsageHistoryCard(
                title: "Swap",
                current: ramSampler.swapUsedRatio,
                history: displayHistory(from: ramSampler.swapUsageSeries),
                useMetalGraph: true,
                metalLineColor: SIMD4<Float>(0.10, 0.55, 0.25, 1.0),
                unitLabel: ramSnapshot?.swapLabel ?? ramSampler.swapLabel,
                currentText: swapUsedText,
                isHidden: $hiddenSwap,
                onFocus: onFocusGraph,
                activeFocusID: activeFocusID,
                onFocusedStateChange: onFocusedGraphChange,
                insightTarget: .memory
            )
        }
    }

    // MARK: - Disk Section

    @ViewBuilder private var diskSection: some View {
        let readScaled = peakScaled(
            series: diskIOSampler.readSeries,
            current: diskIOSampler.readMBps,
            floor: 0.05,
            aggregation: .maximum
        )
        let writeScaled = peakScaled(
            series: diskIOSampler.writeSeries,
            current: diskIOSampler.writeMBps,
            floor: 0.05,
            aggregation: .maximum
        )

        if compactLayout {
            HStack(alignment: .top, spacing: 16) {
                UsageHistoryCard(
                    title: "Disk Read",
                    current: readScaled.current,
                    history: readScaled.history,
                    useMetalGraph: true,
                    metalLineColor: SIMD4<Float>(0.5, 0.5, 0.40, 1.0),
                    unitLabel: "",
                    currentText: [diskIOSampler.readText, diskIOSampler.readPeakText]
                        .compactMap { $0 == "—" ? nil : $0 }
                        .joined(separator: "  ·  "),
                    isHidden: $hiddenDiskRead,
                    onFocus: onFocusGraph,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphChange,
                    insightTarget: .disk
                )

                UsageHistoryCard(
                    title: "Disk Write",
                    current: writeScaled.current,
                    history: writeScaled.history,
                    useMetalGraph: true,
                    metalLineColor: .diskWriteAccentColor,
                    unitLabel: "",
                    currentText: [diskIOSampler.writeText, diskIOSampler.writePeakText]
                        .compactMap { $0 == "—" ? nil : $0 }
                        .joined(separator: "  ·  "),
                    isHidden: $hiddenDiskWrite,
                    onFocus: onFocusGraph,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphChange,
                    insightTarget: .disk
                )
            }
        } else {
            UsageHistoryCard(
                title: "Disk Read",
                current: readScaled.current,
                history: readScaled.history,
                useMetalGraph: true,
                metalLineColor: SIMD4<Float>(0.5, 0.5, 0.40, 1.0),
                unitLabel: "",
                currentText: [diskIOSampler.readText, diskIOSampler.readPeakText]
                    .compactMap { $0 == "—" ? nil : $0 }
                    .joined(separator: "  ·  "),
                isHidden: $hiddenDiskRead,
                onFocus: onFocusGraph,
                activeFocusID: activeFocusID,
                onFocusedStateChange: onFocusedGraphChange,
                insightTarget: .disk
            )

            UsageHistoryCard(
                title: "Disk Write",
                current: writeScaled.current,
                history: writeScaled.history,
                useMetalGraph: true,
                metalLineColor: .diskWriteAccentColor,
                unitLabel: "",
                currentText: [diskIOSampler.writeText, diskIOSampler.writePeakText]
                    .compactMap { $0 == "—" ? nil : $0 }
                    .joined(separator: "  ·  "),
                isHidden: $hiddenDiskWrite,
                onFocus: onFocusGraph,
                activeFocusID: activeFocusID,
                onFocusedStateChange: onFocusedGraphChange,
                insightTarget: .disk
            )
        }
    }

    // MARK: - Network Section

    @ViewBuilder private var networkSection: some View {
        let uploadScaled   = peakScaled(series: networkSampler.uploadSeries,   current: networkSampler.uploadMBps,   floor: 0.1)
        let downloadScaled = peakScaled(series: networkSampler.downloadSeries, current: networkSampler.downloadMBps, floor: 0.1)

        if compactLayout {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    UsageHistoryCard(
                        title: "Network Upload",
                        current: uploadScaled.current,
                        history: uploadScaled.history,
                        useMetalGraph: true,
                        metalLineColor: .networkAccentColor,
                        unitLabel: "",
                        currentText: [networkSampler.uploadText, networkSampler.uploadPeakText]
                            .compactMap { $0 == "—" ? nil : $0 }
                            .joined(separator: "  ·  "),
                        isHidden: $hiddenNetworkUpload,
                        deltaText: deltaBadge(from: networkSampler.uploadSeries),
                        onFocus: onFocusGraph,
                        activeFocusID: activeFocusID,
                        onFocusedStateChange: onFocusedGraphChange,
                        insightTarget: .network,
                        focusLinePanels: networkFocusLinePanels,
                        focusDetailVisuals: networkSettingsDetailVisual().map { [$0] } ?? [],
                        focusExtraStats: networkInterfaceExtraStats,
                        focusExtraDetailLines: networkInterfaceExtraDetailLines,
                        detailActionHandler: networkSettingsActionHandler
                    )

                    UsageHistoryCard(
                        title: "Network Download",
                        current: downloadScaled.current,
                        history: downloadScaled.history,
                        useMetalGraph: true,
                        metalLineColor: .networkAccentColorDimmed,
                        unitLabel: "",
                        currentText: [networkSampler.downloadText, networkSampler.downloadPeakText]
                            .compactMap { $0 == "—" ? nil : $0 }
                            .joined(separator: "  ·  "),
                        isHidden: $hiddenNetworkDownload,
                        deltaText: deltaBadge(from: networkSampler.downloadSeries),
                        onFocus: onFocusGraph,
                        activeFocusID: activeFocusID,
                        onFocusedStateChange: onFocusedGraphChange,
                        insightTarget: .network,
                        focusLinePanels: networkFocusLinePanels,
                        focusDetailVisuals: networkSettingsDetailVisual().map { [$0] } ?? [],
                        focusExtraStats: networkInterfaceExtraStats,
                        focusExtraDetailLines: networkInterfaceExtraDetailLines,
                        detailActionHandler: networkSettingsActionHandler
                    )
                }

                pingLatencyMeterBar()
                    .padding(.horizontal, 2)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                UsageHistoryCard(
                    title: "Network Upload",
                    current: uploadScaled.current,
                    history: uploadScaled.history,
                    useMetalGraph: true,
                    metalLineColor: .networkAccentColor,
                    unitLabel: "",
                    currentText: [networkSampler.uploadText, networkSampler.uploadPeakText]
                        .compactMap { $0 == "—" ? nil : $0 }
                        .joined(separator: "  ·  "),
                    isHidden: $hiddenNetworkUpload,
                    deltaText: deltaBadge(from: networkSampler.uploadSeries),
                    onFocus: onFocusGraph,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphChange,
                    insightTarget: .network,
                    focusLinePanels: networkFocusLinePanels,
                    focusDetailVisuals: networkSettingsDetailVisual().map { [$0] } ?? [],
                    focusExtraStats: networkInterfaceExtraStats,
                    focusExtraDetailLines: networkInterfaceExtraDetailLines,
                    detailActionHandler: networkSettingsActionHandler
                )

                UsageHistoryCard(
                    title: "Network Download",
                    current: downloadScaled.current,
                    history: downloadScaled.history,
                    useMetalGraph: true,
                    metalLineColor: .networkAccentColorDimmed,
                    unitLabel: "",
                    currentText: [networkSampler.downloadText, networkSampler.downloadPeakText]
                        .compactMap { $0 == "—" ? nil : $0 }
                        .joined(separator: "  ·  "),
                    isHidden: $hiddenNetworkDownload,
                    deltaText: deltaBadge(from: networkSampler.downloadSeries),
                    onFocus: onFocusGraph,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphChange,
                    insightTarget: .network,
                    focusLinePanels: networkFocusLinePanels,
                    focusDetailVisuals: networkSettingsDetailVisual().map { [$0] } ?? [],
                    focusExtraStats: networkInterfaceExtraStats,
                    focusExtraDetailLines: networkInterfaceExtraDetailLines,
                    detailActionHandler: networkSettingsActionHandler
                )

                pingLatencyMeterBar()
                    .padding(.horizontal, 2)
            }
        }
    }

    // MARK: - System Section

    @ViewBuilder private var systemSection: some View {
        if compactLayout {
            VStack(alignment: .leading, spacing: 16) {
                if aneSampler.hasNeuralEngine || shouldShowMediaEngineUsageCard {
                    HStack(alignment: .top, spacing: 16) {
                        if aneSampler.hasNeuralEngine {
                            aneUsageCard
                        }
                        if shouldShowMediaEngineUsageCard {
                            mediaEngineUsageCard
                        }
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    thermalUsageCard
                    energyUsageCard
                }
            }
        } else {
            if aneSampler.hasNeuralEngine {
                aneUsageCard
            }

            if shouldShowMediaEngineUsageCard {
                mediaEngineUsageCard
            }
            thermalUsageCard
            energyUsageCard
        }
    }

    // MARK: - Periodic Averages Section

    @ViewBuilder private var periodicAveragesSection: some View {
        if compactLayout {
            HStack(alignment: .top, spacing: 8) {
                floatingCardMenu(.periodicAverages) {
                    PeriodicAveragesCard(
                        historyReader: historyReader,
                        hasNeuralEngine: aneSampler.hasNeuralEngine,
                        primaryGPUID: gpuSampler.gpus.first?.id,
                        historyRefreshToken: longHorizonHistoryRefreshToken,
                        onFocus: onFocusGraph,
                        activeFocusID: activeFocusID,
                        onFocusedStateChange: onFocusedGraphChange,
                        isCompact: true
                    )
                }

                floatingCardMenu(.activityHeatmap) {
                    ActivityHeatmapCard(
                        historyReader: historyReader,
                        primaryGPUID: gpuSampler.gpus.first?.id,
                        hasNeuralEngine: aneSampler.hasNeuralEngine,
                        historyRefreshToken: longHorizonHistoryRefreshToken,
                        onFocus: onFocusGraph,
                        activeFocusID: activeFocusID,
                        onFocusedStateChange: onFocusedGraphChange
                    )
                }
            }
        } else {
            floatingCardMenu(.periodicAverages) {
                PeriodicAveragesCard(
                    historyReader: historyReader,
                    hasNeuralEngine: aneSampler.hasNeuralEngine,
                    primaryGPUID: gpuSampler.gpus.first?.id,
                    historyRefreshToken: longHorizonHistoryRefreshToken,
                    onFocus: onFocusGraph,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphChange
                )
            }

            floatingCardMenu(.activityHeatmap) {
                ActivityHeatmapCard(
                    historyReader: historyReader,
                    primaryGPUID: gpuSampler.gpus.first?.id,
                    hasNeuralEngine: aneSampler.hasNeuralEngine,
                    historyRefreshToken: longHorizonHistoryRefreshToken,
                    onFocus: onFocusGraph,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphChange
                )
            }
        }

        if !isRemoteContext {
            SystemStereoMixVisualizationCardView(floatingSource: floatingSource)
        }
    }

}

struct SystemStereoMixVisualizationCardView: View {
    @Environment(\.appUIScale) private var appUIScale
    @ObservedObject private var systemAudioOutputMeter = SystemAudioOutputMeterModel.shared
    @StateObject private var systemMixVisualizationMonitoring = MonitoringState(autoRefreshDevices: false)
    @State private var systemMixFFTSize = 1024
    @State private var systemMixSpectrumDecay: SpectrumView.DecayOption = .medium
    @State private var systemMixFreqRange: SpectrumView.FrequencyRangePreset = .fullRange
    @State private var systemMixWaveformDuration: TimeInterval = 2
    @State private var attachedSystemMixVizRing: OpaquePointer?
    @State private var attachedSystemMixVizRate: Double = 0
    let floatingSource: FloatingMonitorCardSource?

    @ViewBuilder
    private func floatingCardMenu<Content: View>(
        _ cardKind: FloatingMonitorCardKind,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if let floatingSource {
            content().floatingMonitorContextMenu(cardKind: cardKind, source: floatingSource)
        } else {
            content()
        }
    }

    var body: some View {
        let snap = systemAudioOutputMeter.snapshot
        let backendFeedsViz = snap.selectedBackend == .screenCapture || snap.selectedBackend == .coreAudioTap
        let hasFeed = snap.captureActive && snap.isCaptureEnabled && backendFeedsViz
            && systemAudioOutputMeter.stereoMixVisualizationRingBufferHandle != nil

        ZStack {
            ThemeRoundedRectangle(cornerRadius: 16 * appUIScale).themed()

            VStack(alignment: .leading, spacing: 14 * appUIScale) {
                VStack(alignment: .leading, spacing: 4 * appUIScale) {
                    Text("System Mix · Spectrum & Waveform")
                        .font(.system(size: 13 * appUIScale, weight: .semibold))
                    Text(
                        hasFeed
                            ? "Live analysis from the same Stereo Output capture as the sidebar (Screen Capture or Core Audio tap). Virtual Input / Loopback metering does not populate this view."
                            : "Start Stereo Output with Screen Capture or Core Audio tap in the sidebar to mirror system audio here using the same FFT and waveform engines as the Audio tab."
                    )
                    .font(.system(size: 11 * appUIScale, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if hasFeed {
                    VStack(spacing: 18 * appUIScale) {
                        ZStack {
                            ThemeRoundedRectangle(cornerRadius: 12 * appUIScale).themed(fill: Color.black.opacity(0.12), stroke: Color.white.opacity(0.1))
                            WaveformHistoryView(
                                monitoring: systemMixVisualizationMonitoring,
                                historyDuration: $systemMixWaveformDuration
                            )
                            .padding(.vertical, 4 * appUIScale)
                        }
                        .frame(height: max(96 * appUIScale, 84))

                        floatingCardMenu(.spectrum) {
                            ZStack(alignment: .topLeading) {
                                ThemeRoundedRectangle(cornerRadius: 12 * appUIScale).themed(fill: Color.black.opacity(0.12), stroke: Color.white.opacity(0.1))
                                SpectrumView(
                                    monitoring: systemMixVisualizationMonitoring,
                                    fftSize: $systemMixFFTSize,
                                    decay: $systemMixSpectrumDecay,
                                    selectedFreqRange: $systemMixFreqRange
                                )
                                .padding(EdgeInsets(
                                    top: 12 * appUIScale,
                                    leading: 10 * appUIScale,
                                    bottom: 10 * appUIScale,
                                    trailing: 10 * appUIScale
                                ))
                            }
                            .frame(height: max(240 * appUIScale, 200))
                            .contentShape(ThemeRoundedRectangle(cornerRadius: 12 * appUIScale))
                        }
                    }
                }
            }
            .padding(12 * appUIScale)
        }
        .onAppear {
            syncSystemMixHardwareVisualization()
        }
        .onReceive(systemAudioOutputMeter.$snapshot) { _ in
            syncSystemMixHardwareVisualization()
        }
    }

    private func syncSystemMixHardwareVisualization() {
        let snap = systemAudioOutputMeter.snapshot
        let backendFeedsViz = snap.selectedBackend == .screenCapture || snap.selectedBackend == .coreAudioTap
        guard snap.captureActive,
              snap.isCaptureEnabled,
              backendFeedsViz,
              let ring = systemAudioOutputMeter.stereoMixVisualizationRingBufferHandle else {
            if attachedSystemMixVizRing != nil {
                systemMixVisualizationMonitoring.stopMonitoring()
                attachedSystemMixVizRing = nil
                attachedSystemMixVizRate = 0
            }
            return
        }

        let rate = systemAudioOutputMeter.stereoMixVisualizationSampleRate
        if attachedSystemMixVizRing == ring, abs(attachedSystemMixVizRate - rate) < 0.5 {
            return
        }

        attachedSystemMixVizRing = ring
        attachedSystemMixVizRate = rate

        let label = "System mix · \(snap.capturePathText)"
        systemMixVisualizationMonitoring.startExternalMonitoring(
            sourceName: label,
            ringBuffer: ring,
            channelCount: 2,
            sampleRate: rate,
            themeColor: SystemOutputMeterCard.stereoOutputMeterThemeColor,
            manufacturer: snap.capturePathText,
            connection: "Stereo Output capture"
        )
    }
}

@MainActor
private final class HardwareGraphHistoryBackfillStore: ObservableObject {
    struct DeviceRequest: Hashable {
        let key: HardwareDeviceMetricKey
        let deviceID: String
        let deviceKind: HardwareDeviceKind
    }

    @Published private var metricTimelines: [HardwareMetricKey: [HardwareHistoryMetricBucket]] = [:]
    @Published private var deviceTimelines: [DeviceRequest: [HardwareHistoryMetricBucket]] = [:]
    @Published private(set) var revision: Int = 0

    func refresh(
        historyReader: any HardwareHistoryQuerying,
        range: DateInterval,
        displayIntervalSeconds: Int,
        metricKeys: [HardwareMetricKey],
        deviceRequests: [DeviceRequest]
    ) async {
        let sourceBucketIntervalSeconds = max(60, displayIntervalSeconds)

        var metricResults: [HardwareMetricKey: [HardwareHistoryMetricBucket]] = [:]
        for key in metricKeys {
            metricResults[key] = await historyReader.metricTimeline(
                for: key,
                in: range,
                bucketIntervalSeconds: sourceBucketIntervalSeconds
            )
        }

        var deviceResults: [DeviceRequest: [HardwareHistoryMetricBucket]] = [:]
        for request in deviceRequests {
            deviceResults[request] = await historyReader.deviceMetricTimeline(
                for: request.key,
                deviceID: request.deviceID,
                deviceKind: request.deviceKind,
                in: range,
                bucketIntervalSeconds: sourceBucketIntervalSeconds
            )
        }

        metricTimelines = metricResults
        deviceTimelines = deviceResults
        revision &+= 1
    }

    func alignedMetricValues(
        for key: HardwareMetricKey,
        in range: DateInterval,
        bucketIntervalSeconds: Int,
        aggregation: MetricBucketAggregation
    ) -> [Double?] {
        alignedValues(
            from: metricTimelines[key] ?? [],
            in: range,
            bucketIntervalSeconds: bucketIntervalSeconds,
            aggregation: aggregation
        )
    }

    func alignedDeviceValues(
        for key: HardwareDeviceMetricKey,
        deviceID: String,
        deviceKind: HardwareDeviceKind,
        in range: DateInterval,
        bucketIntervalSeconds: Int,
        aggregation: MetricBucketAggregation
    ) -> [Double?] {
        alignedValues(
            from: deviceTimelines[DeviceRequest(key: key, deviceID: deviceID, deviceKind: deviceKind)] ?? [],
            in: range,
            bucketIntervalSeconds: bucketIntervalSeconds,
            aggregation: aggregation
        )
    }

    private func alignedValues(
        from timeline: [HardwareHistoryMetricBucket],
        in range: DateInterval,
        bucketIntervalSeconds: Int,
        aggregation: MetricBucketAggregation
    ) -> [Double?] {
        let interval = TimeInterval(max(1, bucketIntervalSeconds))
        let bucketCount = max(1, Int(ceil(range.duration / interval)))
        var values = Array<Double?>(repeating: nil, count: bucketCount)

        for bucket in timeline {
            let value: Double?
            switch aggregation {
            case .latest:
                value = bucket.lastValue
            case .average:
                value = bucket.averageValue
            case .maximum:
                value = bucket.maxValue
            @unknown default:
                value = bucket.lastValue
            }

            guard let value else { continue }

            let bucketStart = bucket.bucketStart
            let bucketEnd = bucketStart.addingTimeInterval(TimeInterval(max(1, bucket.bucketDurationSeconds)))
            if bucketEnd <= range.start || bucketStart >= range.end { continue }

            let startIndex = max(0, Int(floor(bucketStart.timeIntervalSince(range.start) / interval)))
            let endIndexExclusive = min(
                bucketCount,
                max(startIndex + 1, Int(ceil(bucketEnd.timeIntervalSince(range.start) / interval)))
            )

            guard startIndex < endIndexExclusive else { continue }
            for index in startIndex..<endIndexExclusive {
                values[index] = value
            }
        }

        return values
    }
}

private struct ObservedSubtree<Object: ObservableObject, Content: View>: View {
    @ObservedObject var primary: Object
    let content: () -> Content

    var body: some View {
        content()
    }
}

private struct ObservedSubtree2<Object1: ObservableObject, Object2: ObservableObject, Content: View>: View {
    @ObservedObject var primary: Object1
    @ObservedObject var secondary: Object2
    let content: () -> Content

    var body: some View {
        content()
    }
}

private struct ObservedSubtree4<
    Object1: ObservableObject,
    Object2: ObservableObject,
    Object3: ObservableObject,
    Object4: ObservableObject,
    Content: View
>: View {
    @ObservedObject var object1: Object1
    @ObservedObject var object2: Object2
    @ObservedObject var object3: Object3
    @ObservedObject var object4: Object4
    let content: () -> Content

    init(
        object1: Object1,
        object2: Object2,
        object3: Object3,
        object4: Object4,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._object1 = ObservedObject(wrappedValue: object1)
        self._object2 = ObservedObject(wrappedValue: object2)
        self._object3 = ObservedObject(wrappedValue: object3)
        self._object4 = ObservedObject(wrappedValue: object4)
        self.content = content
    }

    var body: some View {
        content()
    }
}

private struct ObservedSubtree6<
    Object1: ObservableObject,
    Object2: ObservableObject,
    Object3: ObservableObject,
    Object4: ObservableObject,
    Object5: ObservableObject,
    Object6: ObservableObject,
    Content: View
>: View {
    @ObservedObject var object1: Object1
    @ObservedObject var object2: Object2
    @ObservedObject var object3: Object3
    @ObservedObject var object4: Object4
    @ObservedObject var object5: Object5
    @ObservedObject var object6: Object6
    let content: () -> Content

    var body: some View {
        content()
    }
}
