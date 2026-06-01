import PodcastPreviewShared
import SwiftUI

// MARK: - Activity Heatmap Card for iOS
//
// iOS-optimized version that works with CompanionTimelinePayload from CloudKit
// instead of the Mac-specific HardwareHistoryQuerying protocol.

struct ActivityHeatmapCardForiOS: View {
    @ObservedObject var historyMirror: CloudKitHistoryMirror
    @State private var selectedMetric: HeatmapMetric = .overall
    @State private var cells: [[Double]] = []
    @State private var overallCells: [[OverallHeatmapCell]] = []
    @State private var isLoading = false

    private let columnCount = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isLoading && cells.isEmpty {
                loadingView
            } else if !hasHeatmapData {
                emptyView
            } else {
                heatmapGrid
                    .overlay(alignment: .topTrailing) {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .padding(8)
                                .background(
                                    Capsule()
                                        .fill(GraphiteSlateTheme.fill(for: .row))
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(GraphiteSlateTheme.stroke(for: .row), lineWidth: 1)
                                        )
                                        .overlay(CardBackgroundOverlay(shape: Capsule()))
                                )
                        }
                    }
            }
        }
        .padding(16)
        .graphiteSurfaceWithRim(.control, cornerRadius: 20)
        .task(id: "\(selectedMetric.rawValue)-\(heatmapRefreshToken)") {
            await loadData()
        }
    }

    private var heatmapRefreshToken: String {
        guard let timeline = historyMirror.hourlyTimeline else { return "none" }
        let pointCount = timeline.series.reduce(0) { $0 + $1.points.count }
        let latestPoint = timeline.series
            .flatMap(\.points)
            .map(\.timestamp)
            .max()?
            .timeIntervalSinceReferenceDate ?? 0
        return "\(timeline.updatedAt.timeIntervalSinceReferenceDate)-\(pointCount)-\(Int(latestPoint))"
    }

    private var hasHeatmapData: Bool {
        if selectedMetric == .overall {
            return overallCells
                .flatMap { $0 }
                .contains { $0.displayIntensity > 0.01 }
        }

        return cells
            .flatMap { $0 }
            .contains { $0 > 0.01 }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Activity Heatmap")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(GraphiteSlateTheme.primaryText)

                Text("\(columnCount)-day hourly CloudKit rollup")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(GraphiteSlateTheme.secondaryText)
            }

            Spacer()

            Menu {
                ForEach(HeatmapMetric.allCases) { metric in
                    Button(metric.compactLabel) { selectedMetric = metric }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedMetric.compactLabel)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(GraphiteSlateTheme.subduedText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .graphiteSurfaceWithRim(.control, cornerRadius: 10)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Loading hourly rollup...")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GraphiteSlateTheme.secondaryText)
        }
        .frame(height: 220)
        .frame(maxWidth: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 32))
                .foregroundStyle(GraphiteSlateTheme.secondaryText)
            Text("No hourly activity yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(GraphiteSlateTheme.primaryText)
            Text("This fills in as the source Mac publishes hourly CloudKit rollups.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GraphiteSlateTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(height: 220)
        .frame(maxWidth: .infinity)
    }

    private var heatmapGrid: some View {
        GeometryReader { proxy in
            let metrics = gridMetrics(width: proxy.size.width)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("30d ago")
                    Spacer()
                    Text("today")
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(GraphiteSlateTheme.secondaryText)
                .padding(.leading, metrics.hourLabelWidth + 8)

                HStack(alignment: .top, spacing: 8) {
                    hourLabels(metrics: metrics)
                    dayRows(metrics: metrics)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: 292, alignment: .top)
    }

    private func hourLabels(metrics: HeatmapGridMetrics) -> some View {
        VStack(spacing: metrics.cellSpacing) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hourLabel(for: hour))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(GraphiteSlateTheme.secondaryText)
                    .frame(
                        width: metrics.hourLabelWidth,
                        height: metrics.cellSize,
                        alignment: .trailing
                    )
            }
        }
    }

    private func dayRows(metrics: HeatmapGridMetrics) -> some View {
        VStack(spacing: metrics.cellSpacing) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(spacing: metrics.cellSpacing) {
                    ForEach(0..<min(cells.count, columnCount), id: \.self) { column in
                        RoundedRectangle(cornerRadius: metrics.cellCornerRadius, style: .continuous)
                            .fill(cellColor(colIndex: column, rowIndex: hour))
                            .frame(width: metrics.cellSize, height: metrics.cellSize)
                    }
                }
            }
        }
    }

    private func gridMetrics(width: CGFloat) -> HeatmapGridMetrics {
        let spacing: CGFloat = width < 380 ? 1.3 : 1.8
        let hourLabelWidth: CGFloat = 24
        let reservedWidth = hourLabelWidth + 8 + CGFloat(columnCount - 1) * spacing
        let rawCellSize = (width - reservedWidth) / CGFloat(columnCount)

        return HeatmapGridMetrics(
            hourLabelWidth: hourLabelWidth,
            cellSize: min(9.5, max(5.5, rawCellSize)),
            cellSpacing: spacing
        )
    }

    private func hourLabel(for hour: Int) -> String {
        switch hour {
        case 0:
            return "12a"
        case 6:
            return "6a"
        case 12:
            return "12p"
        case 18:
            return "6p"
        default:
            return ""
        }
    }

    private func cellIntensity(colIndex: Int, rowIndex: Int) -> Double {
        if selectedMetric == .overall {
            return overallCell(colIndex: colIndex, rowIndex: rowIndex).displayIntensity
        }

        return colIndex < cells.count && rowIndex < cells[colIndex].count
            ? cells[colIndex][rowIndex]
            : 0
    }

    private func overallCell(colIndex: Int, rowIndex: Int) -> OverallHeatmapCell {
        colIndex < overallCells.count && rowIndex < overallCells[colIndex].count
            ? overallCells[colIndex][rowIndex]
            : OverallHeatmapCell()
    }

    private func cellColor(colIndex: Int, rowIndex: Int) -> Color {
        if selectedMetric == .overall {
            return overallCellColor(for: overallCell(colIndex: colIndex, rowIndex: rowIndex))
        }

        let intensity = cellIntensity(colIndex: colIndex, rowIndex: rowIndex)
        guard intensity > 0.01 else {
            return HeatmapRGB.idle.color
        }

        return selectedMetric.rgb?
            .interpolated(to: .white, amount: pow(intensity, 0.86))
            .color ?? Color.white.opacity(intensity * 0.3 + 0.1)
    }

    private func overallCellColor(for cell: OverallHeatmapCell) -> Color {
        let intensity = cell.displayIntensity
        guard intensity > 0.01 else {
            return HeatmapRGB.idle.color
        }

        let weightedComponents = cell.components.compactMap { metric, value -> (HeatmapRGB, Double)? in
            guard let rgb = metric.rgb else { return nil }
            let weight = value * OverallHeatmapCell.overallBlendInfluence(for: metric)
            return weight > 0 ? (rgb, weight) : nil
        }
        let totalWeight = weightedComponents.reduce(0) { $0 + $1.1 }
        let blended = totalWeight > 0
            ? weightedComponents.reduce(HeatmapRGB(red: 0, green: 0, blue: 0)) { partial, component in
                HeatmapRGB(
                    red: partial.red + component.0.red * component.1 / totalWeight,
                    green: partial.green + component.0.green * component.1 / totalWeight,
                    blue: partial.blue + component.0.blue * component.1 / totalWeight
                )
            }
            : HeatmapRGB.white

        return HeatmapRGB.idle
            .interpolated(to: blended, amount: pow(intensity, 0.82))
            .color
    }

    private func loadData() async {
        isLoading = true

        guard let timeline = historyMirror.hourlyTimeline else {
            await MainActor.run {
                self.cells = []
                self.overallCells = []
                self.isLoading = false
            }
            return
        }

        let metric = selectedMetric
        let timelineData = buildHeatmapFromTimeline(timeline, metric: metric)

        await MainActor.run {
            self.cells = timelineData.cells
            self.overallCells = timelineData.overallCells

            let widgetData = ActivityHeatmapWidgetData(
                metric: metric.rawValue,
                timestamp: Date(),
                cells: timelineData.cells,
                columnCount: columnCount
            )
            WidgetStorage.saveActivityHeatmapData(widgetData)

            self.isLoading = false
        }
    }

    private func buildHeatmapFromTimeline(
        _ timeline: CompanionTimelinePayload,
        metric: HeatmapMetric
    ) -> (cells: [[Double]], overallCells: [[OverallHeatmapCell]]) {
        var cells = Array(repeating: Array(repeating: 0.0, count: 24), count: columnCount)
        var overallCells = Array(repeating: Array(repeating: OverallHeatmapCell(), count: 24), count: columnCount)

        let calendar = Calendar.current
        let now = Date()
        let relevantSeries = timeline.series.filter { series in
            guard let seriesMetric = heatmapMetric(for: series.seriesKey) else { return false }
            return metric == .overall || seriesMetric == metric
        }

        for series in relevantSeries {
            guard let seriesMetric = heatmapMetric(for: series.seriesKey) else { continue }
            let peak = max(series.peakValue ?? 0, series.points.compactMap(\.value).max() ?? 0)

            for point in series.points {
                guard let rawValue = point.value, rawValue > 0 else { continue }

                let daysSince = calendar.dateComponents([.day], from: point.timestamp, to: now).day ?? 0
                guard daysSince >= 0 && daysSince < columnCount else { continue }

                let hour = calendar.component(.hour, from: point.timestamp)
                let dayIndex = columnCount - 1 - daysSince
                guard dayIndex >= 0 && dayIndex < columnCount && hour >= 0 && hour < 24 else { continue }

                let value = normalizedValue(rawValue, peak: peak)

                if metric == .overall {
                    var cell = overallCells[dayIndex][hour]
                    cell.merge(value: value, metric: seriesMetric)
                    overallCells[dayIndex][hour] = cell
                } else {
                    cells[dayIndex][hour] = max(cells[dayIndex][hour], value)
                }
            }
        }

        return (cells, overallCells)
    }

    private func heatmapMetric(for seriesKey: String) -> HeatmapMetric? {
        let key = seriesKey.lowercased()

        if key.contains("cpu") { return .cpu }
        if key.contains("gpu") || key.contains("renderer") || key.contains("tiler") { return .gpu }
        if key.contains("ane") { return .ane }
        if key.contains("memory") || key.contains("pressure") || key.contains("swap") { return .memory }
        if key.contains("power") { return .power }
        if key.contains("network") || key.contains("upload") || key.contains("download") { return .network }

        return nil
    }

    private func normalizedValue(_ value: Double, peak: Double) -> Double {
        let normalized = peak > 0 ? value / peak : value
        return min(max(normalized, 0), 1)
    }
}

