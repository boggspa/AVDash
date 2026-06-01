import SwiftUI
import PodcastPreviewCore
import PodcastPreviewShared
import Combine

// MARK: - Activity Heatmap Card
//
// Shows a 24-row × N-column grid where:
//   rows  = hours of the day (0–23, top = midnight)
//   cols  = recent days (oldest left, today right)
//   cell  = average load intensity for that hour on that day
//
// The metric displayed is selectable. Data is loaded asynchronously
// from the history query backend so the card never blocks the UI.

struct ActivityHeatmapCard: View {
    @Environment(\.appUIScale) private var appUIScale
    let historyReader: any HardwareHistoryQuerying
    var primaryGPUID: String? = nil
    var hasNeuralEngine: Bool = false
    var historyRefreshToken: String = ""
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil

    // MARK: - State

    @State private var selectedMetric: HeatmapMetric = .overall
    @State private var cells: [[Double]] = []      // [col][row] = [day][hour] → 0…1
    @State private var overallCells: [[OverallHeatmapCell]] = []
    @State private var isLoading = false
    @State private var columnCount = 30            // days to show
    @State private var loadTask: Task<Void, Never>? = nil
    @State private var loadGeneration: Int = 0

    // MARK: - Types

    private struct RGBTriplet: Equatable {
        let red: Double
        let green: Double
        let blue: Double

        static let idle = RGBTriplet(red: 0.10, green: 0.10, blue: 0.11)
        static let white = RGBTriplet(red: 1.0, green: 1.0, blue: 1.0)

        func interpolated(to other: RGBTriplet, amount: Double) -> RGBTriplet {
            let t = min(max(amount, 0.0), 1.0)
            return RGBTriplet(
                red: red + (other.red - red) * t,
                green: green + (other.green - green) * t,
                blue: blue + (other.blue - blue) * t
            )
        }

        var color: Color {
            Color(red: red, green: green, blue: blue)
        }
    }

    private enum HeatmapMetric: String, CaseIterable {
        case overall = "All"
        case cpu     = "CPU"
        case gpu     = "GPU"
        case ane     = "ANE"
        case memory  = "Press"
        case power   = "Pwr"
        case network = "Net"

        var metricKey: HardwareMetricKey? {
            switch self {
            case .overall: return nil
            case .cpu:     return .cpuTotalUsage
            case .ane:     return .aneActivityRatio
            case .memory:  return .memoryPressureRatio
            case .power:   return .combinedPowerWatts
            case .network: return .networkUploadMBps
            case .gpu:     return nil  // device metric — handled separately
        }
        }

        var color: Color {
            switch self {
            case .overall: return Color.white
            case .cpu:     return .blue
            case .gpu:     return Color(red: 0.85, green: 0.20, blue: 0.20)
            case .ane:     return Color(red: 0.65, green: 0.00, blue: 0.65)
            case .memory:  return Color(red: 0.10, green: 0.65, blue: 0.28)
            case .power:   return .orange
            case .network: return .networkAccentColor
            }
        }

        var rgb: RGBTriplet? {
            switch self {
            case .overall:
                return nil
            case .cpu:
                return RGBTriplet(red: 0.16, green: 0.49, blue: 0.95)
            case .gpu:
                return RGBTriplet(red: 0.85, green: 0.20, blue: 0.20)
            case .ane:
                return RGBTriplet(red: 0.65, green: 0.00, blue: 0.65)
            case .memory:
                return RGBTriplet(red: 0.10, green: 0.65, blue: 0.28)
            case .power:
                return RGBTriplet(red: 0.98, green: 0.54, blue: 0.12)
            case .network:
                return RGBTriplet(red: 0.40, green: 0.40, blue: 0.50)
            }
        }

        var compactLabel: String {
            switch self {
            case .overall: return "All"
            case .cpu:     return "CPU"
            case .gpu:     return "GPU"
            case .ane:     return "ANE"
            case .memory:  return "Prs"
            case .power:   return "Pwr"
            case .network: return "Net"
            }
        }

        var tinyLabel: String {
            switch self {
            case .overall: return "A"
            case .cpu:     return "C"
            case .gpu:     return "G"
            case .ane:     return "AI"
            case .memory:  return "M"
            case .power:   return "W"
            case .network: return "N"
            }
        }
    }

    private struct OverallHeatmapCell: Equatable {
        var cpu: Double = 0
        var gpu: Double? = nil
        var memory: Double = 0
        var power: Double = 0
        var network: Double = 0

        /// In the combined "All" view, memory pressure and power often sit at high baselines that are
        /// informative in isolation but visually drown out CPU/GPU/ANE/network. Scale their contribution
        /// to both hue blending and cell brightness so the composite reads more like "compute activity."
        fileprivate static func overallBlendInfluence(for metric: HeatmapMetric) -> Double {
            switch metric {
            case .memory, .power:
                return 0.45
            case .gpu:
                return 1.5
            case .cpu, .ane, .network, .overall:
                return 1.0
            }
        }

