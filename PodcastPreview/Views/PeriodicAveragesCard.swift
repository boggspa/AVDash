import SwiftUI
import PodcastPreviewCore
import PodcastPreviewShared
import Combine

// MARK: - Period

enum PeriodicAveragesPeriod: String, CaseIterable {
    case day   = "24h"
    case week  = "7d"
    case month = "30d"

    var windowSeconds: TimeInterval {
        switch self {
        case .day:   return 24 * 3_600
        case .week:  return 7 * 24 * 3_600
        case .month: return 30 * 24 * 3_600
        }
    }

    /// Bucket granularity: 1 hr (24 pts), 6 hr (28 pts), 1 day (30 pts).
    var bucketSeconds: Int {
        switch self {
        case .day:   return 3_600
        case .week:  return 6 * 3_600
        case .month: return 86_400
        }
    }

    var verticalGridlineCount: Int {
        switch self {
        case .day:   return 24
        case .week:  return 28
        case .month: return 30
        }
    }
}

// MARK: - Series model

struct PeriodicAveragesSeries: Identifiable {
    let id: String
    let label: String
    let color: Color
    /// Normalised [0, 1] values aligned to a fixed bucket grid; nil = no data.
    let values: [Double?]
}

enum PeriodicAveragesGapKind: String {
    case noData
    case offline

    var label: String {
        switch self {
        case .noData:
            return "No Data"
        case .offline:
            return "Offline"
        }
    }

    var fillColor: Color {
        switch self {
        case .noData:
            return Color.white.opacity(0.09)
        case .offline:
            return Color(red: 0.05, green: 0.13, blue: 0.29).opacity(0.52)
        }
    }

    var stripeColor: Color {
        switch self {
        case .noData:
            return Color.white.opacity(0.12)
        case .offline:
            return Color(red: 0.45, green: 0.60, blue: 0.88).opacity(0.18)
        }
    }

    var labelColor: Color {
        switch self {
        case .noData:
            return Color.white.opacity(0.65)
        case .offline:
            return Color(red: 0.76, green: 0.85, blue: 1.0).opacity(0.88)
        }
    }
}

struct PeriodicAveragesGapRegion: Identifiable {
    let lowerIndex: Int
    let upperIndex: Int
    let kind: PeriodicAveragesGapKind

    var id: String {
        "\(kind.rawValue)-\(lowerIndex)-\(upperIndex)"
    }
}

private struct PeriodicAveragesLoadResult {
    let series: [PeriodicAveragesSeries]
    let gapRegions: [PeriodicAveragesGapRegion]
}

// MARK: - ViewModel

@MainActor
final class PeriodicAveragesViewModel: ObservableObject {
    @Published var series: [PeriodicAveragesSeries] = []
    @Published var gapRegions: [PeriodicAveragesGapRegion] = []
    @Published var isLoading = false

    private var fetchTask: Task<Void, Never>?
    private var refreshGeneration: Int = 0

