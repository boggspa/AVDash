import PodcastPreviewShared
import Charts
import SwiftUI

enum TimelinePeriod: String, CaseIterable, Sendable, Identifiable {
    case minute = "24h"
    case hourly = "7d"

    var id: String { rawValue }

    var caption: String {
        switch self {
        case .minute:
            return "24h minute rollup"
        case .hourly:
            return "7d hourly rollup"
        }
    }
}

struct HardwareStatsViewForiOS: View {
    let snapshot: CompanionDashboardSnapshot
    let currentSnapshot: CompanionCurrentSnapshotPayload
    @ObservedObject var historyMirror: CloudKitHistoryMirror

    @State private var selectedCard: CompanionDashboardCard?
    @State private var selectedPeriod: TimelinePeriod = .minute

    private let graphSectionCardSpacing: CGFloat = 14
    private let contentPadding: CGFloat = 16

    private var selectedTimeline: CompanionTimelinePayload? {
        switch selectedPeriod {
        case .minute:
            return historyMirror.minuteTimeline
        case .hourly:
            return historyMirror.hourlyTimeline
        }
    }

    private var selectedTimelineStatusText: String {
        guard let selectedTimeline else {
            return "Waiting for \(selectedPeriod.caption)"
        }

        let pointCount = selectedTimeline.series.reduce(0) { $0 + $1.points.count }
        let updated = selectedTimeline.updatedAt.formatted(date: .omitted, time: .shortened)
        return "\(pointCount) buckets - updated \(updated)"
    }

    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width > 980
            let graphColumnWidth = isWide ? max(geometry.size.width * 0.64, 420) : geometry.size.width
            let sidebarWidth = isWide ? max(geometry.size.width * 0.30, 300) : geometry.size.width

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryHeader

                    if isWide {
                        HStack(alignment: .top, spacing: 16) {
                            graphColumn
                                .frame(width: graphColumnWidth, alignment: .topLeading)

                            sidebarColumn
                                .frame(width: sidebarWidth, alignment: .topLeading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            graphColumn
                            sidebarColumn
                        }
                    }
                }
                .padding(contentPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background { hardwareBackground }
            .overlay {
                if let selectedCard, let focus = makeFocusModel(for: selectedCard) {
                    CompanionFocusOverlayView(focus: focus) {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            self.selectedCard = nil
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: selectedCard?.id ?? "")
        }
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hardware Stats")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(GraphiteSlateTheme.primaryText)
                    Text(snapshot.machineIdentity.displayName)
                        .font(.subheadline)
                        .foregroundStyle(GraphiteSlateTheme.secondaryText)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(snapshot.machineIdentity.macOSVersion ?? "Unknown macOS")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GraphiteSlateTheme.secondaryText)
                    Text("Updated \(currentSnapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(GraphiteSlateTheme.secondaryText)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(snapshot.summaryChips) { chip in
                        CompanionChipView(chip: chip)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Graph Rollup")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(GraphiteSlateTheme.secondaryText)
                    Spacer()
                    Text(selectedTimelineStatusText)
                        .font(.caption2)
                        .foregroundStyle(GraphiteSlateTheme.secondaryText)
                        .lineLimit(1)
                }

                Picker("Graph Rollup", selection: $selectedPeriod) {
                    ForEach(TimelinePeriod.allCases) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Graph Rollup")
            }
        }
        .padding(16)
        .graphiteSurfaceWithRim(.panel, cornerRadius: 20)
    }

    private var hardwareBackground: some View {
        ZStack {
            GraphiteSlateTheme.windowBase
            GraphiteSlateWindowBottomGradient(
                height: 380,
                strength: 0.95
            )
            GraphiteSlateWindowOverlay(
                backdropStrength: 0.96,
                bottomGradientHeight: 520
            )
        }
        .ignoresSafeArea()
    }

    private var graphColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(resolvedGraphSections) { section in
                DashboardSectionView(
                    section: section,
                    gridMinimumWidth: 220,
                    cardSpacing: graphSectionCardSpacing,
                    selectedCard: $selectedCard
                )
            }
        }
    }

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            ActivityHeatmapCardForiOS(historyMirror: historyMirror)

            ForEach(snapshot.sidebarSections) { section in
                DashboardSectionView(
                    section: section,
                    gridMinimumWidth: 240,
                    cardSpacing: 12,
                    selectedCard: $selectedCard
                )
            }
        }
    }

    private var resolvedGraphSections: [CompanionDashboardSection] {
        snapshot.graphSections.map { section in
            CompanionDashboardSection(
                id: section.id,
                title: section.title,
                subtitle: section.subtitle,
                cards: section.cards.map { resolveGraphCard($0) }
            )
        }
    }

    private func resolveGraphCard(_ card: CompanionDashboardCard) -> CompanionDashboardCard {
        guard card.kind == .chart, let focusID = card.focusID else {
            return card
        }

        let liveValue = currentValueText(for: focusID)
        let liveSeries = liveSeriesPayloads(for: focusID)

        if !liveSeries.isEmpty {
            return CompanionDashboardCard(
                id: card.id,
                title: card.title,
                subtitle: card.subtitle,
                detail: card.detail,
                kind: card.kind,
                tint: card.tint,
                primaryValue: liveValue != "—" ? liveValue : card.primaryValue,
                progress: card.progress,
                series: liveSeries.map { payload in
                    let peak = payload.peakValue ?? 0
                    return CompanionSeries(
                        id: payload.id,
                        label: payload.label,
                        tint: payload.tint,
                        values: payload.points.map { bucket in
                            guard let value = bucket.value, peak > 0 else { return bucket.value }
                            return min(max(value / peak, 0.0), 1.0)
                        }
                    )
                },
                rows: card.rows,
                focusID: card.focusID,
                footnote: card.footnote
            )
        }

        return card
    }

    private func liveSeriesPayloads(for focusID: String) -> [CompanionTimelineSeriesPayload] {
        let series = timelineSeries(for: focusID, in: selectedTimeline)
        if !series.isEmpty {
            return series
        }

        return []
    }

    private func makeFocusModel(for card: CompanionDashboardCard) -> CompanionResolvedFocusModel? {
        if let focusID = card.focusID {
            switch focusID {
            case "sidebar.processes":
                return processFocusModel(card: card)
            case "sidebar.events":
                return eventsFocusModel(card: card)
            case "sidebar.power":
                return powerFocusModel(card: card)
            case "sidebar.network":
                return networkFocusModel(card: card)
            case "sidebar.memory":
                return memoryFocusModel(card: card)
            case "sidebar.insights":
                return insightsFocusModel(card: card)
            case "sidebar.cpuCores":
                return cpuCoresFocusModel(card: card)
            default:
                return metricFocusModel(card: card, focusID: focusID)
            }
        }

        return nil
    }

    private func metricFocusModel(card: CompanionDashboardCard, focusID: String) -> CompanionResolvedFocusModel {
        let series = timelineSeries(for: focusID, in: selectedTimeline)
        let values = series.flatMap { $0.points.compactMap(\.value) }

        let currentText = currentValueText(for: focusID)
        let averageText = formatTimelineValue(average(values), for: focusID)
        let peakText = formatTimelineValue(values.max(), for: focusID)

        let stats = [
            CompanionKeyValueRow(label: "Current", value: currentText, tint: card.tint),
            CompanionKeyValueRow(label: "Average", value: averageText, tint: .slate),
            CompanionKeyValueRow(label: "Peak", value: peakText, tint: card.tint)
        ]

        let chips = [
            CompanionSummaryChip(id: "current", label: "Current", value: currentText, tint: card.tint),
            CompanionSummaryChip(id: "avg", label: "Average", value: averageText, tint: .slate, caption: selectedPeriod.caption)
        ]

        let detailLines = supplementalDetailLines(for: focusID, card: card)
        let listRows = supplementalRows(for: focusID)

        let minuteSeries = timelineSeries(for: focusID, in: historyMirror.minuteTimeline)
        let hourlySeries = timelineSeries(for: focusID, in: historyMirror.hourlyTimeline)

        return CompanionResolvedFocusModel(
            title: card.title,
            subtitle: card.subtitle,
            tint: card.tint,
            highlightChips: chips,
            stats: stats,
            detailLines: detailLines,
            minuteSeries: minuteSeries,
            hourlySeries: hourlySeries,
            listRows: listRows
        )
    }

    private func processFocusModel(card: CompanionDashboardCard) -> CompanionResolvedFocusModel {
        let processes = currentSnapshot.liveSnapshot.topProcesses
        let topCPU = processes.max(by: { $0.cpuPercent < $1.cpuPercent })
        let gpuActiveCount = processes.filter(\.gpuActive).count
        let listRows = processes.map { process in
            CompanionKeyValueRow(
                label: process.displayName,
                value: [
                    String(format: "%.0f%% CPU", process.cpuPercent),
                    String(format: "%.0f MB RAM", process.ramMB)
                ].joined(separator: "  ·  "),
                tint: process.gpuActive ? .purple : .blue
            )
        }

        return CompanionResolvedFocusModel(
            title: card.title,
            subtitle: card.subtitle,
            tint: card.tint,
            highlightChips: [
                CompanionSummaryChip(id: "process.count", label: "Processes", value: "\(processes.count)", tint: .cyan, caption: "Tracked now"),
                CompanionSummaryChip(id: "process.gpu", label: "GPU Active", value: "\(gpuActiveCount)", tint: .purple, caption: "Using GPU"),
                CompanionSummaryChip(id: "process.top", label: "Top CPU", value: topCPU?.displayName ?? "—", tint: .blue, caption: topCPU.map { String(format: "%.0f%% CPU", $0.cpuPercent) })
            ],
            stats: [
                CompanionKeyValueRow(label: "Tracked", value: "\(processes.count)", tint: .cyan),
                CompanionKeyValueRow(label: "GPU Active", value: "\(gpuActiveCount)", tint: .purple),
                CompanionKeyValueRow(label: "Top CPU", value: topCPU.map { String(format: "%.0f%%", $0.cpuPercent) } ?? "—", tint: .blue),
                CompanionKeyValueRow(label: "Top RAM", value: processes.max(by: { $0.ramMB < $1.ramMB }).map { String(format: "%.0f MB", $0.ramMB) } ?? "—", tint: .green)
            ],
            detailLines: [
                "These rows come from the source Mac's latest process snapshot rather than seeded sample data.",
                "GPU-active highlights mark processes that were observed with non-zero GPU activity in the latest sampling window."
            ],
            minuteSeries: [],
            hourlySeries: [],
            listRows: listRows
        )
    }

    private func eventsFocusModel(card: CompanionDashboardCard) -> CompanionResolvedFocusModel {
        let events = historyMirror.hardwareEvents?.entries ?? []
        let listRows = events.map { entry in
            CompanionKeyValueRow(
                label: entry.title,
                value: [entry.category.capitalized, entry.detail].compactMap { $0 }.joined(separator: "  ·  "),
                tint: tint(forSeverity: entry.severity)
            )
        }

        return CompanionResolvedFocusModel(
            title: card.title,
            subtitle: card.subtitle,
            tint: card.tint,
            highlightChips: [
                CompanionSummaryChip(id: "events.count", label: "Events", value: "\(events.count)", tint: .slate, caption: "Last 24h"),
                CompanionSummaryChip(id: "events.warn", label: "Highlights", value: "\(events.filter { $0.severity >= 2 }.count)", tint: .orange, caption: "Important")
            ],
            stats: [
                CompanionKeyValueRow(label: "Total", value: "\(events.count)", tint: .slate),
                CompanionKeyValueRow(label: "Highlights", value: "\(events.filter { $0.severity >= 2 }.count)", tint: .orange),
                CompanionKeyValueRow(label: "Cautions", value: "\(events.filter { $0.severity == 1 }.count)", tint: .amber)
            ],
            detailLines: [
                "Recent hardware and monitoring events are synced through the dedicated CloudKit event payload.",
                "Use this to cross-check spikes in the graph history against real state changes on the source Mac."
            ],
            minuteSeries: [],
            hourlySeries: [],
            listRows: listRows
        )
    }

    private func powerFocusModel(card: CompanionDashboardCard) -> CompanionResolvedFocusModel {
        let power = currentSnapshot.liveSnapshot.power
        var detailLines = [
            "Combined power is graphed from the synced CloudKit rollups and paired with the source Mac's latest package readings.",
            "Energy is cumulative over the active monitoring session on the source machine."
        ]

        if let pmText = power.powermetricsText {
            detailLines.append("Source readings: \(pmText)")
        }

        return CompanionResolvedFocusModel(
            title: card.title,
            subtitle: card.subtitle,
            tint: card.tint,
            highlightChips: [
                CompanionSummaryChip(id: "power.combined", label: "Combined", value: formatWatts(power.combinedPowerWatts), tint: .orange, caption: "Current draw"),
                CompanionSummaryChip(id: "power.energy", label: "Energy", value: formatEnergy(power.cumulativeEnergyWh), tint: .green, caption: "Monitoring total"),
                CompanionSummaryChip(id: "power.peak", label: "Peak", value: formatWatts(power.peakCombinedPowerWatts), tint: .amber, caption: "Observed")
            ],
            stats: [
                CompanionKeyValueRow(label: "CPU", value: formatWatts(power.cpuPowerWatts), tint: .blue),
                CompanionKeyValueRow(label: "GPU", value: formatWatts(power.gpuPowerWatts), tint: .red),
                CompanionKeyValueRow(label: "ANE", value: formatWatts(power.anePowerWatts), tint: .pink),
                CompanionKeyValueRow(label: "Uptime", value: formatDuration(power.uptimeSeconds), tint: .slate)
            ],
            detailLines: detailLines,
            minuteSeries: timelineSeries(for: "metric.power.combined", in: historyMirror.minuteTimeline),
            hourlySeries: timelineSeries(for: "metric.power.combined", in: historyMirror.hourlyTimeline),
            listRows: []
        )
    }

    private func networkFocusModel(card: CompanionDashboardCard) -> CompanionResolvedFocusModel {
        let network = currentSnapshot.liveSnapshot.network
        return CompanionResolvedFocusModel(
            title: card.title,
            subtitle: card.subtitle,
            tint: card.tint,
            highlightChips: [
                CompanionSummaryChip(id: "net.upload", label: "Upload", value: formatRate(network.uploadMBps), tint: .green),
                CompanionSummaryChip(id: "net.download", label: "Download", value: formatRate(network.downloadMBps), tint: .blue)
            ],
            stats: [
                CompanionKeyValueRow(label: "Upload", value: formatRate(network.uploadMBps), tint: .green),
                CompanionKeyValueRow(label: "Download", value: formatRate(network.downloadMBps), tint: .blue),
                CompanionKeyValueRow(label: "Latency", value: network.pingLatencyMilliseconds.map { "\($0) ms" } ?? "—", tint: .slate),
                CompanionKeyValueRow(label: "Loss", value: formatPercent(network.packetLossRatio), tint: .slate),
                CompanionKeyValueRow(label: "Interface", value: network.interfaceName ?? "—", tint: .slate),
                CompanionKeyValueRow(label: "Local IP", value: network.localIP ?? "—", tint: .slate),
                CompanionKeyValueRow(label: "Router", value: network.router ?? "—", tint: .slate),
                CompanionKeyValueRow(label: "DNS", value: network.dnsServers.first ?? "—", tint: .slate)
            ],
            detailLines: [
                "The upload and download charts come from the synced network rollups.",
                "Interface, IP, router, and DNS rows are refreshed from the latest live payload."
            ],
            minuteSeries: timelineSeries(for: ["metric.network.upload", "metric.network.download"], in: historyMirror.minuteTimeline),
            hourlySeries: timelineSeries(for: ["metric.network.upload", "metric.network.download"], in: historyMirror.hourlyTimeline),
            listRows: []
        )
    }

    private func memoryFocusModel(card: CompanionDashboardCard) -> CompanionResolvedFocusModel {
        let memory = currentSnapshot.liveSnapshot.memory
        return CompanionResolvedFocusModel(
            title: card.title,
            subtitle: card.subtitle,
            tint: card.tint,
            highlightChips: [
                CompanionSummaryChip(id: "memory.used", label: "Used", value: memorySummary(memory), tint: .green, caption: memory.pressureLabel),
                CompanionSummaryChip(id: "memory.cached", label: "Cached", value: formatGB(memory.cachedGB), tint: .slate, caption: "File cache"),
                CompanionSummaryChip(id: "memory.swap", label: "Swap", value: swapSummary(memory), tint: .slate, caption: "Compressed spill")
            ],
            stats: [
                CompanionKeyValueRow(label: "Compressed", value: formatGB(memory.compressedGB), tint: .slate),
                CompanionKeyValueRow(label: "Wired", value: formatGB(memory.wiredGB), tint: .slate),
                CompanionKeyValueRow(label: "App Memory", value: formatGB(memory.appMemoryGB), tint: .green),
                CompanionKeyValueRow(label: "Pressure", value: memory.pressureLabel, tint: .green)
            ],
            detailLines: [
                memory.pressureSubtext,
                "Usage, pressure, and swap are all coming from the CloudKit-backed history mirror."
            ],
            minuteSeries: timelineSeries(for: ["metric.memory.usage", "metric.memory.pressure", "metric.memory.swap"], in: historyMirror.minuteTimeline),
            hourlySeries: timelineSeries(for: ["metric.memory.usage", "metric.memory.pressure"], in: historyMirror.hourlyTimeline),
            listRows: []
        )
    }

    private func insightsFocusModel(card: CompanionDashboardCard) -> CompanionResolvedFocusModel {
        let rows = currentSnapshot.liveSnapshot.hardwareInsights
        return CompanionResolvedFocusModel(
            title: card.title,
            subtitle: card.subtitle,
            tint: card.tint,
            highlightChips: rows.prefix(3).map { row in
                CompanionSummaryChip(id: "insight.\(row.id)", label: row.label, value: row.value, tint: row.tint)
            },
            stats: rows,
            detailLines: [
                "These summaries are derived from the source Mac's current live snapshot instead of canned copy.",
                "They update whenever the current snapshot payload is republished through CloudKit."
            ],
            minuteSeries: [],
            hourlySeries: [],
            listRows: rows
        )
    }

    private func cpuCoresFocusModel(card: CompanionDashboardCard) -> CompanionResolvedFocusModel {
        let cpu = currentSnapshot.liveSnapshot.cpu
        let frequencies = currentSnapshot.liveSnapshot.power.perCoreFrequenciesGHz
        let rows = cpu.coreUsages.enumerated().map { index, usage in
            let frequency = index < frequencies.count ? String(format: "%.2f GHz", frequencies[index]) : "—"
            return CompanionKeyValueRow(
                label: "Core \(index + 1)",
                value: "\(formatPercent(usage))  ·  \(frequency)",
                tint: usage >= 0.7 ? .orange : .blue
            )
        }

        var detailLines = [
            "Per-core rows reflect the latest snapshot from the source Mac."
        ]

        if let pmText = currentSnapshot.liveSnapshot.power.powermetricsText {
            detailLines.append("Source readings: \(pmText)")
        }

        return CompanionResolvedFocusModel(
            title: card.title,
            subtitle: card.subtitle,
            tint: card.tint,
            highlightChips: [
                CompanionSummaryChip(id: "cpu.total", label: "CPU", value: formatPercent(cpu.totalUsageRatio), tint: .blue),
                CompanionSummaryChip(id: "cpu.eff", label: "E-Cores", value: "\(cpu.efficiencyCoreCount)", tint: .teal),
                CompanionSummaryChip(id: "cpu.perf", label: "P-Cores", value: "\(cpu.performanceCoreCount)", tint: .indigo)
            ],
            stats: [
                CompanionKeyValueRow(label: "Total", value: formatPercent(cpu.totalUsageRatio), tint: .blue),
                CompanionKeyValueRow(label: "Efficiency", value: formatPercent(cpu.efficiencyUsageRatio), tint: .teal),
                CompanionKeyValueRow(label: "Performance", value: formatPercent(cpu.performanceUsageRatio), tint: .indigo)
            ],
            detailLines: detailLines,
            minuteSeries: timelineSeries(for: ["metric.cpu.total", "metric.cpu.efficiency", "metric.cpu.performance"], in: historyMirror.minuteTimeline),
            hourlySeries: [],
            listRows: rows
        )
    }

    private func timelineSeries(for seriesKey: String, in timeline: CompanionTimelinePayload?) -> [CompanionTimelineSeriesPayload] {
        timelineSeries(for: [seriesKey], in: timeline)
    }

    private func timelineSeries(for seriesKeys: [String], in timeline: CompanionTimelinePayload?) -> [CompanionTimelineSeriesPayload] {
        guard let timeline else { return [] }
        return timeline.series.filter { seriesKeys.contains($0.seriesKey) }
    }

    private func currentValueText(for focusID: String) -> String {
        let liveSnapshot = currentSnapshot.liveSnapshot

        switch focusID {
        case "metric.cpu.total":
            return formatPercent(liveSnapshot.cpu.totalUsageRatio)
        case "metric.cpu.efficiency":
            return formatPercent(liveSnapshot.cpu.efficiencyUsageRatio)
        case "metric.cpu.performance":
            return formatPercent(liveSnapshot.cpu.performanceUsageRatio)
        case "metric.memory.usage":
            return memorySummary(liveSnapshot.memory)
        case "metric.memory.pressure":
            return liveSnapshot.memory.pressureLabel
        case "metric.memory.swap":
            return swapSummary(liveSnapshot.memory)
        case "metric.disk.read":
            return formatRate(liveSnapshot.storage.diskReadMBps)
        case "metric.disk.write":
            return formatRate(liveSnapshot.storage.diskWriteMBps)
        case "metric.network.upload":
            return formatRate(liveSnapshot.network.uploadMBps)
        case "metric.network.download":
            return formatRate(liveSnapshot.network.downloadMBps)
        case "metric.power.combined":
            return formatWatts(liveSnapshot.power.combinedPowerWatts)
        case "metric.thermal.level":
            return thermalLabel()
        case "metric.ane.activity":
            return formatPercent(liveSnapshot.ane?.activityRatio)
        case "metric.media.activity":
            return liveSnapshot.media?.activityStateText ?? "Idle"
        default:
            if focusID.hasPrefix("device.gpu.") {
                return gpuCurrentValueText(for: focusID)
            }
            return "—"
        }
    }

    private func supplementalRows(for focusID: String) -> [CompanionKeyValueRow] {
        let liveSnapshot = currentSnapshot.liveSnapshot

        if focusID.hasPrefix("device.gpu."),
           let gpu = gpu(for: focusID) {
            return [
                CompanionKeyValueRow(label: "Renderer", value: formatPercent(gpu.rendererUtilizationRatio), tint: .amber),
                CompanionKeyValueRow(label: "Tiler", value: formatPercent(gpu.tilerUtilizationRatio), tint: .orange),
                CompanionKeyValueRow(label: "Allocated", value: formatMemoryMB(gpu.memoryAllocatedMB), tint: .slate),
                CompanionKeyValueRow(label: "Temperature", value: formatTemperature(gpu.temperatureCelsius), tint: .slate),
                CompanionKeyValueRow(label: "Displays", value: gpu.connectedDisplayCount.map(String.init) ?? "—", tint: .slate)
            ]
        }

        switch focusID {
        case "metric.power.combined":
            return [
                CompanionKeyValueRow(label: "CPU", value: formatWatts(liveSnapshot.power.cpuPowerWatts), tint: .blue),
                CompanionKeyValueRow(label: "GPU", value: formatWatts(liveSnapshot.power.gpuPowerWatts), tint: .red),
                CompanionKeyValueRow(label: "ANE", value: formatWatts(liveSnapshot.power.anePowerWatts), tint: .pink)
            ]
        case "metric.memory.usage", "metric.memory.pressure", "metric.memory.swap":
            return [
                CompanionKeyValueRow(label: "Cached", value: formatGB(liveSnapshot.memory.cachedGB), tint: .slate),
                CompanionKeyValueRow(label: "Compressed", value: formatGB(liveSnapshot.memory.compressedGB), tint: .slate),
                CompanionKeyValueRow(label: "Wired", value: formatGB(liveSnapshot.memory.wiredGB), tint: .slate)
            ]
        case "metric.network.upload", "metric.network.download":
            return [
                CompanionKeyValueRow(label: "Interface", value: liveSnapshot.network.interfaceName ?? "—", tint: .slate),
                CompanionKeyValueRow(label: "IP", value: liveSnapshot.network.localIP ?? "—", tint: .slate),
                CompanionKeyValueRow(label: "DNS", value: liveSnapshot.network.dnsServers.first ?? "—", tint: .slate)
            ]
        case "metric.ane.activity":
            if let ane = liveSnapshot.ane {
                return [
                    CompanionKeyValueRow(label: "Status", value: ane.statusText, tint: .pink),
                    CompanionKeyValueRow(label: "Clients", value: "\(ane.clientCount)", tint: .slate),
                    CompanionKeyValueRow(label: "Power", value: formatWatts(ane.currentPowerWatts), tint: .pink)
                ]
            }
            return []
        case "metric.media.activity":
            if let media = liveSnapshot.media {
                return [
                    CompanionKeyValueRow(label: "State", value: media.activityStateText, tint: .indigo),
                    CompanionKeyValueRow(label: "Codec", value: media.codec ?? "—", tint: .slate),
                    CompanionKeyValueRow(label: "Frames", value: "\(media.recentProcessedFrames)", tint: .slate)
                ]
            }
            return []
        default:
            return []
        }
    }

    private func supplementalDetailLines(for focusID: String, card: CompanionDashboardCard) -> [String] {
        var lines: [String] = []
        if let detail = card.detail {
            lines.append(detail)
        }
        lines.append("The upper chart uses the synced 24-hour minute rollup.")
        lines.append("The lower chart uses the synced 7-day hourly rollup when available.")

        if focusID.hasPrefix("device.gpu.") {
            lines.append("GPU device metrics are keyed per-device so the correct Mac GPU stays selected across refreshes.")
        }

        return lines
    }

    private func gpuCurrentValueText(for focusID: String) -> String {
        guard let gpu = gpu(for: focusID) else { return "—" }
        if focusID.hasSuffix(".renderer") {
            return formatPercent(gpu.rendererUtilizationRatio)
        }
        if focusID.hasSuffix(".tiler") {
            return formatPercent(gpu.tilerUtilizationRatio)
        }
        return formatPercent(gpu.utilizationRatio)
    }

    private func gpu(for focusID: String) -> CompanionLiveGPUSnapshot? {
        let parts = focusID.split(separator: ".")
        guard parts.count >= 4 else { return nil }
        let gpuID = String(parts[2])
        return currentSnapshot.liveSnapshot.gpus.first(where: { $0.id == gpuID })
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func formatTimelineValue(_ value: Double?, for focusID: String) -> String {
        guard let value else { return "—" }
        if focusID.hasPrefix("metric.cpu.") {
            return "\(Int(value.rounded()))%"
        }
        if focusID.hasSuffix(".utilization") || focusID.hasSuffix(".renderer") || focusID.hasSuffix(".tiler") ||
            focusID == "metric.memory.usage" || focusID == "metric.memory.pressure" ||
            focusID == "metric.ane.activity" || focusID == "metric.media.activity" {
            return "\(Int((value * 100).rounded()))%"
        }
        if focusID == "metric.disk.read" || focusID == "metric.disk.write" ||
            focusID == "metric.network.upload" || focusID == "metric.network.download" {
            return formatRate(value)
        }
        if focusID == "metric.power.combined" {
            return formatWatts(value)
        }
        if focusID == "metric.memory.swap" {
            return formatGB(value)
        }
        return String(format: "%.2f", value)
    }

    private func memorySummary(_ memory: CompanionLiveMemorySnapshot) -> String {
        guard let used = memory.usedGB, let total = memory.totalGB else { return "—" }
        return String(format: "%.1f / %.0f GB", used, total)
    }

    private func swapSummary(_ memory: CompanionLiveMemorySnapshot) -> String {
        guard let used = memory.swapUsedGB, let total = memory.swapTotalGB, total > 0 else { return "Inactive" }
        return String(format: "%.1f / %.1f GB", used, total)
    }

    private func thermalLabel() -> String {
        if let row = snapshot.sidebarSections
            .flatMap(\.cards)
            .first(where: { $0.focusID == "metric.thermal.level" })?.primaryValue {
            return row
        }
        return "Unknown"
    }

    private func tint(forSeverity severity: Int) -> CompanionTint {
        switch severity {
        case 2: return .orange
        case 1: return .amber
        default: return .slate
        }
    }

    private func formatPercent(_ ratio: Double?) -> String {
        guard let ratio else { return "—" }
        return "\(Int((min(max(ratio, 0), 1) * 100).rounded()))%"
    }

    private func formatRate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 10 ? String(format: "%.0f MB/s", value) : String(format: "%.1f MB/s", value)
    }

    private func formatWatts(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 10 ? String(format: "%.1f W", value) : String(format: "%.2f W", value)
    }

    private func formatWatts(_ value: Double) -> String {
        formatWatts(Optional(value))
    }

    private func formatEnergy(_ value: Double) -> String {
        if value < 1 {
            return String(format: "%.0f mWh", value * 1000.0)
        }
        return String(format: "%.2f Wh", value)
    }

    private func formatGB(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 10 ? String(format: "%.0f GB", value) : String(format: "%.1f GB", value)
    }

    private func formatMemoryMB(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 1024 {
            return String(format: "%.1f GB", value / 1024.0)
        }
        return String(format: "%.0f MB", value)
    }

    private func formatDuration(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "—"
    }

    private func formatTemperature(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f C", value)
    }

    private func pingSummary(_ network: CompanionLiveNetworkSnapshot) -> String {
        if let latency = network.pingLatencyMilliseconds {
            return String(format: "%.0f ms", latency)
        }
        return network.pingTargetLabel
    }
}