        var components: [(HeatmapMetric, Double)] {
            var out: [(HeatmapMetric, Double)] = [(.cpu, cpu)]
            if let gpu {
                out.append((.gpu, gpu))
            }
            out.append((.memory, memory))
            out.append((.power, power))
            out.append((.network, network))
            return out
        }

        private var influencedValues: [Double] {
            components.map { metric, value in value * Self.overallBlendInfluence(for: metric) }
        }

        var peakIntensity: Double {
            influencedValues.max() ?? 0
        }

        var averageIntensity: Double {
            let values = influencedValues
            guard !values.isEmpty else { return 0 }
            return values.reduce(0, +) / Double(values.count)
        }

        var sharedBusyRatio: Double {
            influencedValues.min() ?? 0
        }

        var displayIntensity: Double {
            min(1.0, peakIntensity * 0.72 + averageIntensity * 0.28)
        }
    }

    private struct NormalizedBucketValue {
        let bucketStart: Date
        let value: Double
    }

    private enum HeaderMode {
        case regular
        case compact
        case stacked
    }

    private struct GridLayoutMetrics {
        let hourLabelWidth: CGFloat
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        let cellSpacing: CGFloat
        let labelFontSize: CGFloat

        var cellCornerRadius: CGFloat {
            max(1, min(cellWidth, cellHeight) * 0.22)
        }
    }

    // MARK: - Scaled layout

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledPadding: CGFloat { 12 * appUIScale }
    private var idealCellSize: CGFloat { 8 * appUIScale }
    private var idealCellSpacing: CGFloat { 1.5 * appUIScale }
    private var scaledLabelFontSize: CGFloat { 9 * appUIScale }
    private var scaledTitleFontSize: CGFloat { 13 * appUIScale }

    private var cardHeight: CGFloat {
        let idealGridHeight = 24 * idealCellSize + 23 * idealCellSpacing
        let headerAndControlsHeight = 44 * appUIScale
        let extraVerticalBreathingRoom = 36 * appUIScale
        return idealGridHeight + scaledPadding * 2 + headerAndControlsHeight + extraVerticalBreathingRoom
    }