    func refresh(
        period: PeriodicAveragesPeriod,
        reader: any HardwareHistoryQuerying,
        hasNeuralEngine: Bool,
        primaryGPUID: String?,
        clearExisting: Bool = false
    ) {
        fetchTask?.cancel()
        refreshGeneration &+= 1
        let generation = refreshGeneration
        if clearExisting {
            series = []
            gapRegions = []
        }
        isLoading = true

        fetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.refreshGeneration == generation {
                    self.isLoading = false
                    self.fetchTask = nil
                }
            }
            let result = await PeriodicAveragesViewModel.loadSeries(
                period: period,
                reader: reader,
                hasNeuralEngine: hasNeuralEngine,
                primaryGPUID: primaryGPUID
            )
            guard !Task.isCancelled else { return }
            guard self.refreshGeneration == generation else { return }
            self.series = result.series
            self.gapRegions = result.gapRegions
        }
    }

    func cancel() {
        fetchTask?.cancel()
        fetchTask = nil
        refreshGeneration &+= 1
        isLoading = false
    }

    // MARK: - Data loading

    private static func loadSeries(
        period: PeriodicAveragesPeriod,
        reader: any HardwareHistoryQuerying,
        hasNeuralEngine: Bool,
        primaryGPUID: String?
    ) async -> PeriodicAveragesLoadResult {

        let now = Date()
        let range = DateInterval(
            start: now.addingTimeInterval(-period.windowSeconds),
            end: now
        )
        let bs = period.bucketSeconds
        let grid = buildGrid(range: range, bucketSeconds: bs)

        // Sequential awaits keep the remote/headless history backend from fanning out
        // a large burst of concurrent database or XPC work for every refresh.
        let cpuTL     = await reader.metricTimeline(for: .cpuTotalUsage,        in: range, bucketIntervalSeconds: bs)
        let memTL     = await reader.metricTimeline(for: .memoryPressureRatio,   in: range, bucketIntervalSeconds: bs)
        let aneTL     = await reader.metricTimeline(for: .aneActivityRatio,      in: range, bucketIntervalSeconds: bs)
        let diskRTL   = await reader.metricTimeline(for: .diskReadMBps,          in: range, bucketIntervalSeconds: bs)
        let diskWTL   = await reader.metricTimeline(for: .diskWriteMBps,         in: range, bucketIntervalSeconds: bs)
        let netUpTL   = await reader.metricTimeline(for: .networkUploadMBps,    in: range, bucketIntervalSeconds: bs)
        let netDownTL = await reader.metricTimeline(for: .networkDownloadMBps,  in: range, bucketIntervalSeconds: bs)
        let powerTL   = await reader.metricTimeline(for: .combinedPowerWatts,   in: range, bucketIntervalSeconds: bs)
        let uptimeTL  = await reader.metricTimeline(for: .systemUptimeSeconds,  in: range, bucketIntervalSeconds: bs)

        guard !Task.isCancelled else { return .init(series: [], gapRegions: []) }

        // GPU utilisation (device metric — requires a device ID)
        var gpuTimeline: [HardwareHistoryMetricBucket]? = nil
        var gpuValues: [Double?]? = nil
        if let gpuID = primaryGPUID {
            let gpuTL = await reader.deviceMetricTimeline(
                for: .utilizationRatio, deviceID: gpuID, deviceKind: .gpu,
                in: range, bucketIntervalSeconds: bs
            )
            let vals = alignRatio(gpuTL, to: grid, bucketSeconds: bs)
            if vals.contains(where: { $0 != nil }) {
                gpuTimeline = gpuTL
                gpuValues = vals
            }
        }

        guard !Task.isCancelled else { return .init(series: [], gapRegions: []) }

        var out: [PeriodicAveragesSeries] = []

        // CPU — ratio metric, already [0, 1]
        out.append(.init(id: "cpu", label: "CPU", color: .blue,
            values: alignRatio(cpuTL, to: grid, bucketSeconds: bs)))

        // GPU — ratio metric, only shown when history exists
        if let gv = gpuValues {
            out.append(.init(id: "gpu", label: "GPU",
                color: Color(red: 0.85, green: 0.20, blue: 0.20),
                values: gv))
        }

        // Memory pressure — ratio metric; mint colour matched to Insights card (Big Sur-compatible)
        out.append(.init(id: "memory", label: "Press",
            color: Color(red: 0.0, green: 0.78, blue: 0.58),
            values: alignRatio(memTL, to: grid, bucketSeconds: bs)))

        // Neural Engine — ratio metric, only when present
        if hasNeuralEngine {
            out.append(.init(id: "ane", label: "ANE",
                color: Color(red: 0.65, green: 0.00, blue: 0.65),
                values: alignRatio(aneTL, to: grid, bucketSeconds: bs)))
        }

        // Disk I/O — combined read+write MB/s, auto-scaled to window peak
        let diskRaw = combineAbsolute(diskRTL, diskWTL, to: grid, bucketSeconds: bs)
        out.append(.init(id: "disk", label: "Disk",
            color: Color(red: 0.55, green: 0.55, blue: 0.10),
            values: autoScale(diskRaw)))

        // Network — combined upload+download MB/s, auto-scaled
        let netRaw = combineAbsolute(netUpTL, netDownTL, to: grid, bucketSeconds: bs)
        out.append(.init(id: "network", label: "Net",
            color: .networkAccentColor,
            values: autoScale(netRaw)))

        // Power — combined watts, auto-scaled
        let powerRaw = alignAbsolute(powerTL, to: grid, bucketSeconds: bs)
        out.append(.init(id: "power", label: "Pwr", color: .orange,
            values: autoScale(powerRaw)))

        var presenceMasks: [[Bool]] = [
            alignPresence(cpuTL, to: grid, bucketSeconds: bs),
            alignPresence(memTL, to: grid, bucketSeconds: bs),
            alignPresence(diskRTL, to: grid, bucketSeconds: bs),
            alignPresence(diskWTL, to: grid, bucketSeconds: bs),
            alignPresence(netUpTL, to: grid, bucketSeconds: bs),
            alignPresence(netDownTL, to: grid, bucketSeconds: bs),
            alignPresence(powerTL, to: grid, bucketSeconds: bs)
        ]
        if hasNeuralEngine {
            presenceMasks.append(alignPresence(aneTL, to: grid, bucketSeconds: bs))
        }
        if let gpuTimeline {
            presenceMasks.append(alignPresence(gpuTimeline, to: grid, bucketSeconds: bs))
        }

        let observedMask = combinePresenceMasks(presenceMasks, count: grid.count)
        let uptimeValues = alignLastValue(uptimeTL, to: grid, bucketSeconds: bs)
        let gapRegions = classifyGapRegions(
            observedMask: observedMask,
            uptimeValues: uptimeValues,
            bucketSeconds: bs
        )

        // Write to widget storage
        let widgetSeries = out.map { series in
            #if os(macOS)
            let cgColor = series.color.cgColor?.components ?? [0, 0, 0, 1]
            #else
            let cgColor = [0, 0, 0, 1]
            #endif
            return PeriodicAveragesWidgetData.SeriesData(
                id: series.id,
                label: series.label,
                colorRed: Double(cgColor[0]),
                colorGreen: Double(cgColor[1]),
                colorBlue: Double(cgColor[2]),
                values: series.values
            )
        }
        let widgetData = PeriodicAveragesWidgetData(
            period: period.rawValue,
            timestamp: now,
            series: widgetSeries
        )
        WidgetStorage.savePeriodicAveragesData(widgetData)

        return .init(series: out, gapRegions: gapRegions)
    }

    // MARK: - Grid & alignment helpers

    /// Build a fixed array of bucket-start dates spanning `range`.
    private static func buildGrid(range: DateInterval, bucketSeconds: Int) -> [Date] {
        let interval = TimeInterval(bucketSeconds)
        let count = max(1, Int(ceil(range.duration / interval)))
        return (0..<count).map { range.start.addingTimeInterval(TimeInterval($0) * interval) }
    }

    /// Map ratio-valued timeline buckets onto a fixed grid. Values clamped to [0, 1].
    private static func alignRatio(
        _ timeline: [HardwareHistoryMetricBucket],
        to grid: [Date],
        bucketSeconds: Int
    ) -> [Double?] {
        guard let gridStart = grid.first else { return [] }
        let interval = TimeInterval(bucketSeconds)
        var result: [Double?] = Array(repeating: nil, count: grid.count)
        for bucket in timeline {
            guard let avg = bucket.averageValue else { continue }
            let idx = Int(bucket.bucketStart.timeIntervalSince(gridStart) / interval)
            if result.indices.contains(idx) {
                result[idx] = min(max(avg, 0.0), 1.0)
            }
        }
        return result
    }

    /// Map absolute-value timeline buckets (MB/s, W, …) onto a fixed grid without clamping.
    private static func alignAbsolute(
        _ timeline: [HardwareHistoryMetricBucket],
        to grid: [Date],
        bucketSeconds: Int
    ) -> [Double?] {
        guard let gridStart = grid.first else { return [] }
        let interval = TimeInterval(bucketSeconds)
        var result: [Double?] = Array(repeating: nil, count: grid.count)
        for bucket in timeline {
            guard let avg = bucket.averageValue else { continue }
            let idx = Int(bucket.bucketStart.timeIntervalSince(gridStart) / interval)
            if result.indices.contains(idx) {
                result[idx] = max(avg, 0.0)
            }
        }
        return result
    }

    /// Map bucket last-values onto the grid, used for monotonic uptime classification.
    private static func alignLastValue(
        _ timeline: [HardwareHistoryMetricBucket],
        to grid: [Date],
        bucketSeconds: Int
    ) -> [Double?] {
        guard let gridStart = grid.first else { return [] }
        let interval = TimeInterval(bucketSeconds)
        var result: [Double?] = Array(repeating: nil, count: grid.count)
        for bucket in timeline {
            guard let last = bucket.lastValue else { continue }
            let idx = Int(bucket.bucketStart.timeIntervalSince(gridStart) / interval)
            if result.indices.contains(idx) {
                result[idx] = max(last, 0.0)
            }
        }
        return result
    }

    /// Track whether a bucket had any observed history at all, independent of value magnitude.
    private static func alignPresence(
        _ timeline: [HardwareHistoryMetricBucket],
        to grid: [Date],
        bucketSeconds: Int
    ) -> [Bool] {
        guard let gridStart = grid.first else { return [] }
        let interval = TimeInterval(bucketSeconds)
        var result = Array(repeating: false, count: grid.count)
        for bucket in timeline {
            guard bucket.observedSampleCount > 0 || bucket.observedRollupCount > 0 else { continue }
            let idx = Int(bucket.bucketStart.timeIntervalSince(gridStart) / interval)
            if result.indices.contains(idx) {
                result[idx] = true
            }
        }
        return result
    }

    private static func combinePresenceMasks(_ masks: [[Bool]], count: Int) -> [Bool] {
        var combined = Array(repeating: false, count: count)
        for mask in masks {
            for idx in 0..<min(mask.count, combined.count) where mask[idx] {
                combined[idx] = true
            }
        }
        return combined
    }

    private static func classifyGapRegions(
        observedMask: [Bool],
        uptimeValues: [Double?],
        bucketSeconds: Int
    ) -> [PeriodicAveragesGapRegion] {
        guard !observedMask.isEmpty else { return [] }

        var regions: [PeriodicAveragesGapRegion] = []
        var idx = 0
        while idx < observedMask.count {
            guard !observedMask[idx] else {
                idx += 1
                continue
            }

            let start = idx
            while idx + 1 < observedMask.count, !observedMask[idx + 1] {
                idx += 1
            }
            let end = idx

            regions.append(
                PeriodicAveragesGapRegion(
                    lowerIndex: start,
                    upperIndex: end,
                    kind: classifyGapKind(
                        startIndex: start,
                        endIndex: end,
                        observedMask: observedMask,
                        uptimeValues: uptimeValues,
                        bucketSeconds: bucketSeconds
                    )
                )
            )
            idx += 1
        }

        return regions
    }

    private static func classifyGapKind(
        startIndex: Int,
        endIndex: Int,
        observedMask: [Bool],
        uptimeValues: [Double?],
        bucketSeconds: Int
    ) -> PeriodicAveragesGapKind {
        let previousObservedIndex = stride(from: startIndex - 1, through: 0, by: -1).first { index in
            observedMask[index] && uptimeValues[index] != nil
        }
        let nextObservedIndex = (endIndex + 1..<observedMask.count).first { index in
            observedMask[index] && uptimeValues[index] != nil
        }

        guard
            let previousObservedIndex,
            let nextObservedIndex,
            let previousUptime = uptimeValues[previousObservedIndex],
            let nextUptime = uptimeValues[nextObservedIndex]
        else {
            return .noData
        }

        let wallElapsedSeconds = Double(nextObservedIndex - previousObservedIndex) * Double(bucketSeconds)
        guard wallElapsedSeconds > 0 else { return .noData }

        let uptimeElapsedSeconds = nextUptime - previousUptime
        let toleranceSeconds = max(180.0, Double(bucketSeconds) * 0.35)

        if uptimeElapsedSeconds < -toleranceSeconds {
            return .offline
        }

        if uptimeElapsedSeconds + toleranceSeconds < wallElapsedSeconds {
            return .offline
        }

        return .noData
    }

    /// Combine two absolute-value timelines element-wise (sum where both present).
    private static func combineAbsolute(
        _ tl1: [HardwareHistoryMetricBucket],
        _ tl2: [HardwareHistoryMetricBucket],
        to grid: [Date],
        bucketSeconds: Int
    ) -> [Double?] {
        let v1 = alignAbsolute(tl1, to: grid, bucketSeconds: bucketSeconds)
        let v2 = alignAbsolute(tl2, to: grid, bucketSeconds: bucketSeconds)
        return zip(v1, v2).map { a, b -> Double? in
            switch (a, b) {
            case let (a?, b?): return a + b
            default: return a ?? b
            }
        }
    }

    /// Normalise absolute values to [0, 1] relative to the window peak.
    private static func autoScale(_ values: [Double?]) -> [Double?] {
        let peak = values.compactMap { $0 }.max() ?? 0
        guard peak > 0 else { return values }
        return values.map { $0.map { $0 / peak } }
    }
}