private struct DashboardSectionView: View {
    let section: CompanionDashboardSection
    let gridMinimumWidth: CGFloat
    let cardSpacing: CGFloat
    @Binding var selectedCard: CompanionDashboardCard?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(GraphiteSlateTheme.primaryText)
                    if let subtitle = section.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(GraphiteSlateTheme.secondaryText)
                    }
                }
                Spacer()
            }

            let columns = [GridItem(.adaptive(minimum: gridMinimumWidth), spacing: cardSpacing, alignment: .top)]

            LazyVGrid(columns: columns, alignment: .leading, spacing: cardSpacing) {
                ForEach(section.cards) { card in
                    DashboardCardView(card: card) {
                        guard card.focusID != nil else { return }
                        withAnimation(.easeInOut(duration: 0.22)) {
                            selectedCard = card
                        }
                    }
                }
            }
        }
        .padding(16)
        .graphiteSurfaceWithRim(.control, cornerRadius: 20)
    }

}

private struct DashboardCardView: View {
    let card: CompanionDashboardCard
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            cardContent
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GraphiteSlateTheme.primaryText)
                    if let subtitle = card.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(GraphiteSlateTheme.secondaryText)
                    }
                }

                Spacer(minLength: 0)

                if let primaryValue = card.primaryValue {
                    Text(primaryValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(card.tint.color)
                }
            }

            switch card.kind {
            case .chart:
                chartBody
            case .meter:
                meterBody
            case .list, .insight:
                listBody
            case .identity:
                identityBody
            }

            if let detail = card.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(GraphiteSlateTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let footnote = card.footnote {
                Text(footnote)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GraphiteSlateTheme.secondaryText)
            }
        }
        .padding(14)
        .graphiteSurfaceWithRim(.panel, cornerRadius: 18, stroke: card.tint.color.opacity(0.22))
        .shadow(color: card.tint.color.opacity(0.10), radius: 14, x: 0, y: 8)
    }

    private var chartBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let series = card.series.first {
                Chart(chartPoints(for: series)) { point in
                    AreaMark(
                        x: .value("Sample", point.index),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(series.tint.color.opacity(0.14))

                    LineMark(
                        x: .value("Sample", point.index),
                        y: .value("Value", point.value)
                    )
                    .foregroundStyle(series.tint.color)
                    .lineStyle(.init(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                }
                .chartYScale(domain: 0...1)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 86)
            }

            if card.series.count > 1 {
                HStack(spacing: 8) {
                    ForEach(card.series) { series in
                        Label(series.label, systemImage: "circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                            .foregroundStyle(series.tint.color)
                    }
                }
            }
        }
    }

    private var meterBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: card.progress ?? 0)
                .tint(card.tint.color)
            if let progress = card.progress {
                Text("\(Int(progress * 100))%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(card.tint.color)
            }
        }
    }

    private var listBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(card.rows) { row in
                HStack {
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(GraphiteSlateTheme.secondaryText)
                    Spacer()
                    Text(row.value)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(row.tint.color)
                }
                if row.id != card.rows.last?.id {
                    Divider().opacity(0.35)
                }
            }
        }
    }

    private var identityBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(card.tint.color.opacity(0.16))
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(card.tint.color)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.primaryValue ?? "Mac")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GraphiteSlateTheme.primaryText)
                    Text(card.subtitle ?? "")
                        .font(.caption2)
                        .foregroundStyle(GraphiteSlateTheme.secondaryText)
                }
            }

            listBody
        }
    }

    private func chartPoints(for series: CompanionSeries) -> [ChartPoint] {
        series.values.enumerated().compactMap { index, value in
            guard let value else { return nil }
            return ChartPoint(index: Double(index), value: min(max(value, 0), 1))
        }
    }
}