    private var cardShape: some InsettableShape {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous)
    }

    private var focusState: HardwareGraphFocusState? {
        guard columnCount > 0, !cells.isEmpty else { return nil }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startDay = calendar.date(byAdding: .day, value: -(columnCount - 1), to: today) ?? today
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = columnCount > 14 ? "MMM d" : "EEE"

        let busiestHourIndex = (0..<24).max { lhs, rhs in
            averageIntensity(forHour: lhs) < averageIntensity(forHour: rhs)
        } ?? 0
        let busiestDayIndex = (0..<columnCount).max { lhs, rhs in
            totalIntensity(forColumn: lhs) < totalIntensity(forColumn: rhs)
        } ?? 0
        let hottestCell = hottestCellLocation()

        let snapshotColumns = (0..<columnCount).map { column in
            (0..<24).map { hour in
                HardwareGraphFocusHeatmapCell(
                    intensity: selectedMetric == .overall ? overallCell(col: column, hour: hour).displayIntensity : cellValue(col: column, hour: hour),
                    color: cellFillColor(col: column, hour: hour),
                    slotStart: slotStart(forColumn: column, hour: hour, startDay: startDay, calendar: calendar)
                )
            }
        }

        let busiestDayDate = calendar.date(byAdding: .day, value: busiestDayIndex, to: startDay) ?? today
        let startLabel = dateFormatter.string(from: startDay)
        let endLabel = dateFormatter.string(from: today)

        return HardwareGraphFocusState(
            id: "heatmap-\(selectedMetric.rawValue.lowercased())",
            title: "Activity Heatmap",
            subtitle: "\(selectedMetric.rawValue) intensity across the last \(columnCount) days",
            accentColor: selectedMetric.color,
            insightTarget: insightTarget(for: selectedMetric),
            heatmapTarget: focusHeatmapTarget(for: selectedMetric),
            selectableHeatmapTargets: availableMetrics.map(focusHeatmapTarget(for:)),
            visualization: .heatmap(
                HardwareGraphFocusHeatmapSnapshot(
                    metricLabel: selectedMetric.rawValue,
                    columns: snapshotColumns,
                    startLabel: startLabel,
                    endLabel: endLabel
                )
            ),
            stats: [
                HardwareGraphFocusStat(label: "Metric", value: selectedMetric.rawValue, tint: selectedMetric.color),
                HardwareGraphFocusStat(label: "Days", value: "\(columnCount)"),
                HardwareGraphFocusStat(label: "Peak Hour", value: hourLabel(busiestHourIndex)),
                HardwareGraphFocusStat(label: "Busiest Day", value: dateFormatter.string(from: busiestDayDate)),
                HardwareGraphFocusStat(label: "Hot Slot", value: hottestCell)
            ],
            detailLines: [
                "Rows represent hours of the day and columns represent recent days, oldest to newest.",
                selectedMetric == .overall
                    ? "Overall blends CPU, GPU, memory pressure, power, and network into one view. Memory and power are weighted lower so steady allocator usage and idle-ish power baselines do not wash out compute-heavy activity."
                    : "Each column is normalized against activity observed within that day so quiet days still remain readable."
            ]
        )
    }

    private var focusRefreshSignature: Int {
        var hasher = Hasher()
        hasher.combine(selectedMetric.rawValue)
        hasher.combine(columnCount)
        for column in cells {
            for value in column {
                hasher.combine(Int((value * 1000).rounded()))
            }
        }
        if selectedMetric == .overall {
            for column in overallCells {
                for cell in column {
                    hasher.combine(Int((cell.displayIntensity * 1000).rounded()))
                }
            }
        }
        return hasher.finalize()
    }

    // MARK: - Body

    var body: some View {
        Group {
        if #available(macOS 12, *) {
            baseCard
                .task(id: "\(selectedMetric.rawValue)-\(historyRefreshToken)") {
                    scheduleHeatmapLoad()
                }
        } else {
            baseCard
                    .onAppear { scheduleHeatmapLoad() }
                    .onChange(of: selectedMetric.rawValue) { _ in scheduleHeatmapLoad() }
                    .onChange(of: historyRefreshToken) { _ in scheduleHeatmapLoad() }
        }
        }
        .onReceive(Timer.publish(every: 60, tolerance: 8, on: .main, in: .common).autoconnect()) { _ in
            scheduleHeatmapLoad()
        }
    }

    private var baseCard: some View {
        cardShape.themed()
            .frame(height: cardHeight)
            .overlay(
                GeometryReader { geometry in
                    let headerMode = headerMode(for: geometry.size.width - scaledPadding * 2)

                    VStack(alignment: .leading, spacing: 8 * appUIScale) {
                        headerRow(mode: headerMode)

                        GeometryReader { gridGeometry in
                            heatmapGrid(layout: gridLayout(for: gridGeometry.size))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                    .padding(scaledPadding)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
            )
            .clipShape(cardShape)
            .contentShape(cardShape)
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
            .onDisappear {
                loadTask?.cancel()
                loadTask = nil
                loadGeneration &+= 1
                isLoading = false
            }
    }

    // MARK: - Header

    @ViewBuilder
    private func headerRow(mode: HeaderMode) -> some View {
        switch mode {
        case .regular:
            HStack(spacing: 6 * appUIScale) {
                Text("Activity Heatmap")
                    .font(.system(size: scaledTitleFontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer(minLength: 8 * appUIScale)

                metricPicker(labels: { $0.rawValue }, fontSize: scaledLabelFontSize + 1, horizontalPadding: 5 * appUIScale)
            }
        case .compact:
            HStack(spacing: 6 * appUIScale) {
                Text("Heatmap")
                    .font(.system(size: max(11, scaledTitleFontSize - 1), weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 6 * appUIScale)

                metricPicker(labels: { $0.compactLabel }, fontSize: scaledLabelFontSize, horizontalPadding: 4 * appUIScale)
            }
        case .stacked:
            VStack(alignment: .leading, spacing: 6 * appUIScale) {
                Text("Heatmap")
                    .font(.system(size: max(10, scaledTitleFontSize - 1), weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                metricPicker(labels: { $0.tinyLabel }, fontSize: max(8, scaledLabelFontSize - 1), horizontalPadding: 3 * appUIScale)
            }
        }
    }

    private func metricPicker(
        labels: @escaping (HeatmapMetric) -> String,
        fontSize: CGFloat,
        horizontalPadding: CGFloat
    ) -> some View {
        HStack(spacing: 2 * appUIScale) {
            ForEach(availableMetrics, id: \.rawValue) { metric in
                let isSelected = metric == selectedMetric
                Button {
                    selectedMetric = metric
                } label: {
                    Text(labels(metric))
                        .font(.system(size: fontSize, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? metric.color : .secondary)
                        .lineLimit(1)
                        .padding(.horizontal, horizontalPadding)
                        .padding(.vertical, 3 * appUIScale)
                        .background(
                            ThemeRoundedRectangle(cornerRadius: 4 * appUIScale)
                                .fill(metricButtonBackground(metric: metric, isSelected: isSelected))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var availableMetrics: [HeatmapMetric] {
        var metrics: [HeatmapMetric] = [.overall, .cpu, .memory, .power, .network]
        if primaryGPUID != nil { metrics.insert(.gpu, at: 2) }
        if hasNeuralEngine {
            let aneInsertIndex = primaryGPUID != nil ? 3 : 2
            metrics.insert(.ane, at: aneInsertIndex)
        }
        return metrics
    }

    // MARK: - Grid

    private func heatmapGrid(layout: GridLayoutMetrics) -> some View {
        HStack(alignment: .top, spacing: layout.cellSpacing) {
            // Hour labels column
            VStack(spacing: layout.cellSpacing) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 6 == 0 ? hourLabel(hour) : "")
                        .font(.system(size: layout.labelFontSize))
                        .foregroundColor(.secondary)
                        .frame(width: layout.hourLabelWidth, height: layout.cellHeight, alignment: .trailing)
                }
            }

            // Data columns
            HStack(alignment: .top, spacing: layout.cellSpacing) {
                ForEach(0..<columnCount, id: \.self) { col in
                    VStack(spacing: layout.cellSpacing) {
                        ForEach(0..<24, id: \.self) { hour in
                            ThemeRoundedRectangle(cornerRadius: layout.cellCornerRadius)
                                .fill(cellFillColor(col: col, hour: hour))
                                .frame(width: layout.cellWidth, height: layout.cellHeight)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    // MARK: - Helpers

    private func cellValue(col: Int, hour: Int) -> Double {
        guard col < cells.count, hour < cells[col].count else { return 0 }
        return cells[col][hour]
    }

    private func averageIntensity(forHour hour: Int) -> Double {
        guard hour >= 0, hour < 24, !cells.isEmpty else { return 0 }
        let values = (0..<columnCount).map { cellValue(col: $0, hour: hour) }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func totalIntensity(forColumn column: Int) -> Double {
        guard column >= 0, column < columnCount else { return 0 }
        return (0..<24).reduce(0) { partial, hour in
            partial + cellValue(col: column, hour: hour)
        }
    }

    private func hottestCellLocation() -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startDay = calendar.date(byAdding: .day, value: -(columnCount - 1), to: today) ?? today
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = columnCount > 14 ? "MMM d" : "EEE"

        var bestValue = 0.0
        var bestColumn = 0
        var bestHour = 0

        for column in 0..<columnCount {
            for hour in 0..<24 {
                let value = selectedMetric == .overall ? overallCell(col: column, hour: hour).displayIntensity : cellValue(col: column, hour: hour)
                if value > bestValue {
                    bestValue = value
                    bestColumn = column
                    bestHour = hour
                }
            }
        }

        guard bestValue > 0 else { return "No activity" }
        let day = calendar.date(byAdding: .day, value: bestColumn, to: startDay) ?? today
        return "\(dateFormatter.string(from: day)) · \(hourLabel(bestHour))"
    }

    private func insightTarget(for metric: HeatmapMetric) -> HardwareGraphFocusInsightTarget? {
        switch metric {
        case .overall:
            return nil
        case .cpu:
            return .cpu
        case .gpu:
            return .gpu
        case .ane:
            return .ane
        case .memory:
            return .memory
        case .power:
            return .power
        case .network:
            return .network
        }
    }

    private func focusHeatmapTarget(for metric: HeatmapMetric) -> HardwareGraphFocusHeatmapTarget {
        switch metric {
        case .overall:
            return .overall
        case .cpu:
            return .cpu
        case .gpu:
            return .gpu
        case .ane:
            return .ane
        case .memory:
            return .memory
        case .power:
            return .power
        case .network:
            return .network
        }
    }

    private func slotStart(
        forColumn column: Int,
        hour: Int,
        startDay: Date,
        calendar: Calendar
    ) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: column, to: startDay) else { return nil }
        return calendar.date(byAdding: .hour, value: hour, to: day)
    }

    private func refreshFocusedStateIfNeeded() {
        guard let focusState,
              focusState.id == activeFocusID,
              let onFocusedStateChange else { return }
        onFocusedStateChange(focusState)
    }

    private func overallCell(col: Int, hour: Int) -> OverallHeatmapCell {
        guard col < overallCells.count, hour < overallCells[col].count else {
            return OverallHeatmapCell(gpu: primaryGPUID != nil ? 0 : nil)
        }
        return overallCells[col][hour]
    }

    private func cellOpacity(_ value: Double) -> Double {
        guard value > 0 else { return 0.06 }
        // Non-linear mapping: low values still visible, high values vivid
        return 0.12 + value * 0.82
    }

    private func cellFillColor(col: Int, hour: Int) -> Color {
        if selectedMetric == .overall {
            return overallCellColor(overallCell(col: col, hour: hour))
        }
        return selectedMetric.color.opacity(cellOpacity(cellValue(col: col, hour: hour)))
    }

    private func metricButtonBackground(metric: HeatmapMetric, isSelected: Bool) -> Color {
        guard isSelected else { return .clear }
        if metric == .overall {
            return Color.white.opacity(0.18)
        }
        return metric.color.opacity(0.15)
    }

    private func overallCellColor(_ cell: OverallHeatmapCell) -> Color {
        let activeComponents = cell.components.filter { $0.1 > 0.001 }
        guard !activeComponents.isEmpty else { return RGBTriplet.idle.color.opacity(0.25) }

        let totalWeight = activeComponents.reduce(0.0) { sum, pair in
            sum + pair.1 * OverallHeatmapCell.overallBlendInfluence(for: pair.0)
        }
        let blendedColor = activeComponents.reduce(
            RGBTriplet(red: 0, green: 0, blue: 0)
        ) { partial, component in
            let (metric, value) = component
            let w = value * OverallHeatmapCell.overallBlendInfluence(for: metric)
            let weight = totalWeight > 0 ? (w / totalWeight) : 0
            guard let rgb = metric.rgb else { return partial }
            return RGBTriplet(
                red: partial.red + rgb.red * weight,
                green: partial.green + rgb.green * weight,
                blue: partial.blue + rgb.blue * weight
            )
        }

        let tinted = RGBTriplet.idle.interpolated(
            to: blendedColor,
            amount: pow(cell.displayIntensity, 0.82)
        )
        let whitened = tinted.interpolated(
            to: RGBTriplet.white,
            amount: pow(cell.sharedBusyRatio, 1.08)
        )
        return whitened.color
    }

    private func hourLabel(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h)\(hour < 12 ? "a" : "p")"
    }

    private func headerMode(for availableWidth: CGFloat) -> HeaderMode {
        if availableWidth >= 380 {
            return .regular
        }
        if availableWidth >= 250 {
            return .compact
        }
        return .stacked
    }

    private func gridLayout(for size: CGSize) -> GridLayoutMetrics {
        let cellSpacing = min(
            idealCellSpacing,
            max(0.6 * appUIScale, ((size.width - (16 * appUIScale)) / CGFloat(max(1, columnCount))) * 0.18)
        )
        let hourLabelWidth = min(max(14 * appUIScale, size.width * 0.11), 24 * appUIScale)
        let availableGridWidth = max(0, size.width - hourLabelWidth - cellSpacing)
        let availableGridHeight = max(0, size.height)
        let totalColumnSpacing = CGFloat(max(0, columnCount - 1)) * cellSpacing
        let totalRowSpacing = CGFloat(23) * cellSpacing
        let cellWidth = max(1, (availableGridWidth - totalColumnSpacing) / CGFloat(max(1, columnCount)))
        let cellHeight = max(1, (availableGridHeight - totalRowSpacing) / 24.0)
        let labelFontSize = min(scaledLabelFontSize, max(7 * appUIScale, cellHeight * 0.72))

        return GridLayoutMetrics(
            hourLabelWidth: hourLabelWidth,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            cellSpacing: cellSpacing,
            labelFontSize: labelFontSize
        )
    }

    // MARK: - Data loading

    private func scheduleHeatmapLoad() {
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask?.cancel()
        loadTask = Task { [generation] in
            await loadHeatmap(generation: generation)
        }
    }

    @MainActor
    private func loadHeatmap(generation: Int) async {
        isLoading = true
        defer {
            if generation == loadGeneration {
                isLoading = false
                loadTask = nil
            }
        }

        let now = Date()
        let calendar = Calendar.current
        let days = columnCount
        let metric = selectedMetric
        let startOfToday = calendar.startOfDay(for: now)
        let rangeStart = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday) ?? now
        let range = DateInterval(start: rangeStart, end: now)

        guard generation == loadGeneration else { return }

        if metric == .overall {
            await loadOverallHeatmap(now: now, calendar: calendar, days: days, generation: generation)
            return
        }

        if metric == .network {
            await loadNetworkHeatmap(now: now, calendar: calendar, days: days, generation: generation)
            return
        }

        let buckets = await fetchBuckets(range: range)
        guard generation == loadGeneration, !Task.isCancelled else { return }

        overallCells = []
        var rawCells = Array(repeating: Array<Double?>(repeating: nil, count: 24), count: days)
        var perDayPeaks = Array(repeating: 0.0, count: days)

        for bucket in buckets {
            guard bucket.coverageRatio >= 0.1, let averageValue = bucket.averageValue else { continue }

            let dayStart = calendar.startOfDay(for: bucket.bucketStart)
            let dayIndex = calendar.dateComponents([.day], from: rangeStart, to: dayStart).day ?? -1
            let hour = calendar.component(.hour, from: bucket.bucketStart)

            guard dayIndex >= 0, dayIndex < days else { continue }
            guard hour >= 0, hour < 24 else { continue }

            let value = max(averageValue, 0.0)
            rawCells[dayIndex][hour] = max(rawCells[dayIndex][hour] ?? 0.0, value)
            perDayPeaks[dayIndex] = max(perDayPeaks[dayIndex], value)
        }

        cells = zip(rawCells, perDayPeaks).map { dayValues, peak in
            let normPeak = max(peak, 0.01)
            return dayValues.map { value in
                guard let value else { return 0.0 }
                return min(max(value / normPeak, 0.0), 1.0)
            }
        }

        guard generation == loadGeneration, !Task.isCancelled else { return }

        // Write to widget storage
        writeHeatmapToWidgetStorage(metric: metric)
    }

    private func writeHeatmapToWidgetStorage(metric: HeatmapMetric) {
        let widgetData = ActivityHeatmapWidgetData(
            metric: metric.rawValue,
            timestamp: Date(),
            cells: cells,
            columnCount: columnCount
        )
        WidgetStorage.saveActivityHeatmapData(widgetData)
    }

    @MainActor
    private func loadOverallHeatmap(now: Date, calendar: Calendar, days: Int, generation: Int) async {
        let startOfToday = calendar.startOfDay(for: now)
        let rangeStart = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday) ?? now
        let range = DateInterval(start: rangeStart, end: now)

        let cpuTimeline = await historyReader.metricTimeline(
            for: .cpuTotalUsage,
            in: range,
            bucketIntervalSeconds: 3600
        )
        let memoryTimeline = await historyReader.metricTimeline(
            for: .memoryPressureRatio,
            in: range,
            bucketIntervalSeconds: 3600
        )
        let powerTimeline = await historyReader.metricTimeline(
            for: .combinedPowerWatts,
            in: range,
            bucketIntervalSeconds: 3600
        )
        let networkUploadTimeline = await historyReader.metricTimeline(
            for: .networkUploadMBps,
            in: range,
            bucketIntervalSeconds: 3600
        )
        let networkDownloadTimeline = await historyReader.metricTimeline(
            for: .networkDownloadMBps,
            in: range,
            bucketIntervalSeconds: 3600
        )
        let networkLatencyTimeline = await historyReader.metricTimeline(
            for: .networkPingLatencyMilliseconds,
            in: range,
            bucketIntervalSeconds: 3600
        )
        let networkLossTimeline = await historyReader.metricTimeline(
            for: .networkPingPacketLossRatio,
            in: range,
            bucketIntervalSeconds: 3600
        )

        let gpuTimeline: [HardwareHistoryMetricBucket]
        if let gpuID = primaryGPUID {
            gpuTimeline = await historyReader.deviceMetricTimeline(
                for: .utilizationRatio,
                deviceID: gpuID,
                deviceKind: .gpu,
                in: range,
                bucketIntervalSeconds: 3600
            )
        } else {
            gpuTimeline = []
        }

        let emptyCell = OverallHeatmapCell(gpu: primaryGPUID != nil ? 0 : nil)
        var newOverallCells = Array(
            repeating: Array(repeating: emptyCell, count: 24),
            count: days
        )

        apply(normalizedRatioBuckets(cpuTimeline), to: &newOverallCells, calendar: calendar, rangeStart: rangeStart) {
            $0.cpu = $1
        }
        apply(normalizedRatioBuckets(memoryTimeline), to: &newOverallCells, calendar: calendar, rangeStart: rangeStart) {
            $0.memory = $1
        }
        apply(normalizedAbsoluteBuckets(powerTimeline), to: &newOverallCells, calendar: calendar, rangeStart: rangeStart) {
            $0.power = $1
        }
        apply(
            normalizedNetworkBuckets(
                uploadTimeline: networkUploadTimeline,
                downloadTimeline: networkDownloadTimeline,
                latencyTimeline: networkLatencyTimeline,
                lossTimeline: networkLossTimeline
            ),
              to: &newOverallCells,
              calendar: calendar,
              rangeStart: rangeStart) {
            $0.network = $1
        }
        if primaryGPUID != nil {
            apply(normalizedRatioBuckets(gpuTimeline), to: &newOverallCells, calendar: calendar, rangeStart: rangeStart) {
                $0.gpu = $1
            }
        }

        guard generation == loadGeneration, !Task.isCancelled else { return }

        overallCells = newOverallCells
        cells = newOverallCells.map { column in
            column.map(\.displayIntensity)
        }

        // Write to widget storage
        writeHeatmapToWidgetStorage(metric: selectedMetric)
    }

    @MainActor
    private func loadNetworkHeatmap(now: Date, calendar: Calendar, days: Int, generation: Int) async {
        let startOfToday = calendar.startOfDay(for: now)
        let rangeStart = calendar.date(byAdding: .day, value: -(days - 1), to: startOfToday) ?? now
        let range = DateInterval(start: rangeStart, end: now)

        let uploadTimeline = await historyReader.metricTimeline(
            for: .networkUploadMBps,
            in: range,
            bucketIntervalSeconds: 3600
        )
        let downloadTimeline = await historyReader.metricTimeline(
            for: .networkDownloadMBps,
            in: range,
            bucketIntervalSeconds: 3600
        )
        let latencyTimeline = await historyReader.metricTimeline(
            for: .networkPingLatencyMilliseconds,
            in: range,
            bucketIntervalSeconds: 3600
        )
        let lossTimeline = await historyReader.metricTimeline(
            for: .networkPingPacketLossRatio,
            in: range,
            bucketIntervalSeconds: 3600
        )

        guard generation == loadGeneration, !Task.isCancelled else { return }

        overallCells = []
        cells = normalizedColumns(
            from: normalizedNetworkBuckets(
                uploadTimeline: uploadTimeline,
                downloadTimeline: downloadTimeline,
                latencyTimeline: latencyTimeline,
                lossTimeline: lossTimeline
            ),
            days: days,
            rangeStart: rangeStart,
            calendar: calendar
        )

        guard generation == loadGeneration, !Task.isCancelled else { return }

        // Write to widget storage
        writeHeatmapToWidgetStorage(metric: selectedMetric)
    }

    private func normalizedRatioBuckets(
        _ timeline: [HardwareHistoryMetricBucket]
    ) -> [NormalizedBucketValue] {
        timeline.compactMap { bucket in
            guard bucket.coverageRatio >= 0.1, let averageValue = bucket.averageValue else { return nil }
            return NormalizedBucketValue(
                bucketStart: bucket.bucketStart,
                value: min(max(averageValue, 0.0), 1.0)
            )
        }
    }

    private func normalizedAbsoluteBuckets(
        _ timeline: [HardwareHistoryMetricBucket]
    ) -> [NormalizedBucketValue] {
        let observed = timeline.compactMap { bucket -> NormalizedBucketValue? in
            guard bucket.coverageRatio >= 0.1, let averageValue = bucket.averageValue else { return nil }
            return NormalizedBucketValue(
                bucketStart: bucket.bucketStart,
                value: max(averageValue, 0.0)
            )
        }

        let peak = observed.map(\.value).max() ?? 0
        guard peak > 0 else {
            return observed.map { NormalizedBucketValue(bucketStart: $0.bucketStart, value: 0) }
        }

        return observed.map {
            NormalizedBucketValue(bucketStart: $0.bucketStart, value: min(max($0.value / peak, 0.0), 1.0))
        }
    }

    private func normalizedCombinedAbsoluteBuckets(
        _ first: [HardwareHistoryMetricBucket],
        _ second: [HardwareHistoryMetricBucket]
    ) -> [NormalizedBucketValue] {
        let combined = combinedBuckets(first, second)
        let observed = combined.compactMap { bucket -> NormalizedBucketValue? in
            guard bucket.coverageRatio >= 0.1, let averageValue = bucket.averageValue else { return nil }
            return NormalizedBucketValue(bucketStart: bucket.bucketStart, value: max(averageValue, 0.0))
        }

        let peak = observed.map(\.value).max() ?? 0
        guard peak > 0 else {
            return observed.map { NormalizedBucketValue(bucketStart: $0.bucketStart, value: 0) }
        }

        return observed.map {
            NormalizedBucketValue(bucketStart: $0.bucketStart, value: min(max($0.value / peak, 0.0), 1.0))
        }
    }

    private func normalizedNetworkBuckets(
        uploadTimeline: [HardwareHistoryMetricBucket],
        downloadTimeline: [HardwareHistoryMetricBucket],
        latencyTimeline: [HardwareHistoryMetricBucket],
        lossTimeline: [HardwareHistoryMetricBucket]
    ) -> [NormalizedBucketValue] {
        mergedNormalizedBuckets([
            normalizedCombinedAbsoluteBuckets(uploadTimeline, downloadTimeline),
            normalizedLatencyBuckets(latencyTimeline),
            normalizedPacketLossBuckets(lossTimeline)
        ])
    }

    private func normalizedLatencyBuckets(
        _ timeline: [HardwareHistoryMetricBucket]
    ) -> [NormalizedBucketValue] {
        timeline.compactMap { bucket in
            guard bucket.coverageRatio >= 0.1, let averageValue = bucket.averageValue else { return nil }
            let baselineAdjusted = max(averageValue - 20.0, 0.0)
            return NormalizedBucketValue(
                bucketStart: bucket.bucketStart,
                value: min(max(baselineAdjusted / 180.0, 0.0), 1.0)
            )
        }
    }

    private func normalizedPacketLossBuckets(
        _ timeline: [HardwareHistoryMetricBucket]
    ) -> [NormalizedBucketValue] {
        timeline.compactMap { bucket in
            guard bucket.coverageRatio >= 0.1, let averageValue = bucket.averageValue else { return nil }
            return NormalizedBucketValue(
                bucketStart: bucket.bucketStart,
                value: min(max(averageValue / 0.20, 0.0), 1.0)
            )
        }
    }

    private func mergedNormalizedBuckets(
        _ collections: [[NormalizedBucketValue]]
    ) -> [NormalizedBucketValue] {
        var merged: [Date: Double] = [:]
        for collection in collections {
            for bucket in collection {
                merged[bucket.bucketStart] = max(merged[bucket.bucketStart] ?? 0.0, bucket.value)
            }
        }

        return merged.keys.sorted().map { bucketStart in
            NormalizedBucketValue(bucketStart: bucketStart, value: merged[bucketStart] ?? 0.0)
        }
    }

    private func normalizedColumns(
        from normalizedBuckets: [NormalizedBucketValue],
        days: Int,
        rangeStart: Date,
        calendar: Calendar
    ) -> [[Double]] {
        var result = Array(repeating: Array(repeating: 0.0, count: 24), count: days)

        for bucket in normalizedBuckets {
            let dayStart = calendar.startOfDay(for: bucket.bucketStart)
            let dayIndex = calendar.dateComponents([.day], from: rangeStart, to: dayStart).day ?? -1
            let hour = calendar.component(.hour, from: bucket.bucketStart)

            guard dayIndex >= 0, dayIndex < days else { continue }
            guard hour >= 0, hour < 24 else { continue }
            result[dayIndex][hour] = max(result[dayIndex][hour], min(max(bucket.value, 0.0), 1.0))
        }

        return result
    }

    private func combinedBuckets(
        _ first: [HardwareHistoryMetricBucket],
        _ second: [HardwareHistoryMetricBucket]
    ) -> [HardwareHistoryMetricBucket] {
        let firstByStart = Dictionary(uniqueKeysWithValues: first.map { ($0.bucketStart, $0) })
        let secondByStart = Dictionary(uniqueKeysWithValues: second.map { ($0.bucketStart, $0) })
        let starts = Array(Set(firstByStart.keys).union(secondByStart.keys)).sorted()

        return starts.compactMap { bucketStart in
            let firstBucket = firstByStart[bucketStart]
            let secondBucket = secondByStart[bucketStart]
            guard firstBucket != nil || secondBucket != nil else { return nil }

            let bucketDurationSeconds = max(
                firstBucket?.bucketDurationSeconds ?? 0,
                secondBucket?.bucketDurationSeconds ?? 0
            )

            return HardwareHistoryMetricBucket(
                bucketStart: bucketStart,
                bucketDurationSeconds: bucketDurationSeconds,
                observedRollupCount: (firstBucket?.observedRollupCount ?? 0) + (secondBucket?.observedRollupCount ?? 0),
                observedSampleCount: (firstBucket?.observedSampleCount ?? 0) + (secondBucket?.observedSampleCount ?? 0),
                estimatedObservedSeconds: max(
                    firstBucket?.estimatedObservedSeconds ?? 0,
                    secondBucket?.estimatedObservedSeconds ?? 0
                ),
                minValue: sumOptional(firstBucket?.minValue, secondBucket?.minValue),
                maxValue: sumOptional(firstBucket?.maxValue, secondBucket?.maxValue),
                averageValue: sumOptional(firstBucket?.averageValue, secondBucket?.averageValue),
                lastValue: sumOptional(firstBucket?.lastValue, secondBucket?.lastValue)
            )
        }
    }

    private func sumOptional(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return lhs + rhs
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    private func apply(
        _ values: [NormalizedBucketValue],
        to cells: inout [[OverallHeatmapCell]],
        calendar: Calendar,
        rangeStart: Date,
        update: (inout OverallHeatmapCell, Double) -> Void
    ) {
        for bucket in values {
            let dayStart = calendar.startOfDay(for: bucket.bucketStart)
            let dayIndex = calendar.dateComponents([.day], from: rangeStart, to: dayStart).day ?? -1
            let hour = calendar.component(.hour, from: bucket.bucketStart)

            guard dayIndex >= 0, dayIndex < cells.count else { continue }
            guard hour >= 0, hour < 24 else { continue }
            update(&cells[dayIndex][hour], bucket.value)
        }
    }

    private func fetchBuckets(range: DateInterval) async -> [HardwareHistoryMetricBucket] {
        switch selectedMetric {
        case .overall:
            return []
        case .gpu:
            guard let gpuID = primaryGPUID else { return [] }
            return await historyReader.deviceMetricTimeline(
                for: .utilizationRatio,
                deviceID: gpuID,
                deviceKind: .gpu,
                in: range,
                bucketIntervalSeconds: 3600
            )
        case .network:
            let uploadTimeline = await historyReader.metricTimeline(
                for: .networkUploadMBps,
                in: range,
                bucketIntervalSeconds: 3600
            )
            let downloadTimeline = await historyReader.metricTimeline(
                for: .networkDownloadMBps,
                in: range,
                bucketIntervalSeconds: 3600
            )
            return combinedBuckets(uploadTimeline, downloadTimeline)
        default:
            guard let key = selectedMetric.metricKey else { return [] }
            return await historyReader.metricTimeline(
                for: key,
                in: range,
                bucketIntervalSeconds: 3600
            )
        }
    }
}