private struct HeatmapGridMetrics {
    let hourLabelWidth: CGFloat
    let cellSize: CGFloat
    let cellSpacing: CGFloat

    var cellCornerRadius: CGFloat {
        max(1, cellSize * 0.22)
    }
}

private extension View {
    func graphiteSurfaceWithRim(
        _ surface: GraphiteSlateSurface,
        cornerRadius: CGFloat = 12,
        stroke: Color? = nil
    ) -> some View {
        self
            .graphiteSurface(surface, cornerRadius: cornerRadius, stroke: stroke)
            .overlay(CardBackgroundOverlay(shape: ThemeRoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }
}

private struct HeatmapRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    static let idle = HeatmapRGB(red: 0.10, green: 0.10, blue: 0.11)
    static let white = HeatmapRGB(red: 1.0, green: 1.0, blue: 1.0)

    func interpolated(to other: HeatmapRGB, amount: Double) -> HeatmapRGB {
        let t = min(max(amount, 0.0), 1.0)
        return HeatmapRGB(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}

private enum HeatmapMetric: String, CaseIterable, Identifiable {
    case overall = "All"
    case cpu = "CPU"
    case gpu = "GPU"
    case ane = "ANE"
    case memory = "Press"
    case power = "Pwr"
    case network = "Net"

    var id: String { rawValue }

    var compactLabel: String {
        switch self {
        case .overall:
            return "All"
        case .cpu:
            return "CPU"
        case .gpu:
            return "GPU"
        case .ane:
            return "ANE"
        case .memory:
            return "Prs"
        case .power:
            return "Pwr"
        case .network:
            return "Net"
        }
    }

    var rgb: HeatmapRGB? {
        switch self {
        case .overall:
            return nil
        case .cpu:
            return HeatmapRGB(red: 0.16, green: 0.49, blue: 0.95)
        case .gpu:
            return HeatmapRGB(red: 0.85, green: 0.20, blue: 0.20)
        case .ane:
            return HeatmapRGB(red: 0.65, green: 0.00, blue: 0.65)
        case .memory:
            return HeatmapRGB(red: 0.10, green: 0.65, blue: 0.28)
        case .power:
            return HeatmapRGB(red: 0.98, green: 0.54, blue: 0.12)
        case .network:
            return HeatmapRGB(red: 0.40, green: 0.40, blue: 0.50)
        }
    }
}

private struct OverallHeatmapCell: Equatable {
    var cpu: Double = 0
    var gpu: Double?
    var ane: Double?
    var memory: Double = 0
    var power: Double = 0
    var network: Double = 0

    static func overallBlendInfluence(for metric: HeatmapMetric) -> Double {
        switch metric {
        case .memory, .power:
            return 0.45
        case .gpu:
            return 1.5
        case .ane:
            return 1.2
        case .cpu, .network, .overall:
            return 1.0
        }
    }

    var displayIntensity: Double {
        let maxValues = [cpu, gpu, ane, memory, power, network].compactMap { $0 }
        return min(maxValues.max() ?? 0, 1)
    }

    mutating func merge(value: Double, metric: HeatmapMetric) {
        switch metric {
        case .cpu:
            cpu = max(cpu, value)
        case .gpu:
            gpu = max(gpu ?? 0, value)
        case .ane:
            ane = max(ane ?? 0, value)
        case .memory:
            memory = max(memory, value)
        case .power:
            power = max(power, value)
        case .network:
            network = max(network, value)
        case .overall:
            break
        }
    }

    var components: [HeatmapMetric: Double] {
        [
            .cpu: cpu,
            .gpu: gpu ?? 0,
            .ane: ane ?? 0,
            .memory: memory,
            .power: power,
            .network: network
        ]
    }
}