private struct CompanionChipView: View {
    let chip: CompanionSummaryChip

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chip.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GraphiteSlateTheme.secondaryText)
            Text(chip.value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(chip.tint.color)
            if let caption = chip.caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(GraphiteSlateTheme.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(chip.tint.color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(chip.tint.color.opacity(0.12), lineWidth: 1)
                )
        )
    }
}

private struct CompanionResolvedFocusModel {
    let title: String
    let subtitle: String?
    let tint: CompanionTint
    let highlightChips: [CompanionSummaryChip]
    let stats: [CompanionKeyValueRow]
    let detailLines: [String]
    let minuteSeries: [CompanionTimelineSeriesPayload]
    let hourlySeries: [CompanionTimelineSeriesPayload]
    let listRows: [CompanionKeyValueRow]
}

private struct CompanionFocusOverlayView: View {
    let focus: CompanionResolvedFocusModel
    let onClose: () -> Void

    var body: some View {
        ZStack {
            GraphiteSlateTheme.shadow.opacity(0.75)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(focus.title)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(GraphiteSlateTheme.primaryText)
                            if let subtitle = focus.subtitle {
                                Text(subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(GraphiteSlateTheme.secondaryText)
                            }
                        }
                        Spacer()
                        Button("Back", action: onClose)
                            .buttonStyle(.bordered)
                    }

                    if !focus.highlightChips.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(focus.highlightChips) { chip in
                                    CompanionChipView(chip: chip)
                                }
                            }
                        }
                    }

                    if !focus.minuteSeries.isEmpty {
                        CompanionTimelinePanel(title: "24 Hour Rollup", series: focus.minuteSeries)
                    }

                    if !focus.hourlySeries.isEmpty {
                        CompanionTimelinePanel(title: "7 Day Rollup", series: focus.hourlySeries)
                    }

                    if !focus.stats.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], alignment: .leading, spacing: 12) {
                            ForEach(focus.stats) { stat in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(stat.label)
                                        .font(.caption2)
                                        .foregroundStyle(GraphiteSlateTheme.secondaryText)
                                    Text(stat.value)
                                        .font(.headline.weight(.semibold))
                                        .foregroundStyle(stat.tint.color)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(GraphiteSlateTheme.fill(for: .control))
                                )
                                .overlay(CardBackgroundOverlay(shape: ThemeRoundedRectangle(cornerRadius: 14, style: .continuous)))
                            }
                        }
                    }

                    if !focus.listRows.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Details")
                                .font(.headline.weight(.semibold))
                            VStack(spacing: 8) {
                                ForEach(focus.listRows) { row in
                                    HStack(alignment: .top) {
                                        Text(row.label)
                                            .font(.caption)
                                            .foregroundStyle(GraphiteSlateTheme.secondaryText)
                                        Spacer()
                                        Text(row.value)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(row.tint.color)
                                            .multilineTextAlignment(.trailing)
                                    }
                                    if row.id != focus.listRows.last?.id {
                                        Divider().opacity(0.3)
                                    }
                                }
                            }
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(GraphiteSlateTheme.fill(for: .control))
                            )
                            .overlay(CardBackgroundOverlay(shape: ThemeRoundedRectangle(cornerRadius: 18, style: .continuous)))
                        }
                    }

                    if !focus.detailLines.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(focus.detailLines, id: \.self) { line in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(focus.tint.color)
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 7)
                                    Text(line)
                                        .font(.callout)
                                        .foregroundStyle(GraphiteSlateTheme.secondaryText)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: 760)
            .frame(maxHeight: 820)
            .background(
                ThemeRoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(GraphiteSlateTheme.fill(for: .panel))
                    .overlay(
                        ThemeRoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(GraphiteSlateTheme.stroke(for: .panel), lineWidth: 1)
                    )
            )
            .overlay(CardBackgroundOverlay(shape: ThemeRoundedRectangle(cornerRadius: 24, style: .continuous)))
            .padding(20)
        }
    }
}