// MARK: - Multi-line graph
// Uses GeometryReader + Path instead of Canvas for Big Sur (macOS 11) compatibility.

struct PeriodicAveragesGraphView: View {
    let series: [PeriodicAveragesSeries]
    let gapRegions: [PeriodicAveragesGapRegion]
    let verticalGridlineCount: Int

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.12)

                gridLines(in: geo.size)

                if let count = series.first?.values.count, count > 0 {
                    ForEach(gapRegions) { region in
                        gapOverlay(for: region, in: geo.size, count: count)
                    }
                }

                if let count = series.first?.values.count, count > 1 {
                    ForEach(series) { s in
                        if s.values.count == count {
                            linePath(for: s, in: geo.size, count: count)
                                .stroke(s.color, lineWidth: 1.5)
                        }
                    }
                }
            }
        }
        .clipShape(ThemeRoundedRectangle(cornerRadius: 6))
    }

    private func gapOverlay(for region: PeriodicAveragesGapRegion, in size: CGSize, count: Int) -> some View {
        let rect = gapRect(for: region, in: size, count: count)

        return ZStack {
            Rectangle()
                .fill(region.kind.fillColor)

            Path { path in
                let stripeSpacing: CGFloat = 12
                for startX in stride(from: -rect.height, through: rect.width + rect.height, by: stripeSpacing) {
                    path.move(to: CGPoint(x: startX, y: rect.height))
                    path.addLine(to: CGPoint(x: startX + rect.height, y: 0))
                }
            }
            .stroke(region.kind.stripeColor, lineWidth: 1)

            if rect.width >= 54 {
                Text(region.kind.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(region.kind.labelColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 6)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .clipped()
        .offset(x: rect.minX, y: rect.minY)
    }

    private func gapRect(for region: PeriodicAveragesGapRegion, in size: CGSize, count: Int) -> CGRect {
        guard count > 1 else {
            return CGRect(origin: .zero, size: size)
        }

        let step = size.width / CGFloat(count - 1)
        let startX = region.lowerIndex == 0
            ? 0
            : max(0, step * (CGFloat(region.lowerIndex) - 0.5))
        let endX = region.upperIndex >= count - 1
            ? size.width
            : min(size.width, step * (CGFloat(region.upperIndex) + 0.5))

        return CGRect(x: startX, y: 0, width: max(0, endX - startX), height: size.height)
    }

    private func gridLines(in size: CGSize) -> some View {
        Path { path in
            for level in [0.25, 0.50, 0.75] as [Double] {
                let y = size.height * CGFloat(1.0 - level)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }

            for index in 1...max(0, verticalGridlineCount) {
                let x = (CGFloat(index) / CGFloat(verticalGridlineCount + 1)) * size.width
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
        }
        .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
    }

    private func linePath(for s: PeriodicAveragesSeries, in size: CGSize, count: Int) -> Path {
        Path { path in
            var penDown = false
            for (i, value) in s.values.enumerated() {
                guard let v = value else { penDown = false; continue }
                let x = size.width * CGFloat(i) / CGFloat(count - 1)
                let y = size.height * CGFloat(1.0 - min(max(v, 0.0), 1.0))
                if !penDown {
                    path.move(to: CGPoint(x: x, y: y))
                    penDown = true
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
    }
}

// MARK: - Period picker

private struct PeriodicPeriodPicker: View {
    @Binding var selection: PeriodicAveragesPeriod
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 2 * scale) {
            ForEach(PeriodicAveragesPeriod.allCases, id: \.rawValue) { period in
                Button {
                    selection = period
                } label: {
                    Text(period.rawValue)
                        .font(.system(size: 10 * scale, weight: .semibold))
                        .foregroundColor(selection == period ? Color.primary : Color.secondary)
                        .padding(.vertical, 4 * scale)
                        .padding(.horizontal, 6 * scale)
                        .background(
                            ThemeRoundedRectangle(cornerRadius: 5 * scale)
                                .fill(selection == period
                                      ? Color.white.opacity(0.15)
                                      : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2 * scale)
        .background(
            ThemeRoundedRectangle(cornerRadius: 7 * scale)
                .fill(Color.black.opacity(0.15))
        )
    }
}

// MARK: - Legend

private struct PeriodicAveragesLegend: View {
    let series: [PeriodicAveragesSeries]
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 10 * scale) {
            ForEach(series) { s in
                HStack(spacing: 4 * scale) {
                    Circle()
                        .fill(s.color)
                        .frame(width: 6 * scale, height: 6 * scale)
                    Text(s.label)
                        .font(.system(size: 10 * scale, weight: .medium))
                        .foregroundColor(Color.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Card

struct PeriodicAveragesCard: View {
    let historyReader: any HardwareHistoryQuerying
    let hasNeuralEngine: Bool
    let primaryGPUID: String?
    var historyRefreshToken: String = ""
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil
    var isCompact: Bool = false

    @StateObject private var viewModel = PeriodicAveragesViewModel()
    @AppStorage("periodicAveragesPeriod") private var periodRaw: String = PeriodicAveragesPeriod.day.rawValue
    @Environment(\.appUIScale) private var appUIScale

    private var period: PeriodicAveragesPeriod {
        PeriodicAveragesPeriod(rawValue: periodRaw) ?? .day
    }

    private var scaledCardHeight: CGFloat {
        isCompact ? (330.5 * appUIScale) : (240 * appUIScale)
    }

    private var scaledGraphHeight: CGFloat {
        isCompact ? (238.5 * appUIScale) : (148 * appUIScale)
    }

    private var focusState: HardwareGraphFocusState? {
        guard !viewModel.series.isEmpty else { return nil }

        let strongestSeries = viewModel.series.max { lhs, rhs in
            lhs.values.compactMap { $0 }.reduce(0, +) < rhs.values.compactMap { $0 }.reduce(0, +)
        }
        let peakValue = viewModel.series
            .flatMap(\.values)
            .compactMap { $0 }
            .max() ?? 0
        let bucketCount = viewModel.series.map { $0.values.count }.max() ?? 0
        let populatedBucketCount = viewModel.series
            .flatMap(\.values)
            .compactMap { $0 }
            .count

        return HardwareGraphFocusState(
            id: "periodic-averages-\(period.rawValue)",
            title: "Periodic Averages",
            subtitle: "Normalized \(period.rawValue) history buckets across the tracked hardware lanes",
            accentColor: strongestSeries?.color ?? .white,
            heatmapTarget: .overall,
            visualization: .lineChart(
                viewModel.series.map {
                    HardwareGraphFocusSeries(
                        id: $0.id,
                        label: $0.label,
                        color: $0.color,
                        values: $0.values
                    )
                }
            ),
            stats: [
                HardwareGraphFocusStat(label: "Period", value: period.rawValue, tint: strongestSeries?.color),
                HardwareGraphFocusStat(label: "Buckets", value: "\(bucketCount)"),
                HardwareGraphFocusStat(label: "Observed", value: "\(populatedBucketCount)"),
                HardwareGraphFocusStat(label: "Strongest", value: strongestSeries?.label ?? "—", tint: strongestSeries?.color),
                HardwareGraphFocusStat(label: "Peak", value: String(format: "%3.0f%%", peakValue * 100))
            ],
            detailLines: [
                "Each line is normalized within its own active window so relative shape is more meaningful than raw scale.",
                "This view is currently using \(period.rawValue) buckets (\(period.bucketSeconds / 3600)h resolution)."
            ]
        )
    }

    private var focusRefreshSignature: Int {
        var hasher = Hasher()
        hasher.combine(periodRaw)
        hasher.combine(viewModel.series.count)
        for series in viewModel.series {
            hasher.combine(series.id)
            hasher.combine(series.label)
            for value in series.values {
                hasher.combine(value.map { Int(($0 * 1000).rounded()) } ?? -1)
            }
        }
        return hasher.finalize()
    }

    /// True when at least one series has two consecutive non-nil values, meaning
    /// a Path stroke will actually produce a visible line segment.
    private var hasDrawableData: Bool {
        viewModel.series.contains { s in
            var prevWasNonNil = false
            for v in s.values {
                if v != nil && prevWasNonNil { return true }
                prevWasNonNil = v != nil
            }
            return false
        }
    }

    private var refreshSignature: String {
        [
            historyRefreshToken,
            periodRaw,
            hasNeuralEngine ? "ane" : "no-ane",
            primaryGPUID ?? "no-gpu"
        ].joined(separator: "|")
    }

    var body: some View {
        ThemeRoundedRectangle(cornerRadius: 16 * appUIScale).themed()
            .frame(height: scaledCardHeight)
            .overlay(
                VStack(alignment: .leading, spacing: 0) {
                    // Header: title + period picker
                    HStack(alignment: .center, spacing: 8) {
                        Text("Periodic Averages")
                            .font(.system(size: 13 * appUIScale, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        PeriodicPeriodPicker(
                            selection: Binding(
                                get: { period },
                                set: { newPeriod in
                                    periodRaw = newPeriod.rawValue
                                    viewModel.refresh(
                                        period: newPeriod,
                                        reader: historyReader,
                                        hasNeuralEngine: hasNeuralEngine,
                                        primaryGPUID: primaryGPUID,
                                        clearExisting: true
                                    )
                                }
                            ),
                            scale: appUIScale
                        )
                    }

                    Spacer(minLength: 8 * appUIScale)

                    // Graph / placeholder
                    Group {
                        if viewModel.isLoading && viewModel.series.isEmpty {
                            ZStack {
                                ThemeRoundedRectangle(cornerRadius: 6 * appUIScale).themed(fill: Color.black.opacity(0.12), stroke: Color.clear)
                                ProgressView().controlSize(.small)
                            }
                        } else if viewModel.series.isEmpty {
                            ZStack {
                                ThemeRoundedRectangle(cornerRadius: 6 * appUIScale).themed(fill: Color.black.opacity(0.12), stroke: Color.clear)
                                VStack(spacing: 4 * appUIScale) {
                                    Text("Collecting data")
                                        .font(.system(size: 11 * appUIScale, weight: .medium))
                                        .foregroundColor(Color.secondary)
                                    Text("Graph fills in as history accumulates")
                                        .font(.system(size: 10 * appUIScale))
                                        .foregroundColor(Color.secondary.opacity(0.6))
                                }
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 16 * appUIScale)
                            }
                        } else {
                            ZStack {
                                PeriodicAveragesGraphView(
                                    series: viewModel.series,
                                    gapRegions: viewModel.gapRegions,
                                    verticalGridlineCount: period.verticalGridlineCount
                                )

                                if !hasDrawableData {
                                    Text("No recorded data in this window")
                                        .font(.system(size: 11 * appUIScale, weight: .medium))
                                        .foregroundColor(Color.secondary)
                                        .padding(.horizontal, 10 * appUIScale)
                                        .padding(.vertical, 6 * appUIScale)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(Color.black.opacity(0.28))
                                        )
                                }
                            }
                        }
                    }
                    .frame(height: scaledGraphHeight)

                    Spacer(minLength: 8 * appUIScale)

                    // Legend
                    PeriodicAveragesLegend(series: viewModel.series, scale: appUIScale)
                }
                .padding(.horizontal, 10 * appUIScale)
                .padding(.vertical, 12 * appUIScale)
            )
            .onAppear {
                refreshFromHistory()
            }
            .onChange(of: historyRefreshToken) { _ in
                refreshFromHistory()
            }
            .onChange(of: hasNeuralEngine) { _ in
                viewModel.refresh(
                    period: period,
                    reader: historyReader,
                    hasNeuralEngine: hasNeuralEngine,
                    primaryGPUID: primaryGPUID,
                    clearExisting: true
                )
            }
            .onChange(of: primaryGPUID) { _ in
                viewModel.refresh(
                    period: period,
                    reader: historyReader,
                    hasNeuralEngine: hasNeuralEngine,
                    primaryGPUID: primaryGPUID,
                    clearExisting: true
                )
            }
            .onDisappear { viewModel.cancel() }
            .contentShape(ThemeRoundedRectangle(cornerRadius: 16 * appUIScale, style: .continuous))
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    guard let onFocus, let focusState else { return }
                    onFocus(focusState)
                }
            )
            .onAppear {
                refreshFocusedStateIfNeeded()
            }
            .onChange(of: focusRefreshSignature) { _ in
                DispatchQueue.main.async {
                    refreshFocusedStateIfNeeded()
                }
            }
    }

    private func refreshFromHistory() {
        viewModel.refresh(
            period: period,
            reader: historyReader,
            hasNeuralEngine: hasNeuralEngine,
            primaryGPUID: primaryGPUID
        )
    }

    private func refreshFocusedStateIfNeeded() {
        guard let focusState,
              focusState.id == activeFocusID,
              let onFocusedStateChange else { return }
        onFocusedStateChange(focusState)
    }
}