private struct CompanionTimelinePanel: View {
    let title: String
    let series: [CompanionTimelineSeriesPayload]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(GraphiteSlateTheme.primaryText)

            Chart {
                ForEach(series) { series in
                    ForEach(chartPoints(for: series)) { point in
                        LineMark(
                            x: .value("Sample", point.index),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(series.tint.color)
                        .lineStyle(.init(lineWidth: 2.0, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .chartYScale(domain: 0...1)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 180)

            if series.count > 1 {
                HStack(spacing: 10) {
                    ForEach(series) { item in
                        Label(item.label, systemImage: "circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                            .foregroundStyle(item.tint.color)
                    }
                }
            }
        }
            .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(GraphiteSlateTheme.fill(for: .control))
        )
        .overlay(CardBackgroundOverlay(shape: ThemeRoundedRectangle(cornerRadius: 18, style: .continuous)))
    }

    private func chartPoints(for series: CompanionTimelineSeriesPayload) -> [ChartPoint] {
        let peak = max(series.peakValue ?? 0, series.points.compactMap(\.value).max() ?? 0)
        return series.points.enumerated().compactMap { index, point in
            guard let value = point.value else { return nil }
            let normalized = peak > 0 ? value / peak : value
            return ChartPoint(index: Double(index), value: min(max(normalized, 0), 1))
        }
    }
}

private struct ChartPoint: Identifiable {
    let index: Double
    let value: Double

    var id: Double { index }
}

private extension View {
    func graphiteSurfaceWithRim(
        _ surface: GraphiteSlateSurface,
        cornerRadius: CGFloat = 12,
        stroke: Color? = nil
    ) -> some View {
        self.graphiteSurface(surface, cornerRadius: cornerRadius, stroke: stroke)
            .overlay(CardBackgroundOverlay(shape: ThemeRoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
    }
}
