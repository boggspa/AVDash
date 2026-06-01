import SwiftUI
import AppKit
import Darwin
import PodcastPreviewCore
import PodcastPreviewShared
import Combine
#if canImport(FoundationModels)
import FoundationModels
#endif

struct HardwareInsightsCard: View {
    @Environment(\.appUIScale) private var appUIScale
    let insightsService: HardwareInsightsService
    let refreshAnchor: Date
    let hasNeuralEngine: Bool
    let primaryGPUID: String?
    // Live snapshot data for contextFact enrichment
    var storageSnapshot: StorageStatsSampler.CapacitySnapshot? = nil
    var mediaActivitySummary: MediaEngineStatsSampler.ActivitySummary? = nil
    var topMemoryRows: [(name: String, ramMB: Double)] = []
    var gpuActiveAppNames: [String] = []
    var uptimeSeconds: TimeInterval? = nil
    var cumulativeEnergyWh: Double = 0
    var appLaunchDate: Date = Date()
    var sessionSummaryLabel: String = "App has been monitoring"
    var sessionContextNoun: String = "monitoring session"
    var processCount: Int? = nil
    var perCoreFrequenciesHz: [Double] = []
    var efficiencyCoreCount: Int = 0
    var performanceCoreCount: Int = 0
    /// Live Top Apps rows for the "App" insight tile. Expected to be pre-sorted by RAM descending.
    var topAppRows: [TopAppInsightRow] = []
    var onFocus: ((HardwareInsightsFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareInsightsFocusState) -> Void)? = nil

    /// Lightweight struct carrying the fields the App insight tile needs from TopAppsCard data.
    struct TopAppInsightRow {
        let name: String
        let bundleIdentifier: String?
        let uptimeSeconds: Double
        let ramMB: Double
        let cpuPercent: Double
        let isGPUActive: Bool
    }

    @AppStorage("hwInsightsCardCollapsed") private var isCollapsed = false
    @State private var selectedWindow: HardwareInsightWindow = .daily
    @State private var rows: [InsightRow] = []
    @State private var sessionStory: SessionStory?
    @State private var isLoading = false
    @State private var viewMode: InsightViewMode = .overview
    @State private var focusIndex = 0
    @State private var focusAdvancedForward = true
    @State private var isFocusHovered = false
    @State private var lastInteractionDate: Date = .distantPast
    @State private var isAIEnhancing = false
    /// Tracks when the LLM last ran for each time window so we don't call it
    /// more often than once every 15 minutes. Cache hits still apply instantly.
    @State private var lastAIEnhancementDates: [HardwareInsightWindow: Date] = [:]
    // AI glow effect — opacity and rotation driven by isAIEnhancing transitions.
    // Both default to 0 so on non-Tahoe systems (where isAIEnhancing is always
    // false) they never change and no overlay is ever visible.
    @State private var aiGlowOpacity: Double = 0
    @State private var aiGlowRotation: Double = 0

    // Distress mode: tracks when a metric has been pinned near its ceiling long
    // enough to warrant a humorous "help me" takeover insight.
    // Key = row id ("cpu", "gpu", "memory", "ane"). Value = when the distress
    // message was last *displayed* (so we can hold it for 10 min then require
    // another 30 min of sustained load before re-triggering).
    @State private var distressLastShownDates: [String: Date] = [:]
    @State private var distressSustainedSinceDates: [String: Date] = [:]

    private let focusAdvanceTimer = Timer.publish(every: 7, on: .main, in: .common).autoconnect()

    private enum InsightViewMode { case overview, focus }

    private struct InsightRow: Identifiable {
        let id: String
        let title: String
        let iconName: String
        let accentColor: Color
        var headline: String
        var detail: String
        let coverageRatio: Double
        var isAIEnhanced: Bool = false
        // Focus-mode extras — defaulted so existing call sites compile unchanged
        var averageValue: Double? = nil
        var peakValue: Double? = nil
        var spikeBucketCount: Int = 0
        var busiestHour: Int? = nil
        var peakWindowDate: Date? = nil
        var valueUnit: FocusValueUnit = .ratio
        var contextFacts: [String] = []
        var aiKind: AIKind = .none
        var insightFingerprint: String = ""
        var appPrimaryName: String? = nil
        var appPrimaryHours: Double? = nil

        enum FocusValueUnit {
            case ratio, megabytesPerSecond, watts
            func formatted(_ value: Double) -> String {
                switch self {
                case .ratio:
                    return "\(Int((value * 100).rounded()))%"
                case .megabytesPerSecond:
                    if value >= 1000 { return String(format: "%.1f GB/s", value / 1000.0) }
                    if value >= 1    { return String(format: "%.1f MB/s", value) }
                    return String(format: "%.0f KB/s", value * 1024)
                case .watts:
                    return value >= 10 ? String(format: "%.1f W", value) : String(format: "%.2f W", value)
                }
            }
        }

        enum AIKind {
            case none
            case metric
            case app
        }
    }

    private struct GPUInsightBundle {
        let main: HardwareMetricInsight
        let renderer: HardwareMetricInsight
        let tiler: HardwareMetricInsight
        let vramUsed: HardwareMetricInsight
        let memAllocated: HardwareMetricInsight
    }

    private struct SessionStory {
        let iconName: String
        let accentColor: Color
        let headline: String
        let detail: String
    }

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledPadding: CGFloat { 12 * appUIScale }
    private var scaledStackSpacing: CGFloat { 12 * appUIScale }
    private var scaledRowSpacing: CGFloat { 14 * appUIScale }
    private var scaledHeaderSpacing: CGFloat { 8 * appUIScale }
    private var scaledTitleFontSize: CGFloat { 13 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }
    private var scaledCaption2FontSize: CGFloat { 11 * appUIScale }
    private var scaledIconSize: CGFloat { 28 * appUIScale }
    private var scaledBadgeHorizontalPadding: CGFloat { 7 * appUIScale }
    private var scaledBadgeVerticalPadding: CGFloat { 4 * appUIScale }
    private var scaledMinCardHeight: CGFloat { 236 * appUIScale }
    private var refreshMinuteToken: Int {
        Int(refreshAnchor.timeIntervalSince1970 / 60)
    }
    private var copywriter: HardwareInsightCopywriter {
        HardwareInsightCopywriter(window: selectedWindow)
    }
    private var hasLoadedInsights: Bool {
        !rows.isEmpty || sessionStory != nil
    }
    private var focusID: String { "hardware-insights-focus" }
    private var focusRefreshSignature: Int {
        var hasher = Hasher()
        hasher.combine(selectedWindow.rawValue)
        hasher.combine(isCollapsed)
        hasher.combine(viewMode == .focus)
        hasher.combine(isLoading)
        hasher.combine(isAIEnhancing)
        if let sessionStory {
            hasher.combine(sessionStory.iconName)
            hasher.combine(sessionStory.headline)
        } else {
            hasher.combine("no-session-story")
        }
        // Lightweight change detection: count + boundary row identifiers instead
        // of iterating every field and contextFact on every body evaluation.
        let displayRows = rows.isEmpty ? loadingRows : rows
        hasher.combine(displayRows.count)
        if let first = displayRows.first {
            hasher.combine(first.id)
            hasher.combine(first.headline)
            hasher.combine(first.isAIEnhanced)
            hasher.combine(first.contextFacts.count)
        }
        if displayRows.count > 1, let last = displayRows.last {
            hasher.combine(last.id)
            hasher.combine(last.headline)
        }
        return hasher.finalize()
    }

    var body: some View {
        Group {
            if #available(macOS 12, *) {
                baseCard
                    .task(id: "\(selectedWindow.rawValue)-\(refreshMinuteToken)-\(topAppRows.isEmpty ? 0 : 1)") {
                        await reloadInsights()
                    }
            } else {
                baseCard
                    .onAppear { Task { await reloadInsights() } }
                    .onChange(of: selectedWindow) { _ in Task { await reloadInsights() } }
                    .onChange(of: refreshMinuteToken) { _ in Task { await reloadInsights() } }
            }
        }
    }

    @ViewBuilder private var baseCard: some View {
        VStack(alignment: .leading, spacing: scaledStackSpacing) {
            header
            if !isCollapsed {
                windowPicker
                    .transition(.opacity.combined(with: .move(edge: .top)))
                if let sessionStory {
                    sessionStoryBanner(sessionStory)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Group {
                    if viewMode == .overview {
                        overviewContent
                    } else {
                        focusContent
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(scaledPadding)
        .frame(maxWidth: .infinity, minHeight: isCollapsed ? 0 : scaledMinCardHeight, alignment: .topLeading)
        .background(
            ThemeRoundedRectangle(cornerRadius: scaledCornerRadius).themed()
        )
        .clipped()
        // AI glow border — rendered OUTSIDE .clipped() so the soft halo is
        // not cut off at the card edge. Invisible (opacity 0) until the LLM
        // enhancement pass runs; fades out automatically when complete.
        .overlay(aiGlowBorder)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard let onFocus,
                      let focusState = focusState else { return }
                onFocus(focusState)
            }
        )
        .onChange(of: isAIEnhancing) { newValue in
            if newValue { beginAIGlow() } else { endAIGlow() }
        }
        .onAppear {
            refreshFocusedStateIfNeeded()
        }
        .onChange(of: focusRefreshSignature) { _ in
            refreshFocusedStateIfNeeded()
        }
        .onHover { isFocusHovered = $0 }
        .onReceive(focusAdvanceTimer) { _ in
            guard viewMode == .focus, !isCollapsed, !isFocusHovered else { return }
            guard Date().timeIntervalSince(lastInteractionDate) > 4 else { return }
            let count = (rows.isEmpty ? loadingRows : rows).count
            guard count > 1 else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                focusAdvancedForward = true
                focusIndex = (focusIndex + 1) % count
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8 * appUIScale) {
            VStack(alignment: .leading, spacing: 4 * appUIScale) {
                Text("Hardware Insights")
                    .font(.system(size: scaledTitleFontSize, weight: .semibold))
                if !isCollapsed {
                    Text("Coverage-aware summaries from tracked history")
                        .font(.system(size: scaledCaption2FontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .transition(.opacity)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 8 * appUIScale) {
                if isAIEnhancing {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 14 * appUIScale, height: 14 * appUIScale)
                        .transition(.opacity)
                }

                if !isCollapsed {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            if viewMode == .focus {
                                viewMode = .overview
                            } else {
                                viewMode = .focus
                                focusIndex = 0
                            }
                        }
                    } label: {
                        Image(systemName: viewMode == .overview ? "scope" : "list.bullet")
                            .font(.system(size: scaledCaption2FontSize))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(viewMode == .overview ? "Focus view" : "Overview")
                    .transition(.opacity)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: scaledCaption2FontSize))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var windowPicker: some View {
        HStack(spacing: 6 * appUIScale) {
            ForEach(HardwareInsightWindow.allCases, id: \.rawValue) { window in
                Button {
                    guard selectedWindow != window else { return }
                    selectedWindow = window
                } label: {
                    Text(window.shortLabel)
                        .font(.system(size: scaledCaption2FontSize, weight: .semibold))
                        .foregroundColor(selectedWindow == window ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6 * appUIScale)
                        .background(
                            ThemeRoundedRectangle(cornerRadius: 10 * appUIScale, style: .continuous)
                                .fill(selectedWindow == window ? Color.white.opacity(0.12) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4 * appUIScale)
        .background(
            ThemeRoundedRectangle(cornerRadius: 12 * appUIScale, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var overviewContent: some View {
        let displayRows = rows.isEmpty ? loadingRows : rows

        return VStack(alignment: .leading, spacing: scaledRowSpacing) {
            ForEach(Array(displayRows.enumerated()), id: \.element.id) { index, row in
                insightRow(row)

                if index < displayRows.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 1)
                }
            }
        }
    }

    private func sessionStoryBanner(_ story: SessionStory) -> some View {
        HStack(alignment: .top, spacing: 10 * appUIScale) {
            ZStack {
                Circle()
                    .fill(story.accentColor.opacity(0.16))
                Image(systemName: story.iconName)
                    .font(.system(size: 12 * appUIScale, weight: .semibold))
                    .foregroundColor(story.accentColor)
            }
            .frame(width: scaledIconSize, height: scaledIconSize)

            VStack(alignment: .leading, spacing: 3 * appUIScale) {
                Text(story.headline)
                    .font(.system(size: scaledCaptionFontSize, weight: .semibold))
                    .lineLimit(1)
                Text(story.detail)
                    .font(.system(size: scaledCaption2FontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10 * appUIScale)
        .background(
            ThemeRoundedRectangle(cornerRadius: 12 * appUIScale, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    ThemeRoundedRectangle(cornerRadius: 12 * appUIScale, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func insightRow(_ row: InsightRow) -> some View {
        HStack(alignment: .top, spacing: 10 * appUIScale) {
            ZStack {
                Circle()
                    .fill(row.accentColor.opacity(0.16))

                Image(systemName: row.iconName)
                    .font(.system(size: 12 * appUIScale, weight: .semibold))
                    .foregroundColor(row.accentColor)
            }
            .frame(width: scaledIconSize, height: scaledIconSize)

            VStack(alignment: .leading, spacing: 4 * appUIScale) {
                HStack(alignment: .firstTextBaseline, spacing: scaledHeaderSpacing) {
                    Text(row.title)
                        .font(.system(size: scaledCaptionFontSize, weight: .semibold))

                    if row.isAIEnhanced {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9 * appUIScale, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.55))
                            .help("Insight text generated by Apple Intelligence")
                            .transition(.opacity)
                    }

                    Spacer(minLength: 6 * appUIScale)

                    Text(coverageLabel(for: row.coverageRatio))
                        .font(.system(size: scaledCaption2FontSize, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, scaledBadgeHorizontalPadding)
                        .padding(.vertical, scaledBadgeVerticalPadding)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                }

                Text(row.headline)
                    .font(.system(size: scaledCaptionFontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(row.detail)
                    .font(.system(size: scaledCaption2FontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: – Focus mode

    private var focusContent: some View {
        let displayRows = rows.isEmpty ? loadingRows : rows
        let safeIndex   = displayRows.isEmpty ? 0 : min(focusIndex, displayRows.count - 1)

        return VStack(alignment: .leading, spacing: scaledStackSpacing) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(displayRows.enumerated()), id: \.element.id) { index, row in
                    if index == safeIndex {
                        expandedInsightRow(row)
                            .transition(.asymmetric(
                                insertion: .move(edge: focusAdvancedForward ? .trailing : .leading)
                                    .combined(with: .opacity),
                                removal:   .move(edge: focusAdvancedForward ? .leading  : .trailing)
                                    .combined(with: .opacity)
                            ))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            HStack(spacing: 0) {
                Button { advanceFocus(by: -1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: scaledCaption2FontSize, weight: .semibold))
                        .foregroundColor(displayRows.count > 1 ? .secondary : .clear)
                        .frame(width: 24 * appUIScale, height: 24 * appUIScale)
                }
                .buttonStyle(.plain)
                .disabled(displayRows.count <= 1)

                Spacer()

                HStack(spacing: 5 * appUIScale) {
                    ForEach(0..<displayRows.count, id: \.self) { i in
                        Circle()
                            .fill(i == safeIndex
                                  ? Color.white.opacity(0.75)
                                  : Color.white.opacity(0.20))
                            .frame(
                                width:  i == safeIndex ? 6 * appUIScale : 4 * appUIScale,
                                height: i == safeIndex ? 6 * appUIScale : 4 * appUIScale
                            )
                            .animation(.easeInOut(duration: 0.2), value: safeIndex)
                    }
                }

                Spacer()

                Button { advanceFocus(by: 1) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: scaledCaption2FontSize, weight: .semibold))
                        .foregroundColor(displayRows.count > 1 ? .secondary : .clear)
                        .frame(width: 24 * appUIScale, height: 24 * appUIScale)
                }
                .buttonStyle(.plain)
                .disabled(displayRows.count <= 1)
            }
        }
    }

    private func expandedInsightRow(_ row: InsightRow) -> some View {
        VStack(alignment: .leading, spacing: 10 * appUIScale) {
            HStack(alignment: .top, spacing: 10 * appUIScale) {
                ZStack {
                    Circle()
                        .fill(row.accentColor.opacity(0.18))
                    Image(systemName: row.iconName)
                        .font(.system(size: 14 * appUIScale, weight: .semibold))
                        .foregroundColor(row.accentColor)
                }
                .frame(width: 34 * appUIScale, height: 34 * appUIScale)

                VStack(alignment: .leading, spacing: 3 * appUIScale) {
                    HStack(alignment: .firstTextBaseline, spacing: scaledHeaderSpacing) {
                        Text(row.title)
                            .font(.system(size: scaledCaptionFontSize + 1, weight: .semibold))

                        if row.isAIEnhanced {
                            Image(systemName: "sparkles")
                                .font(.system(size: 9 * appUIScale, weight: .medium))
                                .foregroundColor(.secondary.opacity(0.55))
                                .help("Insight text generated by Apple Intelligence")
                                .transition(.opacity)
                        }

                        Spacer(minLength: 4 * appUIScale)
                        Text(coverageLabel(for: row.coverageRatio))
                            .font(.system(size: scaledCaption2FontSize, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, scaledBadgeHorizontalPadding)
                            .padding(.vertical, scaledBadgeVerticalPadding)
                            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.06)))
                    }

                    Text(row.headline)
                        .font(.system(size: scaledCaptionFontSize, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(row.detail)
                .font(.system(size: scaledCaption2FontSize, weight: .regular))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if row.averageValue != nil || row.peakValue != nil {
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 1)
                focusStatStrip(for: row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func focusStatStrip(for row: InsightRow) -> some View {
        HStack(spacing: 6 * appUIScale) {
            if let avg = row.averageValue {
                statChip(label: "Avg",     value: row.valueUnit.formatted(avg),  color: row.accentColor)
            }
            if let peak = row.peakValue {
                statChip(label: "Peak",    value: row.valueUnit.formatted(peak), color: row.accentColor)
            }
            if row.spikeBucketCount > 0 {
                statChip(label: "Spikes",  value: "\(row.spikeBucketCount)",     color: row.accentColor)
            }
            if let hour = row.busiestHour {
                statChip(label: "Busiest", value: formatHour(hour),              color: row.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statChip(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .center, spacing: 2 * appUIScale) {
            Text(label)
                .font(.system(size: 9 * appUIScale, weight: .medium))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: scaledCaption2FontSize, weight: .semibold))
        }
        .padding(.horizontal, 8 * appUIScale)
        .padding(.vertical, 5 * appUIScale)
        .background(
            ThemeRoundedRectangle(cornerRadius: 7 * appUIScale, style: .continuous)
                .fill(color.opacity(0.10))
        )
    }

    private var focusState: HardwareInsightsFocusState? {
        let displayRows = rows.isEmpty ? loadingRows : rows
        guard !displayRows.isEmpty || sessionStory != nil else { return nil }

        let mappedRows = displayRows.map { row in
            HardwareInsightsFocusRow(
                id: row.id,
                title: row.title,
                iconName: row.iconName,
                accentColor: row.accentColor,
                coverageText: coverageLabel(for: row.coverageRatio),
                headline: row.headline,
                detail: row.detail,
                isAIEnhanced: row.isAIEnhanced,
                stats: focusStats(for: row),
                contextFacts: row.contextFacts
            )
        }

        let storyThreads = deduplicatedContextFacts(
            mappedRows
                .flatMap(\.contextFacts)
        )

        return HardwareInsightsFocusState(
            id: focusID,
            title: "Hardware Insights",
            subtitle: "Expanded narrative for the \(selectedWindow.shortLabel) hardware window",
            window: selectedWindow,
            isAIEnhancing: isAIEnhancing || isLoading,
            sessionStory: sessionStory.map {
                HardwareInsightsFocusStory(
                    iconName: $0.iconName,
                    accentColor: $0.accentColor,
                    headline: $0.headline,
                    detail: $0.detail
                )
            },
            rows: mappedRows,
            storyThreads: storyThreads
        )
    }

    private func focusStats(for row: InsightRow) -> [HardwareInsightsFocusStat] {
        var stats: [HardwareInsightsFocusStat] = []
        if let averageValue = row.averageValue {
            stats.append(.init(label: "Average", value: row.valueUnit.formatted(averageValue)))
        }
        if let peakValue = row.peakValue {
            stats.append(.init(label: "Peak", value: row.valueUnit.formatted(peakValue)))
        }
        if row.spikeBucketCount > 0 {
            stats.append(.init(label: "Spikes", value: "\(row.spikeBucketCount)"))
        }
        if let busiestHour = row.busiestHour {
            stats.append(.init(label: "Busiest", value: formatHour(busiestHour)))
        }
        return stats
    }

    private func refreshFocusedStateIfNeeded() {
        guard activeFocusID == focusID,
              let onFocusedStateChange,
              let focusState else { return }
        onFocusedStateChange(focusState)
    }

    // MARK: - AI Glow Effect

    /// Two-layer rotating conic gradient border — sharp inner stroke + soft
    /// outer halo — that briefly animates while Apple Intelligence rewrites
    /// the insight summaries. Both layers share the same rotation so they
    /// spin in perfect lockstep.
    private var aiGlowBorder: some View {
        let glowColors: [Color] = [
            Color(red: 0.20, green: 0.60, blue: 1.00),  // blue
            Color(red: 0.55, green: 0.15, blue: 1.00),  // violet
            Color(red: 1.00, green: 0.25, blue: 0.55),  // pink
            Color(red: 1.00, green: 0.55, blue: 0.15),  // orange
            Color(red: 0.15, green: 0.85, blue: 1.00),  // cyan
            Color(red: 0.20, green: 0.60, blue: 1.00),  // blue (wrap-around)
        ]
        let gradient = AngularGradient(
            colors: glowColors,
            center: .center,
            startAngle: .degrees(aiGlowRotation),
            endAngle: .degrees(aiGlowRotation + 360)
        )

        return ZStack {
            // Outer soft halo — wide stroke + heavy blur for the "glow" spread
            ThemeRoundedRectangle(cornerRadius: scaledCornerRadius)
                .stroke(gradient, lineWidth: 6)
                .blur(radius: 8)
            // Inner sharp ring — thin stroke + light blur for crisp colour definition
            ThemeRoundedRectangle(cornerRadius: scaledCornerRadius)
                .stroke(gradient, lineWidth: 1.5)
                .blur(radius: 1.5)
        }
        .opacity(aiGlowOpacity)
        .allowsHitTesting(false)
    }

    private func beginAIGlow() {
        aiGlowRotation = 0
        withAnimation(.easeIn(duration: 0.5)) {
            aiGlowOpacity = 1.0
        }
        withAnimation(.linear(duration: 9.0).repeatForever(autoreverses: false)) {
            aiGlowRotation = 360
        }
    }

    private func endAIGlow() {
        // Fade out gently; the rotation continues invisibly until the next trigger.
        withAnimation(.easeOut(duration: 1.0)) {
            aiGlowOpacity = 0
        }
    }

    private func advanceFocus(by delta: Int) {
        let count = (rows.isEmpty ? loadingRows : rows).count
        guard count > 1 else { return }
        lastInteractionDate = Date()
        withAnimation(.easeInOut(duration: 0.35)) {
            focusAdvancedForward = delta > 0
            focusIndex = ((focusIndex + delta) % count + count) % count
        }
    }

    @MainActor
    private func reloadInsights() async {
        if hasLoadedInsights {
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
        }
        await loadInsights()
    }

    @MainActor
    private func loadInsights() async {
        isLoading = true
        defer { isLoading = false }
        let hadPriorInsights = hasLoadedInsights
        if !hadPriorInsights {
            sessionStory = nil
        }

        // Avoid `async let` here. On macOS 26 release builds this path was
        // crashing in `swift_task_dealloc` while tearing down async-let child
        // tasks after the hardware card finished loading.
        let cpuInsightTask = Task { await insightsService.metricInsight(for: .cpuTotalUsage, window: selectedWindow) }
        let cpuEffInsightTask = Task { await insightsService.metricInsight(for: .cpuEfficiencyUsage, window: selectedWindow) }
        let cpuPerfInsightTask = Task { await insightsService.metricInsight(for: .cpuPerformanceUsage, window: selectedWindow) }
        let gpuBundleTask = Task { await fetchGPUInsights(window: selectedWindow) }
        let ramInsightTask = Task { await insightsService.metricInsight(for: .ramUsageRatio, window: selectedWindow) }
        let pressureInsightTask = Task { await insightsService.metricInsight(for: .memoryPressureRatio, window: selectedWindow) }
        let appMemInsightTask = Task { await insightsService.metricInsight(for: .appMemoryGB, window: selectedWindow) }
        let cachedMemInsightTask = Task { await insightsService.metricInsight(for: .cachedMemoryGB, window: selectedWindow) }
        let compMemInsightTask = Task { await insightsService.metricInsight(for: .compressedMemoryGB, window: selectedWindow) }
        let wiredMemInsightTask = Task { await insightsService.metricInsight(for: .wiredMemoryGB, window: selectedWindow) }
        let swapInsightTask = Task { await insightsService.metricInsight(for: .swapUsageRatio, window: selectedWindow) }
        let aneInsightTask = Task { await insightsService.metricInsight(for: .aneActivityRatio, window: selectedWindow) }
        let aneClientInsightTask = Task { await insightsService.metricInsight(for: .aneClientCount, window: selectedWindow) }
        let diskReadInsightTask = Task { await insightsService.metricInsight(for: .diskReadMBps, window: selectedWindow) }
        let diskWriteInsightTask = Task { await insightsService.metricInsight(for: .diskWriteMBps, window: selectedWindow) }
        let netUpInsightTask = Task { await insightsService.metricInsight(for: .networkUploadMBps, window: selectedWindow) }
        let netDownInsightTask = Task { await insightsService.metricInsight(for: .networkDownloadMBps, window: selectedWindow) }
        let powerInsightTask = Task { await insightsService.metricInsight(for: .combinedPowerWatts, window: selectedWindow) }
        let cpuPowerInsightTask = Task { await insightsService.metricInsight(for: .cpuPowerWatts, window: selectedWindow) }
        let gpuPowerInsightTask = Task { await insightsService.metricInsight(for: .gpuPowerWatts, window: selectedWindow) }
        let anePowerInsightTask = Task { await insightsService.metricInsight(for: .anePowerWatts, window: selectedWindow) }
        let thermalInsightTask = Task { await insightsService.metricInsight(for: .thermalLevel, window: selectedWindow) }
        let cpuNarrativeTask: Task<[String], Never> = Task {
            await insightsService.metricNarrativeFacts(for: .cpuTotalUsage, window: selectedWindow)
        }
        let gpuNarrativeTask: Task<[String], Never> = Task {
            guard let primaryGPUID else { return [String]() }
            return await insightsService.deviceMetricNarrativeFacts(
                for: .utilizationRatio,
                deviceID: primaryGPUID,
                deviceKind: .gpu,
                window: selectedWindow
            )
        }
        let memoryNarrativeTask: Task<[String], Never> = Task {
            await insightsService.metricNarrativeFacts(for: .memoryPressureRatio, window: selectedWindow)
        }
        let aneNarrativeTask: Task<[String], Never> = Task {
            guard hasNeuralEngine else { return [String]() }
            return await insightsService.metricNarrativeFacts(for: .aneActivityRatio, window: selectedWindow)
        }
        let diskNarrativeTask: Task<[String], Never> = Task {
            await insightsService.combinedMetricNarrativeFacts(
                primaryKey: .diskReadMBps,
                secondaryKey: .diskWriteMBps,
                window: selectedWindow
            )
        }
        let networkNarrativeTask: Task<[String], Never> = Task {
            await insightsService.combinedMetricNarrativeFacts(
                primaryKey: .networkDownloadMBps,
                secondaryKey: .networkUploadMBps,
                window: selectedWindow
            )
        }
        let powerNarrativeTask: Task<[String], Never> = Task {
            await insightsService.metricNarrativeFacts(for: .combinedPowerWatts, window: selectedWindow)
        }

        let cpu = await cpuInsightTask.value
        let cpuEff = await cpuEffInsightTask.value
        let cpuPerf = await cpuPerfInsightTask.value
        let gpu = await gpuBundleTask.value
        let ram = await ramInsightTask.value
        let pressure = await pressureInsightTask.value
        let appMem = await appMemInsightTask.value
        let cachedMem = await cachedMemInsightTask.value
        let compMem = await compMemInsightTask.value
        let wiredMem = await wiredMemInsightTask.value
        let swap = await swapInsightTask.value
        let ane = await aneInsightTask.value
        let aneClient = await aneClientInsightTask.value
        let diskRead = await diskReadInsightTask.value
        let diskWrite = await diskWriteInsightTask.value
        let netUp = await netUpInsightTask.value
        let netDown = await netDownInsightTask.value
        let power = await powerInsightTask.value
        let cpuPower = await cpuPowerInsightTask.value
        let gpuPower = await gpuPowerInsightTask.value
        let anePower = await anePowerInsightTask.value
        let thermal = await thermalInsightTask.value
        let cpuNarrativeFacts = await cpuNarrativeTask.value
        let gpuNarrativeFacts = await gpuNarrativeTask.value
        let memoryNarrativeFacts = await memoryNarrativeTask.value
        let aneNarrativeFacts = await aneNarrativeTask.value
        let diskNarrativeFacts = await diskNarrativeTask.value
        let networkNarrativeFacts = await networkNarrativeTask.value
        let powerNarrativeFacts = await powerNarrativeTask.value

        guard !Task.isCancelled else { return }

        // Fetch historical comparisons concurrently for system-level metrics
        let cpuComparisonTask = Task {
            await historicalComparisonFact(metricTitle: "CPU", currentInsight: cpu, metricKey: .cpuTotalUsage)
        }
        let memComparisonTask = Task {
            await historicalComparisonFact(metricTitle: "Memory Pressure", currentInsight: pressure, metricKey: .memoryPressureRatio)
        }
        let aneComparisonTask = Task {
            hasNeuralEngine
                ? await historicalComparisonFact(metricTitle: "Neural Engine", currentInsight: ane, metricKey: .aneActivityRatio)
                : nil
        }
        let powerComparisonTask = Task {
            await historicalComparisonFact(metricTitle: "Power", currentInsight: power, metricKey: .combinedPowerWatts)
        }
        let diskComparisonTask = Task {
            await historicalCombinedMetricComparisonFact(
                metricTitle: "Disk I/O",
                currentPrimary: diskRead,
                currentSecondary: diskWrite,
                primaryMetricKey: .diskReadMBps,
                secondaryMetricKey: .diskWriteMBps,
                primaryLabel: "reads",
                secondaryLabel: "writes"
            )
        }
        let networkComparisonTask = Task {
            await historicalCombinedMetricComparisonFact(
                metricTitle: "Network",
                currentPrimary: netDown,
                currentSecondary: netUp,
                primaryMetricKey: .networkDownloadMBps,
                secondaryMetricKey: .networkUploadMBps,
                primaryLabel: "downloads",
                secondaryLabel: "uploads"
            )
        }
        // GPU uses device-level metrics — fetch its comparison separately
        let gpuComparisonTask = Task { await historicalGPUComparisonFact(currentGPUInsight: gpu?.main) }

        let cpuComp = await cpuComparisonTask.value
        let gpuComp = await gpuComparisonTask.value
        let memComp = await memComparisonTask.value
        let aneComp = await aneComparisonTask.value
        let powerComp = await powerComparisonTask.value
        let diskComp = await diskComparisonTask.value
        let networkComp = await networkComparisonTask.value

        guard !Task.isCancelled else { return }

        var sharedStoryFacts = makeSharedStoryFacts(
            cpu: cpu,
            gpu: gpu?.main,
            memory: ram,
            pressure: pressure,
            ane: hasNeuralEngine ? ane : nil,
            power: power,
            thermal: thermal,
            media: mediaActivitySummary
        )
        let sharedHistoricalFacts = deduplicatedContextFacts([
            cpuNarrativeFacts.first,
            gpuNarrativeFacts.first,
            memoryNarrativeFacts.first,
            hasNeuralEngine ? aneNarrativeFacts.first : nil,
            powerNarrativeFacts.first
        ].compactMap { $0 })
        sharedStoryFacts.append(contentsOf: sharedHistoricalFacts)
        sharedStoryFacts = deduplicatedContextFacts(sharedStoryFacts)

        let cardStory = makeSessionStory(
            cpu: cpu,
            gpu: gpu?.main,
            memory: ram,
            pressure: pressure,
            ane: hasNeuralEngine ? ane : nil,
            power: power,
            thermal: thermal,
            leadAppName: topUserAppName()
        )
        let enhancedCardStory: SessionStory?
        if let leadingHistoricalFact = sharedHistoricalFacts.first, let cardStory {
            enhancedCardStory = SessionStory(
                iconName: cardStory.iconName,
                accentColor: cardStory.accentColor,
                headline: cardStory.headline,
                detail: sentenceJoin([trimTrailingSentencePunctuation(cardStory.detail), leadingHistoricalFact])
            )
        } else {
            enhancedCardStory = cardStory
        }

        var newRows: [InsightRow] = []
        var cpuRow = makeCPURow(from: cpu, efficiency: cpuEff, performance: cpuPerf, cpuPower: cpuPower)
        cpuRow.contextFacts.append(contentsOf: sharedStoryFacts)
        if let cpuComp { cpuRow.contextFacts.append(cpuComp) }
        cpuRow.contextFacts.append(contentsOf: cpuNarrativeFacts)
        if checkDistress(rowID: "cpu", insight: cpu) {
            let distress = distressText(for: "cpu")
            cpuRow.headline = distress.headline
            cpuRow.detail = distress.detail
        } else {
            blendHistoricalFactsIntoDetail(cpuNarrativeFacts, row: &cpuRow)
        }
        newRows.append(cpuRow)

        if let gpu {
            var gpuRow = makeGPURow(bundle: gpu, gpuPower: gpuPower)
            gpuRow.contextFacts.append(contentsOf: sharedStoryFacts)
            if let gpuComp { gpuRow.contextFacts.append(gpuComp) }
            gpuRow.contextFacts.append(contentsOf: gpuNarrativeFacts)
            if checkDistress(rowID: "gpu", insight: gpu.main) {
                let distress = distressText(for: "gpu")
                gpuRow.headline = distress.headline
                gpuRow.detail = distress.detail
            } else {
                blendHistoricalFactsIntoDetail(gpuNarrativeFacts, row: &gpuRow)
            }
            newRows.append(gpuRow)
        }

        var memRow = makeMemoryRow(memory: ram, pressure: pressure, appMem: appMem, cached: cachedMem, compressed: compMem, wired: wiredMem, swap: swap)
        memRow.contextFacts.append(contentsOf: sharedStoryFacts)
        if let memComp { memRow.contextFacts.append(memComp) }
        memRow.contextFacts.append(contentsOf: memoryNarrativeFacts)
        if checkDistress(rowID: "memory", insight: hasObservedMetricData(pressure.summary) ? pressure : ram) {
            let distress = distressText(for: "memory")
            memRow.headline = distress.headline
            memRow.detail = distress.detail
        } else {
            blendHistoricalFactsIntoDetail(memoryNarrativeFacts, row: &memRow)
        }
        newRows.append(memRow)

        if hasNeuralEngine {
            var aneRow = makeANERow(from: ane, clientCount: aneClient, anePower: anePower)
            aneRow.contextFacts.append(contentsOf: sharedStoryFacts)
            if let aneComp { aneRow.contextFacts.append(aneComp) }
            aneRow.contextFacts.append(contentsOf: aneNarrativeFacts)
            if checkDistress(rowID: "ane", insight: ane) {
                let distress = distressText(for: "ane")
                aneRow.headline = distress.headline
                aneRow.detail = distress.detail
            } else {
                blendHistoricalFactsIntoDetail(aneNarrativeFacts, row: &aneRow)
            }
            newRows.append(aneRow)
        }

        var diskRow = makeDiskRow(read: diskRead, write: diskWrite)
        diskRow.contextFacts.append(contentsOf: sharedStoryFacts)
        if let diskComp { diskRow.contextFacts.append(diskComp) }
        diskRow.contextFacts.append(contentsOf: diskNarrativeFacts)
        blendHistoricalFactsIntoDetail(diskNarrativeFacts, row: &diskRow)
        newRows.append(diskRow)

        var netRow = makeNetworkRow(upload: netUp, download: netDown)
        netRow.contextFacts.append(contentsOf: sharedStoryFacts)
        if let networkComp { netRow.contextFacts.append(networkComp) }
        netRow.contextFacts.append(contentsOf: networkNarrativeFacts)
        blendHistoricalFactsIntoDetail(networkNarrativeFacts, row: &netRow)
        newRows.append(netRow)

        var powerRow = makePowerRow(power: power, thermal: thermal, cpuPower: cpuPower, gpuPower: gpuPower, anePower: anePower)
        powerRow.contextFacts.append(contentsOf: sharedStoryFacts)
        if let powerComp { powerRow.contextFacts.append(powerComp) }
        powerRow.contextFacts.append(contentsOf: powerNarrativeFacts)
        blendHistoricalFactsIntoDetail(powerNarrativeFacts, row: &powerRow)
        newRows.append(powerRow)

        if let appRow = makeAppRow() {
            var storyAwareAppRow = appRow
            storyAwareAppRow.contextFacts.append(contentsOf: sharedStoryFacts)
            newRows.append(storyAwareAppRow)
        }

        for index in newRows.indices {
            newRows[index].contextFacts = deduplicatedContextFacts(newRows[index].contextFacts)
            newRows[index].insightFingerprint = insightFingerprint(for: newRows[index])
        }

        rows = newRows
        sessionStory = enhancedCardStory

        // Progressive AI enhancement — macOS 26 / Tahoe+ only.
        // Template-pool text is already visible; AI phrases replace it row by row.
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            await enhanceRowsWithAI()
        }
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    @MainActor
    private func enhanceRowsWithAI() async {
        guard SystemLanguageModel.default.availability == .available else { return }
        guard !rows.isEmpty, !Task.isCancelled else { return }

        func cacheKey(for row: InsightRow) -> String {
            if !row.insightFingerprint.isEmpty {
                return "\(row.id)-\(selectedWindow.rawValue)-\(row.insightFingerprint)"
            }
            let quantized = Int(((row.averageValue ?? row.peakValue ?? 0) * 20).rounded())
            let contextHash = row.contextFacts.isEmpty ? 0 : stableHash(row.contextFacts.joined(separator: "|")) & 0xFFFF
            return "\(row.id)-\(selectedWindow.rawValue)-\(quantized)-\(contextHash)"
        }

        func unitString(for row: InsightRow) -> String {
            switch row.valueUnit {
            case .ratio:              return "%"
            case .megabytesPerSecond: return "MB/s"
            case .watts:              return "W"
            }
        }

        // ── Pass 1: apply any already-cached phrases instantly (no LLM cost) ──
        var indicesNeedingLLM: [Int] = []
        for index in rows.indices {
            let row = rows[index]
            guard row.aiKind != .none else { continue }
            if let cached = await InsightTextCache.shared.phrase(for: cacheKey(for: row)) {
                withAnimation(.easeInOut(duration: 0.35)) {
                    rows[index].headline     = cached.headline
                    rows[index].detail       = cached.detail
                    rows[index].isAIEnhanced = true
                }
            } else {
                indicesNeedingLLM.append(index)
            }
        }

        // ── Pass 2: LLM calls — gated to once per 15 minutes per window ──
        let lastEnhanced = lastAIEnhancementDates[selectedWindow] ?? .distantPast
        guard Date().timeIntervalSince(lastEnhanced) >= 15 * 60 else { return }
        guard !indicesNeedingLLM.isEmpty, !Task.isCancelled else { return }

        withAnimation(.easeInOut(duration: 0.2)) { isAIEnhancing = true }
        defer { withAnimation(.easeInOut(duration: 0.2)) { isAIEnhancing = false } }

        let session = LanguageModelSession(
            instructions: """
            You write concise hardware performance summaries for a macOS monitoring \
            sidebar. Plain natural language — no markdown, no bullet points, no jargon. \
            Some rows describe hardware metrics, and one row may describe app usage patterns. \
            Treat each row like a brief observation from someone who actually watched the \
            machine behave, not like an automatic chart caption. \
            \
            TONE: Match the emotional tone to the data. \
            - Quiet/idle metrics: gently sarcastic or amused. E.g. "GPU filed for boredom \
              leave — not a pixel to render", "ANE had such a quiet session it briefly \
              considered a career change", "NIC had nothing to send and nowhere to go". \
            - Heavy sustained load: empathetic or mildly alarmed. E.g. "CPU ran like it \
              owed someone money", "RAM is one open tab away from a breakdown", \
              "The processor would file a grievance if it could". \
            - Clean efficient performance: quiet admiration. E.g. "Thermally pristine — \
              not a warm moment", "Power draw so miserly the charger had an easy time". \
            - Unusual cross-metric patterns: knowing observations. E.g. when GPU is high \
              but CPU is low: "Somebody's rendering something the old-fashioned cores \
              can't help with". When ANE is heavy but GPU is idle: "On-device AI is \
              doing the heavy lifting — silicon brain fully engaged". \
            \
            WIT: Roughly one in every four or five insights should include a pun or \
            play on words. Never force it — a plain line beats a strained joke. Good \
            examples: "GPU barely broke a sweat", "RAM feeling the squeeze", \
            "CPU kept its cool — literally", "Neural Engine clocked in for overtime", \
            "the drive didn't get much downtime". \
            \
            TIME OF DAY: When busiest-hour context is provided, weave it in naturally. \
            Late night activity → "burning the midnight oil". Early morning → "the \
            early-bird session". Post-lunch → "the afternoon surge". \
            \
            VARIATION: Avoid repetitive openings and repeated sentence skeletons across \
            rows. Mix short verdict-like headlines with slightly more narrative ones. \
            The detail sentence should usually interpret the pattern or connect two \
            subsystems, not just restate average and peak values. \
            \
            APP REFERENCES: When a context fact names a specific app (e.g. Xcode, \
            Logic Pro, Final Cut Pro), reference it by name in the insight rather than \
            saying "an app". \
            For the app-activity row, make it sound like you noticed real habits: \
            long-running staples, quick pop-ins, GPU-heavy apps, or a machine hopping \
            between lots of short sessions. \
            \
            COMPARISONS: When context includes a comparison to a previous period \
            (e.g. "CPU average is up 30% compared to yesterday"), weave it into the \
            narrative — e.g. "CPU ran 30% hotter than yesterday — something changed". \
            \
            WINDOW SHAPE: When context mentions activity being concentrated on a few days, \
            recurring in the morning/evening, or staying elevated for one long run, treat \
            that as meaningful historical behaviour rather than a throwaway fact. \
            \
            CROSS-SYSTEM CLUES: If the prompt gives you power, thermal, media-engine, \
            memory-pressure, or app-attribution clues that explain the metric, use them. \
            Examples: GPU load plus media-engine activity can imply encoding/render work; \
            CPU load plus low power can imply efficiency-core bias; high RAM occupancy but \
            modest pressure means caching rather than distress. \
            \
            ENERGY: When power context mentions tracked Wh or session duration, \
            reference it — e.g. "Burned 4.2 Wh over a 2-hour stretch" or \
            "Averaging 8 W across the whole monitoring session". \
            \
            Keep every insight to one headline (5–10 words, no punctuation) and one \
            detail sentence (8–20 words, ends with a full stop).
            """
        )

        for index in indicesNeedingLLM {
            guard !Task.isCancelled else { return }
            let row = rows[index]
            let phrase: AIInsightPhrase?
            switch row.aiKind {
            case .metric:
                phrase = await copywriter.generatePhrase(
                    metricTitle:      row.title,
                    averageValue:     row.averageValue,
                    peakValue:        row.peakValue,
                    unit:             unitString(for: row),
                    spikeBucketCount: row.spikeBucketCount,
                    busiestHour:      row.busiestHour,
                    contextFacts:     row.contextFacts,
                    session:          session,
                    cacheKey:         cacheKey(for: row)
                )
            case .app:
                guard let topAppName = row.appPrimaryName, let topAppHours = row.appPrimaryHours else { continue }
                phrase = await copywriter.generateAppPhrase(
                    topAppName: topAppName,
                    topAppHours: topAppHours,
                    contextFacts: row.contextFacts,
                    session: session,
                    cacheKey: cacheKey(for: row)
                )
            case .none:
                phrase = nil
            }

            if let phrase {
                withAnimation(.easeInOut(duration: 0.35)) {
                    rows[index].headline = phrase.headline
                    rows[index].detail = phrase.detail
                    rows[index].isAIEnhanced = true
                }
            }
        }

        lastAIEnhancementDates[selectedWindow] = Date()
    }
    #endif

    private var loadingRows: [InsightRow] {
        var placeholders: [InsightRow] = [
            InsightRow(id: "cpu",    title: "CPU",    iconName: "cpu",           accentColor: .blue,
                       headline: "Loading tracked usage",
                       detail: "Pulling recent history for the selected time window.", coverageRatio: 0),
        ]
        if primaryGPUID != nil {
            placeholders.append(InsightRow(id: "gpu", title: "GPU", iconName: "cpu.fill",
                                           accentColor: Color(red: 0.85, green: 0.20, blue: 0.20),
                                           headline: "Loading GPU usage",
                                           detail: "Pulling utilisation and sub-pipeline history.", coverageRatio: 0))
        }
        placeholders.append(InsightRow(id: "memory", title: "Memory", iconName: "memorychip", accentColor: .mintCompat,
                                       headline: "Loading memory trends",
                                       detail: "Checking sustained usage and pressure spikes.", coverageRatio: 0))
        if hasNeuralEngine {
            placeholders.append(InsightRow(id: "ane", title: "Neural Engine", iconName: "sparkles",
                                           accentColor: Color(red: 0.65, green: 0.00, blue: 0.65),
                                           headline: "Loading ANE activity",
                                           detail: "Checking Neural Engine utilisation history.", coverageRatio: 0))
        }
        placeholders.append(contentsOf: [
            InsightRow(id: "disk",    title: "Disk I/O", iconName: "internaldrive",
                       accentColor: Color(red: 0.55, green: 0.55, blue: 0.10),
                       headline: "Loading disk activity",
                       detail: "Scanning read and write throughput history.", coverageRatio: 0),
            InsightRow(id: "network", title: "Network",  iconName: "network",
                       accentColor: .networkAccentColor,
                       headline: "Loading network activity",
                       detail: "Checking upload and download history.", coverageRatio: 0),
            InsightRow(id: "power",   title: "Power",    iconName: "bolt.fill",   accentColor: .orange,
                       headline: "Loading energy profile",
                       detail: "Scanning average draw and peak hardware activity.", coverageRatio: 0),
        ])
        if !topAppRows.isEmpty {
            placeholders.append(InsightRow(id: "apps", title: "Apps", iconName: "apps.ipad.landscape",
                                           accentColor: .appsAccentColor,
                                           headline: "Loading app activity",
                                           detail: "Analysing which apps have been busy.", coverageRatio: 0))
        }
        return placeholders
    }

    private func makeCPURow(
        from insight: HardwareMetricInsight,
        efficiency: HardwareMetricInsight,
        performance: HardwareMetricInsight,
        cpuPower: HardwareMetricInsight
    ) -> InsightRow {
        let summary = insight.summary

        guard hasObservedMetricData(summary) else {
            return InsightRow(
                id: "cpu",
                title: "CPU",
                iconName: "cpu",
                accentColor: .blue,
                headline: "Not enough tracked CPU history",
                detail: "Leave hardware monitoring running longer to surface daily or weekly usage patterns.",
                coverageRatio: summary.coverageRatio
            )
        }

        let averageText = formatRatio(summary.averageValue)
        let peakText = formatRatio(summary.peakValue)
        let headline = joinNonEmpty([
            averageText.map { "Avg \($0)" },
            peakText.map { "Peak \($0)" }
        ], separator: " · ") ?? "Tracked CPU usage"

        var details: [String] = [copywriter.cpuLoadDescription(for: summary.averageValue ?? summary.peakValue ?? 0)]
        if let dynamics = copywriter.dynamicsDescription(for: insight, noun: "CPU") {
            details.append(dynamics)
        }
        if let busiestSummary = busiestSummary(from: insight) {
            details.append(busiestSummary)
        } else if let peakWindowSummary = peakWindowSummary(from: insight.peakWindow) {
            details.append("Peaked around \(peakWindowSummary)")
        }

        if insight.spikeBucketCount > 0 {
            details.append("\(insight.spikeBucketCount) spike window\(insight.spikeBucketCount == 1 ? "" : "s")")
        }

        var contextFacts: [String] = []
        if let effAvg = efficiency.summary.averageValue, let perfAvg = performance.summary.averageValue {
            contextFacts.append(String(format: "Efficiency cores averaged %.0f%%, performance cores averaged %.0f%%", effAvg * 100, perfAvg * 100))
            if effAvg > perfAvg * 1.5 {
                contextFacts.append("Workload was predominantly efficiency-led")
            } else if perfAvg > effAvg * 1.5 {
                contextFacts.append("Performance cores carried more load — suggesting intensive bursts")
            }
        }
        // Per-core GHz (live at insight time, split by cluster type)
        if !perCoreFrequenciesHz.isEmpty && (efficiencyCoreCount > 0 || performanceCoreCount > 0) {
            let pCores = Array(perCoreFrequenciesHz.prefix(performanceCoreCount))
            let eCores = Array(perCoreFrequenciesHz.dropFirst(performanceCoreCount).prefix(efficiencyCoreCount))
            if let eAvg = eCores.isEmpty ? nil : eCores.reduce(0, +) / Double(eCores.count),
               let pAvg = pCores.isEmpty ? nil : pCores.reduce(0, +) / Double(pCores.count) {
                contextFacts.append(String(format: "Current clock: E-cores %.2f GHz, P-cores %.2f GHz", eAvg / 1_000_000_000, pAvg / 1_000_000_000))
            }
        } else if !perCoreFrequenciesHz.isEmpty {
            let avgHz = perCoreFrequenciesHz.reduce(0, +) / Double(perCoreFrequenciesHz.count)
            contextFacts.append(String(format: "Current average core clock: %.2f GHz", avgHz / 1_000_000_000))
        }
        if let count = processCount {
            contextFacts.append("Running alongside \(count) other processes at insight time")
        }
        if let cpuPowerAverage = cpuPower.summary.averageValue {
            if let cpuPowerPeak = cpuPower.summary.peakValue {
                contextFacts.append(String(format: "CPU power averaged %.1f W and peaked at %.1f W", cpuPowerAverage, cpuPowerPeak))
            } else {
                contextFacts.append(String(format: "CPU power averaged %.1f W", cpuPowerAverage))
            }
        }
        if let cpuLeader = topCPUAppRow(), cpuLeader.cpuPercent >= 1 {
            contextFacts.append(String(format: "%@ was the busiest CPU-facing app at insight time (%.0f%%)", cpuLeader.name, cpuLeader.cpuPercent))
        }
        contextFacts.append(contentsOf: patternContextFacts(for: insight, noun: "CPU"))
        if let charFact = characterFact(for: insight, noun: "CPU") {
            contextFacts.append(charFact)
        }

        return InsightRow(
            id: "cpu",
            title: "CPU",
            iconName: "cpu",
            accentColor: .blue,
            headline: headline,
            detail: sentenceJoin(details),
            coverageRatio: summary.coverageRatio,
            averageValue: summary.averageValue,
            peakValue: summary.peakValue,
            spikeBucketCount: insight.spikeBucketCount,
            busiestHour: insight.busiestHourOfDay,
            peakWindowDate: insight.peakWindow?.bucketStart,
            valueUnit: .ratio,
            contextFacts: contextFacts,
            aiKind: .metric
        )
    }

    private func makeMemoryRow(memory: HardwareMetricInsight, pressure: HardwareMetricInsight, appMem: HardwareMetricInsight, cached: HardwareMetricInsight, compressed: HardwareMetricInsight, wired: HardwareMetricInsight, swap: HardwareMetricInsight) -> InsightRow {
        let memorySummary = memory.summary
        let pressureSummary = pressure.summary
        let effectiveCoverage = max(memorySummary.coverageRatio, pressureSummary.coverageRatio)
        let usesPressurePrimary = hasObservedMetricData(pressureSummary)
        let primaryInsight = usesPressurePrimary ? pressure : memory
        let primarySummary = usesPressurePrimary ? pressureSummary : memorySummary

        guard hasObservedMetricData(memorySummary) || hasObservedMetricData(pressureSummary) else {
            return InsightRow(
                id: "memory",
                title: "Memory",
                iconName: "memorychip",
                accentColor: .mintCompat,
                headline: "Not enough tracked memory history",
                detail: "Memory pressure summaries will appear after more sampled history is retained.",
                coverageRatio: effectiveCoverage
            )
        }

        let averageText = formatRatio(primarySummary.averageValue)
        let peakText = formatRatio(primarySummary.peakValue)
        let headline = usesPressurePrimary
            ? (joinNonEmpty([
                averageText.map { "Avg \($0) pressure" },
                peakText.map { "Peak \($0)" }
            ], separator: " · ") ?? "Tracked memory pressure")
            : (joinNonEmpty([
                averageText.map { "Avg \($0) in use" },
                peakText.map { "Peak \($0)" }
            ], separator: " · ") ?? "Tracked memory usage")

        var details: [String] = []

        if usesPressurePrimary {
            details.append(copywriter.memoryPressureDescription(
                spikeBucketCount: pressure.spikeBucketCount,
                peakValue: pressureSummary.peakValue ?? pressureSummary.averageValue ?? 0
            ))
        } else if let averageUsage = memorySummary.averageValue {
            details.append(copywriter.memoryLoadDescription(for: averageUsage))
        }

        if hasObservedMetricData(pressureSummary) && !usesPressurePrimary {
            details.append(copywriter.memoryPressureDescription(spikeBucketCount: pressure.spikeBucketCount, peakValue: pressureSummary.peakValue ?? 0))
        }
        if let dynamics = copywriter.dynamicsDescription(for: primaryInsight, noun: usesPressurePrimary ? "Memory pressure" : "Memory") {
            details.append(dynamics)
        }

        if let busiestSummary = busiestSummary(from: primaryInsight) {
            details.append(busiestSummary)
        }

        var contextFacts: [String] = []
        if usesPressurePrimary, let memoryAverage = memorySummary.averageValue {
            contextFacts.append(String(format: "Average RAM occupancy was %.0f%%, but pressure is the better gauge of actual memory strain on macOS", memoryAverage * 100))
        }
        let memBreakdownParts: [String] = [
            appMem.summary.averageValue.map    { String(format: "App %.1f GB",        $0) },
            cached.summary.averageValue.map    { String(format: "Cached %.1f GB",     $0) },
            compressed.summary.averageValue.map { String(format: "Compressed %.1f GB", $0) },
            wired.summary.averageValue.map     { String(format: "Wired %.1f GB",      $0) }
        ].compactMap { $0 }
        if !memBreakdownParts.isEmpty {
            contextFacts.append(memBreakdownParts.joined(separator: ", "))
        }
        if let compPeak = compressed.summary.peakValue, compPeak > 0.5 {
            contextFacts.append(String(format: "Memory compression peaked at %.1f GB, indicating memory pressure", compPeak))
        }
        if let swapAvg = swap.summary.averageValue, swapAvg > 0.05 {
            contextFacts.append(String(format: "Swap usage averaged %.0f%%", swapAvg * 100))
        }
        let topApps = topMemoryRows.prefix(3).filter { $0.ramMB > 50 }
        if !topApps.isEmpty {
            let appDesc = topApps.map { String(format: "%@ %.0f MB", $0.name, $0.ramMB) }.joined(separator: ", ")
            contextFacts.append("Top memory consumers at insight time: \(appDesc)")
        }
        contextFacts.append(contentsOf: patternContextFacts(for: primaryInsight, noun: usesPressurePrimary ? "Memory pressure" : "Memory"))
        if let charFact = characterFact(for: primaryInsight, noun: usesPressurePrimary ? "Memory pressure" : "Memory") {
            contextFacts.append(charFact)
        }

        return InsightRow(
            id: "memory",
            title: "Memory",
            iconName: "memorychip",
            accentColor: .mintCompat,
            headline: headline,
            detail: sentenceJoin(details),
            coverageRatio: effectiveCoverage,
            averageValue: primarySummary.averageValue,
            peakValue: primarySummary.peakValue,
            spikeBucketCount: usesPressurePrimary ? pressure.spikeBucketCount : memory.spikeBucketCount,
            busiestHour: primaryInsight.busiestHourOfDay,
            peakWindowDate: primaryInsight.peakWindow?.bucketStart,
            valueUnit: .ratio,
            contextFacts: contextFacts,
            aiKind: .metric
        )
    }

    private func makePowerRow(power: HardwareMetricInsight, thermal: HardwareMetricInsight, cpuPower: HardwareMetricInsight, gpuPower: HardwareMetricInsight, anePower: HardwareMetricInsight) -> InsightRow {
        let powerSummary = power.summary
        let thermalSummary = thermal.summary
        let effectiveCoverage = max(powerSummary.coverageRatio, thermalSummary.coverageRatio)

        if hasObservedMetricData(powerSummary) {
            let averageText = formatWatts(powerSummary.averageValue)
            let peakText = formatWatts(powerSummary.peakValue)
            let headline = joinNonEmpty([
                averageText.map { "Avg \($0)" },
                peakText.map { "Peak \($0)" }
            ], separator: " · ") ?? "Tracked power draw"

            var details: [String] = [copywriter.powerLoadDescription(for: powerSummary.averageValue ?? powerSummary.peakValue ?? 0)]
            if let dynamics = copywriter.dynamicsDescription(for: power, noun: "Power draw") {
                details.append(dynamics)
            }
            if let busiestSummary = busiestSummary(from: power) {
                details.append(busiestSummary)
            }
            if power.spikeBucketCount > 0 {
                details.append("\(power.spikeBucketCount) high-draw window\(power.spikeBucketCount == 1 ? "" : "s")")
            }
            if hasObservedMetricData(thermalSummary) {
                details.append(copywriter.thermalDescription(peakLevel: thermalSummary.peakValue ?? 0, spikeBucketCount: thermal.spikeBucketCount))
            }

            var contextFacts: [String] = []
            let powerBreakdownParts: [String] = [
                cpuPower.summary.averageValue.map { String(format: "CPU %.1f W", $0) },
                gpuPower.summary.averageValue.map { String(format: "GPU %.1f W", $0) },
                anePower.summary.averageValue.map { String(format: "ANE %.1f W", $0) }
            ].compactMap { $0 }
            if !powerBreakdownParts.isEmpty {
                contextFacts.append("Average breakdown: " + powerBreakdownParts.joined(separator: ", "))
            }
            if let cpuAvg = cpuPower.summary.averageValue, let gpuAvg = gpuPower.summary.averageValue {
                if cpuAvg > gpuAvg * 1.5 {
                    contextFacts.append("CPU was the dominant power consumer")
                } else if gpuAvg > cpuAvg * 1.5 {
                    contextFacts.append("GPU was the dominant power consumer")
                }
            }
            if let mediaActivitySummary, mediaActivitySummary.activityState != .idle {
                if let codec = mediaActivitySummary.codec {
                    contextFacts.append("Media engine activity (\(codec)) likely contributed to the power profile")
                } else {
                    contextFacts.append("Media engine activity likely contributed to the power profile")
                }
            }
            if let uptime = uptimeSeconds, uptime > 60 {
                let hours = Int(uptime) / 3600
                let minutes = (Int(uptime) % 3600) / 60
                let uptimeStr = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
                contextFacts.append("System uptime at insight time: \(uptimeStr)")
            }
            if cumulativeEnergyWh > 0.01 {
                let sessionElapsed = Date().timeIntervalSince(appLaunchDate)
                let sessionHours = sessionElapsed / 3600
                if sessionHours >= 0.05 {
                    let avgWatts = cumulativeEnergyWh / sessionHours
                    contextFacts.append(String(format: "Tracked %.2f Wh over this %.1fh %@ (avg %.1f W)",
                                               cumulativeEnergyWh, sessionHours, sessionContextNoun, avgWatts))
                } else {
                    contextFacts.append(String(format: "Tracked %.2f Wh since %@ began", cumulativeEnergyWh, sessionContextNoun))
                }
                // Energy rate context — helps FM reason about efficiency
                if sessionHours >= 1.0 {
                    let hourlyRate = cumulativeEnergyWh / sessionHours
                    if hourlyRate < 5 {
                        contextFacts.append("Energy consumption rate is very efficient")
                    } else if hourlyRate < 15 {
                        contextFacts.append("Moderate hourly energy consumption rate")
                    } else {
                        contextFacts.append("High hourly energy consumption rate")
                    }
                }
            }
            // App session duration gives FM context on how long the data represents
            let sessionMinutes = Int(Date().timeIntervalSince(appLaunchDate) / 60)
            if sessionMinutes >= 5 {
                let hours = sessionMinutes / 60
                let mins = sessionMinutes % 60
                let sessionStr = hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
                contextFacts.append("\(sessionSummaryLabel) for \(sessionStr)")
            }
            contextFacts.append(contentsOf: patternContextFacts(for: power, noun: "Power draw"))
            if let charFact = characterFact(for: power, noun: "Power draw") {
                contextFacts.append(charFact)
            }

            return InsightRow(
                id: "power",
                title: "Power",
                iconName: "bolt.fill",
                accentColor: .orange,
                headline: headline,
                detail: sentenceJoin(details),
                coverageRatio: effectiveCoverage,
                averageValue: powerSummary.averageValue,
                peakValue: powerSummary.peakValue,
                spikeBucketCount: power.spikeBucketCount,
                busiestHour: power.busiestHourOfDay,
                peakWindowDate: power.peakWindow?.bucketStart,
                valueUnit: .watts,
                contextFacts: contextFacts,
                aiKind: .metric
            )
        }

        guard hasObservedMetricData(thermalSummary) else {
            return InsightRow(
                id: "power",
                title: "Power",
                iconName: "bolt.fill",
                accentColor: .orange,
                headline: "Not enough tracked power history",
                detail: "Combined power and thermal behaviour will appear once the collector has retained more data.",
                coverageRatio: effectiveCoverage
            )
        }

        return InsightRow(
            id: "power",
            title: "Thermals",
            iconName: "thermometer.medium",
            accentColor: .orange,
            headline: copywriter.thermalHeadline(for: thermalSummary.averageValue ?? thermalSummary.peakValue ?? 0),
            detail: sentenceJoin([
                copywriter.thermalDescription(peakLevel: thermalSummary.peakValue ?? 0, spikeBucketCount: thermal.spikeBucketCount),
                busiestSummary(from: thermal)
            ]),
            coverageRatio: effectiveCoverage,
            averageValue: thermalSummary.averageValue,
            peakValue: thermalSummary.peakValue,
            spikeBucketCount: thermal.spikeBucketCount,
            busiestHour: thermal.busiestHourOfDay,
            peakWindowDate: thermal.peakWindow?.bucketStart,
            valueUnit: .ratio,
            aiKind: .metric
        )
    }

    private func makeANERow(from insight: HardwareMetricInsight, clientCount: HardwareMetricInsight, anePower: HardwareMetricInsight) -> InsightRow {
        let summary = insight.summary

        guard hasObservedMetricData(summary) else {
            return InsightRow(
                id: "ane",
                title: "Neural Engine",
                iconName: "sparkles",
                accentColor: Color(red: 0.65, green: 0.00, blue: 0.65),
                headline: "Not enough tracked ANE history",
                detail: "Neural Engine activity summaries will appear after more sampled history is retained.",
                coverageRatio: summary.coverageRatio
            )
        }

        let averageText = formatRatio(summary.averageValue)
        let peakText    = formatRatio(summary.peakValue)
        let headline    = joinNonEmpty([
            averageText.map { "Avg \($0)" },
            peakText.map { "Peak \($0)" }
        ], separator: " · ") ?? "Tracked ANE activity"

        var details: [String] = [copywriter.aneLoadDescription(for: summary.averageValue ?? summary.peakValue ?? 0)]
        if let dynamics = copywriter.dynamicsDescription(for: insight, noun: "Neural Engine") {
            details.append(dynamics)
        }
        if let busiest = busiestSummary(from: insight) { details.append(busiest) }
        if insight.spikeBucketCount > 0 {
            details.append("\(insight.spikeBucketCount) high-activity window\(insight.spikeBucketCount == 1 ? "" : "s")")
        }

        var contextFacts: [String] = []
        if let avgClients = clientCount.summary.averageValue, avgClients >= 1 {
            contextFacts.append(String(format: "Averaged %.1f concurrent ML client\(avgClients < 1.5 ? "" : "s") competing for ANE time", avgClients))
        }
        if let peakClients = clientCount.summary.peakValue, peakClients >= 2 {
            contextFacts.append(String(format: "Peak concurrent clients: %.0f", peakClients))
        }
        if let anePowerAverage = anePower.summary.averageValue {
            if let anePowerPeak = anePower.summary.peakValue {
                contextFacts.append(String(format: "ANE power averaged %.2f W and peaked at %.2f W", anePowerAverage, anePowerPeak))
            } else {
                contextFacts.append(String(format: "ANE power averaged %.2f W", anePowerAverage))
            }
        }
        contextFacts.append(contentsOf: patternContextFacts(for: insight, noun: "Neural Engine"))
        if let charFact = characterFact(for: insight, noun: "Neural Engine") {
            contextFacts.append(charFact)
        }

        return InsightRow(
            id: "ane",
            title: "Neural Engine",
            iconName: "sparkles",
            accentColor: Color(red: 0.65, green: 0.00, blue: 0.65),
            headline: headline,
            detail: sentenceJoin(details),
            coverageRatio: summary.coverageRatio,
            averageValue: summary.averageValue,
            peakValue: summary.peakValue,
            spikeBucketCount: insight.spikeBucketCount,
            busiestHour: insight.busiestHourOfDay,
            peakWindowDate: insight.peakWindow?.bucketStart,
            valueUnit: .ratio,
            contextFacts: contextFacts,
            aiKind: .metric
        )
    }

    private func fetchGPUInsights(window: HardwareInsightWindow) async -> GPUInsightBundle? {
        guard let gpuID = primaryGPUID else { return nil }

        let mainInsightTask = Task {
            await insightsService.deviceMetricInsight(for: .utilizationRatio, deviceID: gpuID, deviceKind: .gpu, window: window)
        }
        let rendererInsightTask = Task {
            await insightsService.deviceMetricInsight(for: .rendererUtilizationRatio, deviceID: gpuID, deviceKind: .gpu, window: window)
        }
        let tilerInsightTask = Task {
            await insightsService.deviceMetricInsight(for: .tilerUtilizationRatio, deviceID: gpuID, deviceKind: .gpu, window: window)
        }
        let vramInsightTask = Task {
            await insightsService.deviceMetricInsight(for: .vramUsedMegabytes, deviceID: gpuID, deviceKind: .gpu, window: window)
        }
        let memAllocInsightTask = Task {
            await insightsService.deviceMetricInsight(for: .memoryAllocatedMegabytes, deviceID: gpuID, deviceKind: .gpu, window: window)
        }

        return GPUInsightBundle(
            main:         await mainInsightTask.value,
            renderer:     await rendererInsightTask.value,
            tiler:        await tilerInsightTask.value,
            vramUsed:     await vramInsightTask.value,
            memAllocated: await memAllocInsightTask.value
        )
    }

    private func makeGPURow(bundle: GPUInsightBundle, gpuPower: HardwareMetricInsight) -> InsightRow {
        let summary = bundle.main.summary

        guard hasObservedMetricData(summary) else {
            return InsightRow(
                id: "gpu",
                title: "GPU",
                iconName: "cpu.fill",
                accentColor: Color(red: 0.85, green: 0.20, blue: 0.20),
                headline: "Not enough tracked GPU history",
                detail: "Leave hardware monitoring running longer to surface GPU usage patterns.",
                coverageRatio: summary.coverageRatio
            )
        }

        let averageText = formatRatio(summary.averageValue)
        let peakText    = formatRatio(summary.peakValue)
        let headline    = joinNonEmpty([
            averageText.map { "Avg \($0)" },
            peakText.map { "Peak \($0)" }
        ], separator: " · ") ?? "Tracked GPU usage"

        var details: [String] = [copywriter.gpuLoadDescription(for: summary.averageValue ?? summary.peakValue ?? 0)]

        if let gpuAppsDesc = copywriter.gpuActiveAppsDescription(appNames: gpuActiveAppNames) {
            details.append(gpuAppsDesc)
        }
        if let dynamics = copywriter.dynamicsDescription(for: bundle.main, noun: "GPU") {
            details.append(dynamics)
        }

        // Surface renderer / tiler averages when they carry meaningful signal
        let rendSummary  = bundle.renderer.summary
        let tilerSummary = bundle.tiler.summary
        let subMetrics: [String] = [
            (hasObservedMetricData(rendSummary)  ? rendSummary.averageValue  : nil).map { "Renderer avg \(Int(($0 * 100).rounded()))%" },
            (hasObservedMetricData(tilerSummary) ? tilerSummary.averageValue : nil).map { "Tiler avg \(Int(($0 * 100).rounded()))%" }
        ].compactMap { $0 }
        if !subMetrics.isEmpty { details.append(subMetrics.joined(separator: " · ")) }

        if let busiest = busiestSummary(from: bundle.main) { details.append(busiest) }
        if bundle.main.spikeBucketCount > 0 {
            details.append("\(bundle.main.spikeBucketCount) spike window\(bundle.main.spikeBucketCount == 1 ? "" : "s")")
        }

        var contextFacts: [String] = []
        let vramSummary = bundle.vramUsed.summary
        let memAllocSummary = bundle.memAllocated.summary
        if let vramAvg = vramSummary.averageValue, let vramPeak = vramSummary.peakValue {
            contextFacts.append(String(format: "VRAM usage averaged %.0f MB, peaked at %.0f MB", vramAvg, vramPeak))
        } else if let vramAvg = vramSummary.averageValue {
            contextFacts.append(String(format: "VRAM usage averaged %.0f MB", vramAvg))
        }
        if let memAvg = memAllocSummary.averageValue {
            contextFacts.append(String(format: "Allocated GPU memory averaged %.0f MB", memAvg))
        }
        if let rendAvg = rendSummary.averageValue, let tilerAvg = tilerSummary.averageValue,
           hasObservedMetricData(rendSummary), hasObservedMetricData(tilerSummary) {
            if rendAvg > tilerAvg * 2.0 {
                contextFacts.append("Renderer pipeline significantly outpaced the tiler — workload was fragment-heavy")
            } else if tilerAvg > rendAvg * 2.0 {
                contextFacts.append("Tiler pipeline outpaced the renderer — workload was geometry-heavy")
            }
        }
        if let media = mediaActivitySummary, media.activityState != .idle {
            var mediaDesc = "Media engine: \(media.activityState.rawValue)"
            if let codec = media.codec { mediaDesc += " (\(codec))" }
            if media.retainedSessionCount > 1 { mediaDesc += ", \(media.retainedSessionCount) sessions" }
            contextFacts.append(mediaDesc)
        } else if let media = mediaActivitySummary, let lastActive = media.lastMeaningfulActivityDate {
            let ago = Date().timeIntervalSince(lastActive)
            if ago < 3600 {
                let minAgo = Int(ago / 60)
                if let codec = media.codec {
                    contextFacts.append("Media engine (\(codec)) was active \(minAgo)m ago")
                } else {
                    contextFacts.append("Media engine was active \(minAgo)m ago")
                }
            }
        }
        if !gpuActiveAppNames.isEmpty {
            let appList = gpuActiveAppNames.prefix(5).joined(separator: ", ")
            contextFacts.append("Active GPU clients: \(appList)")
            contextFacts.append("\(gpuActiveAppNames.count) tracked app\(gpuActiveAppNames.count == 1 ? "" : "s") showed live GPU activity")
        }
        if let gpuPowerAverage = gpuPower.summary.averageValue {
            if let gpuPowerPeak = gpuPower.summary.peakValue {
                contextFacts.append(String(format: "GPU power averaged %.2f W and peaked at %.2f W", gpuPowerAverage, gpuPowerPeak))
            } else {
                contextFacts.append(String(format: "GPU power averaged %.2f W", gpuPowerAverage))
            }
        }
        contextFacts.append(contentsOf: patternContextFacts(for: bundle.main, noun: "GPU"))
        if let charFact = characterFact(for: bundle.main, noun: "GPU") {
            contextFacts.append(charFact)
        }

        return InsightRow(
            id: "gpu",
            title: "GPU",
            iconName: "cpu.fill",
            accentColor: Color(red: 0.85, green: 0.20, blue: 0.20),
            headline: headline,
            detail: sentenceJoin(details),
            coverageRatio: summary.coverageRatio,
            averageValue: summary.averageValue,
            peakValue: summary.peakValue,
            spikeBucketCount: bundle.main.spikeBucketCount,
            busiestHour: bundle.main.busiestHourOfDay,
            peakWindowDate: bundle.main.peakWindow?.bucketStart,
            valueUnit: .ratio,
            contextFacts: contextFacts,
            aiKind: .metric
        )
    }

    private func makeDiskRow(read: HardwareMetricInsight, write: HardwareMetricInsight) -> InsightRow {
        let readSummary  = read.summary
        let writeSummary = write.summary
        let effectiveCoverage = max(readSummary.coverageRatio, writeSummary.coverageRatio)

        guard hasObservedMetricData(readSummary) || hasObservedMetricData(writeSummary) else {
            return InsightRow(
                id: "disk",
                title: "Disk I/O",
                iconName: "internaldrive",
                accentColor: Color(red: 0.55, green: 0.55, blue: 0.10),
                headline: "Not enough tracked disk history",
                detail: "Disk read and write summaries will appear after more sampled history is retained.",
                coverageRatio: effectiveCoverage
            )
        }

        let readPeak  = formatMBps(readSummary.peakValue)
        let writePeak = formatMBps(writeSummary.peakValue)
        let headline  = joinNonEmpty([
            readPeak.map  { "Peak R \($0)" },
            writePeak.map { "W \($0)" }
        ], separator: " · ") ?? "Tracked disk activity"

        let dominantInsight = (readSummary.peakValue ?? 0) >= (writeSummary.peakValue ?? 0) ? read : write
        var details: [String] = [copywriter.diskActivityDescription(
            readAvg:  readSummary.averageValue  ?? 0,
            writeAvg: writeSummary.averageValue ?? 0
        )]
        if let dynamics = copywriter.dynamicsDescription(for: dominantInsight, noun: "Disk I/O") {
            details.append(dynamics)
        }
        if let busiest = busiestSummary(from: dominantInsight) { details.append(busiest) }
        let totalSpikes = read.spikeBucketCount + write.spikeBucketCount
        if totalSpikes > 0 {
            details.append("\(totalSpikes) high-activity window\(totalSpikes == 1 ? "" : "s")")
        }

        let focusAvg  = max(readSummary.averageValue ?? 0, writeSummary.averageValue ?? 0)
        let focusPeak = max(readSummary.peakValue ?? 0, writeSummary.peakValue ?? 0)

        var contextFacts: [String] = []
        let readAvgVal  = readSummary.averageValue ?? 0
        let writeAvgVal = writeSummary.averageValue ?? 0
        if readAvgVal > 0 || writeAvgVal > 0 {
            let avgParts: [String] = [
                readAvgVal  > 0 ? String(format: "Read avg %.1f MB/s",  readAvgVal)  : nil,
                writeAvgVal > 0 ? String(format: "Write avg %.1f MB/s", writeAvgVal) : nil
            ].compactMap { $0 }
            if !avgParts.isEmpty { contextFacts.append(avgParts.joined(separator: ", ")) }
            if readAvgVal > writeAvgVal * 3 {
                contextFacts.append("Activity was heavily read-dominant — consistent data loading or streaming")
            } else if writeAvgVal > readAvgVal * 3 {
                contextFacts.append("Activity was heavily write-dominant — data generation or backup")
            }
        }
        let readPeakVal  = readSummary.peakValue ?? 0
        let writePeakVal = writeSummary.peakValue ?? 0
        if readPeakVal > 0 || writePeakVal > 0 {
            let peakParts: [String] = [
                readPeakVal  > 0 ? String(format: "Read %.1f MB/s",  readPeakVal)  : nil,
                writePeakVal > 0 ? String(format: "Write %.1f MB/s", writePeakVal) : nil
            ].compactMap { $0 }
            if !peakParts.isEmpty { contextFacts.append("Peaks: " + peakParts.joined(separator: ", ")) }
        }
        if let snap = storageSnapshot {
            let usedGB  = Double(snap.usedBytes)  / 1_073_741_824
            let totalGB = Double(snap.totalBytes) / 1_073_741_824
            var storageFact = String(format: "Drive: %.0f GB used of %.0f GB", usedGB, totalGB)
            if let kind = snap.kindLabel { storageFact += " (\(kind))" }
            contextFacts.append(storageFact)
            if let speed = snap.speedLabel { contextFacts.append("Benchmarked speed: \(speed)") }
        }
        contextFacts.append(contentsOf: patternContextFacts(for: dominantInsight, noun: "Disk I/O"))
        if let charFact = characterFact(for: read, noun: "Disk I/O") {
            contextFacts.append(charFact)
        }

        return InsightRow(
            id: "disk",
            title: "Disk I/O",
            iconName: "internaldrive",
            accentColor: Color(red: 0.55, green: 0.55, blue: 0.10),
            headline: headline,
            detail: sentenceJoin(details),
            coverageRatio: effectiveCoverage,
            averageValue: focusAvg  > 0 ? focusAvg  : nil,
            peakValue:    focusPeak > 0 ? focusPeak : nil,
            spikeBucketCount: totalSpikes,
            busiestHour: dominantInsight.busiestHourOfDay,
            peakWindowDate: dominantInsight.peakWindow?.bucketStart,
            valueUnit: .megabytesPerSecond,
            contextFacts: contextFacts,
            aiKind: .metric
        )
    }

    private func makeNetworkRow(upload: HardwareMetricInsight, download: HardwareMetricInsight) -> InsightRow {
        let upSummary   = upload.summary
        let downSummary = download.summary
        let effectiveCoverage = max(upSummary.coverageRatio, downSummary.coverageRatio)

        guard hasObservedMetricData(upSummary) || hasObservedMetricData(downSummary) else {
            return InsightRow(
                id: "network",
                title: "Network",
                iconName: "network",
                accentColor: .networkAccentColor,
                headline: "Not enough tracked network history",
                detail: "Upload and download summaries will appear after more sampled history is retained.",
                coverageRatio: effectiveCoverage
            )
        }

        let upPeak   = formatMBps(upSummary.peakValue)
        let downPeak = formatMBps(downSummary.peakValue)
        let headline = joinNonEmpty([
            upPeak.map   { "Peak ↑ \($0)" },
            downPeak.map { "↓ \($0)" }
        ], separator: " · ") ?? "Tracked network activity"

        let dominantInsight = (upSummary.peakValue ?? 0) >= (downSummary.peakValue ?? 0) ? upload : download
        var details: [String] = [copywriter.networkActivityDescription(
            upAvg:   upSummary.averageValue   ?? 0,
            downAvg: downSummary.averageValue ?? 0
        )]
        if let dynamics = copywriter.dynamicsDescription(for: dominantInsight, noun: "Network") {
            details.append(dynamics)
        }
        if let busiest = busiestSummary(from: dominantInsight) { details.append(busiest) }
        let totalSpikes = upload.spikeBucketCount + download.spikeBucketCount
        if totalSpikes > 0 {
            details.append("\(totalSpikes) high-activity window\(totalSpikes == 1 ? "" : "s")")
        }

        let focusAvg  = max(upSummary.averageValue ?? 0, downSummary.averageValue ?? 0)
        let focusPeak = max(upSummary.peakValue ?? 0, downSummary.peakValue ?? 0)

        var contextFacts: [String] = []
        let upAvgVal   = upSummary.averageValue   ?? 0
        let downAvgVal = downSummary.averageValue ?? 0
        if upAvgVal > 0 || downAvgVal > 0 {
            let avgParts: [String] = [
                upAvgVal   > 0 ? String(format: "Upload avg %.1f MB/s",   upAvgVal)   : nil,
                downAvgVal > 0 ? String(format: "Download avg %.1f MB/s", downAvgVal) : nil
            ].compactMap { $0 }
            if !avgParts.isEmpty { contextFacts.append(avgParts.joined(separator: ", ")) }
            if downAvgVal > upAvgVal * 3 {
                contextFacts.append("Traffic was predominantly inbound — streaming, syncing, or downloading")
            } else if upAvgVal > downAvgVal * 3 {
                contextFacts.append("Traffic was predominantly outbound — uploading, syncing, or serving")
            }
        }
        contextFacts.append(contentsOf: patternContextFacts(for: dominantInsight, noun: "Network"))
        if let charFact = characterFact(for: upload, noun: "Network") {
            contextFacts.append(charFact)
        }

        return InsightRow(
            id: "network",
            title: "Network",
            iconName: "network",
            accentColor: .networkAccentColor,
            headline: headline,
            detail: sentenceJoin(details),
            coverageRatio: effectiveCoverage,
            averageValue: focusAvg  > 0 ? focusAvg  : nil,
            peakValue:    focusPeak > 0 ? focusPeak : nil,
            spikeBucketCount: totalSpikes,
            busiestHour: dominantInsight.busiestHourOfDay,
            peakWindowDate: dominantInsight.peakWindow?.bucketStart,
            valueUnit: .megabytesPerSecond,
            contextFacts: contextFacts,
            aiKind: .metric
        )
    }

    // MARK: - App insight row

    /// Apps to exclude from the App insight tile — system-level processes that aren't
    /// meaningful user activity.
    private static let excludedAppNames: Set<String> = [
        "Finder", "Notification Center", "NotificationCenter",
        "WindowServer", "Window Server", "System Settings",
        "Spotlight", "SystemUIServer", "loginwindow",
        "PodcastPreview", "com.apple.dock", "Dock",
        "Control Center", "ControlCenter", "Software Update",
        "TGOnDeviceInferenceProviderService", "com.apple.Webkit.WebContent",
        "com.apple.quicklook.ThumbnailAgent", "Audio Routing Kit (ARK)", "Autoupdate",
        "CalenderAgent", "QuickLookUIService", "WallpaperDynamicExtension",
        "MTLCompilerService", "com.apple.quicklook.ThumbnailsAgent", "com.apple.WebKit.WebContent",
        "ReportCrash", "IMDPersistenceAgent", "WeatherMenu",
    ]

    private static let supportingServiceNames: Set<String> = [
        "analyticsd", "backgroundtaskmanagementagent", "cfprefsd",
        "corespotlightd", "coreaudiod", "distnoted",
        "iconservicesagent", "kernel_task", "launchd",
        "logd", "mds", "mds_stores", "mdworker", "mdworker_shared",
        "mediaremoted", "notifyd", "powerd", "runningboardd",
        "sharingd", "smd", "spotlightknowledged", "sysmond",
        "tccd", "thermalmonitord", "trustd",
        // Additional background processes from system inspection
        "mobileassetd", "replayd", "bluetoothd", "bluetoothuserd",
        "cloudphotod", "homed", "dataacccessd", "bird",
        "knowledgeconstructiond", "inputanalyticsd", "nsurlsessiond",
        "devicecheckd", "intelligenceplatformd", "ndoagent",
        "wallpaperagent", "localizationswitcherd", "commerce",
        "photolibraryd", "tipsd", "commcenter", "trustedpeershelper",
        "facetimemessagestored", "peopled", "replicatord",
        "webprivacyd", "voicebankingd", "colorsync", "dirhelper",
        "neagent", "nehelper", "networkserviceproxy", "seserviced",
        "spindumpagent", "usbnotificationagent", "secd",
        // Extended daemon and system process list from terminal inspection
        "airportd", "amfid", "aned", "aneuserd", "apfsd", "apsd",
        "assetsubscriptiond", "authd", "backupd", "backupd-helper",
        "backgroundassets", "backgroundtaskmanagementd", "biometrickitd", "bluetoothd", "bird", "captiveagent",
        "cfprefsd", "cloudphotod", "colorsyncd", "com.apple.dt.instruments.dtarbiter",
        "configd", "containermanagerd", "containermanagerd_system", "corebrightnessd", "coreduetd",
        "corerepaird", "corespeechd", "corespeechd_system", "countryd",
        "dasd", "dataacccessd", "devicecheckd", "diagnosticd", "distnoted",
        "dmd", "dprivacyd", "duetexpertd", "eligibilityd",
        "findmydeviced", "findmylocateagent", "gamed", "gamecontrollerd",
        "gamepolicyd", "generativeexperiencesd", "griddatad", "hidd", "homed",
        "icloudnotificationagent", "inputanalyticsd", "intelligentroutingd",
        "kernelmanagerd", "keybagd", "keyboardservicesd", "knowledgeconstructiond", "linkd", "locationd",
        "logd", "lsd", "mds", "mds_stores", "mdworker", "mdworker_shared",
        "mediaremoted", "metrickitd", "microstackshot", "milod", "mobileassetd", "mlhostd", "mlruntimed",
        "mmaintenanced", "modelmanagerd", "mobilerepaird", "naiveproxy", "naturallanguaged", "nearbyd",
        "neagent", "nehelper", "nesessionmanager", "nfcd",
        "networkserviceproxy", "nsurlsessiond", "ospredictiond", "passd", "peopled",
        "photolibraryd", "powerd", "powerexperienced", "proactived", "proactiveeventtrackerd",
        "promotedcontentd", "rapportd", "remindd", "remoted", "replayd",
        "routined", "rtcreportingd", "runningboardd", "safari", "safaridriver", "searchpartyd",
        "searchpartyuseragent", "seserviced", "sharingd", "siriknowledged",
        "smd", "spindump_agent", "spotlight", "spotlightknowledged", "symptomsd",
        "swcd", "swtransparencyd", "sysdiagnosed", "sysmond", "tccd", "tailspind",
        "textcomposerd", "textunderstandingd", "thermalmonitord", "tipsd", "transparencyd",
        "triald", "triald_system", "trialservice", "trialservice_system", "trustd", "tzd",
        "uarpassetmanagerd", "uarpd", "useractivityd",
        "usermanagerd", "usernotificationcenter", "usbnotificationagent", "watchdogd",
        "wifianalyticsd", "wifip2pd", "wifivelocityd", "weatherd", "webprivacyd",
        "windowserver", "windowmanager", "xpcroleaccountd"
    ]

    private enum AppInsightClassification {
        case excluded
        case candidate
        case supportingService
    }

    private struct AppInsightPools {
        let allVisible: [TopAppInsightRow]
        let candidateRows: [TopAppInsightRow]
        let supportingRows: [TopAppInsightRow]

        var competitiveRows: [TopAppInsightRow] {
            candidateRows.isEmpty ? allVisible : candidateRows
        }
    }

    private func appInsightPools() -> AppInsightPools {
        let classified = topAppRows.map { row in
            (row: row, classification: appInsightClassification(for: row))
        }

        return AppInsightPools(
            allVisible: classified.filter { $0.classification != .excluded }.map(\.row),
            candidateRows: classified.filter { $0.classification == .candidate }.map(\.row),
            supportingRows: classified.filter { $0.classification == .supportingService }.map(\.row)
        )
    }

    private func appInsightClassification(for row: TopAppInsightRow) -> AppInsightClassification {
        if Self.excludedAppNames.contains(row.name) {
            return .excluded
        }

        let rawName = row.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = rawName.lowercased()
        let normalizedBundleIdentifier = row.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalizedName == "podcastpreview"
            || normalizedBundleIdentifier == Bundle.main.bundleIdentifier?.lowercased()
            || normalizedBundleIdentifier?.hasPrefix("com.chrisizatt.podcastpreview") == true {
            return .excluded
        }

        if Self.supportingServiceNames.contains(normalizedName) {
            return .supportingService
        }

        let lowercaseDaemonStyleName = rawName == rawName.lowercased()
            && !rawName.contains(" ")

        let serviceKeywordDetected = normalizedName.contains("daemon")
            || normalizedName.contains("helper")
            || normalizedName.contains("agent")
            || normalizedName.contains("xpcservice")

        let appleServiceBundleDetected = normalizedBundleIdentifier?.hasPrefix("com.apple.") == true
            && (
                normalizedBundleIdentifier?.contains(".xpc") == true
                || normalizedBundleIdentifier?.contains(".helper") == true
                || normalizedBundleIdentifier?.contains(".daemon") == true
                || normalizedBundleIdentifier?.contains(".service") == true
                || normalizedBundleIdentifier?.contains(".agent") == true
            )

        let daemonSuffixDetected = lowercaseDaemonStyleName
            && normalizedName.hasSuffix("d")
            && normalizedName.count <= 24

        let daemonLikeProcess = lowercaseDaemonStyleName
            && (serviceKeywordDetected || daemonSuffixDetected || appleServiceBundleDetected)

        if daemonLikeProcess || appleServiceBundleDetected {
            return .supportingService
        }

        return .candidate
    }

    private func formattedAppInsightDuration(seconds: Double) -> String {
        guard seconds > 0 else { return "0m" }
        let totalMinutes = Int((seconds / 60).rounded(.down))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 && minutes > 0 {
            return "\(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(max(1, minutes))m"
    }

    private func makeAppRow() -> InsightRow? {
        let pools = appInsightPools()
        let apps = pools.competitiveRows
        guard !apps.isEmpty else { return nil }
        let supportingRows = pools.supportingRows

        // Sort by uptime descending to find the dominant app
        let byUptime = apps.sorted { $0.uptimeSeconds > $1.uptimeSeconds }
        let topApp = byUptime[0]
        let topHours = topApp.uptimeSeconds / 3600

        let headline = copywriter.appInsightHeadline(topAppName: topApp.name, topAppHours: topHours)

        var details: [String] = []

        // 1. Dominant session description
        details.append(copywriter.appDominantSessionDescription(appName: topApp.name, hours: topHours))

        // 2. Brief visitor — shortest meaningful uptime app (>0s, <5 min)
        if let briefApp = byUptime.last, briefApp.name != topApp.name, briefApp.uptimeSeconds > 0, briefApp.uptimeSeconds < 300 {
            details.append(copywriter.appBriefVisitorDescription(appName: briefApp.name, minutes: max(1, Int(briefApp.uptimeSeconds / 60))))
        }

        // 3. Resource hog — highest RAM consumer
        let byRAM = apps.sorted { $0.ramMB > $1.ramMB }
        if let ramHog = byRAM.first, ramHog.ramMB > 200 {
            details.append(copywriter.appResourceHogDescription(appName: ramHog.name, resourceLabel: "RAM"))
        }

        // 4. GPU-active apps
        let gpuApps = apps.filter { $0.isGPUActive }
        if !gpuApps.isEmpty {
            let names = gpuApps.prefix(3).map(\.name).joined(separator: ", ")
            details.append("\(names) \(gpuApps.count == 1 ? "is" : "are") actively using GPU time")
        }

        // 5. "Always-on" apps — uptime > 2h
        let alwaysOn = byUptime.filter { $0.uptimeSeconds > 7200 && $0.name != topApp.name }
        if let second = alwaysOn.first {
            details.append(copywriter.appAlwaysPresentDescription(appName: second.name))
        }

        // 6. CPU hog
        let byCPU = apps.sorted { $0.cpuPercent > $1.cpuPercent }
        if let cpuHog = byCPU.first, cpuHog.cpuPercent > 10 {
            details.append(copywriter.appResourceHogDescription(appName: cpuHog.name, resourceLabel: "CPU"))
        }

        if let backgroundLeader = supportingRows.max(by: { $0.uptimeSeconds < $1.uptimeSeconds }),
           backgroundLeader.uptimeSeconds > max(topApp.uptimeSeconds, 3600) {
            details.append("\(backgroundLeader.name) kept a longer background watch at \(formattedAppInsightDuration(seconds: backgroundLeader.uptimeSeconds)), but it stayed supporting context rather than the main story")
        }

        // Context facts for FM enrichment
        var contextFacts: [String] = []
        let appCount = apps.count
        contextFacts.append("\(appCount) user-facing app\(appCount == 1 ? "" : "s") contended for the headline")
        let totalRAM = pools.allVisible.reduce(0.0) { $0 + $1.ramMB }
        contextFacts.append(String(format: "Combined tracked app memory: %.1f GB", totalRAM / 1024))
        if !supportingRows.isEmpty {
            contextFacts.append("\(supportingRows.count) background or system service\(supportingRows.count == 1 ? "" : "s") were tracked separately so they didn't drown out foreground activity")
        }
        if topHours >= 4 {
            contextFacts.append("\(topApp.name) has been running for over \(Int(topHours)) hours — a power user staple")
        }
        let shortSessions = apps.filter { $0.uptimeSeconds < 300 && $0.uptimeSeconds > 0 }
        if shortSessions.count >= 3 {
            contextFacts.append("\(shortSessions.count) apps had sub-5-minute sessions — lots of quick dips")
        }
        if let cpuLeader = apps.max(by: { $0.cpuPercent < $1.cpuPercent }), cpuLeader.cpuPercent >= 1 {
            contextFacts.append(String(format: "%@ currently leads CPU share at %.0f%%", cpuLeader.name, cpuLeader.cpuPercent))
        }
        let gpuActiveApps = apps.filter(\.isGPUActive)
        if !gpuActiveApps.isEmpty {
            let gpuNames = gpuActiveApps.prefix(4).map(\.name).joined(separator: ", ")
            contextFacts.append("Live GPU-active apps: \(gpuNames)")
        }
        if let backgroundLeader = supportingRows.max(by: { $0.uptimeSeconds < $1.uptimeSeconds }),
           backgroundLeader.uptimeSeconds > max(topApp.uptimeSeconds, 3600) {
            contextFacts.append("\(backgroundLeader.name) actually had the longest raw uptime at \(formattedAppInsightDuration(seconds: backgroundLeader.uptimeSeconds)), but background services are supporting context unless no user-facing apps were seen")
        }

        return InsightRow(
            id: "apps",
            title: "Apps",
            iconName: "apps.ipad.landscape",
            accentColor: .appsAccentColor,
            headline: headline,
            detail: sentenceJoin(details),
            coverageRatio: 1.0,
            contextFacts: contextFacts,
            aiKind: .app,
            appPrimaryName: topApp.name,
            appPrimaryHours: topHours
        )
    }

    /// Generates a personality-style sentence describing whether a metric spent most of the window
    /// near idle ("had a restful period") or near saturation ("was pinned and needs a break").
    /// Returns nil when there is insufficient data or no extreme pattern.
    private func characterFact(for insight: HardwareMetricInsight, noun: String) -> String? {
        let observed = insight.summary.observedBucketCount
        guard observed >= 4 else { return nil }
        let idleRatio   = Double(insight.idleBucketCount) / Double(observed)
        let spikeRatio  = Double(insight.spikeBucketCount) / Double(observed)
        if idleRatio >= 0.75 {
            let idlePhrases = [
                "\(noun) was really bored — almost nothing to do all window",
                "\(noun) had a genuinely restful window — nearly all observed periods were at deep rest",
                "\(noun) took the hour off and put its feet up",
                "\(noun) could have been on holiday and nobody would have noticed",
                "\(noun) was practically asleep at the wheel — in the best way",
                "\(noun) had an existential crisis — nothing to do, all session",
                "\(noun) was so idle it briefly considered filing for redundancy",
                "\(noun) saw so little action it might as well have been a screensaver",
            ]
            let seed = abs(observed &* 31 &+ Int((idleRatio * 100).rounded()))
            return idlePhrases[seed % idlePhrases.count]
        } else if idleRatio >= 0.50 {
            let halfIdlePhrases = [
                "\(noun) spent more than half the window in near-idle territory",
                "\(noun) had plenty of downtime between bursts — a relaxed stretch overall",
                "\(noun) mostly twiddled its thumbs with occasional spurts of effort",
                "\(noun) was on a go-slow — more rest than work this stretch",
                "\(noun) clocked more idle time than active time — a true work-life balance",
            ]
            let seed = abs(observed &* 31 &+ Int((idleRatio * 100).rounded()))
            return halfIdlePhrases[seed % halfIdlePhrases.count]
        } else if spikeRatio >= 0.60 {
            let pinnedPhrases = [
                "\(noun) was pinned near its ceiling for most of the window with little relief",
                "\(noun) barely got a moment's rest — near-max load throughout",
                "\(noun) was working flat out for the majority of this stretch",
            ]
            let seed = abs(observed &* 31 &+ Int((spikeRatio * 100).rounded()))
            return pinnedPhrases[seed % pinnedPhrases.count]
        } else if spikeRatio >= 0.35 {
            let hardPhrases = [
                "\(noun) ran hard for a large portion of the window",
                "\(noun) put in serious effort — a lot of high-load buckets in there",
                "\(noun) was earning its keep — frequent near-peak events throughout",
            ]
            let seed = abs(observed &* 31 &+ Int((spikeRatio * 100).rounded()))
            return hardPhrases[seed % hardPhrases.count]
        }
        return nil
    }

    // MARK: - Distress mode

    /// The minimum observed seconds of near-peak load (≥90% average) required before triggering
    /// a distress takeover. Using `estimatedObservedSeconds` from the insight summary lets us
    /// reason in wall-clock time regardless of the bucket cadence for the active window.
    private static let distressThresholdSeconds: Int = 30 * 60 // 30 minutes
    /// How long a distress insight stays pinned before normal text resumes.
    private static let distressDisplayDurationSeconds: TimeInterval = 10 * 60 // 10 minutes
    /// After a distress insight expires, require at least this much additional sustained load
    /// before it can re-trigger. We enforce this by checking `distressLastShownDates`.
    private static let distressCooldownSeconds: TimeInterval = 30 * 60 // 30 minutes

    /// Checks whether a metric row qualifies for a humorous distress takeover.
    /// Criteria: average ≥ 90%, spike buckets represent ≥ 30 min of wall time, and the
    /// distress cooldown has elapsed since the last display.
    private func checkDistress(rowID: String, insight: HardwareMetricInsight) -> Bool {
        let avg = insight.summary.averageValue ?? 0
        // Only ratio-based metrics (CPU/GPU/Memory/ANE) qualify — they're 0…1 normalised.
        guard avg >= 0.90 else {
            // Load dropped — reset the sustained-since tracker
            distressSustainedSinceDates.removeValue(forKey: rowID)
            return false
        }

        // Track when sustained high load started
        let now = Date()
        if distressSustainedSinceDates[rowID] == nil {
            distressSustainedSinceDates[rowID] = now
        }

        // Use spike bucket count × bucket duration as a proxy for sustained high-load wall time
        let observed = insight.summary.observedBucketCount
        guard observed > 0 else { return false }
        let bucketDurationSec = max(1, insight.summary.estimatedObservedSeconds / observed)
        let spikeWallTimeSec = insight.spikeBucketCount * bucketDurationSec
        guard spikeWallTimeSec >= Self.distressThresholdSeconds else { return false }

        // If we're currently showing a distress message, keep it pinned for the display duration
        if let lastShown = distressLastShownDates[rowID] {
            if now.timeIntervalSince(lastShown) < Self.distressDisplayDurationSeconds {
                return true // still within display window
            }
            // Display expired — enforce cooldown before re-triggering
            if now.timeIntervalSince(lastShown) < Self.distressCooldownSeconds {
                return false
            }
        }

        // Trigger distress
        distressLastShownDates[rowID] = now
        return true
    }

    /// Returns a concise distress headline and detail for a metric that's been pushed hard.
    private func distressText(for rowID: String) -> (headline: String, detail: String) {
        let now = Date()
        let seed = abs(rowID.hashValue &+ Int(now.timeIntervalSince1970 / 600)) // changes every 10 min
        switch rowID {
        case "cpu":
            let headlines = [
                "CPU under sustained load",
                "Processor pressure remains high",
                "CPU headroom is running thin",
                "Cores are near capacity",
                "Sustained CPU saturation detected",
                "CPU load needs attention",
                "Processor has been pinned",
                "Compute pressure is elevated",
            ]
            let details = [
                "Sustained near-peak load has held for over 30 minutes.",
                "Every core has been running close to capacity for an extended period.",
                "The CPU has had little recovery time across the current window.",
                "Serious sustained processor load is reducing available headroom.",
                "Peak load has remained high long enough to merit attention.",
            ]
            return (headlines[seed % headlines.count], details[seed % details.count])
        case "gpu":
            let headlines = [
                "GPU under sustained load",
                "Graphics pressure remains high",
                "GPU headroom is running thin",
                "Shaders are near capacity",
                "Sustained GPU saturation detected",
                "GPU load needs attention",
                "Graphics processor has been pinned",
                "Render pressure is elevated",
            ]
            let details = [
                "Sustained heavy rendering has held for more than 30 minutes.",
                "The GPU has had little recovery time across the current window.",
                "Fragment and render workloads are keeping graphics headroom tight.",
                "Multiple pipeline stages appear saturated for an extended period.",
                "Persistent peak load is limiting available graphics capacity.",
            ]
            return (headlines[seed % headlines.count], details[seed % details.count])
        case "memory":
            let headlines = [
                "Memory pressure remains high",
                "RAM headroom is running thin",
                "Sustained memory saturation detected",
                "Memory capacity is nearly full",
                "RAM load needs attention",
                "Memory pressure is elevated",
                "System memory has been pinned",
                "Available memory is constrained",
            ]
            let details = [
                "Near-capacity use has held for over 30 minutes.",
                "RAM has stayed close to full with little relief.",
                "Memory pressure has remained high enough for compression to matter.",
                "Sustained memory saturation is reducing available system headroom.",
                "Available memory has been constrained for an extended period.",
            ]
            return (headlines[seed % headlines.count], details[seed % details.count])
        case "ane":
            let headlines = [
                "Neural Engine under sustained load",
                "ANE pressure remains high",
                "ML workload pressure is elevated",
                "Neural Engine headroom is running thin",
                "Sustained ANE saturation detected",
                "ANE load needs attention",
                "Neural Engine has been pinned",
                "Inference pressure is elevated",
            ]
            let details = [
                "Sustained heavy inference has held for more than 30 minutes.",
                "The ANE has had little recovery time across the current window.",
                "On-device ML demand is keeping Neural Engine headroom tight.",
                "Neural Engine saturation is limiting available inference capacity.",
                "Heavy sustained inference load is keeping ANE utilization high.",
            ]
            return (headlines[seed % headlines.count], details[seed % details.count])
        default:
            return ("Under sustained heavy load", "This metric has been pushed hard for over 30 minutes without relief.")
        }
    }

    // MARK: - Historical comparison

    /// Fetches the insight for the *previous* window of the same duration (e.g. yesterday's daily,
    /// last week's weekly) and returns a comparison sentence if the difference is noteworthy.
    private func historicalComparisonFact(
        metricTitle: String,
        currentInsight: HardwareMetricInsight,
        metricKey: HardwareMetricKey
    ) async -> String? {
        guard let window = currentInsight.window else { return nil }
        let currentAvg = currentInsight.summary.averageValue ?? 0
        guard currentAvg > 0.01 else { return nil }

        // Anchor the previous window at the start of the current one
        let previousInsight = await insightsService.metricInsight(
            for: metricKey,
            window: window,
            anchorDate: currentInsight.range.start.addingTimeInterval(-1)
        )
        guard let prevAvg = previousInsight.summary.averageValue, prevAvg > 0.01 else { return nil }

        let delta = currentAvg - prevAvg
        let pctChange = abs(delta / prevAvg) * 100

        // Only mention if the change is significant (>15%)
        guard pctChange >= 15 else { return nil }

        let windowLabel: String
        switch window {
        case .daily:   windowLabel = "yesterday"
        case .weekly:  windowLabel = "last week"
        case .monthly: windowLabel = "last month"
        @unknown default:
            windowLabel = "the previous window"
        }

        // Include notable peak comparison when available
        if let currentPeak = currentInsight.peakWindow,
           let prevPeak = previousInsight.peakWindow {
            let peakDelta = currentPeak.peakValue - prevPeak.peakValue
            if abs(peakDelta / max(prevPeak.peakValue, 0.01)) > 0.20 {
                let direction = delta > 0 ? "up" : "down"
                let peakDir = peakDelta > 0 ? "higher" : "lower"
                return String(format: "%@ average is %@ %.0f%% compared to %@, with peaks running %@ too",
                              metricTitle, direction, pctChange, windowLabel, peakDir)
            }
        }

        if delta > 0 {
            return String(format: "%@ average is up %.0f%% compared to %@", metricTitle, pctChange, windowLabel)
        } else {
            return String(format: "%@ average is down %.0f%% compared to %@", metricTitle, pctChange, windowLabel)
        }
    }

    /// GPU-specific historical comparison using device-level metric queries.
    private func historicalGPUComparisonFact(currentGPUInsight: HardwareMetricInsight?) async -> String? {
        guard let current = currentGPUInsight,
              let window = current.window,
              let gpuID = primaryGPUID,
              let currentAvg = current.summary.averageValue, currentAvg > 0.01 else { return nil }

        let previous = await insightsService.deviceMetricInsight(
            for: .utilizationRatio,
            deviceID: gpuID,
            deviceKind: .gpu,
            window: window,
            anchorDate: current.range.start.addingTimeInterval(-1)
        )
        guard let prevAvg = previous.summary.averageValue, prevAvg > 0.01 else { return nil }

        let delta = currentAvg - prevAvg
        let pctChange = abs(delta / prevAvg) * 100
        guard pctChange >= 15 else { return nil }

        let windowLabel: String
        switch window {
        case .daily:   windowLabel = "yesterday"
        case .weekly:  windowLabel = "last week"
        case .monthly: windowLabel = "last month"
        @unknown default:
            windowLabel = "the previous window"
        }

        if delta > 0 {
            return String(format: "GPU average is up %.0f%% compared to %@", pctChange, windowLabel)
        } else {
            return String(format: "GPU average is down %.0f%% compared to %@", pctChange, windowLabel)
        }
    }

    private func historicalCombinedMetricComparisonFact(
        metricTitle: String,
        currentPrimary: HardwareMetricInsight,
        currentSecondary: HardwareMetricInsight,
        primaryMetricKey: HardwareMetricKey,
        secondaryMetricKey: HardwareMetricKey,
        primaryLabel: String,
        secondaryLabel: String
    ) async -> String? {
        guard let window = currentPrimary.window ?? currentSecondary.window else { return nil }

        let currentPrimaryAvg = currentPrimary.summary.averageValue ?? 0
        let currentSecondaryAvg = currentSecondary.summary.averageValue ?? 0
        let currentCombined = currentPrimaryAvg + currentSecondaryAvg
        guard currentCombined > 0.01 else { return nil }

        let anchorDate = currentPrimary.range.start.addingTimeInterval(-1)
        let previousPrimaryTask = Task {
            await insightsService.metricInsight(
                for: primaryMetricKey,
                window: window,
                anchorDate: anchorDate
            )
        }
        let previousSecondaryTask = Task {
            await insightsService.metricInsight(
                for: secondaryMetricKey,
                window: window,
                anchorDate: anchorDate
            )
        }

        let prevPrimaryAvg = (await previousPrimaryTask.value).summary.averageValue ?? 0
        let prevSecondaryAvg = (await previousSecondaryTask.value).summary.averageValue ?? 0
        let prevCombined = prevPrimaryAvg + prevSecondaryAvg
        guard prevCombined > 0.01 else { return nil }

        let delta = currentCombined - prevCombined
        let pctChange = abs(delta / prevCombined) * 100
        guard pctChange >= 15 else { return nil }

        let windowLabel: String
        switch window {
        case .daily:   windowLabel = "yesterday"
        case .weekly:  windowLabel = "last week"
        case .monthly: windowLabel = "last month"
        @unknown default:
            windowLabel = "the previous window"
        }

        let direction = delta > 0 ? "up" : "down"
        var detail = ""
        if currentPrimaryAvg > currentSecondaryAvg * 3 {
            detail = ", mostly driven by \(primaryLabel)"
        } else if currentSecondaryAvg > currentPrimaryAvg * 3 {
            detail = ", mostly driven by \(secondaryLabel)"
        }

        return "\(metricTitle) throughput is \(direction) \(Int(pctChange.rounded()))% compared to \(windowLabel)\(detail)"
    }

    private func patternContextFacts(for insight: HardwareMetricInsight, noun: String) -> [String] {
        var facts: [String] = []

        switch insight.trendDirection {
        case .rising:
            facts.append("\(noun) ramped up as the window progressed")
        case .falling:
            facts.append("\(noun) did more of its work early and eased off later")
        case .oscillating:
            facts.append("\(noun) swung around noticeably instead of holding a clean line")
        case .flat:
            break
        @unknown default:
            break
        }

        switch insight.activityCadence {
        case .quiet:
            if insight.longestIdleStreak >= 3 {
                facts.append("Longest quiet streak lasted \(insight.longestIdleStreak) well-covered bucket\(insight.longestIdleStreak == 1 ? "" : "s")")
            }
        case .bursty:
            facts.append("\(noun) arrived in short bursts rather than one long push")
        case .steady:
            if let variability = insight.variabilityRatio, variability <= 0.12, insight.summary.observedBucketCount >= 6 {
                facts.append("\(noun) was unusually consistent from bucket to bucket")
            }
        case .sustained:
            if insight.longestSpikeStreak >= 2 {
                facts.append("Longest sustained high-load run covered \(insight.longestSpikeStreak) bucket\(insight.longestSpikeStreak == 1 ? "" : "s")")
            }
        @unknown default:
            break
        }

        if let variability = insight.variabilityRatio, variability >= 0.45 {
            facts.append("\(noun) changed sharply between neighbouring buckets")
        }

        if let peakRecency = insight.peakRecencyRatio {
            if peakRecency >= 0.75 {
                facts.append("Peak activity arrived late in the selected window")
            } else if peakRecency <= 0.25 {
                facts.append("Peak activity happened early and was not matched later")
            }
        }

        return Array(facts.prefix(3))
    }

    private func makeSharedStoryFacts(
        cpu: HardwareMetricInsight,
        gpu: HardwareMetricInsight?,
        memory: HardwareMetricInsight,
        pressure: HardwareMetricInsight,
        ane: HardwareMetricInsight?,
        power: HardwareMetricInsight,
        thermal: HardwareMetricInsight,
        media: MediaEngineStatsSampler.ActivitySummary?
    ) -> [String] {
        let cpuAvg = cpu.summary.averageValue ?? 0
        let gpuAvg = gpu?.summary.averageValue ?? 0
        let aneAvg = ane?.summary.averageValue ?? 0
        let memoryAvg = memory.summary.averageValue ?? 0
        let pressureAvg = pressure.summary.averageValue ?? 0
        let pressurePeak = pressure.summary.peakValue ?? 0
        let powerAvg = power.summary.averageValue ?? 0
        let thermalPeak = thermal.summary.peakValue ?? 0

        var facts: [String] = []

        if gpuAvg > max(cpuAvg * 1.35, 0.35) {
            facts.append("Overall workload skewed GPU-heavy relative to CPU activity")
        } else if aneAvg > max(gpuAvg * 1.25, 0.25) && aneAvg > max(cpuAvg * 0.45, 0.15) {
            facts.append("On-device machine-learning work was a defining part of the session mix")
        } else if cpuAvg > 0.55 {
            facts.append("CPU carried most of the heavy lifting across the session")
        }

        if pressureAvg > 0.45 || pressurePeak > 0.60 || (!hasObservedMetricData(pressure.summary) && memoryAvg > 0.80) {
            facts.append("Memory headroom was tight enough to influence the rest of the session")
        }

        if thermalPeak > 0.75 {
            facts.append("Thermals were part of the story, not just background noise")
        } else if powerAvg < 8 && cpu.activityCadence == .quiet && (gpu?.activityCadence ?? .quiet) == .quiet {
            facts.append("The machine stayed notably frugal despite the activity mix")
        }

        if let busiestHour = dominantBusiestHour(
            cpu: cpu,
            gpu: gpu,
            memory: hasObservedMetricData(pressure.summary) ? pressure : memory,
            ane: ane,
            power: power
        ) {
            facts.append("Most heavy activity clustered around \(formatHour(busiestHour))")
        }

        if let media, media.activityState != .idle {
            if let codec = media.codec {
                facts.append("Media engines were in play as well, with \(codec) activity showing up in the same window")
            } else {
                facts.append("Media engines were part of the session mix instead of staying fully idle")
            }
        }

        return Array(facts.prefix(3))
    }

    private func makeSessionStory(
        cpu: HardwareMetricInsight,
        gpu: HardwareMetricInsight?,
        memory: HardwareMetricInsight,
        pressure: HardwareMetricInsight,
        ane: HardwareMetricInsight?,
        power: HardwareMetricInsight,
        thermal: HardwareMetricInsight,
        leadAppName: String?
    ) -> SessionStory? {
        let cpuAvg = cpu.summary.averageValue ?? 0
        let gpuAvg = gpu?.summary.averageValue ?? 0
        let memoryAvg = memory.summary.averageValue ?? 0
        let pressureAvg = pressure.summary.averageValue ?? 0
        let pressurePeak = pressure.summary.peakValue ?? 0
        let aneAvg = ane?.summary.averageValue ?? 0
        let powerAvg = power.summary.averageValue ?? 0
        let thermalPeak = thermal.summary.peakValue ?? 0
        let appLead = leadAppName ?? "Foreground apps"

        struct StoryCandidate {
            let id: String
            let score: Double
            let priority: Int
            let story: SessionStory
        }

        let pressureObserved = hasObservedMetricData(pressure.summary)
        let relaxedGPUCadence = gpu?.activityCadence ?? .quiet

        // Hero line: memory pressure is often chronically elevated (allocator keeps pages, benign pressure)
        // while CPU/GPU/ANE spikes better reflect "what dominated the session". Scale memory (and lightly,
        // power/thermal) down for ranking only — thresholds and copy are unchanged.
        let heroLeadMemoryScoreScale = 0.48
        let heroLeadPowerScoreScale = 0.88

        var candidates: [StoryCandidate] = []

        if pressureAvg > 0.55 || pressurePeak > 0.66 || (!pressureObserved && memoryAvg > 0.85) {
            let rawMemoryScore = pressureObserved
                ? ((pressureAvg * 0.72) + (pressurePeak * 0.28))
                : (memoryAvg * 0.82)
            let memoryScore = rawMemoryScore * heroLeadMemoryScoreScale
            candidates.append(
                StoryCandidate(
                    id: "memory",
                    score: memoryScore,
                    priority: 2,
                    story: SessionStory(
                        iconName: "memorychip",
                        accentColor: .mintCompat,
                        headline: "Memory took centre stage",
                        detail: "\(appLead) kept RAM crowded, and pressure spikes shaped the rest of this window."
                    )
                )
            )
        }

        if thermalPeak > 0.85 || powerAvg > 30 {
            let rawPowerScore = max(thermalPeak * 0.95, min(powerAvg / 40.0, 0.92))
            let powerScore = rawPowerScore * heroLeadPowerScoreScale
            candidates.append(
                StoryCandidate(
                    id: "power",
                    score: powerScore,
                    priority: 0,
                    story: SessionStory(
                        iconName: "thermometer.medium",
                        accentColor: .orange,
                        headline: "This was a warm-blooded run",
                        detail: "Power draw and thermal pressure were visible parts of the story, not just side effects."
                    )
                )
            )
        }

        if aneAvg > max(gpuAvg * 1.30, 0.35) && aneAvg > max(cpuAvg * 0.45, 0.15) {
            let anePeak = ane?.summary.peakValue ?? aneAvg
            let aneScore = (aneAvg * 0.8) + (anePeak * 0.2)
            candidates.append(
                StoryCandidate(
                    id: "ane",
                    score: aneScore,
                    priority: 1,
                    story: SessionStory(
                        iconName: "sparkles",
                        accentColor: Color(red: 0.65, green: 0.00, blue: 0.65),
                        headline: "Neural work set the tone",
                        detail: "On-device AI had more of the spotlight than the GPU this time around."
                    )
                )
            )
        }

        if gpuAvg > max(cpuAvg * 1.50, 0.35) {
            let gpuPeak = gpu?.summary.peakValue ?? gpuAvg
            let gpuScore = (gpuAvg * 0.8) + (gpuPeak * 0.2)
            candidates.append(
                StoryCandidate(
                    id: "gpu",
                    score: gpuScore,
                    priority: 3,
                    story: SessionStory(
                        iconName: "cpu.fill",
                        accentColor: Color(red: 0.85, green: 0.20, blue: 0.20),
                        headline: "Graphics work led the session",
                        detail: "\(appLead) leaned harder on the GPU than on the CPU over this \(selectedWindow.shortLabel) view."
                    )
                )
            )
        }

        if cpuAvg > 0.55 || cpu.activityCadence == .sustained {
            let cpuPeak = cpu.summary.peakValue ?? cpuAvg
            let cpuScore = max((cpuAvg * 0.8) + (cpuPeak * 0.2), cpu.activityCadence == .sustained ? 0.62 : 0)
            candidates.append(
                StoryCandidate(
                    id: "cpu",
                    score: cpuScore,
                    priority: 4,
                    story: SessionStory(
                        iconName: "cpu",
                        accentColor: .blue,
                        headline: "CPU did the bulk of it",
                        detail: "This window looked more like sustained processor work than a graphics-first or idle stretch."
                    )
                )
            )
        }

        if powerAvg < 8 && cpu.activityCadence == .quiet && relaxedGPUCadence == .quiet {
            candidates.append(
                StoryCandidate(
                    id: "relaxed",
                    score: 0.28,
                    priority: 5,
                    story: SessionStory(
                        iconName: "leaf.fill",
                        accentColor: .green,
                        headline: "An unusually easygoing stretch",
                        detail: "Light draw, long idle runs, and low drama made this a notably relaxed session."
                    )
                )
            )
        }

        let fallback = SessionStory(
            iconName: "waveform.path.ecg",
            accentColor: .appsAccentColor,
            headline: "A mixed workload window",
            detail: "No single subsystem stole the show, which usually means a genuinely varied session."
        )

        guard !candidates.isEmpty else { return fallback }

        candidates.sort { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.0001 {
                return lhs.score > rhs.score
            }
            return lhs.priority < rhs.priority
        }

        var winningCandidate = candidates[0]

        // Memory should win when it clearly dominates, not simply because it
        // passed a threshold earlier than CPU/GPU/Power. If another subsystem
        // is within a small margin, let that stronger alternative lead instead.
        let heroMemoryRunnerUpMargin = 0.14
        if winningCandidate.id == "memory",
           let runnerUp = candidates.dropFirst().first,
           runnerUp.score >= (winningCandidate.score - heroMemoryRunnerUpMargin) {
            winningCandidate = runnerUp
        }

        return winningCandidate.story
    }

    private func dominantBusiestHour(
        cpu: HardwareMetricInsight,
        gpu: HardwareMetricInsight?,
        memory: HardwareMetricInsight,
        ane: HardwareMetricInsight?,
        power: HardwareMetricInsight
    ) -> Int? {
        let candidates: [(average: Double, hour: Int?)] = [
            (cpu.summary.averageValue ?? 0, cpu.busiestHourOfDay),
            (gpu?.summary.averageValue ?? 0, gpu?.busiestHourOfDay),
            (memory.summary.averageValue ?? 0, memory.busiestHourOfDay),
            (ane?.summary.averageValue ?? 0, ane?.busiestHourOfDay),
            (power.summary.averageValue ?? 0, power.busiestHourOfDay),
        ]

        return candidates
            .filter { $0.hour != nil }
            .max { lhs, rhs in lhs.average < rhs.average }?
            .hour
    }

    private func topUserAppName() -> String? {
        appInsightPools()
            .competitiveRows
            .max { $0.uptimeSeconds < $1.uptimeSeconds }?
            .name
    }

    private func topCPUAppRow() -> TopAppInsightRow? {
        appInsightPools()
            .competitiveRows
            .max { $0.cpuPercent < $1.cpuPercent }
    }

    private func deduplicatedContextFacts(_ facts: [String]) -> [String] {
        var seen: Set<String> = []
        return facts.filter { seen.insert($0).inserted }
    }

    private func blendHistoricalFactsIntoDetail(_ facts: [String], row: inout InsightRow) {
        guard let leadingFact = facts.first else { return }
        let normalizedFact = leadingFact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFact.isEmpty else { return }

        let normalizedDetail = row.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDetail.lowercased().contains(normalizedFact.lowercased()) else { return }

        row.detail = sentenceJoin([
            trimTrailingSentencePunctuation(normalizedDetail),
            trimTrailingSentencePunctuation(normalizedFact)
        ])
    }

    private func insightFingerprint(for row: InsightRow) -> String {
        guard row.aiKind != .none else { return "" }

        let tokens: [String] = [
            row.id,
            row.title,
            String(describing: row.aiKind),
            fingerprintToken(for: row.averageValue, unit: row.valueUnit),
            fingerprintToken(for: row.peakValue, unit: row.valueUnit),
            String(row.spikeBucketCount),
            row.busiestHour.map(String.init) ?? "nil",
            row.peakWindowDate.map { String(Int($0.timeIntervalSince1970 / 300)) } ?? "nil",
            row.appPrimaryName ?? "nil",
            row.appPrimaryHours.map { String(Int(($0 * 10).rounded())) } ?? "nil",
            row.contextFacts.joined(separator: "|"),
        ]

        return String(stableHash(tokens.joined(separator: "||")))
    }

    private func fingerprintToken(for value: Double?, unit: InsightRow.FocusValueUnit) -> String {
        guard let value else { return "nil" }
        let scaled: Double
        switch unit {
        case .ratio:
            scaled = value * 100
        case .megabytesPerSecond:
            scaled = value
        case .watts:
            scaled = value * 10
        }
        return String(Int(scaled.rounded()))
    }

    private func stableHash(_ text: String) -> Int {
        text.unicodeScalars.reduce(5381) { partialResult, scalar in
            ((partialResult << 5) &+ partialResult) &+ Int(scalar.value)
        }
    }

    private func hasObservedMetricData(_ summary: HardwareHistoryMetricSummary) -> Bool {
        summary.averageValue != nil || summary.peakValue != nil || summary.lastValue != nil
    }

    private func coverageLabel(for coverageRatio: Double) -> String {
        guard coverageRatio > 0 else { return "Warm-up" }
        return "\(Int((coverageRatio * 100).rounded()))% seen"
    }

    private func formatMBps(_ value: Double?) -> String? {
        guard let value, value > 0.001 else { return nil }
        if value >= 1000 { return String(format: "%.1f GB/s", value / 1000.0) }
        if value >= 1    { return String(format: "%.1f MB/s", value) }
        return String(format: "%.0f KB/s", value * 1024)
    }

    private func thermalDescription(for insight: HardwareMetricInsight) -> String {
        let peakLevel = insight.summary.peakValue ?? 0

        switch peakLevel {
        case ..<0.10:
            return "Thermals stayed nominal"
        case ..<0.50:
            return "Thermals briefly reached fair pressure"
        case ..<0.85:
            return "Thermals hit serious pressure"
        default:
            return "Thermals reached critical pressure"
        }
    }

    private func thermalHeadline(for insight: HardwareMetricInsight) -> String {
        let averageLevel = insight.summary.averageValue ?? insight.summary.peakValue ?? 0

        switch averageLevel {
        case ..<0.10:
            return "Thermals mostly nominal"
        case ..<0.50:
            return "Thermals mostly fair"
        case ..<0.85:
            return "Thermals often serious"
        default:
            return "Thermals frequently critical"
        }
    }

    private func busiestSummary(from insight: HardwareMetricInsight) -> String? {
        copywriter.busiestSummary(
            daypartLabel: insight.busiestDaypart?.displayLabel,
            formattedHour: insight.busiestHourOfDay.map(formatHour)
        )
    }

    private func peakWindowSummary(from peakWindow: HardwareInsightPeakWindow?) -> String? {
        guard let peakWindow else { return nil }

        if #available(macOS 12, *) {
            switch selectedWindow {
            case .daily:
                return peakWindow.bucketStart.formatted(.dateTime.hour().minute())
            case .weekly, .monthly:
                return peakWindow.bucketStart.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            @unknown default:
                return peakWindow.bucketStart.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            }
        } else {
            let formatter = DateFormatter()
            switch selectedWindow {
            case .daily:
                formatter.dateFormat = "h:mm a"
            case .weekly, .monthly:
                formatter.dateFormat = "EEE h:mm a"
            @unknown default:
                formatter.dateFormat = "EEE h:mm a"
            }
            return formatter.string(from: peakWindow.bucketStart)
        }
    }

    private func formatRatio(_ value: Double?) -> String? {
        guard let value else { return nil }
        return "\(Int((value * 100).rounded()))%"
    }

    private func formatWatts(_ value: Double?) -> String? {
        guard let value else { return nil }
        if value >= 10 {
            return String(format: "%.1f W", value)
        }
        return String(format: "%.2f W", value)
    }

    private func formatHour(_ hour: Int) -> String {
        let normalizedHour = min(max(hour, 0), 23)
        var components = DateComponents()
        components.calendar = Calendar.current
        components.timeZone = TimeZone.current
        components.year = 2001
        components.month = 1
        components.day = 1
        components.hour = normalizedHour
        components.minute = 0

        let date = components.date ?? Date(timeIntervalSinceReferenceDate: Double(normalizedHour * 3600))
        if #available(macOS 12, *) {
            return date.formatted(.dateTime.hour().minute())
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        }
    }

    private func sentenceJoin(_ components: [String?]) -> String {
        let trimmed = components
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !trimmed.isEmpty else { return "More tracked history is needed to generate a useful summary." }
        return trimmed.joined(separator: ". ") + "."
    }

    private func trimTrailingSentencePunctuation(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix(".") {
            trimmed.removeLast()
        }
        return trimmed
    }

    private func joinNonEmpty(_ components: [String?], separator: String) -> String? {
        let filtered = components.compactMap { $0 }.filter { !$0.isEmpty }
        guard !filtered.isEmpty else { return nil }
        return filtered.joined(separator: separator)
    }
}

extension HardwareInsightWindow {
    var shortLabel: String {
        switch self {
        case .daily:
            return "24h"
        case .weekly:
            return "7d"
        case .monthly:
            return "30d"
        @unknown default:
            return rawValue
        }
    }
}

private extension Color {
    static var mintCompat: Color {
        if #available(macOS 12, *) {
            return .mint
        } else {
            return Color(red: 0.0, green: 0.78, blue: 0.58)
        }
    }
}

extension Color {
    static let networkAccentColor = Color(red: 0.40, green: 0.40, blue: 0.50)
    static let networkAccentColorDimmed = Color(red: 0.34, green: 0.34, blue: 0.45)
    static let appsAccentColor = Color(red: 0.40, green: 0.65, blue: 0.95)
    static let diskWriteAccentColor = Color(red: 0.98, green: 0.80, blue: 0.16)
}

extension SIMD4 where Scalar == Float {
    static let networkAccentColor = SIMD4<Float>(0.40, 0.40, 0.50, 1.0)
    static let networkAccentColorDimmed = SIMD4<Float>(0.34, 0.34, 0.45, 1.0)
    static let diskWriteAccentColor = SIMD4<Float>(0.98, 0.80, 0.16, 1.0)
}

private extension HardwareInsightDaypart {
    var displayLabel: String {
        switch self {
        case .overnight:
            return "overnight"
        case .morning:
            return "morning"
        case .afternoon:
            return "afternoon"
        case .evening:
            return "evening"
        @unknown default:
            return rawValue
        }
    }
}

struct NetworkStatsMiniCard: View {
    @Environment(\.appUIScale) private var appUIScale
    let networkInterfaceSampler: NetworkInterfaceSampler
    var networkUploadUsage: Float? = nil
    var networkUploadHistory: [Float] = []
    var networkUploadLabel: String? = nil
    var networkUploadCurrentText: String? = nil
    var networkUploadDeltaText: String? = nil
    var networkDownloadUsage: Float? = nil
    var networkDownloadHistory: [Float] = []
    var networkDownloadLabel: String? = nil
    var networkDownloadCurrentText: String? = nil
    var networkDownloadDeltaText: String? = nil
    var networkFocusLinePanels: [HardwareGraphFocusLinePanelSnapshot] = []
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil

    private var scaledCardCornerRadius: CGFloat { 12 * appUIScale }
    private var scaledCardHeight: CGFloat { 80 * appUIScale }
    private var scaledStackSpacing: CGFloat { 20 * appUIScale }
    private var scaledHorizontalPadding: CGFloat { 12 * appUIScale }
    private var scaledVerticalPadding: CGFloat { 10 * appUIScale }
    private var scaledRowHeight: CGFloat { 22 * appUIScale }
    private var scaledRowSpacing: CGFloat { 4 * appUIScale }
    private var scaledTitleFontSize: CGFloat { 12 * appUIScale }
    private var scaledValueFontSize: CGFloat { 13 * appUIScale }
    private var scaledSystemCardHeight: CGFloat { 320 * appUIScale }

    private var hasNetworkUsageData: Bool { !networkUploadHistory.isEmpty || networkUploadUsage != nil }
    private var focusID: String { hasNetworkUsageData ? "usage-network-upload" : "network-stats" }

    private var networkInterfaceStats: [HardwareGraphFocusStat] {
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

    private var networkInterfaceDetailLines: [String] {
        guard let snapshot = networkInterfaceSampler.latestSnapshot else { return [] }
        var lines: [String] = []
        if let primaryIP = snapshot.primaryInterface?.primaryLocalIP { lines.append("Primary IP: \(primaryIP)") }
        if let subnet = snapshot.primaryInterface?.primarySubnetMask { lines.append("Subnet: \(subnet)") }
        if let mac = snapshot.primaryInterface?.macAddress { lines.append("MAC: \(mac)") }
        lines.append("Interfaces: \(snapshot.interfaces.count)")
        lines.append("Active: \(snapshot.interfaces.filter { $0.isActive }.count)")
        return lines
    }

    private func percentageString(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private var focusState: HardwareGraphFocusState? {
        guard let snapshot = networkInterfaceSampler.latestSnapshot else { return nil }
        guard snapshot.isConnected else { return nil }

        if hasNetworkUsageData {
            // Combined focus state: Upload history + network interface details
            let accentColor = Color.networkAccentColor
            let lineValues = networkUploadHistory.map { Optional(Double($0)) }
            let observed = lineValues.compactMap { $0 }

            var stats: [HardwareGraphFocusStat] = []
            if let uploadUsage = networkUploadUsage {
                stats.append(.init(label: "Live", value: percentageString(Double(uploadUsage)), tint: accentColor))
            }
            if !observed.isEmpty {
                let average = observed.reduce(0, +) / Double(observed.count)
                stats.append(.init(label: "Window Avg", value: percentageString(average)))
                stats.append(.init(label: "Peak", value: percentageString(observed.max() ?? 0)))
                stats.append(.init(label: "Floor", value: percentageString(observed.min() ?? 0)))
                stats.append(.init(label: "Samples", value: "\(networkUploadHistory.count)"))
            }
            if let deltaText = networkUploadDeltaText, !deltaText.isEmpty {
                stats.append(.init(label: "Trend", value: deltaText, tint: deltaText.hasPrefix("↑") ? Color(red: 0.90, green: 0.40, blue: 0.40) : Color(red: 0.30, green: 0.75, blue: 0.45)))
            }
            stats += networkInterfaceStats

            let detailLines = [networkUploadCurrentText].compactMap { $0?.isEmpty == false ? $0 : nil } + networkInterfaceDetailLines

            let subtitle = networkUploadLabel?.isEmpty == false ? networkUploadLabel : "Focused view of the visible history window"

            return HardwareGraphFocusState(
                id: focusID,
                title: "Network Upload",
                subtitle: subtitle,
                accentColor: accentColor,
                insightTarget: .network,
                visualization: .lineChart([
                    HardwareGraphFocusSeries(
                        id: "primary",
                        label: "Upload",
                        color: accentColor,
                        values: lineValues
                    )
                ]),
                linePanelSnapshots: networkFocusLinePanels,
                stats: stats,
                detailLines: detailLines
            )
        }

        // Fallback: summary-only focus state when no usage data available
        let interfaceRows = snapshot.interfaces.compactMap { interface in
            HardwareGraphFocusNetworkInterfaceRowSnapshot(
                id: interface.interfaceName,
                name: interface.displayName,
                connectionType: interface.connectionType.rawValue,
                isActive: interface.isActive,
                localIP: interface.primaryLocalIP,
                subnetMask: interface.primarySubnetMask,
                macAddress: interface.macAddress
            )
        }

        return HardwareGraphFocusState(
            id: focusID,
            title: "Network Stats",
            subtitle: "Detailed network interface information including IP configuration, DNS settings, and connection types.",
            accentColor: Color.networkAccentColor,
            visualization: .summary(
                HardwareGraphFocusSummarySnapshot(
                    title: "Network Overview",
                    subtitle: "Real-time network interface status and configuration details.",
                    hero: nil,
                    tiles: [
                        .init(title: "Interfaces", value: "\(snapshot.interfaces.count)", detail: "total interfaces", tint: Color.networkAccentColor),
                        .init(title: "Active", value: "\(snapshot.interfaces.filter { $0.isActive }.count)", detail: "connected interfaces", tint: Color(red: 0.30, green: 0.84, blue: 0.50)),
                        .init(title: "Types", value: "\(snapshot.connectionTypes.count)", detail: "connection types", tint: Color(red: 0.96, green: 0.72, blue: 0.18)),
                        .init(title: "DNS", value: "\(snapshot.primaryInterface?.dnsServers.count ?? 0)", detail: "DNS servers", tint: Color(red: 0.84, green: 0.56, blue: 0.10))
                    ],
                    rows: []
                )
            ),
            detailVisuals: [
                .networkInterfaces(
                    HardwareGraphFocusNetworkInterfacesSnapshot(
                        id: "network-interfaces-list",
                        subtitle: "All network interfaces with their current configuration and status.",
                        rows: interfaceRows
                    )
                )
            ],
            stats: networkInterfaceStats,
            detailLines: [
                "Network interface information is refreshed every 30 seconds using SystemConfiguration APIs.",
                "Connection types are automatically detected based on interface naming patterns and system configuration.",
                "Primary interface selection favors non-loopback active interfaces, typically Ethernet or WiFi."
            ]
        )
    }

    private var focusRefreshSignature: Int {
        var hasher = Hasher()
        if let uploadUsage = networkUploadUsage {
            hasher.combine(Int((Double(uploadUsage) * 1000).rounded()))
        }
        // Lightweight: count + boundary values instead of iterating every history sample.
        hasher.combine(networkUploadHistory.count)
        if let first = networkUploadHistory.first {
            hasher.combine(Int((Double(first) * 1000).rounded()))
        }
        if let last = networkUploadHistory.last {
            hasher.combine(Int((Double(last) * 1000).rounded()))
        }
        hasher.combine(networkUploadLabel ?? "")
        hasher.combine(networkUploadCurrentText ?? "")
        hasher.combine(networkUploadDeltaText ?? "")
        hasher.combine(focusState?.signatureHash ?? 0)
        return hasher.finalize()
    }

    var body: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCardCornerRadius).themed()
            .frame(height: scaledSystemCardHeight)
            .overlay(
                VStack(alignment: .leading, spacing: scaledRowSpacing) {
                    // Title with network icon on the right
                    HStack(alignment: .center, spacing: 12 * appUIScale) {
                        Text("Network Stats")
                            .font(.system(size: scaledTitleFontSize, weight: .semibold))
                            .foregroundColor(.primary)

                        Spacer(minLength: 4 * appUIScale)

                        Image(systemName: "network")
                            .font(.system(size: 24 * appUIScale, weight: .semibold))
                            .foregroundColor(.networkAccentColor)
                            .frame(width: 28 * appUIScale, height: 28 * appUIScale)
                    }
                    .frame(height: scaledRowHeight)
                    .padding(.bottom, 2)

                    horizontalDivider

                    // Connection
                    networkInfoRow(
                        icon: networkInterfaceSampler.connectionTypes.count == 1 ?
                            networkInterfaceSampler.connectionTypes.first?.sfSymbol ?? "network" : "network",
                        title: "Connection",
                        value: connectionDisplayText
                    )

                    horizontalDivider

                    // Configuration
                    networkInfoRow(
                        icon: "gear",
                        title: "Configuration",
                        value: networkInterfaceSampler.primaryInterface?.configMethod.rawValue ?? "—"
                    )

                    horizontalDivider

                    // Local IP
                    networkInfoRow(
                        icon: "location",
                        title: "Local IP",
                        value: networkInterfaceSampler.primaryInterface?.primaryLocalIP ?? "—"
                    )

                    horizontalDivider

                    // Subnet Mask
                    networkInfoRow(
                        icon: "slash.circle",
                        title: "Subnet Mask",
                        value: networkInterfaceSampler.primaryInterface?.primarySubnetMask ?? "—"
                    )

                    horizontalDivider

                    // Router
                    networkInfoRow(
                        icon: "arrow.up.right.and.arrow.down.left.rectangle",
                        title: "Router",
                        value: networkInterfaceSampler.primaryInterface?.router ?? "—"
                    )

                    horizontalDivider

                    // DNS Servers
                    networkInfoRow(
                        icon: "server.rack",
                        title: "DNS Servers",
                        value: dnsServersText
                    )

                    horizontalDivider

                    // Search Domain
                    networkInfoRow(
                        icon: "magnifyingglass",
                        title: "Search Domain",
                        value: searchDomainText
                    )

                    horizontalDivider

                    // Ethernet Speed
                    networkInfoRow(
                        icon: "speedometer",
                        title: "Ethernet Speed",
                        value: networkInterfaceSampler.primaryInterface?.ethernetSpeed ?? "—"
                    )

                    horizontalDivider

                    // MAC Address
                    networkInfoRow(
                        icon: "barcode",
                        title: "MAC Address",
                        value: networkInterfaceSampler.primaryInterface?.macAddress ?? "—"
                    )
                }
                .padding(.horizontal, scaledHorizontalPadding)
                .padding(.vertical, scaledVerticalPadding)
            )
        .contentShape(Rectangle())
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
            refreshFocusedStateIfNeeded()
        }
    }

    private func networkInfoRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4 * appUIScale) {
            HStack(spacing: 4 * appUIScale) {
                Image(systemName: icon)
                    .font(.system(size: scaledTitleFontSize * 0.9))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: scaledTitleFontSize, weight: .regular))
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 4 * appUIScale)

            Text(value)
                .font(.system(size: scaledValueFontSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(height: scaledRowHeight)
    }

    private var connectionDisplayText: String {
        let connectionTypes = networkInterfaceSampler.connectionTypes

        if connectionTypes.count == 1, let connection = connectionTypes.first {
            return connection.rawValue
        } else if connectionTypes.count > 1 {
            // Show readable text for multiple connections
            return connectionTypes.map { $0.rawValue }.joined(separator: " + ")
        } else {
            return "Disconnected"
        }
    }

    private var dnsServersText: String {
        guard let dnsServers = networkInterfaceSampler.primaryInterface?.dnsServers, !dnsServers.isEmpty else {
            return "—"
        }
        return dnsServers.prefix(3).joined(separator: ", ")
    }

    private var searchDomainText: String {
        guard let searchDomains = networkInterfaceSampler.primaryInterface?.searchDomains, !searchDomains.isEmpty else {
            return "—"
        }
        return searchDomains.first ?? "—"
    }

    private func refreshFocusedStateIfNeeded() {
        guard let focusState,
              focusState.id == activeFocusID,
              let onFocusedStateChange else { return }
        onFocusedStateChange(focusState)
    }

    private var horizontalDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
            .padding(.horizontal, -scaledHorizontalPadding)
    }
}

struct PowerMiniCard: View {
    @Environment(\.appUIScale) private var appUIScale
    let systemSnapshot: PowerStatsSampler.SystemSnapshot?
    let powerSnapshot: PowerStatsSampler.ReadingsSnapshot?
    let combinedPowerSeries: MetricSeries
    let cumulativeEnergySeries: MetricSeries
    let sessionStartDate: Date
    var sessionLabel: String = "App launched"
    var efficiencyScore: String? = nil
    var hardwareAgentUptimeSeconds: TimeInterval? = nil
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil

    private var scaledCardCornerRadius: CGFloat { 12 * appUIScale }
    private var scaledCardHeight: CGFloat { 80 * appUIScale }
    private var scaledStackSpacing: CGFloat { 20 * appUIScale }
    private var scaledHorizontalPadding: CGFloat { 12 * appUIScale }
    private var scaledVerticalPadding: CGFloat { 10 * appUIScale }
    private var scaledRowHeight: CGFloat { 22 * appUIScale }
    private var scaledRowSpacing: CGFloat { 4 * appUIScale }
    private var scaledTitleFontSize: CGFloat { 12 * appUIScale }
    private var scaledValueFontSize: CGFloat { 13 * appUIScale }
    private var powerMetricRowCount: CGFloat { 6 + (efficiencyScore != nil ? 1 : 0) }
    private var scaledSystemCardHeight: CGFloat {
        // Title row + metric rows + 1 pt dividers, plus the VStack spacing between each child.
        let rowCount = 1 + powerMetricRowCount
        let dividerCount = powerMetricRowCount
        let spacingCount = powerMetricRowCount * 2

        return (2 * scaledVerticalPadding)
            + (rowCount * scaledRowHeight)
            + dividerCount
            + (spacingCount * scaledRowSpacing)
    }
    private var focusID: String { "power-monitoring" }

    private var focusState: HardwareGraphFocusState? {
        let peakPowerWatts = max(
            powerSnapshot?.peakCombinedPowerWatts ?? 0,
            combinedPowerSeries.peakObservedValue ?? 0,
            powerSnapshot?.combinedPowerWatts ?? 0
        )
        let normalizedPowerHistory = normalizedHardwareFocusSeries(
            from: combinedPowerSeries,
            ceiling: peakPowerWatts > 0 ? peakPowerWatts : nil
        )
        let normalizedEnergyHistory = normalizedHardwareFocusSeries(
            from: cumulativeEnergySeries,
            ceiling: max(
                powerSnapshot?.cumulativeCombinedEnergyWh ?? 0,
                cumulativeEnergySeries.peakObservedValue ?? 0
            )
        )
        let hasObservedPowerHistory = normalizedPowerHistory.contains(where: { $0 != nil })
        let hasObservedEnergyHistory = normalizedEnergyHistory.contains(where: { $0 != nil })

        guard hasObservedPowerHistory || powerSnapshot != nil || systemSnapshot != nil else { return nil }

        let visualizationValues: [Double?]
        if hasObservedPowerHistory {
            visualizationValues = normalizedPowerHistory
        } else if let livePower = powerSnapshot?.combinedPowerWatts, peakPowerWatts > 0 {
            let normalizedLive = min(max(livePower / peakPowerWatts, 0), 1)
            visualizationValues = [normalizedLive, normalizedLive]
        } else {
            visualizationValues = []
        }

        var stats: [HardwareGraphFocusStat] = []
        if combinedPowerText != "—" {
            stats.append(.init(label: "Live Power", value: combinedPowerText, tint: .orange))
        }
        if avgPowerText != "—" {
            stats.append(.init(label: "Session Avg", value: avgPowerText, tint: Color(red: 0.96, green: 0.72, blue: 0.18)))
        }
        if let peakPowerWatts = powerSnapshot?.peakCombinedPowerWatts, peakPowerWatts > 0 {
            stats.append(.init(label: "Peak", value: String(format: "%.3f W", peakPowerWatts), tint: Color(red: 0.92, green: 0.46, blue: 0.16)))
        }
        if cumulativeCombinedEnergyText != "—" {
            stats.append(.init(label: "Energy Used", value: cumulativeCombinedEnergyText, tint: Color(red: 0.84, green: 0.56, blue: 0.10)))
        }
        stats.append(.init(label: sessionLabel, value: appLaunchedText))
        if processCountText != "—" {
            stats.append(.init(label: "Processes", value: processCountText, tint: .white.opacity(0.9)))
        }
        if let score = efficiencyScore {
            stats.append(.init(label: "Score", value: score, tint: scoreColor(score)))
        }

        var detailLines: [String] = []
        if combinedPowerText != "—" && cumulativeCombinedEnergyText != "—" {
            detailLines.append("\(sessionLabel) has covered \(appLaunchedText), during which the machine used \(cumulativeCombinedEnergyText) of tracked combined energy.")
        } else {
            detailLines.append("This HUD tracks power from \(sessionLabel.lowercased()) onward rather than plotting uptime itself.")
        }
        if avgPowerText != "—" {
            detailLines.append("\(avgPowerLabel) power currently sits at \(avgPowerText), giving a quick sense of how demanding the monitoring window has been overall.")
        }
        if processCountText != "—" {
            detailLines.append("Latest system snapshot observed \(processCountText) running processes on the machine.")
        }
        if uptimeText != "—" {
            detailLines.append("System uptime is \(uptimeText).")
        }

        let energyPanel: HardwareGraphFocusLinePanelSnapshot? = hasObservedEnergyHistory
            ? HardwareGraphFocusLinePanelSnapshot(
                id: "power-energy-history",
                title: "Tracked Energy History",
                chipTitle: "Energy",
                subtitle: "Cumulative energy recorded since \(sessionLabel.lowercased()).",
                detailText: "This curve rises with the combined watt-hour integral, so steeper segments represent hungrier stretches of the monitoring session.",
                series: [
                    HardwareGraphFocusSeries(
                        id: "power-energy",
                        label: "Tracked Energy",
                        color: Color(red: 0.90, green: 0.62, blue: 0.16),
                        values: normalizedEnergyHistory
                    )
                ]
            )
            : nil

        return HardwareGraphFocusState(
            id: focusID,
            title: "Power & Monitoring",
            subtitle: "Dashboard view of combined power over the visible history window.",
            accentColor: .orange,
            insightTarget: .power,
            heatmapTarget: .power,
            visualization: .lineChart([
                HardwareGraphFocusSeries(
                    id: "combined-power",
                    label: "Combined Power",
                    color: .orange,
                    values: visualizationValues
                )
            ]),
            linePanelSnapshots: energyPanel.map { [$0] } ?? [],
            stats: stats,
            detailLines: detailLines
        )
    }

    private var focusRefreshSignature: Int {
        focusState?.signatureHash ?? 0
    }

    var body: some View {
        VStack(spacing: scaledStackSpacing) {
            if shouldShowBatteryCard {
                ThemeRoundedRectangle(cornerRadius: scaledCardCornerRadius).themed()
                    .frame(height: scaledCardHeight)
                    .overlay(
                        HStack(spacing: 0) {
                            verticalColumn(title: "Battery", value: batteryPercentText)
                                .layoutPriority(1)

                            verticalDivider

                            verticalColumn(title: "Cycles", value: cycleCountText)
                                .layoutPriority(1)
                        }
                        .padding(.horizontal, scaledHorizontalPadding)
                        .padding(.vertical, scaledVerticalPadding)
                    )
            }

            ThemeRoundedRectangle(cornerRadius: scaledCardCornerRadius).themed()
                .frame(height: scaledSystemCardHeight)
                .overlay(
                    VStack(alignment: .leading, spacing: scaledRowSpacing) {
                        // Title with power icon on the right
                        HStack(alignment: .center, spacing: 12 * appUIScale) {
                            Text("Power Stats")
                                .font(.system(size: scaledTitleFontSize, weight: .semibold))
                                .foregroundColor(.primary)

                            Spacer(minLength: 4 * appUIScale)

                            Image(systemName: "bolt.fill")
                                .font(.system(size: 24 * appUIScale, weight: .semibold))
                                .foregroundColor(.orange)
                                .frame(width: 28 * appUIScale, height: 28 * appUIScale)
                        }
                        .frame(height: scaledRowHeight)
                        .padding(.bottom, 2)

                        horizontalDivider

                        HStack(alignment: .firstTextBaseline, spacing: 4 * appUIScale) {
                            HStack(spacing: 4 * appUIScale) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: scaledTitleFontSize * 0.9))
                                    .foregroundColor(.secondary)
                                Text("Combined Power")
                                    .font(.system(size: scaledTitleFontSize, weight: .regular))
                                    .foregroundColor(.secondary)
                            }

                            Spacer(minLength: 4 * appUIScale)

                            Text(combinedPowerText)
                                .font(.system(size: scaledValueFontSize, weight: .semibold))
                                .lineLimit(1)
                        }
                        .frame(height: scaledRowHeight)

                        horizontalDivider

                        HStack(alignment: .firstTextBaseline, spacing: 4 * appUIScale) {
                            HStack(spacing: 4 * appUIScale) {
                                Image(systemName: "waveform")
                                    .font(.system(size: scaledTitleFontSize * 0.9))
                                    .foregroundColor(.secondary)
                                Text(avgPowerLabel)
                                    .font(.system(size: scaledTitleFontSize, weight: .regular))
                                    .foregroundColor(.secondary)
                            }

                            Spacer(minLength: 4 * appUIScale)

                            Text(avgPowerText)
                                .font(.system(size: scaledValueFontSize, weight: .semibold))
                                .lineLimit(1)
                        }
                        .frame(height: scaledRowHeight)

                        horizontalDivider

                        HStack(alignment: .firstTextBaseline, spacing: 4 * appUIScale) {
                            HStack(spacing: 4 * appUIScale) {
                                Image(systemName: "bolt.horizontal")
                                    .font(.system(size: scaledTitleFontSize * 0.9))
                                    .foregroundColor(.secondary)
                                Text("Tracked Energy")
                                    .font(.system(size: scaledTitleFontSize, weight: .regular))
                                    .foregroundColor(.secondary)
                            }

                            Spacer(minLength: 4 * appUIScale)

                            Text(cumulativeCombinedEnergyText)
                                .font(.system(size: scaledValueFontSize, weight: .semibold))
                                .lineLimit(1)
                        }
                        .frame(height: scaledRowHeight)

                        horizontalDivider

                        HStack(alignment: .firstTextBaseline, spacing: 4 * appUIScale) {
                            HStack(spacing: 4 * appUIScale) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: scaledTitleFontSize * 0.9))
                                    .foregroundColor(.secondary)
                                Text(sessionLabel)
                                    .font(.system(size: scaledTitleFontSize, weight: .regular))
                                    .foregroundColor(.secondary)
                            }

                            Spacer(minLength: 4 * appUIScale)

                            Text(monitoringTimeText)
                                .font(.system(size: scaledValueFontSize, weight: .semibold))
                                .lineLimit(1)
                        }
                        .frame(height: scaledRowHeight)

                        horizontalDivider

                        HStack(alignment: .firstTextBaseline, spacing: 4 * appUIScale) {
                            HStack(spacing: 4 * appUIScale) {
                                Image(systemName: "clock.fill")
                                    .font(.system(size: scaledTitleFontSize * 0.9))
                                    .foregroundColor(.secondary)
                                Text("Uptime")
                                    .font(.system(size: scaledTitleFontSize, weight: .regular))
                                    .foregroundColor(.secondary)
                            }

                            Spacer(minLength: 4 * appUIScale)

                            Text(uptimeText)
                                .font(.system(size: scaledValueFontSize, weight: .semibold))
                                .lineLimit(1)
                        }
                        .frame(height: scaledRowHeight)

                        horizontalDivider

                        HStack(alignment: .firstTextBaseline, spacing: 4 * appUIScale) {
                            HStack(spacing: 4 * appUIScale) {
                                Image(systemName: "app.badge.fill")
                                    .font(.system(size: scaledTitleFontSize * 0.9))
                                    .foregroundColor(.secondary)
                                Text("Processes")
                                    .font(.system(size: scaledTitleFontSize, weight: .regular))
                                    .foregroundColor(.secondary)
                            }

                            Spacer(minLength: 4 * appUIScale)

                            Text(processCountText)
                                .font(.system(size: scaledValueFontSize, weight: .semibold))
                                .lineLimit(1)
                        }
                        .frame(height: scaledRowHeight)

                        if let score = efficiencyScore {
                            horizontalDivider

                            HStack(alignment: .firstTextBaseline, spacing: 4 * appUIScale) {
                                HStack(spacing: 4 * appUIScale) {
                                    Image(systemName: "gauge.with.dots.needle.67percent")
                                        .font(.system(size: scaledTitleFontSize * 0.9))
                                        .foregroundColor(.secondary)
                                    Text("Session Score")
                                        .font(.system(size: scaledTitleFontSize, weight: .regular))
                                        .foregroundColor(.secondary)
                                }

                                Spacer(minLength: 4 * appUIScale)

                                Text(score)
                                    .font(.system(size: scaledValueFontSize, weight: .semibold))
                                    .foregroundColor(scoreColor(score))
                                    .lineLimit(1)
                            }
                            .frame(height: scaledRowHeight)
                        }
                    }
                    .padding(.horizontal, scaledHorizontalPadding)
                    .padding(.vertical, scaledVerticalPadding)
                )
        }
        .contentShape(Rectangle())
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
            refreshFocusedStateIfNeeded()
        }
    }

    private func scoreColor(_ score: String) -> Color {
        switch score {
        case "A": return Color(red: 0.20, green: 0.78, blue: 0.40)
        case "B": return Color(red: 0.50, green: 0.78, blue: 0.20)
        case "C": return .orange
        default:  return Color(red: 0.85, green: 0.30, blue: 0.20)
        }
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1)
            .padding(.vertical, 6 * appUIScale)
    }

    private var horizontalDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
            .padding(.horizontal, -scaledHorizontalPadding)
    }

    private func verticalColumn(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6 * appUIScale) {
            Text(title)
                .font(.system(size: scaledTitleFontSize, weight: .regular))
                .foregroundColor(.secondary)

            Text(value)
                .font(.system(size: scaledValueFontSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10 * appUIScale)
    }

    private var batteryPercentText: String {
        guard let batteryPercent = systemSnapshot?.batteryPercent else { return "—" }
        return "\(batteryPercent)%"
    }

    private var cycleCountText: String {
        guard let cycleCount = systemSnapshot?.cycleCount else { return "—" }
        return "\(cycleCount)"
    }

    private var processCountText: String {
        guard let processCount = systemSnapshot?.processCount else { return "—" }
        return "\(processCount)"
    }

    private var combinedPowerText: String {
        powerSnapshot?.combinedPowerWattsText ?? "—"
    }

    private var cumulativeCombinedEnergyText: String {
        powerSnapshot?.cumulativeCombinedEnergyText ?? "—"
    }

    private var uptimeText: String {
        systemSnapshot?.uptimeText ?? "—"
    }

    private var resolvedMonitoringElapsedSeconds: TimeInterval? {
        if let agentUptime = hardwareAgentUptimeSeconds, agentUptime > 0 {
            return agentUptime
        }

        let elapsedSeconds = max(0, Date().timeIntervalSince(sessionStartDate))
        return elapsedSeconds > 0 ? elapsedSeconds : nil
    }

    // Derives the display text from the authoritative monitoring window when available.
    private var appLaunchedText: String {
        PowerStatsSampler.formatUptime(resolvedMonitoringElapsedSeconds ?? 0)
    }

    private var monitoringTimeText: String {
        return appLaunchedText
    }

    private var averageWindowSeconds: TimeInterval? {
        if let elapsedSeconds = resolvedMonitoringElapsedSeconds, elapsedSeconds >= 60 {
            return elapsedSeconds
        }

        guard cumulativeEnergySeries.samples.count >= 2,
              let firstSample = cumulativeEnergySeries.samples.first,
              let lastSample = cumulativeEnergySeries.samples.last else { return nil }

        let sampleWindowSeconds = lastSample.timestamp.timeIntervalSince(firstSample.timestamp)
        return sampleWindowSeconds >= 60 ? sampleWindowSeconds : nil
    }

    private func formatAverageWindowLabel(seconds: TimeInterval) -> String {
        let clampedSeconds = max(0, Int(seconds))
        let days = clampedSeconds / 86_400
        let hours = (clampedSeconds % 86_400) / 3_600
        let minutes = (clampedSeconds % 3_600) / 60

        if days > 0 {
            return "\(days)d \(hours)h Avg"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m Avg"
        }
        return "\(max(1, minutes))m Avg"
    }

    // Session average power computed from the cumulative energy integral:
    // avg_W = energy_Wh × 3600 / elapsed_s.
    private var avgPowerText: String {
        guard let energyWh = powerSnapshot?.cumulativeCombinedEnergyWh, energyWh > 0 else { return "—" }
        guard let windowSeconds = averageWindowSeconds else { return "—" }

        let avgWatts = (energyWh * 3600.0) / windowSeconds
        return String(format: "%.3f W", avgWatts)
    }

    private var avgPowerLabel: String {
        guard let windowSeconds = averageWindowSeconds else { return "—" }
        return formatAverageWindowLabel(seconds: windowSeconds)
    }

    private var shouldShowBatteryCard: Bool {
        let batteryMissingOrZero: Bool = {
            guard let batteryPercent = systemSnapshot?.batteryPercent else { return true }
            return batteryPercent <= 0
        }()

        let cyclesMissingOrZero: Bool = {
            guard let cycleCount = systemSnapshot?.cycleCount else { return true }
            return cycleCount <= 0
        }()

        return !(batteryMissingOrZero && cyclesMissingOrZero)
    }

    private func refreshFocusedStateIfNeeded() {
        guard let focusState,
              focusState.id == activeFocusID,
              let onFocusedStateChange else { return }
        onFocusedStateChange(focusState)
    }
}

func normalizedHardwareFocusSeries(from series: MetricSeries, ceiling: Double?) -> [Double?] {
    let resolvedCeiling = max(ceiling ?? 0, series.peakObservedValue ?? 0)
    guard resolvedCeiling > 0 else {
        return series.samples.map { _ in nil }
    }

    return series.samples.map { sample in
        guard let value = sample.value else { return nil }
        return min(max(value / resolvedCeiling, 0), 1)
    }
}

func makeSharedNeuralEngineFocusVisualSnapshot(
    statusSnapshot: ANEStatsSampler.StatusSnapshot?
) -> HardwareGraphFocusNeuralEngineVisualSnapshot? {
    guard let statusSnapshot else { return nil }

    let totalCoreCount = statusSnapshot.coreCount
    let visibleCoreCount = min(max(totalCoreCount ?? 0, 0), 32)
    return HardwareGraphFocusNeuralEngineVisualSnapshot(
        id: "neural-engine-core-rail",
        title: "Apple Intelligence Cores",
        subtitle: "Live capsule rail mirrored from the current Neural Engine snapshot.",
        visibleCoreCount: visibleCoreCount,
        totalCoreCount: totalCoreCount,
        architectureText: statusSnapshot.architectureText == "—" ? nil : statusSnapshot.architectureText,
        statusText: statusSnapshot.statusText,
        currentPowerText: statusSnapshot.powerText == "—" ? nil : statusSnapshot.powerText,
        clientCount: statusSnapshot.clientCount,
        clients: statusSnapshot.clients,
        isIdle: statusSnapshot.statusText.lowercased() == "idle",
        isActive: statusSnapshot.currentPowerMilliwatts > 0
    )
}

func makeSharedNeuralEngineFocusState(
    statusSnapshot: ANEStatsSampler.StatusSnapshot?,
    activitySeries: MetricSeries,
    powerSeries: MetricSeries,
    title: String = "Neural Engine",
    subtitle: String = "Focused view of the visible Neural Engine history window."
) -> HardwareGraphFocusState? {
    let normalizedActivityHistory = activitySeries.samples.map { sample in
        sample.value.map { min(max($0, 0), 1) }
    }
    let observedActivityValues = activitySeries.observedValues()
    let liveActivityValue = statusSnapshot?.activityValue ?? activitySeries.latestObservedValue
    let sampleCount = activitySeries.samples.count

    guard !observedActivityValues.isEmpty || liveActivityValue != nil || statusSnapshot != nil else { return nil }

    let visualizationValues: [Double?]
    if normalizedActivityHistory.contains(where: { $0 != nil }) {
        visualizationValues = normalizedActivityHistory
    } else if let liveActivityValue {
        let normalizedLive = min(max(liveActivityValue, 0), 1)
        visualizationValues = [normalizedLive, normalizedLive]
    } else {
        visualizationValues = []
    }

    var stats: [HardwareGraphFocusStat] = []
    if let liveActivityValue {
        stats.append(.init(label: "Live", value: String(format: "%.0f%%", min(max(liveActivityValue, 0), 1) * 100), tint: Color(red: 0.70, green: 0.22, blue: 0.86)))
    }
    if !observedActivityValues.isEmpty {
        let averageValue = observedActivityValues.reduce(0, +) / Double(observedActivityValues.count)
        stats.append(.init(label: "Window Avg", value: String(format: "%.0f%%", averageValue * 100), tint: Color(red: 0.58, green: 0.18, blue: 0.80)))
        stats.append(.init(label: "Peak", value: String(format: "%.0f%%", (observedActivityValues.max() ?? 0) * 100), tint: Color(red: 0.86, green: 0.42, blue: 0.92)))
    }
    if let coreCount = statusSnapshot?.coreCount, coreCount > 0 {
        stats.append(.init(label: "Cores", value: "\(coreCount)"))
    }
    if let clientCount = statusSnapshot?.clientCount {
        stats.append(.init(label: "Clients", value: "\(clientCount)"))
    }
    if let powerText = statusSnapshot?.powerText, powerText != "—" {
        stats.append(.init(label: "Power", value: powerText, tint: Color(red: 0.34, green: 0.72, blue: 1.0)))
    }
    if sampleCount > 0 {
        stats.append(.init(label: "Samples", value: "\(sampleCount)"))
    }

    var detailLines: [String] = []
    if let architectureText = statusSnapshot?.architectureText, architectureText != "—" {
        detailLines.append("Architecture reports as \(architectureText).")
    }
    if let statusText = statusSnapshot?.statusText {
        if let powerText = statusSnapshot?.powerText, powerText != "—" {
            detailLines.append("Engine currently reports \(statusText.lowercased()) status at \(powerText).")
        } else {
            detailLines.append("Engine currently reports \(statusText.lowercased()) status.")
        }
    }
    if let peakPowerText = statusSnapshot?.peakPowerText, peakPowerText != "—" {
        detailLines.append("Observed peak ANE power in this session is \(peakPowerText).")
    }
    if let powerDeltaText = statusSnapshot?.powerDeltaText, powerDeltaText != "—" {
        detailLines.append("Latest power delta versus the previous sample is \(powerDeltaText).")
    }
    if let clientCount = statusSnapshot?.clientCount {
        if clientCount > 0 {
            detailLines.append("Observed \(clientCount) active ML client\(clientCount == 1 ? "" : "s") in the latest sample.")
        } else {
            detailLines.append("No active ML client processes were visible in the latest sample.")
        }
    }

    let powerHistoryCeiling = max(
        powerSeries.peakObservedValue ?? 0,
        statusSnapshot.map { $0.currentPowerMilliwatts / 1000.0 } ?? 0,
        statusSnapshot.map { $0.peakPowerMilliwatts / 1000.0 } ?? 0
    )
    let normalizedPowerHistory = normalizedHardwareFocusSeries(from: powerSeries, ceiling: powerHistoryCeiling > 0 ? powerHistoryCeiling : nil)
    let powerHistoryPanel: HardwareGraphFocusLinePanelSnapshot? =
        normalizedPowerHistory.contains(where: { $0 != nil })
        ? HardwareGraphFocusLinePanelSnapshot(
            id: "neural-engine-power-history",
            title: "ANE Power History",
            chipTitle: "Power",
            subtitle: "Recorded Neural Engine power normalized against the current observed peak.",
            detailText: "This curve reflects ANE wattage over the visible window, which helps separate busy-but-efficient inference from genuinely power-hungry bursts.",
            series: [
                HardwareGraphFocusSeries(
                    id: "neural-engine-power",
                    label: "ANE Power",
                    color: Color(red: 0.26, green: 0.72, blue: 1.0),
                    values: normalizedPowerHistory
                )
            ]
        )
        : nil

    return HardwareGraphFocusState(
        id: "neural-engine",
        title: title,
        subtitle: subtitle,
        accentColor: Color(red: 0.65, green: 0.00, blue: 0.65),
        insightTarget: .ane,
        heatmapTarget: .ane,
        visualization: .lineChart([
            HardwareGraphFocusSeries(
                id: "neural-engine-activity",
                label: "ANE Activity",
                color: Color(red: 0.65, green: 0.00, blue: 0.65),
                values: visualizationValues
            )
        ]),
        linePanelSnapshots: powerHistoryPanel.map { [$0] } ?? [],
        detailVisuals: makeSharedNeuralEngineFocusVisualSnapshot(statusSnapshot: statusSnapshot).map { [.neuralEngine($0)] } ?? [],
        stats: stats,
        detailLines: detailLines
    )
}

nonisolated private func sharedSysctlString(_ name: String) -> String? {
    var size: size_t = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer).trimmingCharacters(in: .controlCharacters)
}

nonisolated private func sharedSysctlInt(_ name: String) -> Int? {
    var value: Int = 0
    var size = MemoryLayout<Int>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
}

nonisolated private func sharedSysctlUInt64(_ name: String) -> UInt64? {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    if sysctlbyname(name, &value, &size, nil, 0) == 0 {
        return value
    }

    var fallback: UInt32 = 0
    var fallbackSize = MemoryLayout<UInt32>.size
    guard sysctlbyname(name, &fallback, &fallbackSize, nil, 0) == 0 else { return nil }
    return UInt64(fallback)
}

private func sharedMachineModelType(from identifier: String?) -> String {
    guard let identifier, !identifier.isEmpty else { return "Mac" }
    if let info = MacModelDictionary.lookup(identifier) {
        return info.modelName
    }
    if identifier.hasPrefix("MacBookAir") { return "MacBook Air" }
    if identifier.hasPrefix("MacBookPro") { return "MacBook Pro" }
    if identifier.hasPrefix("MacBook") { return "MacBook" }
    if identifier.hasPrefix("Macmini") { return "Mac mini" }
    if identifier.hasPrefix("MacPro") { return "Mac Pro" }
    if identifier.hasPrefix("iMac") { return "iMac" }
    if identifier.hasPrefix("MacStudio") { return "Mac Studio" }
    if identifier.hasPrefix("Mac") { return "Mac" }
    return "Mac"
}

private func sharedMachineFamily(from identifier: String?) -> MacFamily {
    guard let identifier, !identifier.isEmpty else { return .mac }
    if let info = MacModelDictionary.lookup(identifier) {
        return info.family
    }
    if identifier.hasPrefix("MacBookPro") { return .macBookPro }
    if identifier.hasPrefix("MacBookAir") { return .macBookAir }
    if identifier.hasPrefix("MacBook") { return .macBook }
    if identifier.hasPrefix("Macmini") { return .macMini }
    if identifier.hasPrefix("MacPro") { return .macPro }
    if identifier.hasPrefix("iMac") { return .iMac }
    if identifier.hasPrefix("Mac13") || identifier.hasPrefix("Mac14,13") || identifier.hasPrefix("Mac14,14") || identifier.hasPrefix("Mac15,14") || identifier.hasPrefix("Mac16,9") {
        return .macStudio
    }
    return .mac
}

private func sharedMachineYear(from identifier: String?) -> String {
    guard let identifier, let info = MacModelDictionary.lookup(identifier) else { return "Unknown" }
    return info.releaseYear
}

private func sharedFormatBytes(_ bytes: UInt64?) -> String {
    guard let bytes else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
}

private func sharedFormatGigabytes(_ value: Double?) -> String {
    guard let value else { return "—" }
    return String(format: "%.1f GB", value)
}

private func sharedFormattedCoreBreakdown(physical: Int?, logical: Int?, performance: Int?, efficiency: Int?) -> String {
    var parts: [String] = []
    if let physical, physical > 0 {
        parts.append("\(physical) physical")
    }
    if let logical, logical > 0 {
        parts.append("\(logical) logical")
    }
    if let performance, performance > 0 || (efficiency ?? 0) > 0 {
        let perfText = String(performance)
        let effText = efficiency.map(String.init) ?? "0"
        parts.append("P\(perfText) / E\(effText)")
    }
    return parts.isEmpty ? "—" : parts.joined(separator: " · ")
}

private func sharedReadableCPUName(_ rawName: String?) -> String {
    guard let rawName, !rawName.isEmpty else { return "—" }
    let trimmed = rawName.replacingOccurrences(of: "(TM)", with: "")
        .replacingOccurrences(of: "(R)", with: "")
        .replacingOccurrences(of: "Apple ", with: "Apple ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? rawName : trimmed
}

struct SharedResolvedGPUIdentity {
    let liveGPU: GPUStatsSampler.GPUUnit?
    let metadata: GPUUnitMetadata?

    var displayName: String {
        sharedReadableGPUName(metadata?.name ?? liveGPU?.name)
    }

    var coreCount: Int? {
        liveGPU?.coreCount ?? metadata?.coreCount
    }
}

struct SharedGPUMemorySummary {
    let label: String
    let value: String
}

private func sharedComparableGPUName(_ rawName: String?) -> String {
    guard let rawName, !rawName.isEmpty else { return "" }
    let separated = rawName
        .replacingOccurrences(of: "([A-Z]+)([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
        .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        .replacingOccurrences(of: "([A-Za-z])(\\d)", with: "$1 $2", options: .regularExpression)
        .replacingOccurrences(of: "(\\d)([A-Za-z])", with: "$1 $2", options: .regularExpression)
        .replacingOccurrences(of: "[^A-Za-z0-9]+", with: " ", options: .regularExpression)
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return separated.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
}

private func sharedGPUNameTokens(_ rawName: String?) -> Set<String> {
    Set(
        sharedComparableGPUName(rawName)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 1 || Int($0) != nil }
    )
}

private func sharedReadableGPUComponent(_ value: String) -> String {
    switch value.lowercased() {
    case "amd": return "AMD"
    case "intel": return "Intel"
    case "nvidia": return "NVIDIA"
    case "apple": return "Apple"
    case "gpu": return "GPU"
    case "hd": return "HD"
    case "uhd": return "UHD"
    default:
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst().lowercased()
    }
}

func sharedReadableGPUName(_ rawName: String?) -> String {
    guard let rawName, !rawName.isEmpty else { return "GPU" }
    let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "GPU" }
    if trimmed.contains(" ") {
        return trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
    let comparable = sharedComparableGPUName(trimmed)
    guard !comparable.isEmpty else { return trimmed }
    return comparable
        .split(separator: " ")
        .map { sharedReadableGPUComponent(String($0)) }
        .joined(separator: " ")
}

private func sharedGPUVendorHint(name: String?, vendor: String?) -> String? {
    if let vendor, !vendor.isEmpty {
        return vendor.lowercased()
    }
    let comparable = sharedComparableGPUName(name)
    if comparable.contains("apple") { return "apple" }
    if comparable.contains("amd") || comparable.contains("radeon") { return "amd" }
    if comparable.contains("intel") { return "intel" }
    if comparable.contains("nvidia") || comparable.contains("geforce") || comparable.contains("quadro") { return "nvidia" }
    return nil
}

private func sharedGPUVRAMMegabytes(_ description: String?) -> Double? {
    guard let description, !description.isEmpty else { return nil }
    let normalized = description.lowercased()
    guard let numericText = normalized.range(of: "[0-9]+(?:\\.[0-9]+)?", options: .regularExpression).map({ String(normalized[$0]) }),
          let numericValue = Double(numericText) else { return nil }
    if normalized.contains("tb") { return numericValue * 1_048_576.0 }
    if normalized.contains("gb") { return numericValue * 1024.0 }
    if normalized.contains("mb") { return numericValue }
    return nil
}

private func sharedDedicatedGPUMemoryCeilingMB(liveGPU: GPUStatsSampler.GPUUnit?, metadata: GPUUnitMetadata?) -> Double? {
    if let total = liveGPU?.vramTotalMB, total > 0 {
        return Double(total)
    }
    if let used = liveGPU?.vramUsedMB, let free = liveGPU?.vramFreeMB, used + free > 0 {
        return Double(used + free)
    }
    if let staticVRAM = sharedGPUVRAMMegabytes(metadata?.vramDescription), staticVRAM > 0 {
        return staticVRAM
    }
    return nil
}

private func sharedGPUIdentityScore(_ liveGPU: GPUStatsSampler.GPUUnit, metadata: GPUUnitMetadata) -> Int {
    var score = 0
    let liveComparable = sharedComparableGPUName(liveGPU.name)
    let metadataComparable = sharedComparableGPUName(metadata.name)

    if !liveComparable.isEmpty, !metadataComparable.isEmpty {
        if liveComparable == metadataComparable {
            score += 120
        } else {
            let commonTokens = sharedGPUNameTokens(liveGPU.name).intersection(sharedGPUNameTokens(metadata.name))
            score += commonTokens.count * 20
            if liveComparable.contains(metadataComparable) || metadataComparable.contains(liveComparable) {
                score += 30
            }
        }
    }

    if let liveVendor = sharedGPUVendorHint(name: liveGPU.name, vendor: nil),
       let metadataVendor = sharedGPUVendorHint(name: metadata.name, vendor: metadata.vendor),
       liveVendor == metadataVendor {
        score += 25
    }

    if let liveCoreCount = liveGPU.coreCount,
       let metadataCoreCount = metadata.coreCount,
       liveCoreCount == metadataCoreCount {
        score += 20
    }

    if let liveVRAM = sharedDedicatedGPUMemoryCeilingMB(liveGPU: liveGPU, metadata: nil),
       let metadataVRAM = sharedGPUVRAMMegabytes(metadata.vramDescription) {
        let delta = abs(liveVRAM - metadataVRAM)
        if delta <= 256 {
            score += 25
        } else if delta <= 1024 {
            score += 10
        }
    }

    if let displays = metadata.connectedDisplayCount, displays > 0,
       let liveVRAM = liveGPU.vramUsedMB, liveVRAM > 0 {
        score += 5
    }

    return score
}

func sharedResolveGPUIdentities(liveGPUs: [GPUStatsSampler.GPUUnit], metadataUnits: [GPUUnitMetadata]) -> [SharedResolvedGPUIdentity] {
    guard !liveGPUs.isEmpty else {
        return metadataUnits.map { SharedResolvedGPUIdentity(liveGPU: nil, metadata: $0) }
    }

    var remainingMetadataIndices = Array(metadataUnits.indices)
    var resolved: [SharedResolvedGPUIdentity] = []
    resolved.reserveCapacity(max(liveGPUs.count, metadataUnits.count))

    for liveGPU in liveGPUs {
        let rankedCandidates = remainingMetadataIndices
            .map { ($0, sharedGPUIdentityScore(liveGPU, metadata: metadataUnits[$0])) }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0 < rhs.0
                }
                return lhs.1 > rhs.1
            }

        if let best = rankedCandidates.first,
           best.1 > 0 || (liveGPUs.count == 1 && metadataUnits.count == 1) {
            resolved.append(SharedResolvedGPUIdentity(liveGPU: liveGPU, metadata: metadataUnits[best.0]))
            remainingMetadataIndices.removeAll { $0 == best.0 }
        } else {
            resolved.append(SharedResolvedGPUIdentity(liveGPU: liveGPU, metadata: nil))
        }
    }

    for index in remainingMetadataIndices {
        resolved.append(SharedResolvedGPUIdentity(liveGPU: nil, metadata: metadataUnits[index]))
    }

    return resolved
}

func sharedResolvedGPUIdentity(
    for liveGPU: GPUStatsSampler.GPUUnit,
    liveGPUs: [GPUStatsSampler.GPUUnit],
    metadataUnits: [GPUUnitMetadata]
) -> SharedResolvedGPUIdentity {
    sharedResolveGPUIdentities(liveGPUs: liveGPUs, metadataUnits: metadataUnits)
        .first { $0.liveGPU?.id == liveGPU.id }
        ?? SharedResolvedGPUIdentity(liveGPU: liveGPU, metadata: nil)
}

func sharedGPUDisplayTitle(for identity: SharedResolvedGPUIdentity) -> String {
    if let coreCount = identity.coreCount, coreCount > 0 {
        return "GPU — \(identity.displayName) (\(coreCount)-core)"
    }
    return "GPU — \(identity.displayName)"
}

func sharedUsesUnifiedGPUMemoryEstimate(
    liveGPU: GPUStatsSampler.GPUUnit?,
    metadata: GPUUnitMetadata?,
    memorySnapshot: RAMStatsSampler.MemorySnapshot?,
    cpuDisplayName: String?
) -> Bool {
    guard sharedDedicatedGPUMemoryCeilingMB(liveGPU: liveGPU, metadata: metadata) == nil else { return false }
    guard memorySnapshot != nil else { return false }

    let nameHints = [
        liveGPU?.name.lowercased(),
        metadata?.name?.lowercased(),
        metadata?.vendor?.lowercased(),
        cpuDisplayName?.lowercased()
    ].compactMap { $0 }

    if nameHints.contains(where: { $0.contains("apple") }) {
        return true
    }

    return nameHints.contains(where: { $0.contains("apple m") })
}

private func sharedEstimatedUnifiedGPUMemoryBudgetMB(
    currentAllocationMB: Double,
    memorySnapshot: RAMStatsSampler.MemorySnapshot
) -> Double {
    let totalMB = Double(memorySnapshot.totalBytes) / 1_048_576.0
    let freeMB = Double(memorySnapshot.freeBytes) / 1_048_576.0
    let cachedMB = Double(memorySnapshot.cachedBytes) / 1_048_576.0
    let purgeableMB = Double(memorySnapshot.purgeableBytes ?? 0) / 1_048_576.0
    let reusableMB = Double(memorySnapshot.reusableBytes ?? 0) / 1_048_576.0

    let weightedHeadroomMB = freeMB + (cachedMB * 0.85) + ((purgeableMB + reusableMB) * 0.50)
    let safetyReserveMB = max(2_048.0, totalMB * 0.08)
    let pressureDiscount = min(max(memorySnapshot.pressureValue, 0), 1) * 0.45
    let adjustedHeadroomMB = weightedHeadroomMB * (1.0 - pressureDiscount)
    let dynamicBudgetMB = currentAllocationMB + max(0, adjustedHeadroomMB - safetyReserveMB)
    let hardCapMB = max(currentAllocationMB, totalMB - safetyReserveMB)
    return max(currentAllocationMB, min(dynamicBudgetMB, hardCapMB))
}

func sharedGPUMemoryCeilingMB(
    liveGPU: GPUStatsSampler.GPUUnit?,
    metadata: GPUUnitMetadata?,
    memorySnapshot: RAMStatsSampler.MemorySnapshot?,
    cpuDisplayName: String?
) -> Double? {
    if let dedicatedCeiling = sharedDedicatedGPUMemoryCeilingMB(liveGPU: liveGPU, metadata: metadata) {
        return dedicatedCeiling
    }
    guard sharedUsesUnifiedGPUMemoryEstimate(
        liveGPU: liveGPU,
        metadata: metadata,
        memorySnapshot: memorySnapshot,
        cpuDisplayName: cpuDisplayName
    ),
    let memorySnapshot else { return nil }

    let currentAllocationMB = Double(liveGPU?.gpuMemoryAllocatedMB ?? liveGPU?.vramUsedMB ?? 0)
    return sharedEstimatedUnifiedGPUMemoryBudgetMB(currentAllocationMB: currentAllocationMB, memorySnapshot: memorySnapshot)
}

private func sharedDisplayedGPUMemoryMB(
    liveGPU: GPUStatsSampler.GPUUnit?,
    metadata: GPUUnitMetadata?,
    memorySnapshot: RAMStatsSampler.MemorySnapshot?,
    cpuDisplayName: String?
) -> Double? {
    if sharedUsesUnifiedGPUMemoryEstimate(
        liveGPU: liveGPU,
        metadata: metadata,
        memorySnapshot: memorySnapshot,
        cpuDisplayName: cpuDisplayName
    ) {
        return Double(liveGPU?.gpuMemoryAllocatedMB ?? liveGPU?.vramUsedMB ?? 0)
    }
    if let used = liveGPU?.vramUsedMB {
        return Double(used)
    }
    return nil
}

func sharedGPUMemorySummary(
    liveGPU: GPUStatsSampler.GPUUnit?,
    metadata: GPUUnitMetadata?,
    memorySnapshot: RAMStatsSampler.MemorySnapshot?,
    cpuDisplayName: String?
) -> SharedGPUMemorySummary? {
    let usesUnifiedEstimate = sharedUsesUnifiedGPUMemoryEstimate(
        liveGPU: liveGPU,
        metadata: metadata,
        memorySnapshot: memorySnapshot,
        cpuDisplayName: cpuDisplayName
    )
    let ceilingMB = sharedGPUMemoryCeilingMB(
        liveGPU: liveGPU,
        metadata: metadata,
        memorySnapshot: memorySnapshot,
        cpuDisplayName: cpuDisplayName
    )
    let displayedMB = sharedDisplayedGPUMemoryMB(
        liveGPU: liveGPU,
        metadata: metadata,
        memorySnapshot: memorySnapshot,
        cpuDisplayName: cpuDisplayName
    )

    if usesUnifiedEstimate {
        if let displayedMB, let ceilingMB {
            return SharedGPUMemorySummary(
                label: "GPU Mem",
                value: String(format: "Alloc %.1f / %.1f GB est.", displayedMB / 1024.0, ceilingMB / 1024.0)
            )
        }
        if let allocated = liveGPU?.gpuMemoryAllocatedMB {
            return SharedGPUMemorySummary(label: "GPU Mem", value: String(format: "Alloc %.1f GB", Double(allocated) / 1024.0))
        }
    }

    if let displayedMB, let ceilingMB {
        return SharedGPUMemorySummary(
            label: "VRAM",
            value: String(format: "%.1f / %.1f GB", displayedMB / 1024.0, ceilingMB / 1024.0)
        )
    }

    if let ceilingMB {
        return SharedGPUMemorySummary(label: usesUnifiedEstimate ? "GPU Mem" : "VRAM", value: sharedFormatGigabytes(ceilingMB / 1024.0))
    }

    return nil
}

func sharedGPUMemorySupplementalRows(
    liveGPU: GPUStatsSampler.GPUUnit?,
    metadata: GPUUnitMetadata?,
    memorySnapshot: RAMStatsSampler.MemorySnapshot?,
    cpuDisplayName: String?
) -> [(label: String, value: String)] {
    let usesUnifiedEstimate = sharedUsesUnifiedGPUMemoryEstimate(
        liveGPU: liveGPU,
        metadata: metadata,
        memorySnapshot: memorySnapshot,
        cpuDisplayName: cpuDisplayName
    )
    var rows: [(label: String, value: String)] = []

    if usesUnifiedEstimate {
        if let allocated = liveGPU?.gpuMemoryAllocatedMB, allocated > 0 {
            rows.append((label: "Allocated", value: sharedFormatGigabytes(Double(allocated) / 1024.0)))
        }
        if let inUse = liveGPU?.gpuMemoryInUseMB, inUse > 0 {
            rows.append((label: "In Use", value: sharedFormatGigabytes(Double(inUse) / 1024.0)))
        }
        if let driver = liveGPU?.gpuMemoryDriverInUseMB, driver > 0 {
            rows.append((label: "Driver", value: sharedFormatGigabytes(Double(driver) / 1024.0)))
        }
    } else {
        if let free = liveGPU?.vramFreeMB, free > 0 {
            rows.append((label: "Free", value: sharedFormatGigabytes(Double(free) / 1024.0)))
        }
    }

    return rows
}

func sharedGPUMemoryDetailText(
    liveGPU: GPUStatsSampler.GPUUnit?,
    metadata: GPUUnitMetadata?,
    memorySnapshot: RAMStatsSampler.MemorySnapshot?,
    cpuDisplayName: String?
) -> String? {
    var parts: [String] = []
    if let summary = sharedGPUMemorySummary(
        liveGPU: liveGPU,
        metadata: metadata,
        memorySnapshot: memorySnapshot,
        cpuDisplayName: cpuDisplayName
    ) {
        parts.append("\(summary.label) \(summary.value)")
    }
    parts.append(contentsOf: sharedGPUMemorySupplementalRows(
        liveGPU: liveGPU,
        metadata: metadata,
        memorySnapshot: memorySnapshot,
        cpuDisplayName: cpuDisplayName
    ).map { "\($0.label) \($0.value)" })
    return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
}

func sharedMemoryHardwareRows(for unit: MemoryUnitMetadata) -> [(label: String, value: String)] {
    var rows: [(label: String, value: String)] = []
    if let total = unit.totalMemory { rows.append((label: "Total", value: total)) }
    if let type = unit.type { rows.append((label: "Type", value: type)) }
    if let architecture = unit.architecture { rows.append((label: "Architecture", value: architecture)) }
    if let speed = unit.speed { rows.append((label: "Speed", value: speed)) }
    if let ecc = unit.ecc { rows.append((label: "ECC", value: ecc)) }
    if let moduleSummary = unit.moduleSummary { rows.append((label: "Modules", value: moduleSummary)) }
    if let populated = unit.populatedSlotCount, let slotCount = unit.slotCount, slotCount > 0 {
        rows.append((label: "Slots", value: "\(populated) / \(slotCount)"))
    } else if let populated = unit.populatedSlotCount {
        rows.append((label: "Slots", value: "\(populated)"))
    }
    if let upgradeable = unit.upgradeable { rows.append((label: "Upgradeable", value: upgradeable ? "Yes" : "No")) }
    if let manufacturer = unit.manufacturerSummary { rows.append((label: "Manufacturer", value: manufacturer)) }
    if let chip = unit.chip { rows.append((label: "Chip", value: chip)) }
    return rows
}

func sharedMemoryLiveRows(from snapshot: RAMStatsSampler.MemorySnapshot?) -> [(label: String, value: String)] {
    guard let snapshot else { return [] }
    var rows: [(label: String, value: String)] = []
    rows.append((label: "Used", value: snapshot.ramLabel))
    rows.append((label: "Cached", value: sharedFormatGigabytes(Double(snapshot.cachedBytes) / 1_073_741_824.0)))
    rows.append((label: "Compressed", value: sharedFormatGigabytes(Double(snapshot.compressedBytes) / 1_073_741_824.0)))
    rows.append((label: "Wired", value: sharedFormatGigabytes(Double(snapshot.wiredBytes) / 1_073_741_824.0)))
    if let appMemoryBytes = snapshot.appMemoryBytes {
        rows.append((label: "Apps", value: sharedFormatGigabytes(Double(appMemoryBytes) / 1_073_741_824.0)))
    }
    rows.append((label: "Pressure", value: snapshot.pressureLabel))
    if snapshot.swapLabel != "—" {
        rows.append((label: "Swap", value: snapshot.swapLabel))
    }
    return rows
}

private func sharedHasNonNominalMemoryModuleStatus(_ status: String?) -> Bool {
    guard let normalized = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          normalized.isEmpty == false else { return false }
    return normalized != "ok" && normalized != "enabled"
}

private func sharedMemoryModuleDetailParts(
    _ module: MemoryModule,
    includeManufacturer: Bool
) -> [String] {
    var parts: [String] = []
    if let size = module.size { parts.append(size) }
    if let type = module.type { parts.append(type) }
    if let speed = module.speed { parts.append(speed) }
    if includeManufacturer, let manufacturer = module.manufacturer, !manufacturer.isEmpty {
        parts.append(manufacturer)
    }
    if sharedHasNonNominalMemoryModuleStatus(module.status), let status = module.status {
        parts.append(status)
    }
    return parts
}

private func sharedMemoryModuleDetailLines(for unit: MemoryUnitMetadata) -> [String] {
    guard unit.modules.isEmpty == false else { return [] }

    let includeManufacturer = Set(unit.modules.compactMap {
        $0.manufacturer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }).count > 1

    let descriptors = unit.modules.map {
        sharedMemoryModuleDetailParts($0, includeManufacturer: includeManufacturer).joined(separator: " · ")
    }
    let hasStatusAttention = unit.modules.contains { sharedHasNonNominalMemoryModuleStatus($0.status) }
    let shouldShowLines = hasStatusAttention || Set(descriptors.filter { !$0.isEmpty }).count > 1
    guard shouldShowLines else { return [] }

    return unit.modules.enumerated().compactMap { index, module in
        let parts = sharedMemoryModuleDetailParts(module, includeManufacturer: includeManufacturer)
        guard parts.isEmpty == false else { return nil }
        return "Module \(index + 1): \(parts.joined(separator: " · "))"
    }
}

func sharedMemoryDetailLines(for unit: MemoryUnitMetadata, snapshot: RAMStatsSampler.MemorySnapshot? = nil) -> [String] {
    var lines = sharedMemoryHardwareRows(for: unit).map { "\($0.label): \($0.value)" }
    lines.append(contentsOf: sharedMemoryLiveRows(from: snapshot).map { "\($0.label): \($0.value)" })
    lines.append(contentsOf: sharedMemoryModuleDetailLines(for: unit))
    return lines
}

private struct SystemInventoryFocusSnapshot {
    let modelIdentifier: String
    let cpuName: String?
    let chipName: String?
    let architectureText: String
    let physicalCoreCount: Int?
    let logicalCoreCount: Int?
    let performanceCoreCount: Int?
    let efficiencyCoreCount: Int?
    let memoryBytes: UInt64?
    let buildVersion: String?
    let kernelVersion: String?
}

@MainActor
private final class SystemInventoryFocusLoader: ObservableObject {
    @Published private(set) var snapshot: SystemInventoryFocusSnapshot?
    @Published private(set) var isLoading = false

    private var loadToken = UUID()

    func refresh() {
        let token = UUID()
        loadToken = token
        snapshot = nil
        isLoading = true

        DispatchQueue.global(qos: .utility).async {
            let probed = Self.probe()
            DispatchQueue.main.async {
                guard self.loadToken == token else { return }
                self.snapshot = probed
                self.isLoading = false
            }
        }
    }

    nonisolated private static func probe() -> SystemInventoryFocusSnapshot {
        let isAppleSilicon = sharedSysctlInt("hw.optional.arm64") == 1
        let modelIdentifier = sharedSysctlString("hw.model") ?? "Unknown"
        let cpuName = sharedSysctlString("machdep.cpu.brand_string")
        let chipName = sharedSysctlString("hw.targettype") ?? cpuName
        let architectureText = isAppleSilicon ? "Apple Silicon / arm64" : "Intel / x86_64"
        let physicalCoreCount = sharedSysctlInt("hw.physicalcpu_max") ?? sharedSysctlInt("hw.physicalcpu")
        let logicalCoreCount = sharedSysctlInt("hw.logicalcpu_max") ?? sharedSysctlInt("hw.logicalcpu")
        let perfLevelCounts = CPUStatsSampler.detectPerfLevelClusterCounts()
        let performanceCoreCount = perfLevelCounts.performance > 0 ? perfLevelCounts.performance : nil
        let efficiencyCoreCount = perfLevelCounts.efficiency > 0 ? perfLevelCounts.efficiency : nil
        let memoryBytes = sharedSysctlUInt64("hw.memsize")
        let buildVersion = (NSDictionary(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist") as? [String: Any])?["ProductBuildVersion"] as? String
        var uts = utsname()
        uname(&uts)
        let kernelVersion = withUnsafePointer(to: &uts.release) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }

        return SystemInventoryFocusSnapshot(
            modelIdentifier: modelIdentifier,
            cpuName: cpuName,
            chipName: chipName,
            architectureText: architectureText,
            physicalCoreCount: physicalCoreCount,
            logicalCoreCount: logicalCoreCount,
            performanceCoreCount: performanceCoreCount,
            efficiencyCoreCount: efficiencyCoreCount,
            memoryBytes: memoryBytes,
            buildVersion: buildVersion,
            kernelVersion: kernelVersion
        )
    }
}

private enum StorageMediaCategoryKey: String, CaseIterable {
    case mov
    case mp4
    case png
    case jpeg
    case wav
    case compressedAudio
    case rawImaging
    case finalCut
    case audioProjects
    case motionDesign
    case otherMedia

    var label: String {
        switch self {
        case .mov: return "MOV Files"
        case .mp4: return "MP4 / Video"
        case .png: return "PNG Images"
        case .jpeg: return "JPEG / HEIC"
        case .wav: return "WAV / AIFF"
        case .compressedAudio: return "MP3 / FLAC"
        case .rawImaging: return "RAW / EXR"
        case .finalCut: return "Final Cut"
        case .audioProjects: return "Audio Projects"
        case .motionDesign: return "Motion / Design"
        case .otherMedia: return "Other Media"
        }
    }

    var tint: Color {
        switch self {
        case .mov: return Color(red: 0.24, green: 0.66, blue: 1.0)
        case .mp4: return Color(red: 0.30, green: 0.55, blue: 0.98)
        case .png: return Color(red: 0.21, green: 0.80, blue: 0.67)
        case .jpeg: return Color(red: 0.93, green: 0.68, blue: 0.24)
        case .wav: return Color(red: 0.84, green: 0.40, blue: 0.98)
        case .compressedAudio: return Color(red: 0.70, green: 0.48, blue: 0.98)
        case .rawImaging: return Color(red: 0.92, green: 0.45, blue: 0.32)
        case .finalCut: return Color(red: 0.98, green: 0.30, blue: 0.52)
        case .audioProjects: return Color(red: 0.34, green: 0.78, blue: 0.92)
        case .motionDesign: return Color(red: 0.74, green: 0.52, blue: 0.96)
        case .otherMedia: return Color.white.opacity(0.86)
        }
    }

    var actionID: String {
        "storage-media-search-\(rawValue)"
    }

    var searchExtensions: [String] {
        switch self {
        case .mov:
            return ["mov"]
        case .mp4:
            return ["mp4", "m4v", "avi", "mkv", "mxf", "webm", "mpg", "mpeg"]
        case .png:
            return ["png"]
        case .jpeg:
            return ["jpg", "jpeg", "heic", "heif"]
        case .wav:
            return ["wav", "aif", "aiff", "caf", "bwf", "aifc"]
        case .compressedAudio:
            return ["mp3", "m4a", "aac", "flac", "ogg", "opus"]
        case .rawImaging:
            return ["exr", "dpx", "tif", "tiff", "bmp", "gif", "arw", "cr2", "cr3", "nef", "orf", "raf", "rw2", "pef", "srw", "dng", "r3d", "braw"]
        case .finalCut:
            return ["fcp", "fcpbundle", "fcpproject", "fcarchive", "fcpxml"]
        case .audioProjects:
            return ["logicx", "band", "ptx", "ptf", "als", "flp"]
        case .motionDesign:
            return ["prproj", "aep", "aet", "drp", "drt", "blend", "psd", "psb", "afphoto", "afdesign", "ai", "sketch"]
        case .otherMedia:
            return ["wmv", "asf", "ts", "mts", "m2ts", "3gp", "amr"]
        }
    }

    static func actionKey(for actionID: String) -> StorageMediaCategoryKey? {
        StorageMediaCategoryKey.allCases.first { $0.actionID == actionID }
    }
}

private struct StorageMediaBreakdownCategory: Identifiable {
    let key: StorageMediaCategoryKey
    let sizeBytes: Int64
    let fileCount: Int

    var id: String { key.rawValue }
}

private struct StorageMediaBreakdownSnapshot {
    let volumeLabel: String
    let scopeLabel: String
    let scanDurationText: String
    let totalMediaBytes: Int64
    let categories: [StorageMediaBreakdownCategory]
}

private enum StorageMediaFinderSearchPresenter {
    private static let scopePaths: [String] = [
        URL(fileURLWithPath: "/Users").resolvingSymlinksInPath().path,
        URL(fileURLWithPath: "/Applications").resolvingSymlinksInPath().path
    ]

    static func openFinderSearch(for category: StorageMediaCategoryKey) {
        let query = rawQuery(for: category)
        let smartFolderURL = temporarySmartFolderURL(for: category)

        do {
            try FileManager.default.createDirectory(
                at: smartFolderURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            let data = try smartFolderData(rawQuery: query, scopePaths: scopePaths)
            try data.write(to: smartFolderURL, options: .atomic)
            NSWorkspace.shared.open(smartFolderURL)
        } catch {
            NSSound.beep()
        }
    }

    private static func rawQuery(for category: StorageMediaCategoryKey) -> String {
        let clauses = category.searchExtensions.map { ext in
            "(kMDItemFSName == \"*.\(ext)\"cdw)"
        }
        return clauses.count == 1 ? clauses[0] : "(\(clauses.joined(separator: " || ")))"
    }

    private static func temporarySmartFolderURL(for category: StorageMediaCategoryKey) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastPreviewStorageSearches", isDirectory: true)
            .appendingPathComponent("\(category.rawValue).savedSearch")
    }

    private static func smartFolderData(rawQuery: String, scopePaths: [String]) throws -> Data {
        let rawQuerySlice: [String: Any] = [
            "criteria": ["com_apple_RawQueryAttribute", 104],
            "displayValues": ["Raw query", rawQuery],
            "rowType": 0,
            "subrows": []
        ]

        let plist: [String: Any] = [
            "CompatibleVersion": 1,
            "RawQuery": rawQuery,
            "RawQueryDict": [
                "FinderFilesOnly": true,
                "RawQuery": rawQuery,
                "SearchScopes": scopePaths,
                "UserFilesOnly": false
            ],
            "SearchCriteria": [
                "AnyAttributeContains": "",
                "CurrentFolderPath": scopePaths,
                "FXCriteriaSlices": [rawQuerySlice],
                "FXScope": 0,
                "FXScopeArrayOfPaths": scopePaths
            ]
        ]

        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
}

@MainActor
private final class StorageMediaBreakdownLoader: ObservableObject {
    @Published private(set) var snapshot: StorageMediaBreakdownSnapshot?
    @Published private(set) var isLoading = false

    private var loadToken = UUID()

    func refresh() {
        let token = UUID()
        loadToken = token
        snapshot = nil
        isLoading = true

        DispatchQueue.global(qos: .utility).async {
            let scanned = Self.scan()
            DispatchQueue.main.async {
                guard self.loadToken == token else { return }
                self.snapshot = scanned
                self.isLoading = false
            }
        }
    }

    nonisolated private static func scan() -> StorageMediaBreakdownSnapshot {
        let start = Date()
        let fileManager = FileManager.default
        let volumeURL = URL(fileURLWithPath: "/")
        let volumeName = (try? volumeURL.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Startup Disk"
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isPackageKey,
            .nameKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey
        ]
        var totals: [StorageMediaCategoryKey: (bytes: Int64, count: Int)] = [:]
        let scopeLabel = "Startup disk user-accessible areas"

        let enumerator = fileManager.enumerator(
            at: volumeURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        )

        while let next = enumerator?.nextObject() as? URL {
            guard let values = try? next.resourceValues(forKeys: resourceKeys) else { continue }

            if values.isDirectory == true {
                if shouldSkipStorageDirectory(next, volumeRoot: volumeURL) {
                    enumerator?.skipDescendants()
                    continue
                }
                if values.isPackage == true {
                    if let key = storageMediaCategory(forExtension: next.pathExtension.lowercased(), isPackage: true) {
                        let size = recursiveAllocatedSize(at: next)
                        if size > 0 {
                            var entry = totals[key] ?? (0, 0)
                            entry.bytes += size
                            entry.count += 1
                            totals[key] = entry
                        }
                    }
                    enumerator?.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true else { continue }
            guard let key = storageMediaCategory(forExtension: next.pathExtension.lowercased(), isPackage: false) else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            guard size > 0 else { continue }
            var entry = totals[key] ?? (0, 0)
            entry.bytes += size
            entry.count += 1
            totals[key] = entry
        }

        let categories = StorageMediaCategoryKey.allCases.compactMap { key -> StorageMediaBreakdownCategory? in
            guard let entry = totals[key], entry.bytes > 0 else { return nil }
            return StorageMediaBreakdownCategory(key: key, sizeBytes: entry.bytes, fileCount: entry.count)
        }

        let elapsed = max(Date().timeIntervalSince(start), 0.1)
        let durationText: String
        if elapsed < 60 {
            durationText = String(format: "%.1fs", elapsed)
        } else {
            durationText = String(format: "%.1fm", elapsed / 60.0)
        }

        return StorageMediaBreakdownSnapshot(
            volumeLabel: volumeName.isEmpty ? "Startup Disk" : volumeName,
            scopeLabel: scopeLabel,
            scanDurationText: durationText,
            totalMediaBytes: categories.reduce(0) { $0 + $1.sizeBytes },
            categories: categories.sorted { lhs, rhs in
                if lhs.sizeBytes == rhs.sizeBytes {
                    return lhs.key.rawValue < rhs.key.rawValue
                }
                return lhs.sizeBytes > rhs.sizeBytes
            }
        )
    }

    nonisolated private static func shouldSkipStorageDirectory(_ url: URL, volumeRoot: URL) -> Bool {
        let last = url.lastPathComponent
        if last.isEmpty { return false }

        if url.pathComponents.count <= volumeRoot.pathComponents.count + 1 {
            let blocked = Set([
                "System",
                "private",
                "dev",
                "Volumes",
                "cores",
                "net",
                "tmp",
                "Library"
            ])
            return blocked.contains(last)
        }

        let blockedNames = Set([
            ".Spotlight-V100",
            ".DocumentRevisions-V100",
            ".fseventsd",
            ".TemporaryItems",
            ".Trashes",
            "Caches"
        ])
        return blockedNames.contains(last)
    }

    nonisolated private static func storageMediaCategory(forExtension ext: String, isPackage: Bool) -> StorageMediaCategoryKey? {
        guard !ext.isEmpty else { return nil }
        if ext == "mov" { return .mov }
        if ["mp4", "m4v", "avi", "mkv", "mxf", "webm", "mpg", "mpeg"].contains(ext) { return .mp4 }
        if ext == "png" { return .png }
        if ["jpg", "jpeg", "heic", "heif"].contains(ext) { return .jpeg }
        if ["wav", "aif", "aiff", "caf", "bwf", "aifc"].contains(ext) { return .wav }
        if ["mp3", "m4a", "aac", "flac", "ogg", "opus"].contains(ext) { return .compressedAudio }
        if ["exr", "dpx", "tif", "tiff", "bmp", "gif", "arw", "cr2", "cr3", "nef", "orf", "raf", "rw2", "pef", "srw", "dng", "r3d", "braw"].contains(ext) { return .rawImaging }
        if ["fcp", "fcpbundle", "fcpproject", "fcarchive", "fcpxml"].contains(ext) {
            return .finalCut
        }
        if ["logicx", "band", "ptx", "ptf", "als", "flp"].contains(ext) { return .audioProjects }
        if ["prproj", "aep", "aet", "drp", "drt", "blend", "psd", "psb", "afphoto", "afdesign", "ai", "sketch"].contains(ext) { return .motionDesign }
        if isPackage {
            return nil
        }
        if ["wmv", "asf", "ts", "mts", "m2ts", "3gp", "amr"].contains(ext) {
            return .otherMedia
        }
        return nil
    }

    nonisolated private static func recursiveAllocatedSize(at root: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        )
        var total: Int64 = 0
        while let next = enumerator?.nextObject() as? URL {
            guard let values = try? next.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}

struct SystemSpecsCard: View {
    @Environment(\.appUIScale) private var appUIScale
    let machineIdentity: RemoteMachineIdentity?
    let cpuDisplayName: String?
    let gpuDisplayNames: [String]
    let totalMemoryBytes: UInt64?
    let storageSnapshot: StorageStatsSampler.CapacitySnapshot?
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil

    @StateObject private var inventoryLoader = SystemInventoryFocusLoader()

    private struct Specs {
        let modelType: String
        let modelYear: String
        let osString: String
        let family: MacFamily
    }

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledCardHeight: CGFloat { 110 * appUIScale }
    private var scaledContentSpacing: CGFloat { 12 * appUIScale }
    private var scaledTextStackSpacing: CGFloat { 6 * appUIScale }
    private var scaledPadding: CGFloat { 12 * appUIScale }
    private var scaledSpacerMinLength: CGFloat { 8 * appUIScale }
    private var scaledIconHeight: CGFloat { 60 * appUIScale }
    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }
    private var focusID: String { machineIdentity.map { "system-specs-\($0.machineID)" } ?? "system-specs-local" }

    init(
        machineIdentity: RemoteMachineIdentity? = nil,
        cpuDisplayName: String? = nil,
        gpuDisplayNames: [String] = [],
        totalMemoryBytes: UInt64? = nil,
        storageSnapshot: StorageStatsSampler.CapacitySnapshot? = nil,
        onFocus: ((HardwareGraphFocusState) -> Void)? = nil,
        activeFocusID: String? = nil,
        onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil
    ) {
        self.machineIdentity = machineIdentity
        self.cpuDisplayName = cpuDisplayName
        self.gpuDisplayNames = gpuDisplayNames
        self.totalMemoryBytes = totalMemoryBytes
        self.storageSnapshot = storageSnapshot
        self.onFocus = onFocus
        self.activeFocusID = activeFocusID
        self.onFocusedStateChange = onFocusedStateChange
    }

    var body: some View {
        let specs = loadSpecs()

        return ThemeRoundedRectangle(cornerRadius: scaledCornerRadius).themed()
            .frame(height: scaledCardHeight)
            .overlay(
                HStack(alignment: .center, spacing: scaledContentSpacing) {
                    VStack(alignment: .leading, spacing: scaledTextStackSpacing) {
                        Text(specs.modelType)
                            .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
                            .lineLimit(1)

                        Text(specs.modelYear)
                            .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
                            .lineLimit(1)

                        Text(specs.osString)
                            .font(.system(size: scaledCaptionFontSize, weight: .regular))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: scaledSpacerMinLength)

                    MachineThumbnailView(family: specs.family)
                        .frame(width: scaledIconHeight, height: scaledIconHeight)
                }
                .padding(scaledPadding)
            )
            .contentShape(ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous))
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    presentFocus()
                }
            )
            .onAppear {
                refreshFocusedStateIfNeeded()
            }
            .onChange(of: focusRefreshSignature) { _ in
                refreshFocusedStateIfNeeded()
            }
    }

    private func loadSpecs() -> Specs {
        let identifier = machineIdentity?.modelIdentifier
            ?? inventoryLoader.snapshot?.modelIdentifier
            ?? sharedSysctlString("hw.model")
        let osString = RemoteSystemDisplayFormatter.macOSDisplayString(from: machineIdentity?.macOSVersion)
            ?? RemoteSystemDisplayFormatter.macOSDisplayString(version: ProcessInfo.processInfo.operatingSystemVersion)
        return Specs(
            modelType: sharedMachineModelType(from: identifier),
            modelYear: sharedMachineYear(from: identifier),
            osString: osString,
            family: sharedMachineFamily(from: identifier)
        )
    }

    private var focusRefreshSignature: Int {
        focusState?.signatureHash ?? 0
    }

    private var focusState: HardwareGraphFocusState? {
        let specs = loadSpecs()
        let localInventory = inventoryLoader.snapshot
        let resolvedCPUName = sharedReadableCPUName(localInventory?.chipName ?? localInventory?.cpuName ?? machineIdentity?.chipType ?? cpuDisplayName ?? machineIdentity?.cpuName)
        let resolvedMemoryBytes = localInventory?.memoryBytes
            ?? totalMemoryBytes
            ?? machineIdentity?.totalRAMGB.map { UInt64($0 * 1_073_741_824.0) }
        let gpuText = resolvedGPUText
        let storageKind = storageSnapshot?.kindLabel ?? "—"
        let storageHealth = storageSnapshot?.healthLabel ?? "—"
        let coreBreakdown = sharedFormattedCoreBreakdown(
            physical: localInventory?.physicalCoreCount,
            logical: localInventory?.logicalCoreCount,
            performance: localInventory?.performanceCoreCount,
            efficiency: localInventory?.efficiencyCoreCount
        )
        let osBuild = localInventory?.buildVersion
        let kernelVersion = localInventory?.kernelVersion
        let isRemote = machineIdentity != nil

        let summaryHero = HardwareGraphFocusSummaryHero.machine(
            HardwareGraphFocusMachineHeroSnapshot(
                family: specs.family,
                modelName: specs.modelType,
                modelYear: specs.modelYear == "Unknown" ? nil : specs.modelYear,
                osText: specs.osString,
                badgeText: isRemote ? "Remote" : "This Mac",
                supportingText: inventoryLoader.isLoading && !isRemote
                    ? "Loading a one-shot local inventory snapshot..."
                    : (isRemote ? "Using the remote machine identity and currently streamed hardware metadata." : "One-shot local inventory seeded when this focused view was opened.")
            )
        )

        var summaryTiles: [HardwareGraphFocusSummaryTile] = [
            .init(title: "CPU / Chip", value: resolvedCPUName, tint: Color(red: 0.28, green: 0.62, blue: 0.98)),
            .init(title: "Memory", value: sharedFormatBytes(resolvedMemoryBytes), tint: Color(red: 0.22, green: 0.75, blue: 0.44)),
            .init(title: "GPU", value: gpuText, detail: gpuDisplayNames.count > 1 ? "\(gpuDisplayNames.count) GPUs detected" : nil, tint: Color(red: 0.92, green: 0.36, blue: 0.28)),
            .init(title: "Startup Disk", value: storageKind == "—" ? "Monitoring" : storageKind, detail: storageHealth == "—" ? nil : storageHealth, tint: Color(red: 0.86, green: 0.74, blue: 0.20))
        ]
        if inventoryLoader.isLoading && !isRemote {
            summaryTiles.append(.init(title: "Inventory", value: "Loading…", detail: "Pulling a fresh read-only hardware snapshot.", tint: .white.opacity(0.9)))
        }

        var rows: [HardwareGraphFocusSummaryRow] = [
            .init(label: "Model Identifier", value: machineIdentity?.modelIdentifier ?? localInventory?.modelIdentifier ?? "—"),
            .init(label: "Architecture", value: localInventory?.architectureText ?? (machineIdentity?.chipType?.contains("Apple") == true ? "Apple Silicon / arm64" : "—")),
            .init(label: "CPU / Chip", value: resolvedCPUName),
            .init(label: "Core Layout", value: coreBreakdown),
            .init(label: "Memory", value: sharedFormatBytes(resolvedMemoryBytes)),
            .init(label: "GPU(s)", value: gpuText),
            .init(label: "macOS", value: specs.osString),
            .init(label: "Storage", value: storageKind == "—" ? storageSnapshot?.storageLabel ?? "—" : storageKind)
        ]
        if let osBuild, !osBuild.isEmpty {
            rows.append(.init(label: "Build", value: osBuild))
        }
        if let kernelVersion, !kernelVersion.isEmpty {
            rows.append(.init(label: "Kernel", value: kernelVersion))
        }
        if storageHealth != "—" {
            rows.append(.init(label: "Storage Health", value: storageHealth))
        }

        let stats: [HardwareGraphFocusStat] = [
            .init(label: "Model", value: specs.modelType, tint: .white.opacity(0.9)),
            .init(label: "Year", value: specs.modelYear),
            .init(label: "Memory", value: sharedFormatBytes(resolvedMemoryBytes), tint: Color(red: 0.22, green: 0.75, blue: 0.44)),
            .init(label: "GPUs", value: resolvedGPUCount > 0 ? "\(resolvedGPUCount)" : "—")
        ]

        var detailLines: [String] = []
        if isRemote {
            detailLines.append("This focused view is using the remote machine identity plus the currently streamed hardware samplers, so it stays lightweight without issuing local IOKit calls on the remote Mac.")
        } else if inventoryLoader.isLoading {
            detailLines.append("A fresh one-shot local inventory readout is loading now. Once ready, the table will refresh without re-querying until you open this focused view again.")
        } else {
            detailLines.append("This panel captures a one-shot local inventory readout when you enter it, which avoids constant IORegistry churn while still giving a System Report-style overview.")
        }
        if storageKind != "—" {
            detailLines.append("Startup storage currently reports \(storageKind.lowercased())\(storageHealth != "—" ? " with \(storageHealth.lowercased()) health." : ".")")
        }

        return HardwareGraphFocusState(
            id: focusID,
            title: specs.modelType,
            subtitle: "Dashboard HUD for this machine's identity and hardware inventory.",
            accentColor: Color(red: 0.70, green: 0.74, blue: 0.88),
            visualization: .summary(
                HardwareGraphFocusSummarySnapshot(
                    title: "System Inventory",
                    subtitle: "Read-only machine summary modeled after a lightweight System Report pass.",
                    hero: summaryHero,
                    tiles: summaryTiles,
                    rows: rows.filter { $0.value != "—" }
                )
            ),
            stats: stats,
            detailLines: detailLines
        )
    }

    private var resolvedGPUText: String {
        if !gpuDisplayNames.isEmpty {
            if gpuDisplayNames.count == 1 {
                return gpuDisplayNames[0]
            }
            return gpuDisplayNames.joined(separator: " · ")
        }
        if let gpuName = machineIdentity?.gpuName, !gpuName.isEmpty {
            return gpuName
        }
        return "—"
    }

    private var resolvedGPUCount: Int {
        if !gpuDisplayNames.isEmpty {
            return gpuDisplayNames.count
        }
        return machineIdentity?.gpuName?.isEmpty == false ? 1 : 0
    }

    private func presentFocus() {
        if machineIdentity == nil {
            inventoryLoader.refresh()
        }
        guard let onFocus, let focusState else { return }
        onFocus(focusState)
    }

    private func refreshFocusedStateIfNeeded() {
        guard let focusState,
              focusState.id == activeFocusID,
              let onFocusedStateChange else { return }
        onFocusedStateChange(focusState)
    }
}

struct MachineThumbnailView: View {
    let family: MacFamily
    @Environment(\.appUIScale) private var appUIScale

    private var systemMachineIcon: NSImage? {
        let icon = NSImage(named: NSImage.Name("NSComputer"))
        icon?.isTemplate = false
        return icon
    }

    private var familyBadgeLabel: String {
        switch family {
        case .macBook:
            return "Book"
        case .macBookAir:
            return "Air"
        case .macBookPro:
            return "Pro"
        case .macMini:
            return "mini"
        case .iMac:
            return "iMac"
        case .macStudio:
            return "Studio"
        case .macPro:
            return "Pro"
        case .mac:
            return "Mac"
        }
    }

    private var metalGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.98),
                Color(red: 0.83, green: 0.84, blue: 0.88),
                Color(red: 0.62, green: 0.64, blue: 0.69)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var darkMetalGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.30, green: 0.32, blue: 0.36),
                Color(red: 0.18, green: 0.19, blue: 0.21)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var displayGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.09, green: 0.14, blue: 0.24),
                Color(red: 0.16, green: 0.44, blue: 0.64),
                Color(red: 0.49, green: 0.71, blue: 0.90)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomTrailing) {
                if let systemMachineIcon {
                    ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .overlay(
                            Image(nsImage: systemMachineIcon)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .padding(5 * appUIScale)
                                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                        )
                } else {
                    thumbnail(in: geometry.size)
                }

                Text(familyBadgeLabel)
                    .font(.system(size: 9 * appUIScale, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))
                    .padding(.horizontal, 6 * appUIScale)
                    .padding(.vertical, 3 * appUIScale)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.58))
                    )
                    .padding(4 * appUIScale)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    @ViewBuilder
    private func thumbnail(in size: CGSize) -> some View {
        switch family {
        case .macBook, .macBookAir, .macBookPro:
            laptopThumbnail(in: size)
        case .macMini:
            macMiniThumbnail(in: size)
        case .macStudio:
            macStudioThumbnail(in: size)
        case .macPro:
            macProThumbnail(in: size)
        case .iMac, .mac:
            desktopThumbnail(in: size)
        }
    }

    private func laptopThumbnail(in size: CGSize) -> some View {
        let w = size.width
        let h = size.height

        return ZStack {
            ThemeRoundedRectangle(cornerRadius: w * 0.10, style: .continuous)
                .fill(metalGradient)
                .frame(width: w * 0.82, height: h * 0.50)
                .offset(y: -h * 0.08)
                .shadow(color: .black.opacity(0.22), radius: 4, y: 2)

            ThemeRoundedRectangle(cornerRadius: w * 0.07, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .frame(width: w * 0.74, height: h * 0.42)
                .offset(y: -h * 0.08)

            ThemeRoundedRectangle(cornerRadius: w * 0.05, style: .continuous)
                .fill(displayGradient)
                .frame(width: w * 0.68, height: h * 0.35)
                .offset(y: -h * 0.09)

            ThemeRoundedRectangle(cornerRadius: w * 0.06, style: .continuous)
                .fill(metalGradient)
                .frame(width: w * 0.96, height: h * 0.10)
                .offset(y: h * 0.26)
                .shadow(color: .black.opacity(0.20), radius: 3, y: 2)

            Capsule()
                .fill(Color.white.opacity(0.55))
                .frame(width: w * 0.22, height: h * 0.018)
                .offset(y: h * 0.28)
        }
    }

    private func desktopThumbnail(in size: CGSize) -> some View {
        let w = size.width
        let h = size.height

        return ZStack {
            ThemeRoundedRectangle(cornerRadius: w * 0.08, style: .continuous)
                .fill(metalGradient)
                .frame(width: w * 0.84, height: h * 0.56)
                .offset(y: -h * 0.08)
                .shadow(color: .black.opacity(0.22), radius: 4, y: 2)

            ThemeRoundedRectangle(cornerRadius: w * 0.05, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .frame(width: w * 0.76, height: h * 0.48)
                .offset(y: -h * 0.08)

            ThemeRoundedRectangle(cornerRadius: w * 0.04, style: .continuous)
                .fill(displayGradient)
                .frame(width: w * 0.70, height: h * 0.41)
                .offset(y: -h * 0.09)

            ThemeRoundedRectangle(cornerRadius: w * 0.02, style: .continuous)
                .fill(metalGradient)
                .frame(width: w * 0.12, height: h * 0.17)
                .offset(y: h * 0.24)

            Capsule()
                .fill(metalGradient)
                .frame(width: w * 0.30, height: h * 0.05)
                .offset(y: h * 0.34)
        }
    }

    private func macMiniThumbnail(in size: CGSize) -> some View {
        let w = size.width
        let h = size.height

        return ZStack {
            ThemeRoundedRectangle(cornerRadius: w * 0.22, style: .continuous)
                .fill(metalGradient)
                .frame(width: w * 0.76, height: h * 0.42)
                .shadow(color: .black.opacity(0.20), radius: 4, y: 2)

            ThemeRoundedRectangle(cornerRadius: w * 0.20, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
                .frame(width: w * 0.76, height: h * 0.42)

            Circle()
                .fill(Color.black.opacity(0.25))
                .frame(width: w * 0.08, height: w * 0.08)
                .offset(x: w * 0.20, y: h * 0.08)
        }
    }

    private func macStudioThumbnail(in size: CGSize) -> some View {
        let w = size.width
        let h = size.height

        return ZStack {
            ThemeRoundedRectangle(cornerRadius: w * 0.18, style: .continuous)
                .fill(metalGradient)
                .frame(width: w * 0.74, height: h * 0.58)
                .shadow(color: .black.opacity(0.22), radius: 5, y: 3)

            ThemeRoundedRectangle(cornerRadius: w * 0.18, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
                .frame(width: w * 0.74, height: h * 0.58)

            ThemeRoundedRectangle(cornerRadius: w * 0.12, style: .continuous)
                .fill(Color.black.opacity(0.14))
                .frame(width: w * 0.44, height: h * 0.08)
                .offset(y: h * 0.12)

            Circle()
                .fill(Color.black.opacity(0.22))
                .frame(width: w * 0.06, height: w * 0.06)
                .offset(x: w * 0.22, y: h * 0.17)
        }
    }

    private func macProThumbnail(in size: CGSize) -> some View {
        let w = size.width
        let h = size.height

        return ZStack {
            ThemeRoundedRectangle(cornerRadius: w * 0.16, style: .continuous)
                .fill(darkMetalGradient)
                .frame(width: w * 0.52, height: h * 0.78)
                .shadow(color: .black.opacity(0.25), radius: 5, y: 3)

            VStack(spacing: h * 0.05) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: w * 0.03) {
                        ForEach(0..<4, id: \.self) { _ in
                            Circle()
                                .fill(Color.white.opacity(0.18))
                                .frame(width: w * 0.045, height: w * 0.045)
                        }
                    }
                }
            }
            .frame(width: w * 0.34, height: h * 0.42)

            ThemeRoundedRectangle(cornerRadius: w * 0.04, style: .continuous)
                .fill(Color.white.opacity(0.18))
                .frame(width: w * 0.10, height: h * 0.06)
                .offset(x: -w * 0.18, y: -h * 0.33)

            ThemeRoundedRectangle(cornerRadius: w * 0.04, style: .continuous)
                .fill(Color.white.opacity(0.18))
                .frame(width: w * 0.10, height: h * 0.06)
                .offset(x: w * 0.18, y: -h * 0.33)
        }
    }
}

struct MediaEngineCard: View {
    @Environment(\.appUIScale) private var appUIScale
    let capabilityState: MediaEngineStatsSampler.CapabilityState?
    let activitySummary: MediaEngineStatsSampler.ActivitySummary?
    let activitySeries: MetricSeries
    let recentSessions: [MediaEngineStatsSampler.RecentSession]
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledCardMinHeight: CGFloat { 206 * appUIScale }
    private var scaledStackSpacing: CGFloat { 8 * appUIScale }
    private var scaledDetailSpacing: CGFloat { 4 * appUIScale }
    private var scaledPadding: CGFloat { 12 * appUIScale }
    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 11 * appUIScale }
    private var scaledCaption2FontSize: CGFloat { 10 * appUIScale }
    private var scaledContentSpacing: CGFloat { 12 * appUIScale }
    private var scaledDetailLineHeight: CGFloat { 16 * appUIScale }
    private var scaledTitleHeight: CGFloat { 18 * appUIScale }
    private var scaledIndicatorColumnWidth: CGFloat { 60 * appUIScale }
    private var scaledChipContainerSize: CGFloat { 56 * appUIScale }
    private var scaledChipCornerRadius: CGFloat { 14 * appUIScale }
    private var scaledListItemSpacing: CGFloat { 1 * appUIScale }

    private var textColumnMinHeight: CGFloat {
        scaledTitleHeight
            + scaledStackSpacing
            + (22 * appUIScale)
            + detailRowsHeight
            + (CGFloat(visibleDetailRowCount) * scaledDetailSpacing)
    }

    private var scaledCardHeight: CGFloat {
        max(scaledCardMinHeight, max(textColumnMinHeight, scaledChipContainerSize) + (scaledPadding * 2))
    }

    private var visibleDetailRowCount: Int {
        5
            + (currentCodecText != "—" ? 1 : 0)
            + (lastActiveText != "—" ? 1 : 0)
    }

    private var detailRowsHeight: CGFloat {
        detailRowHeight(for: 1)
            + detailRowHeight(for: 1)
            + detailRowHeight(for: encodeCodecItems.count)
            + detailRowHeight(for: decodeCodecItems.count)
            + (currentCodecText != "—" ? detailRowHeight(for: currentCodecItems.count) : 0)
            + detailRowHeight(for: recentSummaryItems.count)
            + (lastActiveText != "—" ? detailRowHeight(for: 1) : 0)
    }

    private var focusAccentColor: Color {
        Color(red: 0.37, green: 0.36, blue: 0.90)
    }

    private var encodeCodecsText: String {
        capabilityState?.supportedEncodeCodecsText ?? "—"
    }

    private var encodeCodecItems: [String] {
        splitListText(encodeCodecsText, separators: [" / ", "/"])
    }

    private var decodeCodecsText: String {
        capabilityState?.supportedDecodeCodecsText ?? "—"
    }

    private var decodeCodecItems: [String] {
        splitListText(decodeCodecsText, separators: [" / ", "/"])
    }

    private var cardTitle: String {
        capabilityState?.displayTitle ?? "Media Engines"
    }

    private var pathDescriptionText: String {
        capabilityState?.pathDescription ?? "Hardware media path detected"
    }

    private var recentEncodeCount: Int {
        recentSessions.filter { $0.role == .encode }.count
    }

    private var recentDecodeCount: Int {
        recentSessions.filter { $0.role == .decode }.count
    }

    private var recentSummaryItems: [String] {
        var parts: [String] = []
        if recentEncodeCount > 0 {
            parts.append("\(recentEncodeCount) enc")
        }
        if recentDecodeCount > 0 {
            parts.append("\(recentDecodeCount) dec")
        }
        if let frames = activitySummary?.recentProcessedFrames, frames > 0 {
            parts.append("\(frames) frames")
        }
        return parts
    }

    private var recentSummaryText: String {
        recentSummaryItems.isEmpty ? "None recent" : recentSummaryItems.joined(separator: " | ")
    }

    private var currentCodecText: String {
        activitySummary?.codecText ?? "—"
    }

    private var currentCodecItems: [String] {
        splitListText(currentCodecText, separators: [" | ", " / ", "/"])
    }

    private var lastActiveText: String {
        activitySummary?.lastActiveText ?? "—"
    }

    private var focusState: HardwareGraphFocusState? {
        let hasContent = capabilityState != nil || activitySummary != nil || !recentSessions.isEmpty || !activitySeries.samples.isEmpty
        guard hasContent else { return nil }

        let normalizedHistory: [Double?] = {
            if activitySeries.samples.isEmpty {
                let currentValue = Double(activitySummary?.activityValue ?? 0)
                return [currentValue, currentValue]
            }
            return activitySeries.samples.map { $0.value }
        }()
        let subtitle = activitySummary?.subtitleText(supportsEncode: capabilityState?.supportsEncode ?? false)
            ?? pathDescriptionText

        var stats: [HardwareGraphFocusStat] = [
            .init(label: "Status", value: activitySummary?.statusText ?? "Idle", tint: focusAccentColor),
            .init(label: "Recent", value: recentSummaryText),
            .init(label: "Path", value: supportedPathText)
        ]
        if let frames = activitySummary?.recentProcessedFrames, frames > 0 {
            stats.append(.init(label: "Frames", value: "\(frames)"))
        }
        if lastActiveText != "—" {
            stats.append(.init(label: "Last Active", value: lastActiveText))
        }

        var detailLines: [String] = [
            "Detected path: \(pathDescriptionText).",
            "Encode codecs: \(encodeCodecsText).",
            "Decode codecs: \(decodeCodecsText)."
        ]

        if !recentSessions.isEmpty {
            detailLines.append(contentsOf: recentSessions.prefix(5).map(sessionSummaryLine))
        } else {
            detailLines.append("No recent encode or decode sessions were retained in the current window.")
        }

        let focusRecentSessions: [MediaEngineStatsSampler.RecentSession] = {
            let meaningfulCompleted = recentSessions.filter {
                $0.isCompleted || ($0.framesProcessed ?? 0) > 0 || ($0.framesDropped ?? 0) > 0
            }
            if !meaningfulCompleted.isEmpty {
                return Array(meaningfulCompleted.prefix(10))
            }
            return Array(recentSessions.prefix(10))
        }()

        return HardwareGraphFocusState(
            id: "media-engines-card",
            title: cardTitle,
            subtitle: subtitle,
            accentColor: focusAccentColor,
            heatmapTarget: .overall,
            visualization: .lineChart([
                HardwareGraphFocusSeries(
                    id: "media-activity",
                    label: "Activity",
                    color: focusAccentColor,
                    values: normalizedHistory
                )
            ]),
            mediaRecentSessions: focusRecentSessions,
            stats: stats,
            detailLines: detailLines
        )
    }

    private var focusRefreshSignature: Int {
        var hasher = Hasher()
        hasher.combine(cardTitle)
        // Lightweight: count + most-recent sample instead of full sample iteration.
        hasher.combine(activitySeries.samples.count)
        if let lastSample = activitySeries.samples.last {
            hasher.combine(lastSample.timestamp)
            hasher.combine(lastSample.value.map { Int(($0 * 1000).rounded()) } ?? 0)
        }
        // Sessions: count + first session identity is enough to detect list changes.
        hasher.combine(recentSessions.count)
        if let firstSession = recentSessions.first {
            hasher.combine(firstSession.id)
            hasher.combine(firstSession.lastEventDate)
        }
        hasher.combine(activitySummary?.statusText ?? "")
        hasher.combine(activitySummary?.subtitleText(supportsEncode: capabilityState?.supportsEncode ?? false) ?? "")
        return hasher.finalize()
    }

    private var supportedPathText: String {
        switch capabilityState?.capabilityKind {
        case .appleMediaEngines:
            return "Apple Silicon"
        case .intelQuickSyncCPU:
            return "CPU Package"
        case .afterburnerPCIe:
            return capabilityState?.pathDeviceName ?? "PCIe x16"
        case .gpuHardwareVideo:
            return capabilityState?.pathDeviceName ?? "GPU-Accelerated"
        case nil:
            return "Detected"
        @unknown default:
            return "Detected"
        }
    }

    @ViewBuilder
    private var cardBackground: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius).themed()
    }

    @ViewBuilder
    private var textContent: some View {
        let subtitleText = activitySummary?.subtitleText(supportsEncode: capabilityState?.supportsEncode ?? false) ?? pathDescriptionText
        let statusText = activitySummary?.statusText ?? "—"

        VStack(alignment: .leading, spacing: scaledStackSpacing) {
            Text(cardTitle)
                .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: scaledTitleHeight, alignment: .leading)
                .multilineTextAlignment(.leading)

            VStack(alignment: .leading, spacing: scaledDetailSpacing) {
                Text(subtitleText)
                    .font(.system(size: scaledCaptionFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                detailRow(label: "Status", value: statusText)
                detailRow(label: "Path", value: supportedPathText, lineLimit: 2)
                detailListRow(label: "Encode", items: encodeCodecItems)
                detailListRow(label: "Decode", items: decodeCodecItems)
                if currentCodecText != "—" {
                    if currentCodecItems.count > 1 {
                        detailListRow(label: "In Use", items: currentCodecItems)
                    } else {
                        detailRow(label: "In Use", value: currentCodecText)
                    }
                }
                detailListRow(label: "Recent", items: recentSummaryItems, emptyValue: "None recent")
                if lastActiveText != "—" {
                    detailRow(label: "Last Active", value: lastActiveText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var indicatorColumn: some View {
        VStack {
            Spacer(minLength: 0)

            ZStack {
                MediaEncoderChipMetalView(
                    activityState: activitySummary?.activityState ?? .idle,
                    activityValue: Float(activitySummary?.activityValue ?? 0),
                    cornerRadius: scaledChipCornerRadius,
                    symbolName: "aspectratio"
                )
                .clipShape(ThemeRoundedRectangle(cornerRadius: scaledChipCornerRadius, style: .continuous))
            }
            .frame(width: scaledChipContainerSize, height: scaledChipContainerSize, alignment: .center)

            Spacer(minLength: 0)
        }
        .frame(width: scaledIndicatorColumnWidth, height: scaledCardHeight - (scaledPadding * 2), alignment: .top)
    }

    @ViewBuilder
    private func detailRow(label: String, value: String, lineLimit: Int? = 1) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6 * appUIScale) {
            Text("\(label):")
                .font(.system(size: scaledCaption2FontSize, weight: .regular))
                .foregroundColor(.secondary)

            Text(value)
                .font(.system(size: scaledCaptionFontSize, weight: .regular))
                .foregroundColor(.secondary.opacity(0.92))
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: scaledDetailLineHeight, alignment: .leading)
    }

    @ViewBuilder
    private func detailListRow(label: String, items: [String], emptyValue: String = "—") -> some View {
        HStack(alignment: .top, spacing: 6 * appUIScale) {
            Text("\(label):")
                .font(.system(size: scaledCaption2FontSize, weight: .regular))
                .foregroundColor(.secondary)

            if items.isEmpty {
                Text(emptyValue)
                    .font(.system(size: scaledCaptionFontSize, weight: .regular))
                    .foregroundColor(.secondary.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: scaledListItemSpacing) {
                    ForEach(Array(items.enumerated()), id: \.offset) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 4 * appUIScale) {
                            Text("•")
                                .font(.system(size: scaledCaption2FontSize, weight: .regular))
                                .foregroundColor(.secondary.opacity(0.92))

                            Text(entry.element)
                                .font(.system(size: scaledCaptionFontSize, weight: .regular))
                                .foregroundColor(.secondary.opacity(0.92))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: detailRowHeight(for: items.count), alignment: .leading)
    }

    private func detailRowHeight(for itemCount: Int) -> CGFloat {
        let resolvedCount = max(1, itemCount)
        return (CGFloat(resolvedCount) * scaledDetailLineHeight)
            + (CGFloat(max(0, resolvedCount - 1)) * scaledListItemSpacing)
    }

    var body: some View {
        HStack(alignment: .top, spacing: scaledContentSpacing) {
            textContent
                .layoutPriority(1)

            indicatorColumn
        }
        .padding(scaledPadding)
            .frame(minHeight: scaledCardHeight)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(cardBackground)
            .clipShape(ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous))
            .contentShape(ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous))
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
                refreshFocusedStateIfNeeded()
            }
    }

    private func refreshFocusedStateIfNeeded() {
        guard let focusState,
              focusState.id == activeFocusID,
              let onFocusedStateChange else { return }
        onFocusedStateChange(focusState)
    }

    private func sessionSummaryLine(_ session: MediaEngineStatsSampler.RecentSession) -> String {
        var parts: [String] = [
            session.roleText,
            session.codecText
        ]
        if let resolution = session.resolutionText {
            parts.append(resolution)
        }
        if let frames = session.framesProcessed, frames > 0 {
            parts.append("\(frames) frames")
        } else {
            parts.append("observed")
        }
        if let dropped = session.framesDropped, dropped > 0 {
            parts.append("\(dropped) dropped")
        }
        parts.append(relativeTimeString(since: session.lastActivityDate))
        return parts.joined(separator: " | ")
    }

    private func relativeTimeString(since date: Date) -> String {
        let delta = max(0, Date().timeIntervalSince(date))
        if delta < 1 { return "now" }
        if delta < 10 { return String(format: "%.1fs ago", delta) }
        if delta < 60 { return "\(Int(delta))s ago" }
        if delta < 3600 { return "\(Int(delta / 60))m ago" }
        return "\(Int(delta / 3600))h ago"
    }

    private func splitListText(_ value: String, separators: [String]) -> [String] {
        guard value != "—" else { return [] }

        var normalized = value
        for separator in separators {
            normalized = normalized.replacingOccurrences(of: separator, with: "\n")
        }

        return normalized
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "—" }
    }
}

struct NeuralEngineCard: View {
    @Environment(\.appUIScale) private var appUIScale
    let statusSnapshot: ANEStatsSampler.StatusSnapshot?
    let activitySeries: MetricSeries
    let powerSeries: MetricSeries
    var onResetPeak: (() -> Void)? = nil
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledCardMinHeight: CGFloat { 180 * appUIScale }
    private var scaledStackSpacing: CGFloat { 8 * appUIScale }
    private var scaledDetailSpacing: CGFloat { 2 * appUIScale }
    private var scaledPadding: CGFloat { 12 * appUIScale }
    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }
    private var scaledContentSpacing: CGFloat { 12 * appUIScale }
    private var scaledCapsuleRailPadding: CGFloat { 10 * appUIScale }
    private var scaledDetailLineHeight: CGFloat { 16 * appUIScale }
    private var scaledTitleHeight: CGFloat { 18 * appUIScale }
    private var scaledCapsuleColumnWidth: CGFloat { 72 * appUIScale }
    private var scaledCapsuleWidth: CGFloat { 56 * appUIScale }
    private var scaledCapsuleHeight: CGFloat { 5 * appUIScale }
    private var scaledCapsuleSpacing: CGFloat { 1 }
    private var scaledCapsuleTopPadding: CGFloat { 6 * appUIScale }
    private var maxVisibleCapsules: Int { 32 }

    private var parsedCoreCount: Int? {
        statusSnapshot?.coreCount
    }

    private var peakPowerText: String? {
        guard let text = statusSnapshot?.peakPowerText, text != "—" else { return nil }
        return text
    }

    private var powerDeltaText: String? {
        guard let text = statusSnapshot?.powerDeltaText, text != "—" else { return nil }
        return text
    }

    private var clientsText: [String] {
        statusSnapshot?.clients ?? []
    }

    private var visibleCapsuleCount: Int {
        guard let parsedCoreCount, parsedCoreCount > 0 else { return 0 }
        return min(parsedCoreCount, maxVisibleCapsules)
    }

    private var capsuleStackHeight: CGFloat {
        guard visibleCapsuleCount > 0 else { return scaledCapsuleHeight }
        let actualCapsuleHeight = scaledCapsuleHeight + (6 * appUIScale)
        return (CGFloat(visibleCapsuleCount) * actualCapsuleHeight)
            + (CGFloat(max(visibleCapsuleCount - 1, 0)) * scaledCapsuleSpacing)
            + scaledCapsuleTopPadding
            + (scaledCapsuleRailPadding * 2)
    }

    private var textColumnMinHeight: CGFloat {
        var baseHeight = scaledTitleHeight + (4 * scaledDetailLineHeight) + scaledStackSpacing + (scaledDetailSpacing * 3)

        if peakPowerText != nil || powerDeltaText != nil {
            baseHeight += (2 * scaledDetailLineHeight) + (scaledDetailSpacing * 2)
        }

        let clientsHeight: CGFloat = {
            guard !clientsText.isEmpty else { return 0 }
            let numVisibleClients = min(clientsText.count, 5)
            let clientsHeaderHeight = scaledDetailLineHeight + (scaledDetailSpacing * 2)
            let clientsListHeight = CGFloat(numVisibleClients) * (scaledDetailLineHeight * 0.9)
            return clientsHeaderHeight + clientsListHeight
        }()

        return baseHeight + clientsHeight
    }

    private var scaledCardHeight: CGFloat {
        max(scaledCardMinHeight, max(capsuleStackHeight, textColumnMinHeight) + (scaledPadding * 2))
    }

    private var statusGlowColor: Color {
        switch (statusSnapshot?.statusText ?? "idle").lowercased() {
        case "active":
            return Color.blue.opacity(0.55)
        case "busy":
            return Color.red.opacity(0.55)
        default:
            return Color.clear
        }
    }

    private var simdStatusGlowColor: SIMD4<Float> {
        let color = NSColor(statusGlowColor)
        let converted = color.usingColorSpace(.deviceRGB) ?? color
        return SIMD4(
            Float(converted.redComponent),
            Float(converted.greenComponent),
            Float(converted.blueComponent),
            Float(converted.alphaComponent)
        )
    }

    private var isIdle: Bool {
        (statusSnapshot?.statusText ?? "idle").lowercased() == "idle"
    }

    private var isActive: Bool {
        (statusSnapshot?.currentPowerMilliwatts ?? 0) > 0
    }

    private var focusState: HardwareGraphFocusState? {
        makeSharedNeuralEngineFocusState(
            statusSnapshot: statusSnapshot,
            activitySeries: activitySeries,
            powerSeries: powerSeries,
            title: "Neural Engine",
            subtitle: "Shared focused view for the visible Neural Engine history window."
        )
    }

    private var focusRefreshSignature: Int {
        focusState?.signatureHash ?? 0
    }

    @ViewBuilder
    private var cardBackground: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius).themed()
    }

    @ViewBuilder
    private var textContent: some View {
        let coreCountText = statusSnapshot?.coreCountText ?? "—"
        let architectureText = statusSnapshot?.architectureText ?? "—"
        let statusText = statusSnapshot?.statusText ?? "—"
        let powerText = statusSnapshot?.powerText ?? "—"
        let peakPowerText = statusSnapshot?.peakPowerText
        let powerDeltaText = statusSnapshot?.powerDeltaText
        let clientsText = statusSnapshot?.clients ?? []

        VStack(alignment: .leading, spacing: scaledStackSpacing) {
            Text("Neural Engine")
                .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: scaledTitleHeight, alignment: .leading)
                .multilineTextAlignment(.leading)

            VStack(alignment: .leading, spacing: scaledDetailSpacing) {
                detailRow("Cores: \(coreCountText)")
                detailRow("Architecture: \(architectureText)")
                detailRow("Status: \(statusText)")
                if powerText != "—" {
                    detailRow("Power: \(powerText)")
                }

                if let peakPowerText = peakPowerText, peakPowerText != "—" {
                    HStack {
                        detailRow("Peak: \(peakPowerText)")
                        if let onResetPeak = onResetPeak {
                            Button(action: onResetPeak) {
                                Text("Reset")
                                    .font(.system(size: scaledCaptionFontSize - 1, weight: .regular))
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(.secondary)
                        }
                    }
                }

                if let powerDeltaText = powerDeltaText, powerDeltaText != "—" {
                    detailRow("Delta: \(powerDeltaText)")
                }

                VStack(alignment: .leading, spacing: scaledDetailSpacing) {
                    Text("Clients:")
                        .font(.system(size: scaledCaptionFontSize, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: scaledDetailLineHeight, alignment: .leading)
                        .padding(.top, scaledDetailSpacing * 2)

                    if clientsText.isEmpty {
                        Text("  • None")
                            .font(.system(size: scaledCaptionFontSize - 1, weight: .regular))
                            .foregroundColor(.secondary.opacity(0.85))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: scaledDetailLineHeight * 0.9, alignment: .leading)
                    } else {
                        ForEach(clientsText.prefix(5), id: \.self) { client in
                            let readableName = ANEStatsSampler.readableServiceName(for: client)
                            Text("  • \(readableName)")
                                .font(.system(size: scaledCaptionFontSize - 1, weight: .regular))
                                .foregroundColor(.secondary.opacity(0.85))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: scaledDetailLineHeight * 0.9, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: scaledCardHeight - (scaledPadding * 2), alignment: .topLeading)
    }

    @ViewBuilder
    private var capsuleColumn: some View {
        NeuralEngineCapsuleMetalView(
            visibleCapsuleCount: visibleCapsuleCount,
            isIdle: isIdle,
            isActive: isActive,
            statusColor: simdStatusGlowColor,
            capsuleColumnWidth: scaledCapsuleColumnWidth,
            cardContentHeight: scaledCardHeight - (scaledPadding * 2),
            capsuleWidth: scaledCapsuleWidth,
            capsuleHeight: scaledCapsuleHeight,
            capsuleSpacing: scaledCapsuleSpacing,
            capsuleRailPadding: scaledCapsuleRailPadding,
            capsuleTopPadding: scaledCapsuleTopPadding
        )
        .frame(width: scaledCapsuleColumnWidth, height: scaledCardHeight - (scaledPadding * 2), alignment: .top)
        .clipped()
    }

    @ViewBuilder
    private func detailRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: scaledCaptionFontSize, weight: .regular))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: scaledDetailLineHeight, alignment: .leading)
            .multilineTextAlignment(.leading)
    }

    var body: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius).themed()
            .frame(height: scaledCardHeight)
            .overlay(
                HStack(alignment: .top, spacing: scaledContentSpacing) {
                    textContent
                        .layoutPriority(1)

                    capsuleColumn
                }
                .padding(scaledPadding)
            )
            .clipShape(ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous))
            .contentShape(ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous))
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
                refreshFocusedStateIfNeeded()
            }
    }

    private func refreshFocusedStateIfNeeded() {
        guard let focusState,
              focusState.id == activeFocusID,
              let onFocusedStateChange else { return }
        onFocusedStateChange(focusState)
    }
}

struct StorageCard: View {
    @Environment(\.appUIScale) private var appUIScale
    let snapshot: StorageStatsSampler.CapacitySnapshot?
    var isRemote: Bool = false
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil

    @StateObject private var mediaBreakdownLoader = StorageMediaBreakdownLoader()

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledCardHeight: CGFloat { 162 * appUIScale }
    private var scaledStackSpacing: CGFloat { 10 * appUIScale }
    private var scaledDetailSpacing: CGFloat { 2 * appUIScale }
    private var scaledMeterHeight: CGFloat { 10 * appUIScale }
    private var scaledPadding: CGFloat { 12 * appUIScale }
    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }
    private var scaledCaption2FontSize: CGFloat { 11 * appUIScale }
    private var focusID: String { isRemote ? "storage-card-remote" : "storage-card-local" }

    private var storageIconName: String {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            return "internaldrive"
        } else {
            return "opticaldiscdrive"
        }
        #else
        return "internaldrive"
        #endif
    }

    private var storageUsageGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: Color.white.opacity(0.85), location: 0.0),
                .init(color: Color.gray.opacity(0.85), location: 0.7),
                .init(color: Color.orange, location: 0.8),
                .init(color: Color.orange, location: 0.9),
                .init(color: Color.red, location: 1.0)
            ]),
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        let label = snapshot?.storageLabel ?? "—"
        let usedRatio = snapshot?.usedRatio ?? 0
        let storageKindLabel = snapshot?.kindLabel
        let storageSpeedLabel = snapshot?.speedLabel
        let storageHealthLabel = snapshot?.healthLabel
        let hasStorageMeta = (storageKindLabel?.isEmpty == false)
            || (storageSpeedLabel?.isEmpty == false)
            || (storageHealthLabel?.isEmpty == false)

        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius).themed()
            .frame(height: scaledCardHeight)
            .overlay(
                VStack(alignment: .leading, spacing: scaledStackSpacing) {
                    Text("Storage")
                        .font(.system(size: scaledHeadlineFontSize, weight: .semibold))

                    HStack {
                        Text(label)
                            .font(.system(size: scaledCaptionFontSize, weight: .regular))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        Spacer()
                    }

                    if hasStorageMeta {
                        VStack(alignment: .leading, spacing: 4 * appUIScale) {
                            HStack(alignment: .firstTextBaseline, spacing: 8 * appUIScale) {
                                if let storageKindLabel, !storageKindLabel.isEmpty {
                                    Text(storageKindLabel)
                                        .font(.system(size: scaledCaption2FontSize, weight: .regular))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .layoutPriority(1)
                                }

                                Spacer(minLength: 0)

                                if let storageHealthLabel, !storageHealthLabel.isEmpty {
                                    Text(storageHealthLabel)
                                        .font(.system(size: scaledCaption2FontSize, weight: .medium))
                                        .foregroundColor(healthColor(for: storageHealthLabel))
                                        .lineLimit(1)
                                }
                            }

                            if let storageSpeedLabel, !storageSpeedLabel.isEmpty {
                                Text(storageSpeedLabel)
                                    .font(.system(size: scaledCaption2FontSize, weight: .regular))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.82)
                            }
                        }
                    }

                    HStack(alignment: .center, spacing: 12 * appUIScale) {
                        GeometryReader { geo in
                            let w = geo.size.width
                            let fillW = w * CGFloat(min(max(usedRatio, 0), 1))

                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.10))

                                Rectangle()
                                    .fill(
                                        storageUsageGradient
                                    )
                                    .frame(width: w)
                                    .mask(
                                        HStack(spacing: 0) {
                                            Rectangle()
                                                .frame(width: fillW)
                                            Spacer(minLength: 0)
                                        }
                                    )
                            }
                        }
                        .frame(height: scaledMeterHeight)

                        // Storage icon with Disk I/O color
                        Image(systemName: storageIconName)
                            .font(.system(size: 24 * appUIScale, weight: .semibold))
                            .foregroundColor(Color(red: 0.55, green: 0.55, blue: 0.10))
                            .frame(width: 28 * appUIScale, height: 28 * appUIScale)
                    }

                    Text(String(format: "%.0f%% used", min(max(usedRatio, 0), 1) * 100))
                        .font(.system(size: scaledCaption2FontSize, weight: .regular))
                        .foregroundColor(.secondary)
                }
                .padding(scaledPadding)
            )
            .contentShape(ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous))
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    presentFocus()
                }
            )
            .onAppear {
                refreshFocusedStateIfNeeded()
            }
            .onChange(of: focusRefreshSignature) { _ in
                refreshFocusedStateIfNeeded()
            }
    }

    private func healthColor(for healthLabel: String) -> Color {
        let lower = healthLabel.lowercased()

        func compatibleCyan() -> Color {
            if #available(macOS 12.0, *) {
                return .cyan
            } else {
                return Color(.sRGB, red: 0.0, green: 0.68, blue: 0.94, opacity: 1.0)
            }
        }

        if lower.contains("excellent") {
            return .green
        } else if lower.contains("good") {
            return compatibleCyan()
        } else if lower.contains("fair") {
            return .yellow
        } else if lower.contains("poor") {
            return .orange
        } else if lower.contains("critical") {
            return .red
        } else {
            return .secondary
        }
    }

    private var focusRefreshSignature: Int {
        focusState?.signatureHash ?? 0
    }

    private var focusState: HardwareGraphFocusState? {
        guard let snapshot else { return nil }

        let usedRatio = Double(snapshot.usedRatio)
        let totalBytes = max(snapshot.totalBytes, 0)
        let usedBytes = max(snapshot.usedBytes, 0)
        let freeBytes = max(snapshot.freeBytes, 0)
        let localBreakdown = mediaBreakdownLoader.snapshot
        let categoryTiles: [HardwareGraphFocusSummaryTile] = {
            if let localBreakdown, !localBreakdown.categories.isEmpty {
                return localBreakdown.categories.map { category in
                    HardwareGraphFocusSummaryTile(
                        title: category.key.label,
                        value: ByteCountFormatter.string(fromByteCount: category.sizeBytes, countStyle: .binary),
                        detail: "\(category.fileCount) item\(category.fileCount == 1 ? "" : "s")",
                        tint: category.key.tint,
                        actionID: category.key.actionID
                    )
                }
            }
            if mediaBreakdownLoader.isLoading && !isRemote {
                return [
                    .init(title: "Media Scan", value: "Scanning…", detail: "Walking the startup disk's user-accessible media folders once for this view.", tint: Color(red: 0.86, green: 0.74, blue: 0.20))
                ]
            }
            if isRemote {
                return [
                    .init(title: "Media Scan", value: "Remote", detail: "Startup-disk media categorisation is currently local-only.", tint: Color.white.opacity(0.9))
                ]
            }
            return [
                .init(title: "Media Scan", value: "No media found", detail: "This one-shot pass did not find tracked media containers in the scanned areas.", tint: Color.white.opacity(0.9))
            ]
        }()

        var rows: [HardwareGraphFocusSummaryRow] = [
            .init(label: "Capacity", value: snapshot.storageLabel),
            .init(label: "Used", value: ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .binary)),
            .init(label: "Free", value: ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .binary))
        ]
        if let kindLabel = snapshot.kindLabel, !kindLabel.isEmpty {
            rows.append(.init(label: "Storage Kind", value: kindLabel))
        }
        if let speedLabel = snapshot.speedLabel, !speedLabel.isEmpty {
            rows.append(.init(label: "Speed", value: speedLabel))
        }
        if let healthLabel = snapshot.healthLabel, !healthLabel.isEmpty {
            rows.append(.init(label: "Health", value: healthLabel))
        }
        if let localBreakdown {
            rows.append(.init(label: "Scan Scope", value: "\(localBreakdown.volumeLabel) · \(localBreakdown.scopeLabel)"))
            rows.append(.init(label: "Media Found", value: ByteCountFormatter.string(fromByteCount: localBreakdown.totalMediaBytes, countStyle: .binary)))
            rows.append(.init(label: "Scan Time", value: localBreakdown.scanDurationText))
        } else if isRemote {
            rows.append(.init(label: "Scan Scope", value: "Remote file-kind scan unavailable"))
        }

        let stats: [HardwareGraphFocusStat] = [
            .init(label: "Used", value: String(format: "%.0f%%", usedRatio * 100), tint: Color(red: 0.86, green: 0.74, blue: 0.20)),
            .init(label: "Free", value: ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .binary)),
            .init(label: "Total", value: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .binary)),
            .init(label: "Media Tiles", value: "\(localBreakdown?.categories.count ?? 0)")
        ]

        var detailLines: [String] = [
            "This storage view expands the capacity meter and keeps the supporting details anchored to the current startup volume."
        ]
        if isRemote {
            detailLines.append("File-kind breakdown is intentionally local-only for now, so remote machines stick to streamed storage metadata instead of attempting a host-side filesystem crawl.")
        } else if mediaBreakdownLoader.isLoading {
            detailLines.append("A one-shot media scan is running now. The breakdown will populate once and then stay fixed until you reopen this focused view.")
        } else if let localBreakdown, !localBreakdown.categories.isEmpty {
            detailLines.append("One-shot media scan covered \(localBreakdown.scopeLabel.lowercased()) on \(localBreakdown.volumeLabel) and found \(ByteCountFormatter.string(fromByteCount: localBreakdown.totalMediaBytes, countStyle: .binary)) of tracked media containers.")
            detailLines.append("Double-click any media tile to open a one-shot Finder search for that file family.")
        }

        return HardwareGraphFocusState(
            id: focusID,
            title: "Storage",
            subtitle: "Expanded startup disk capacity and one-shot media breakdown.",
            accentColor: Color(red: 0.86, green: 0.74, blue: 0.20),
            visualization: .summary(
                HardwareGraphFocusSummarySnapshot(
                    title: "Startup Disk",
                    subtitle: "Storage meter plus media-file buckets captured for this focused view.",
                    hero: .storage(
                        HardwareGraphFocusStorageHeroSnapshot(
                            title: isRemote ? "Remote Storage" : "Startup Disk",
                            subtitle: snapshot.kindLabel,
                            usedRatio: usedRatio,
                            usedText: snapshot.storageLabel,
                            detailText: snapshot.speedLabel
                        )
                    ),
                    tiles: categoryTiles,
                    rows: rows
                )
            ),
            stats: stats,
            detailLines: detailLines,
            detailActionHandler: { actionID in
                guard !isRemote,
                      let category = StorageMediaCategoryKey.actionKey(for: actionID) else { return }
                StorageMediaFinderSearchPresenter.openFinderSearch(for: category)
            }
        )
    }

    private func presentFocus() {
        if !isRemote {
            mediaBreakdownLoader.refresh()
        }
        guard let onFocus, let focusState else { return }
        onFocus(focusState)
    }

    private func refreshFocusedStateIfNeeded() {
        guard let focusState,
              focusState.id == activeFocusID,
              let onFocusedStateChange else { return }
        onFocusedStateChange(focusState)
    }
}

struct AppUsageMiniCard: View {
    @Environment(\.appUIScale) private var appUIScale
    let metrics: AppStatsSampler.Metrics
    let cpuSeries: MetricSeries
    let gpuSeries: MetricSeries
    let memorySeries: MetricSeries
    let readSeries: MetricSeries
    let writeSeries: MetricSeries
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledHorizontalPadding: CGFloat { 12 * appUIScale }
    private var scaledVerticalPadding: CGFloat { 10 * appUIScale }
    private var scaledTitleRowHeight: CGFloat { 24 * appUIScale }
    private var scaledTitleRowBottomPadding: CGFloat { 2 * appUIScale }
    private var scaledHeaderDividerHeight: CGFloat { 1 * appUIScale }
    private var scaledRowHeight: CGFloat { 22 * appUIScale }
    private var scaledRowSpacing: CGFloat { 4 * appUIScale }
    private var scaledTitleFontSize: CGFloat { 12 * appUIScale }
    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledValueFontSize: CGFloat { 13 * appUIScale }
    private var cardShape: some Shape {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous)
    }
    /// Five metric rows, four 1 pt dividers, and `VStack` spacing between each.
    private var scaledCardHeight: CGFloat {
        let rowBlock = 5 * scaledRowHeight + CGFloat(4) + 8 * scaledRowSpacing
        let titleBlock = scaledTitleRowHeight + scaledTitleRowBottomPadding
        return 2 * scaledVerticalPadding + titleBlock + scaledHeaderDividerHeight + rowBlock
    }
    private var focusID: String { "app-usage-mini-card" }

    var body: some View {
        cardBackground
            .overlay(cardContent)
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
                refreshFocusedStateIfNeeded()
            }
    }

    private var cardBackground: some View {
        cardShape
            .fill(Color.black.opacity(0.08))
            .overlay(
                cardShape
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .frame(height: scaledCardHeight)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            headerDivider
            metricsRows
        }
        .padding(.horizontal, scaledHorizontalPadding)
        .padding(.vertical, scaledVerticalPadding)
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12 * appUIScale) {
            Text("This App")
                .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 8 * appUIScale)

            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 24 * appUIScale, weight: .semibold))
                .foregroundColor(.white)
                .shadow(color: Color.black.opacity(0.15), radius: 0.5, x: 0, y: 0)
                .frame(width: 28 * appUIScale, height: 28 * appUIScale)
        }
        .frame(height: scaledTitleRowHeight)
        .padding(.bottom, scaledTitleRowBottomPadding)
    }

    private var metricsRows: some View {
        VStack(alignment: .leading, spacing: scaledRowSpacing) {
            metricRow(systemImage: "cpu", title: "App CPU", value: metrics.cpuText)
            appUsageHorizontalDivider
            metricRow(systemImage: "square.stack.3d.down.forward", title: "App GPU", value: metrics.gpuText)
            appUsageHorizontalDivider
            metricRow(systemImage: "memorychip", title: "App Memory", value: metrics.memText)
            appUsageHorizontalDivider
            metricRow(systemImage: "arrow.down.circle", title: "App Disk Read", value: metrics.diskReadText)
            appUsageHorizontalDivider
            metricRow(systemImage: "arrow.up.circle", title: "App Disk Write", value: metrics.diskWriteText)
        }
    }

    private var appUsageHorizontalDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
            .padding(.horizontal, -scaledHorizontalPadding)
    }

    private var headerDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: scaledHeaderDividerHeight)
            .padding(.horizontal, -scaledHorizontalPadding)
    }

    private func metricRow(
        systemImage: String,
        title: String,
        value: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4 * appUIScale) {
            HStack(spacing: 4 * appUIScale) {
                Image(systemName: systemImage)
                    .font(.system(size: scaledTitleFontSize * 0.9))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(.system(size: scaledTitleFontSize, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4 * appUIScale)

            Text(value)
                .font(.system(size: scaledValueFontSize, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(height: scaledRowHeight)
    }

    private var focusRefreshSignature: Int {
        focusState?.signatureHash ?? 0
    }

    private var focusState: HardwareGraphFocusState? {
        let cpuValues = cpuSeries.samples.map { $0.value.map { min(max($0, 0), 1) } }
        let gpuValues = gpuSeries.samples.map { $0.value.map { min(max($0, 0), 1) } }
        let memoryCeiling = max(memorySeries.peakObservedValue ?? 0, memorySeries.latestObservedValue ?? 0.01)
        let memoryValues = normalizedHardwareFocusSeries(from: memorySeries, ceiling: memoryCeiling > 0 ? memoryCeiling : nil)
        let readCeiling = max(readSeries.peakObservedValue ?? 0, metrics.diskReadMBps ?? 0, 0.05)
        let writeCeiling = max(writeSeries.peakObservedValue ?? 0, metrics.diskWriteMBps ?? 0, 0.05)
        let readValues = normalizedHardwareFocusSeries(from: readSeries, ceiling: readCeiling)
        let writeValues = normalizedHardwareFocusSeries(from: writeSeries, ceiling: writeCeiling)
        let hasObservedHistory = cpuValues.contains(where: { $0 != nil })
            || gpuValues.contains(where: { $0 != nil })
            || memoryValues.contains(where: { $0 != nil })
            || readValues.contains(where: { $0 != nil })
            || writeValues.contains(where: { $0 != nil })
            || metrics.cpuPercent != nil
            || metrics.gpuPercent != nil
            || metrics.residentMemoryBytes != nil
            || metrics.diskReadMBps != nil
            || metrics.diskWriteMBps != nil

        guard hasObservedHistory else { return nil }

        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "AVDash"

        let cpuPeak = cpuSeries.observedValues().map { $0 * 100.0 }.max() ?? metrics.cpuPercent
        let gpuPeak = gpuSeries.observedValues().map { $0 * 100.0 }.max() ?? metrics.gpuPercent
        let memoryPeakBytes = memorySeries.peakObservedValue.map { UInt64(max($0, 0) * 1_073_741_824.0) } ?? metrics.residentMemoryBytes
        let peakMemoryText = sharedFormatBytes(memoryPeakBytes)
        let peakReadText = AppStatsSampler.formatRate(readSeries.peakObservedValue ?? metrics.diskReadMBps)
        let peakWriteText = AppStatsSampler.formatRate(writeSeries.peakObservedValue ?? metrics.diskWriteMBps)

        var linePanels: [HardwareGraphFocusLinePanelSnapshot] = [
            HardwareGraphFocusLinePanelSnapshot(
                id: "app-cpu-history",
                title: "App CPU History",
                chipTitle: "CPU",
                subtitle: "PodcastPreview-family CPU share normalized against total system capacity.",
                detailText: "CPU is derived from rolling per-process CPU-time deltas across the tracked PodcastPreview app, helpers, and services.",
                series: [
                    HardwareGraphFocusSeries(id: "app-cpu", label: "CPU", color: .blue, values: cpuValues)
                ]
            ),
            HardwareGraphFocusLinePanelSnapshot(
                id: "app-memory-history",
                title: "App Memory History",
                chipTitle: "Memory",
                subtitle: "Resident memory for the tracked PodcastPreview process family, normalized to the visible peak.",
                detailText: memoryPeakBytes != nil ? "Peak resident footprint for the tracked PodcastPreview process family reached \(peakMemoryText)." : "Resident footprint will scale as samples arrive.",
                series: [
                    HardwareGraphFocusSeries(id: "app-memory", label: "Memory", color: Color(red: 0.18, green: 0.72, blue: 0.34), values: memoryValues)
                ]
            ),
            HardwareGraphFocusLinePanelSnapshot(
                id: "app-disk-read-history",
                title: "App Disk Read History",
                chipTitle: "Read",
                subtitle: "Live disk read throughput across the tracked PodcastPreview process family.",
                detailText: "Read throughput is derived from rolling per-process rusage counters on the existing app sampler cadence.",
                series: [
                    HardwareGraphFocusSeries(id: "app-disk-read", label: "Read", color: Color(red: 0.78, green: 0.68, blue: 0.28), values: readValues)
                ]
            ),
            HardwareGraphFocusLinePanelSnapshot(
                id: "app-disk-write-history",
                title: "App Disk Write History",
                chipTitle: "Write",
                subtitle: "Live disk write throughput across the tracked PodcastPreview process family.",
                detailText: "Write bursts are tracked from rolling per-process rusage counters without adding a separate background collector.",
                series: [
                    HardwareGraphFocusSeries(id: "app-disk-write", label: "Write", color: Color(red: 0.46, green: 0.74, blue: 0.58), values: writeValues)
                ]
            )
        ]
        if gpuValues.contains(where: { $0 != nil }) || metrics.gpuPercent != nil {
            linePanels.append(
                HardwareGraphFocusLinePanelSnapshot(
                    id: "app-gpu-history",
                    title: "App GPU History",
                    chipTitle: "GPU",
                    subtitle: "PodcastPreview-family GPU activity, using a direct app hook or a tracked GPU-client estimate.",
                    detailText: "When a direct app GPU hook is available this reuses it; otherwise GPU is estimated from the tracked processes' share of sampled GPU-client time.",
                    series: [
                        HardwareGraphFocusSeries(id: "app-gpu", label: "GPU", color: Color(red: 0.88, green: 0.30, blue: 0.26), values: gpuValues)
                    ]
                )
            )
        }

        return HardwareGraphFocusState(
            id: focusID,
            title: "\(appName) App",
            subtitle: "Lightweight focus view for the tracked PodcastPreview process family's CPU, GPU, memory, and live disk I/O history.",
            accentColor: .blue,
            visualization: .lineChart([
                HardwareGraphFocusSeries(id: "app-focus-cpu", label: "CPU", color: .blue, values: cpuValues),
                HardwareGraphFocusSeries(id: "app-focus-gpu", label: "GPU", color: Color(red: 0.88, green: 0.30, blue: 0.26), values: gpuValues),
                HardwareGraphFocusSeries(id: "app-focus-memory", label: "Memory", color: Color(red: 0.18, green: 0.72, blue: 0.34), values: memoryValues),
                HardwareGraphFocusSeries(id: "app-focus-read", label: "Read", color: Color(red: 0.78, green: 0.68, blue: 0.28), values: readValues),
                HardwareGraphFocusSeries(id: "app-focus-write", label: "Write", color: Color(red: 0.46, green: 0.74, blue: 0.58), values: writeValues)
            ]),
            linePanelSnapshots: linePanels,
            stats: [
                .init(label: "Live CPU", value: metrics.cpuText, tint: .blue),
                .init(label: "Peak CPU", value: cpuPeak.map { String(format: "%.1f%%", $0) } ?? "—", tint: .blue.opacity(0.85)),
                .init(label: "Live GPU", value: metrics.gpuText, tint: Color(red: 0.88, green: 0.30, blue: 0.26)),
                .init(label: "Peak GPU", value: gpuPeak.map { String(format: "%.1f%%", $0) } ?? "—", tint: Color(red: 0.88, green: 0.30, blue: 0.26).opacity(0.85)),
                .init(label: "Live Memory", value: metrics.memText, tint: Color(red: 0.18, green: 0.72, blue: 0.34)),
                .init(label: "Peak Memory", value: peakMemoryText, tint: Color(red: 0.18, green: 0.72, blue: 0.34).opacity(0.85)),
                .init(label: "Live Read", value: metrics.diskReadText, tint: Color(red: 0.78, green: 0.68, blue: 0.28)),
                .init(label: "Peak Read", value: peakReadText, tint: Color(red: 0.78, green: 0.68, blue: 0.28).opacity(0.85)),
                .init(label: "Live Write", value: metrics.diskWriteText, tint: Color(red: 0.46, green: 0.74, blue: 0.58)),
                .init(label: "Peak Write", value: peakWriteText, tint: Color(red: 0.46, green: 0.74, blue: 0.58).opacity(0.85))
            ],
            detailLines: [
                "This mini focus reuses the existing app sampler cadence, so it gives you PodcastPreview-family history without the heavier persisted per-process linkage used by the Top Apps card.",
                "CPU is shown as a share of total machine capacity across all logical cores, so a few percent of one busy core can appear as a small overall percentage on high-core-count Macs.",
                "GPU is either the direct app-side Metal signal or an estimate derived from the tracked processes' share of sampled GPU-client time. Memory is normalized against the visible peak resident footprint, and disk read/write are normalized against the visible live peak.",
                "Bundle: \(Bundle.main.bundleIdentifier ?? "com.chrisizatt.PodcastPreview")."
            ]
        )
    }

    private func refreshFocusedStateIfNeeded() {
        guard let focusState,
              focusState.id == activeFocusID,
              let onFocusedStateChange else { return }
        onFocusedStateChange(focusState)
    }
}

struct TopAppsCard: View {
    @Environment(\.appUIScale) private var appUIScale
    @AppStorage("topAppsShowTimeline") private var showTimeline = false
    let rows: [OtherAppsSampler.Row]
    var liveHistoryProvider: ((PersistedProcessIdentity) -> OtherAppsSampler.LiveHistorySnapshot?)? = nil
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil

    private var visibleRows: [OtherAppsSampler.Row] {
        Array(rows.prefix(RunningAppsSampler.topProcessLimit))
    }

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var timelineHeight: CGFloat {
        let apps = min(visibleRows.filter { $0.uptimeSeconds > 0 }.count, 8)
        return CGFloat(apps) * 14 * appUIScale + 80 * appUIScale
    }
    private var scaledCardHeight: CGFloat { (showTimeline ? 580 + timelineHeight / appUIScale : 580) * appUIScale }
    private var scaledHeaderSpacing: CGFloat { 10 * appUIScale }
    private var scaledRowSpacing: CGFloat { 6 * appUIScale }
    private var scaledRowHeaderSpacing: CGFloat { 8 * appUIScale }
    private var scaledMetricSpacing: CGFloat { 14 * appUIScale }
    private var scaledRowVerticalPadding: CGFloat { 6 * appUIScale }
    private var scaledPadding: CGFloat { 12 * appUIScale }
    private var scaledIconSize: CGFloat { 16 * appUIScale }
    private var scaledIconCornerRadius: CGFloat { 3 * appUIScale }
    private var scaledUptimeWidth: CGFloat { 54 * appUIScale }
    private var scaledRowLeadingPadding: CGFloat { 24 * appUIScale }
    private var scaledSpacerMinLength: CGFloat { 8 * appUIScale }
    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }
    private var scaledCaption2FontSize: CGFloat { 11 * appUIScale }
    private var focusRefreshSignature: Int {
        var hasher = Hasher()
        // Lightweight: check the top-3 rows only (already sorted by activity),
        // using pid + coarse CPU. Captures all ranking and load changes without
        // iterating every field on every body evaluation.
        hasher.combine(visibleRows.count)
        for row in visibleRows.prefix(3) {
            hasher.combine(row.pid)
            hasher.combine(Int((row.cpuPercent * 100).rounded()))
            hasher.combine(row.isGPUActive)
        }
        return hasher.finalize()
    }

    var body: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius).themed()
            .frame(height: scaledCardHeight)
            .clipShape(ThemeRoundedRectangle(cornerRadius: scaledCornerRadius))
            .overlay(
                VStack(alignment: .leading, spacing: scaledHeaderSpacing) {
                    VStack(alignment: .leading, spacing: 6 * appUIScale) {
                        HStack(alignment: .center, spacing: 12 * appUIScale) {
                            Text("Top Apps")
                                .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)

                            Spacer(minLength: scaledSpacerMinLength)

                            Image(systemName: "apps.ipad.landscape")
                                .font(.system(size: 24 * appUIScale, weight: .semibold))
                                .foregroundColor(.appsAccentColor)
                                .frame(width: 28 * appUIScale, height: 28 * appUIScale)
                        }

                        Text("Uptime · CPU · RAM · GPU · Disk")
                            .font(.system(size: scaledCaptionFontSize, weight: .regular))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    headerDivider

                    if rows.isEmpty {
                        Text("No data")
                            .font(.system(size: scaledCaptionFontSize, weight: .regular))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, scaledPadding * 2)
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(spacing: 0) {
                                ForEach(visibleRows.indices, id: \.self) { index in
                                    let r = visibleRows[index]
                                    VStack(alignment: .leading, spacing: scaledRowSpacing) {
                                        HStack(alignment: .top, spacing: scaledRowHeaderSpacing) {
                                            if let icon = r.icon {
                                                Image(nsImage: icon)
                                                    .resizable()
                                                    .scaledToFit()
                                                    .frame(width: scaledIconSize, height: scaledIconSize)
                                                    .cornerRadius(scaledIconCornerRadius)
                                            } else {
                                                ThemeRoundedRectangle(cornerRadius: scaledIconCornerRadius)
                                                    .fill(Color.white.opacity(0.12))
                                                    .frame(width: scaledIconSize, height: scaledIconSize)
                                            }

                                            Text(r.name)
                                                .font(.system(size: scaledCaptionFontSize, weight: .regular))
                                                .lineLimit(1)

                                            Spacer(minLength: scaledSpacerMinLength)

                                            Text(r.uptimeText)
                                                .font(.system(size: scaledCaption2FontSize, weight: .regular))
                                                .foregroundColor(.secondary)
                                                .frame(width: scaledUptimeWidth, alignment: .trailing)
                                        }

                                        VStack(alignment: .leading, spacing: 6 * appUIScale) {
                                            HStack(spacing: scaledMetricSpacing) {
                                                metricChip(
                                                    title: "CPU",
                                                    value: cpuDisplayText(for: r),
                                                    accentColor: .blue,
                                                    isEmphasized: displayedCPUPercent(for: r) > 0
                                                )
                                                metricChip(
                                                    title: "RAM",
                                                    value: ramDisplayText(for: r),
                                                    accentColor: Color(red: 0.10, green: 0.65, blue: 0.28),
                                                    isEmphasized: displayedRAMGB(for: r) > 0
                                                )
                                                if r.gpuPercent != nil || r.isGPUActive {
                                                    gpuMetricChip(for: r)
                                                }
                                                Spacer(minLength: 0)
                                            }

                                            HStack(spacing: scaledMetricSpacing) {
                                                metricChip(title: "Read", value: diskDisplayText(r.diskReadMBps))
                                                metricChip(title: "Write", value: diskDisplayText(r.diskWriteMBps))
                                                Spacer(minLength: 0)
                                            }
                                        }
                                        .padding(.leading, scaledRowLeadingPadding)
                                    }
                                    .padding(.vertical, scaledRowVerticalPadding)
                                    .contentShape(Rectangle())
                                    .simultaneousGesture(
                                        TapGesture(count: 2).onEnded {
                                            guard let onFocus,
                                                  let focusState = focusState(for: r) else { return }
                                            onFocus(focusState)
                                        }
                                    )

                                    if index < visibleRows.count - 1 {
                                        Rectangle()
                                            .fill(Color.white.opacity(0.10))
                                            .frame(height: 1)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .padding(scaledPadding)
            )
            .onAppear {
                refreshFocusedStateIfNeeded()
            }
            .onChange(of: focusRefreshSignature) { _ in
                refreshFocusedStateIfNeeded()
            }
    }

    private func ramDisplayText(for row: OtherAppsSampler.Row) -> String {
        String(format: "%.2f GB", row.ramMB / 1024.0)
    }

    private func cpuDisplayText(for row: OtherAppsSampler.Row) -> String {
        String(format: "%.1f%%", row.cpuPercent)
    }

    private func displayedCPUPercent(for row: OtherAppsSampler.Row) -> Double {
        (row.cpuPercent * 10).rounded() / 10
    }

    private func displayedRAMGB(for row: OtherAppsSampler.Row) -> Double {
        ((row.ramMB / 1024.0) * 100).rounded() / 100
    }

    private func diskDisplayText(_ value: Double) -> String {
        AppStatsSampler.formatRate(value)
    }

    private func gpuDisplayText(for row: OtherAppsSampler.Row) -> String {
        guard let gpuPercent = row.gpuPercent else {
            return row.isGPUActive ? "Active" : "—"
        }
        if gpuPercent < 10 {
            return String(format: "%.1f%%", gpuPercent)
        }
        return String(format: "%.0f%%", gpuPercent)
    }

    private func metricChip(
        title: String,
        value: String,
        accentColor: Color? = nil,
        isEmphasized: Bool = false
    ) -> some View {
        let valueColor = isEmphasized ? (accentColor ?? .secondary) : .secondary

        return VStack(alignment: .leading, spacing: 2 * appUIScale) {
            Text(title)
                .font(.system(size: scaledCaption2FontSize, weight: .regular))
                .foregroundColor(.secondary)

            if #available(macOS 12.0, *) {
                Text(value)
                    .font(.system(size: scaledCaption2FontSize, weight: .regular, design: .monospaced))
                    .foregroundColor(valueColor)
                    .monospacedDigit()
                    .lineLimit(1)
            } else {
                Text(value)
                    .font(.system(size: scaledCaption2FontSize, weight: .regular, design: .monospaced))
                    .foregroundColor(valueColor)
                    .lineLimit(1)
            }
        }
    }

    private func gpuMetricChip(for row: OtherAppsSampler.Row) -> some View {
        let accent = Color(red: 0.85, green: 0.20, blue: 0.20)
        let isEmphasized = (row.gpuPercent ?? 0) > 0 || row.isGPUActive

        return metricChip(
            title: "GPU",
            value: gpuDisplayText(for: row),
            accentColor: accent,
            isEmphasized: isEmphasized
        )
    }

    private var headerDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
            .padding(.horizontal, -scaledPadding)
    }

    private func focusState(for row: OtherAppsSampler.Row) -> HardwareGraphFocusState? {
        let processIdentity = PersistedProcessIdentity(
            displayName: row.name,
            bundleIdentifier: row.bundleIdentifier
        )
        let liveGPUShareRatio = currentGPUShareRatio(for: row)
        let processTarget = HardwareGraphFocusProcessTarget(
            identity: processIdentity,
            currentCPUPercent: row.cpuPercent,
            currentRAMMB: row.ramMB,
            isGPUActive: row.isGPUActive,
            currentGPUShareRatio: liveGPUShareRatio,
            uptimeSeconds: row.uptimeSeconds
        )
        let accentColor = row.isGPUActive ? Color(red: 0.85, green: 0.20, blue: 0.20) : .blue
        let bundleDescription = row.bundleIdentifier ?? "Process focus seeded from the current Top Apps row."
        let gpuStatLabel = liveGPUShareRatio != nil ? "GPU Share" : "GPU"
        let gpuStatValue = liveGPUShareRatio.map(formatGPUSharePercent) ?? (row.isGPUActive ? "Active" : "Quiet")
        let liveProcessSnapshot = makeLiveProcessSnapshot(for: row, identity: processIdentity)

        return HardwareGraphFocusState(
            id: "top-app-\(processIdentity.processKey)",
            title: row.name,
            subtitle: row.bundleIdentifier ?? "App-focused view with persisted historical linkage.",
            accentColor: accentColor,
            processTarget: processTarget,
            visualization: .lineChart([
                HardwareGraphFocusSeries(
                    id: "live-cpu",
                    label: "Live CPU",
                    color: accentColor,
                    values: [min(max(row.cpuPercent / 100.0, 0), 1), min(max(row.cpuPercent / 100.0, 0), 1)]
                )
            ]),
            processLiveSnapshot: liveProcessSnapshot,
            stats: [
                .init(label: "Live CPU", value: String(format: "%.1f%%", row.cpuPercent), tint: .blue),
                .init(label: "Live RAM", value: ramDisplayText(for: row), tint: Color(red: 0.10, green: 0.65, blue: 0.28)),
                .init(label: gpuStatLabel, value: gpuStatValue, tint: row.isGPUActive ? accentColor : .secondary),
                .init(label: "Disk Read", value: diskDisplayText(row.diskReadMBps), tint: Color(red: 0.78, green: 0.68, blue: 0.28)),
                .init(label: "Disk Write", value: diskDisplayText(row.diskWriteMBps), tint: Color(red: 0.46, green: 0.74, blue: 0.58)),
                .init(label: "Uptime", value: row.uptimeText)
            ],
            detailLines: [
                bundleDescription,
                "Live focus history reuses the existing Top Apps sampler cadence, so it updates without adding extra probe overhead.",
                "Historical linkage uses persisted minute and hourly app rollups to show where this process tended to dominate CPU, RAM, GPU activity, or power-correlated load.",
                "Disk read/write chips are live-only right now, derived from per-process rusage counters on the same sampler cadence."
            ]
        )
    }

    private func makeLiveProcessSnapshot(for row: OtherAppsSampler.Row, identity: PersistedProcessIdentity) -> HardwareGraphFocusProcessLiveSnapshot? {
        guard let liveHistorySnapshot = liveHistoryProvider?(identity),
              liveHistorySnapshot.samples.count >= 2 else {
            return nil
        }

        let samples = liveHistorySnapshot.samples
        let maxCPUPercent = max(samples.map(\.cpuPercent).max() ?? row.cpuPercent, 0.01)
        let maxRAMMB = max(samples.map(\.ramMB).max() ?? row.ramMB, 1)
        let hasGPUShare = samples.contains { ($0.gpuShareRatio ?? 0) > 0 }
        let maxReadMBps = max(samples.map(\.diskReadMBps).max() ?? row.diskReadMBps, 0.05)
        let maxWriteMBps = max(samples.map(\.diskWriteMBps).max() ?? row.diskWriteMBps, 0.05)

        let cpuSeries = HardwareGraphFocusSeries(
            id: "process-live-cpu",
            label: "CPU",
            color: .blue,
            values: samples.map { min(max($0.cpuPercent / maxCPUPercent, 0), 1) }
        )
        let ramSeries = HardwareGraphFocusSeries(
            id: "process-live-ram",
            label: "RAM",
            color: Color(red: 0.10, green: 0.65, blue: 0.28),
            values: samples.map { min(max($0.ramMB / maxRAMMB, 0), 1) }
        )
        let gpuSeries = HardwareGraphFocusSeries(
            id: "process-live-gpu",
            label: hasGPUShare ? "GPU Share" : "GPU Activity",
            color: Color(red: 0.85, green: 0.20, blue: 0.20),
            values: samples.map {
                if hasGPUShare {
                    return min(max($0.gpuShareRatio ?? 0, 0), 1)
                }
                return $0.isGPUActive ? 1 : 0
            }
        )
        let readSeries = HardwareGraphFocusSeries(
            id: "process-live-read",
            label: "Disk Read",
            color: Color(red: 0.78, green: 0.68, blue: 0.28),
            values: samples.map { min(max($0.diskReadMBps / maxReadMBps, 0), 1) }
        )
        let writeSeries = HardwareGraphFocusSeries(
            id: "process-live-write",
            label: "Disk Write",
            color: Color(red: 0.46, green: 0.74, blue: 0.58),
            values: samples.map { min(max($0.diskWriteMBps / maxWriteMBps, 0), 1) }
        )

        return HardwareGraphFocusProcessLiveSnapshot(
            title: "Live Footprint",
            subtitle: "Recent in-memory app samples. This view updates on the normal Top Apps sampler cadence rather than waiting for persisted rollups.",
            series: [cpuSeries, ramSeries, gpuSeries, readSeries, writeSeries],
            detailText: hasGPUShare
                ? "GPU Share reflects sampled per-app GPU-client time, while disk read/write come from lightweight per-process rusage deltas."
                : "GPU Activity reflects live GPU client visibility, while disk read/write come from lightweight per-process rusage deltas."
        )
    }

    private func currentGPUShareRatio(for row: OtherAppsSampler.Row) -> Double? {
        row.gpuShareRatio
    }

    private func formatGPUSharePercent(_ ratio: Double) -> String {
        let percent = min(max(ratio, 0), 1) * 100
        if percent < 10 {
            return String(format: "%.1f%%", percent)
        }
        return String(format: "%.0f%%", percent)
    }

    private func refreshFocusedStateIfNeeded() {
        guard let activeFocusID,
              activeFocusID.hasPrefix("top-app-"),
              let onFocusedStateChange else { return }

        guard let matchingRow = visibleRows.first(where: {
            let identity = PersistedProcessIdentity(displayName: $0.name, bundleIdentifier: $0.bundleIdentifier)
            return "top-app-\(identity.processKey)" == activeFocusID
        }),
        let focusState = focusState(for: matchingRow) else {
            return
        }

        onFocusedStateChange(focusState)
    }
}

struct SystemOutputMeterCard: View {
    /// Shared with system-mix FFT / waveform on the Hardware tab (``startExternalMonitoring(themeColor:)``).
    static let stereoOutputMeterThemeColor = Color(red: 0.18, green: 0.72, blue: 0.40)
    static let hardwareSpectrumThemeColor = stereoOutputMeterThemeColor
    static let hardwareWaveformThemeColor = Color(red: 0.24, green: 0.56, blue: 0.95)

    @Environment(\.appUIScale) private var appUIScale
    let snapshot: SystemAudioOutputMeterModel.Snapshot
    var onToggleEnabled: ((Bool) -> Void)? = nil
    var onDetailAction: ((String) -> Void)? = nil
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledCardHeight: CGFloat { 204 * appUIScale }
    private var scaledPadding: CGFloat { 13 * appUIScale }
    private var scaledHeaderSpacing: CGFloat { 12 * appUIScale }
    private var scaledChannelSpacing: CGFloat { 12 * appUIScale }
    private var scaledFooterSpacing: CGFloat { 12 * appUIScale }
    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }
    private var scaledLabelWidth: CGFloat { 18 * appUIScale }
    private var scaledMeterHeight: CGFloat { 18 * appUIScale }
    private var scaledValueWidth: CGFloat { 54 * appUIScale }
    private var focusID: String { "system-output-meter-card" }

    var body: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius).themed()
            .frame(height: scaledCardHeight)
            .overlay(
                VStack(alignment: .leading, spacing: scaledHeaderSpacing) {
                    HStack(alignment: .center, spacing: 8 * appUIScale) {
                        Text("Stereo Output")
                            .font(.system(size: scaledHeadlineFontSize, weight: .semibold))

                        Spacer(minLength: 8 * appUIScale)

                        Toggle(
                            "",
                            isOn: Binding(
                                get: { snapshot.isCaptureEnabled },
                                set: { newValue in
                                    onToggleEnabled?(newValue)
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .scaleEffect(0.74 * appUIScale, anchor: .trailing)

                        statusCapsule
                    }

                    Text(snapshot.detailText)
                        .font(.system(size: scaledCaptionFontSize - 0.5, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    stereoMeterBlock

                    HStack(alignment: .top, spacing: scaledFooterSpacing) {
                        footerItem(title: "Output", value: snapshot.outputDeviceText)
                        footerItem(title: "Source", value: snapshot.sourceText)
                        footerItem(title: "Rate", value: snapshot.sampleRateText)
                    }
                }
                .padding(scaledPadding)
            )
            .clipShape(ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous))
            .contentShape(ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous))
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
                refreshFocusedStateIfNeeded()
            }
    }

    private var statusCapsule: some View {
        Text(snapshot.statusText)
            .font(.system(size: scaledCaptionFontSize - 1, weight: .semibold))
            .foregroundColor(statusForegroundColor)
            .padding(.horizontal, 8 * appUIScale)
            .padding(.vertical, 4 * appUIScale)
            .background(
                ThemeRoundedRectangle(cornerRadius: 7 * appUIScale, style: .continuous)
                    .fill(statusBackgroundColor)
            )
            .overlay(
                ThemeRoundedRectangle(cornerRadius: 7 * appUIScale, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
    }

    private var stereoMeterBlock: some View {
        HStack(spacing: 8 * appUIScale) {
            VStack(alignment: .leading, spacing: scaledChannelSpacing) {
                channelLabel("L")
                channelLabel("R")
            }
            .frame(width: scaledLabelWidth, alignment: .leading)

            MetalHorizontalMeterStripView(
                levels: [
                    Float(min(max(snapshot.leftLevel, 0), 1)),
                    Float(min(max(snapshot.rightLevel, 0), 1))
                ],
                peakHolds: [
                    Float(min(max(snapshot.leftPeakHold, 0), 1)),
                    Float(min(max(snapshot.rightPeakHold, 0), 1))
                ],
                themeColor: Self.stereoOutputMeterThemeColor,
                meterHeight: scaledMeterHeight,
                meterSpacing: scaledChannelSpacing
            )
            .frame(height: (scaledMeterHeight * 2) + scaledChannelSpacing)
            .background(
                ThemeRoundedRectangle(cornerRadius: 4 * appUIScale, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .clipShape(ThemeRoundedRectangle(cornerRadius: 4 * appUIScale, style: .continuous))
            .overlay(
                ThemeRoundedRectangle(cornerRadius: 4 * appUIScale, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )

            VStack(alignment: .trailing, spacing: scaledChannelSpacing) {
                channelValue(snapshot.leftValueText)
                channelValue(snapshot.rightValueText)
            }
            .frame(width: scaledValueWidth, alignment: .trailing)
        }
    }

    private func channelLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: scaledCaptionFontSize, weight: .semibold, design: .monospaced))
            .foregroundColor(.secondary)
            .frame(height: scaledMeterHeight, alignment: .center)
    }

    private func channelValue(_ valueText: String) -> some View {
        Text(valueText)
            .font(.system(size: scaledCaptionFontSize - 0.5, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.84))
            .lineLimit(1)
            .frame(height: scaledMeterHeight, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func footerItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3 * appUIScale) {
            Text(title)
                .font(.system(size: scaledCaptionFontSize - 1, weight: .regular))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Text(value)
                .font(.system(size: scaledCaptionFontSize - 0.5, weight: .medium))
                .foregroundColor(.white.opacity(0.82))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusBackgroundColor: Color {
        switch snapshot.statusStyle {
        case .unsupported:
            return Color.white.opacity(0.08)
        case .disabled:
            return Color.white.opacity(0.09)
        case .permissionNeeded:
            return Color(red: 0.44, green: 0.28, blue: 0.18).opacity(0.72)
        case .idle:
            return Color(red: 0.22, green: 0.28, blue: 0.42).opacity(0.78)
        case .warmup:
            return Color(red: 0.38, green: 0.30, blue: 0.16).opacity(0.82)
        case .live:
            return Color(red: 0.16, green: 0.44, blue: 0.28).opacity(0.82)
        }
    }

    private var statusForegroundColor: Color {
        switch snapshot.statusStyle {
        case .unsupported:
            return .secondary
        case .disabled:
            return Color.white.opacity(0.74)
        case .permissionNeeded:
            return Color(red: 0.98, green: 0.84, blue: 0.62)
        case .idle:
            return Color(red: 0.76, green: 0.84, blue: 1.0)
        case .warmup:
            return Color(red: 0.96, green: 0.88, blue: 0.62)
        case .live:
            return Color(red: 0.78, green: 0.96, blue: 0.84)
        }
    }

    private var focusRefreshSignature: Int {
        guard activeFocusID == focusID else { return 0 }
        return focusState?.signatureHash ?? 0
    }

    private var focusState: HardwareGraphFocusState? {
        return HardwareGraphFocusState(
            id: focusID,
            title: "Stereo Output",
            subtitle: "Live stereo metering from the current macOS output path.",
            accentColor: statusBackgroundColor,
            visualization: .summary(
                HardwareGraphFocusSummarySnapshot(
                    title: "Stereo Output",
                    subtitle: snapshot.detailText,
                    hero: nil,
                    tiles: [
                        .init(title: "Left", value: snapshot.leftValueText, detail: snapshot.hasSignal ? "Live channel" : "Waiting for signal", tint: Self.stereoOutputMeterThemeColor),
                        .init(title: "Right", value: snapshot.rightValueText, detail: snapshot.hasSignal ? "Live channel" : "Waiting for signal", tint: Color(red: 0.82, green: 0.76, blue: 0.28)),
                        .init(title: "Frames", value: "\(snapshot.diagnostics.totalFrames)", detail: snapshot.capturePathText, tint: statusBackgroundColor),
                        .init(title: "Hot Frames", value: "\(snapshot.diagnostics.hotFrames)", detail: snapshot.diagnostics.lastBufferSource, tint: Color(red: 0.36, green: 0.56, blue: 0.86))
                    ],
                    rows: [
                        .init(label: "Output Device", value: snapshot.outputDeviceText),
                        .init(label: "Source", value: snapshot.sourceText),
                        .init(label: "Capture Path", value: snapshot.capturePathText),
                        .init(label: "Backend Preference", value: backendPreferenceText),
                        .init(label: "Virtual Input", value: snapshot.virtualInputDeviceText),
                        .init(label: "Sample Rate", value: snapshot.sampleRateText),
                        .init(label: "Last Signal", value: lastSignalText),
                        .init(label: "Last Buffer", value: snapshot.diagnostics.lastBufferSource),
                        .init(label: "Last Payload", value: payloadText),
                        .init(label: "Last Samples", value: sampleCountText),
                        .init(label: "Output UID", value: outputUIDText),
                        .init(label: "Last Error", value: lastErrorText)
                    ]
                )
            ),
            detailVisuals: focusDetailVisuals,
            stats: [
                .init(label: "Left", value: snapshot.leftValueText, tint: Self.stereoOutputMeterThemeColor),
                .init(label: "Right", value: snapshot.rightValueText, tint: Color(red: 0.82, green: 0.76, blue: 0.28)),
                .init(label: "Backend", value: snapshot.capturePathText, tint: statusBackgroundColor),
                .init(label: "Frames", value: "\(snapshot.diagnostics.totalFrames)", tint: Color(red: 0.36, green: 0.56, blue: 0.86)),
                .init(label: "Hot", value: "\(snapshot.diagnostics.hotFrames)", tint: Color(red: 0.48, green: 0.76, blue: 0.92)),
                .init(label: "Payload", value: payloadText, tint: Color(red: 0.44, green: 0.54, blue: 0.86))
            ],
            detailLines: focusDetailLines,
            detailActionHandler: onDetailAction
        )
    }

    private var focusDetailVisuals: [HardwareGraphFocusDetailVisual] {
        var visuals: [HardwareGraphFocusDetailVisual] = [
            .actions(
                HardwareGraphFocusActionsSnapshot(
                    id: "\(focusID)-power",
                    title: "Meter Power",
                    subtitle: "Turn the stereo meter fully on or off when you want to trade live audio metering for lower background CPU.",
                    rows: powerRows
                )
            ),
            .actions(
                HardwareGraphFocusActionsSnapshot(
                    id: "\(focusID)-sources",
                    title: "Audio Source",
                    subtitle: "Keep System Mix as the default, or latch onto one running app when you want the meters to ignore the rest of the machine.",
                    rows: sourceActionRows
                )
            ),
            .actions(
                HardwareGraphFocusActionsSnapshot(
                    id: "\(focusID)-backends",
                    title: "Capture Backends",
                    subtitle: "Switch paths live while this focused view stays open so we can see which backend is actually receiving audio.",
                    rows: backendActionRows
                )
            ),
            .actions(
                HardwareGraphFocusActionsSnapshot(
                    id: "\(focusID)-virtual-inputs",
                    title: "Virtual Input Device",
                    subtitle: "Pick which Loopback or BlackHole-style stereo input should be used when the Virtual Input backend is active.",
                    rows: virtualInputDeviceRows
                )
            ),
            .actions(
                HardwareGraphFocusActionsSnapshot(
                    id: "\(focusID)-diagnostics",
                    title: "Core Audio Debug",
                    subtitle: "These rows tell us whether callbacks are arriving, whether they carry non-zero samples, and where the last payload came from.",
                    rows: diagnosticRows
                )
            )
        ]

        if snapshot.supportsScreenCapture {
            visuals.append(
                .actions(
                    HardwareGraphFocusActionsSnapshot(
                        id: "\(focusID)-permissions",
                        title: "Screen Capture Access",
                        subtitle: "This only matters for the Screen Capture fallback path.",
                        rows: permissionRows
                    )
                )
            )
        }

        return visuals
    }

    private var powerRows: [HardwareGraphFocusActionRowSnapshot] {
        [
            HardwareGraphFocusActionRowSnapshot(
                id: snapshot.isCaptureEnabled
                    ? SystemAudioOutputMeterModel.FocusAction.disableCapture
                    : SystemAudioOutputMeterModel.FocusAction.enableCapture,
                name: "Stereo Metering",
                statusText: snapshot.isCaptureEnabled ? "On" : "Off",
                subtitleText: snapshot.isCaptureEnabled
                    ? "Currently sampling the selected backend for live L/R output metering."
                    : "Currently stopped to reduce background CPU and audio processing.",
                detailText: snapshot.isCaptureEnabled
                    ? "Turning this off tears down the active meter backend rather than merely hiding the UI."
                    : "Turning this on recreates the current preferred backend and resumes live output metering.",
                tone: snapshot.isCaptureEnabled ? .positive : .neutral,
                actionTitle: snapshot.isCaptureEnabled ? "Turn Off" : "Turn On",
                isActionEnabled: true,
                isActionInProgress: false
            )
        ]
    }

    private var backendActionRows: [HardwareGraphFocusActionRowSnapshot] {
        [
            HardwareGraphFocusActionRowSnapshot(
                id: SystemAudioOutputMeterModel.FocusAction.useAutomatic,
                name: "Automatic",
                statusText: snapshot.backendPreference == .automatic ? "Selected" : "Available",
                subtitleText: "Prefers Core Audio Tap on macOS 14.2+, then Screen Capture, then Virtual Input only when native routes are unavailable.",
                detailText: "This is the default path and should feel the least fussy once the healthiest backend is available on this Mac.",
                tone: snapshot.backendPreference == .automatic ? .positive : .neutral,
                actionTitle: snapshot.backendPreference == .automatic ? nil : "Use Automatic",
                isActionEnabled: true,
                isActionInProgress: false
            ),
            HardwareGraphFocusActionRowSnapshot(
                id: SystemAudioOutputMeterModel.FocusAction.useCoreAudioTap,
                name: "Core Audio Tap",
                statusText: snapshot.selectedBackend == .coreAudioTap ? "Active" : (snapshot.supportsCoreAudioTap ? "Available" : "Unavailable"),
                subtitleText: "Native low-level tap for the current macOS output mix.",
                detailText: snapshot.supportsCoreAudioTap ? "Best long-term architecture on macOS 14.2 and newer." : "This backend needs macOS 14.2 or newer.",
                tone: snapshot.selectedBackend == .coreAudioTap ? .positive : (snapshot.supportsCoreAudioTap ? .neutral : .attention),
                actionTitle: (snapshot.selectedBackend == .coreAudioTap || !snapshot.supportsCoreAudioTap) ? nil : "Use Core Audio",
                isActionEnabled: snapshot.supportsCoreAudioTap,
                isActionInProgress: false
            ),
            HardwareGraphFocusActionRowSnapshot(
                id: SystemAudioOutputMeterModel.FocusAction.useScreenCapture,
                name: "Screen Capture",
                statusText: snapshot.selectedBackend == .screenCapture ? "Active" : (snapshot.supportsScreenCapture ? "Available" : "Unavailable"),
                subtitleText: "Reliable fallback that captures the current system audio mix.",
                detailText: snapshot.supportsScreenCapture ? "Useful when Core Audio taps are alive but still suspiciously quiet." : "This backend needs macOS 13 or newer.",
                tone: snapshot.selectedBackend == .screenCapture ? .positive : (snapshot.supportsScreenCapture ? .neutral : .attention),
                actionTitle: (snapshot.selectedBackend == .screenCapture || !snapshot.supportsScreenCapture) ? nil : "Use Screen Capture",
                isActionEnabled: snapshot.supportsScreenCapture,
                isActionInProgress: false
            ),
            HardwareGraphFocusActionRowSnapshot(
                id: SystemAudioOutputMeterModel.FocusAction.useVirtualInput,
                name: "Virtual Input",
                statusText: snapshot.selectedBackend == .virtualInput ? "Active" : (snapshot.supportsVirtualInputFallback ? "Available" : "Unavailable"),
                subtitleText: "Meters a routed Loopback or BlackHole-style stereo input instead of a native output tap.",
                detailText: snapshot.supportsVirtualInputFallback
                    ? "Currently targeting \(snapshot.virtualInputDeviceText). This works as a best-effort fallback on older macOS and as an advanced manual routing option on newer systems."
                    : "Install or configure Loopback or BlackHole, then route your system mix into its stereo input if you want this manual fallback path.",
                tone: snapshot.selectedBackend == .virtualInput ? .positive : (snapshot.supportsVirtualInputFallback ? .neutral : .attention),
                actionTitle: (snapshot.selectedBackend == .virtualInput || !snapshot.supportsVirtualInputFallback) ? nil : "Use Virtual Input",
                isActionEnabled: snapshot.supportsVirtualInputFallback,
                isActionInProgress: false
            ),
            HardwareGraphFocusActionRowSnapshot(
                id: SystemAudioOutputMeterModel.FocusAction.restartCapture,
                name: "Restart Capture",
                statusText: "Ready",
                subtitleText: "Recreate the current backend session without leaving the Hardware page.",
                detailText: "Handy after output-device changes, after granting Screen Recording access, or after re-routing a Loopback / BlackHole device.",
                tone: .neutral,
                actionTitle: "Restart",
                isActionEnabled: true,
                isActionInProgress: false
            )
        ]
    }

    private var virtualInputDeviceRows: [HardwareGraphFocusActionRowSnapshot] {
        guard snapshot.availableVirtualInputDevices.isEmpty == false else {
            return [
                HardwareGraphFocusActionRowSnapshot(
                    id: "\(focusID)-virtual-input-empty",
                    name: "No Compatible Virtual Input",
                    statusText: "Unavailable",
                    subtitleText: "Looking for Loopback or BlackHole stereo input devices.",
                    detailText: "Install or configure a compatible virtual input if you want this backend available on this Mac.",
                    tone: .attention,
                    actionTitle: nil,
                    isActionEnabled: false,
                    isActionInProgress: false
                )
            ]
        }

        return snapshot.availableVirtualInputDevices.map { target in
            let isSelected = snapshot.selectedVirtualInputID == target.uid
            let sampleRateText = target.sampleRate > 0
                ? String(format: "%.1f kHz", target.sampleRate / 1000.0)
                : "Unknown rate"
            return HardwareGraphFocusActionRowSnapshot(
                id: SystemAudioOutputMeterModel.FocusAction.selectVirtualInputPrefix + target.uid,
                name: target.displayName,
                statusText: isSelected ? "Selected" : "Available",
                subtitleText: "\(target.subtitle) · \(sampleRateText)",
                detailText: "Use \(target.displayName) whenever the Virtual Input backend is active. This is handy for complex Loopback or BlackHole routing graphs.",
                tone: isSelected ? .positive : .neutral,
                actionTitle: isSelected ? nil : "Use Device",
                isActionEnabled: true,
                isActionInProgress: false
            )
        }
    }

    private var sourceActionRows: [HardwareGraphFocusActionRowSnapshot] {
        var rows: [HardwareGraphFocusActionRowSnapshot] = [
            HardwareGraphFocusActionRowSnapshot(
                id: SystemAudioOutputMeterModel.FocusAction.useSystemMix,
                name: "System Mix",
                statusText: snapshot.selectedSourceID == "system-mix" ? "Selected" : "Available",
                subtitleText: "Meter the full output mix from the current macOS device.",
                detailText: "This keeps the card broad and is still the best default when you want overall stereo activity.",
                tone: snapshot.selectedSourceID == "system-mix" ? .positive : .neutral,
                actionTitle: snapshot.selectedSourceID == "system-mix" ? nil : "Use System Mix",
                isActionEnabled: true,
                isActionInProgress: false
            )
        ]

        if snapshot.backendPreference == .virtualInput {
            rows.append(
                HardwareGraphFocusActionRowSnapshot(
                    id: "\(focusID)-virtual-input-source-note",
                    name: "App Isolation",
                    statusText: "Unavailable",
                    subtitleText: "Virtual Input meters a routed stereo input rather than one directly isolated process.",
                    detailText: "Switch back to Automatic, Core Audio Tap, or Screen Capture if you want to target a single running app instead of the whole routed mix.",
                    tone: .attention,
                    actionTitle: nil,
                    isActionEnabled: false,
                    isActionInProgress: false
                )
            )
        } else if snapshot.supportsCoreAudioTap || snapshot.supportsScreenCapture {
            rows.append(
                contentsOf: snapshot.availableSourceTargets.map { target in
                    let isSelected = snapshot.selectedSourceID == target.id
                    return HardwareGraphFocusActionRowSnapshot(
                        id: SystemAudioOutputMeterModel.FocusAction.selectAppPrefix + target.id,
                        name: target.displayName,
                        statusText: isSelected ? "Selected" : "Available",
                        subtitleText: target.subtitle,
                        detailText: "Listen only to \(target.displayName). Automatic will prefer Screen Capture for app-scoped metering, while Core Audio Tap can still try a per-process route on newer macOS builds.",
                        tone: isSelected ? .positive : .neutral,
                        actionTitle: isSelected ? nil : "Use App Only",
                        isActionEnabled: true,
                        isActionInProgress: false
                    )
                }
            )
        }

        return rows
    }

    private var diagnosticRows: [HardwareGraphFocusActionRowSnapshot] {
        [
            HardwareGraphFocusActionRowSnapshot(
                id: "\(focusID)-diag-frames",
                name: "Frame Flow",
                statusText: "\(snapshot.diagnostics.totalFrames)",
                subtitleText: "\(snapshot.diagnostics.hotFrames) hot frames",
                detailText: "If this climbs while the meters stay still, we are probably receiving silent buffers.",
                tone: snapshot.diagnostics.totalFrames > 0 ? .positive : .attention,
                actionTitle: nil,
                isActionEnabled: false,
                isActionInProgress: false
            ),
            HardwareGraphFocusActionRowSnapshot(
                id: "\(focusID)-diag-buffer",
                name: "Last Buffer Source",
                statusText: snapshot.diagnostics.lastBufferSource,
                subtitleText: "Output UID \(outputUIDText)",
                detailText: "This tells us whether the most recent samples came from Core Audio input, Core Audio output, Screen Capture audio, or a routed virtual input device.",
                tone: .neutral,
                actionTitle: nil,
                isActionEnabled: false,
                isActionInProgress: false
            ),
            HardwareGraphFocusActionRowSnapshot(
                id: "\(focusID)-diag-payload",
                name: "Payload",
                statusText: payloadText,
                subtitleText: sampleCountText,
                detailText: "A healthy live backend should show real byte counts and sample counts rather than staying at zero.",
                tone: snapshot.diagnostics.lastPayloadBytes > 0 ? .positive : .attention,
                actionTitle: nil,
                isActionEnabled: false,
                isActionInProgress: false
            ),
            HardwareGraphFocusActionRowSnapshot(
                id: "\(focusID)-diag-error",
                name: "Last Error",
                statusText: snapshot.diagnostics.lastErrorText == nil ? "None" : "Captured",
                subtitleText: snapshot.capturePathText,
                detailText: lastErrorText,
                tone: snapshot.diagnostics.lastErrorText == nil ? .positive : .attention,
                actionTitle: nil,
                isActionEnabled: false,
                isActionInProgress: false
            )
        ]
    }

    private var permissionRows: [HardwareGraphFocusActionRowSnapshot] {
        [
            HardwareGraphFocusActionRowSnapshot(
                id: SystemAudioOutputMeterModel.FocusAction.requestScreenCaptureAccess,
                name: "Request Screen Recording",
                statusText: snapshot.screenCapturePermissionGranted ? "Granted" : "Needed",
                subtitleText: "Required only for the Screen Capture fallback backend.",
                detailText: snapshot.screenCapturePermissionGranted ? "This backend already has access." : "Use this if you want instant fallback to Screen Capture audio metering.",
                tone: snapshot.screenCapturePermissionGranted ? .positive : .attention,
                actionTitle: snapshot.screenCapturePermissionGranted ? nil : "Request Access",
                isActionEnabled: !snapshot.screenCapturePermissionGranted,
                isActionInProgress: false
            ),
            HardwareGraphFocusActionRowSnapshot(
                id: SystemAudioOutputMeterModel.FocusAction.openScreenCaptureSettings,
                name: "Open Settings",
                statusText: "System Settings",
                subtitleText: "Jump to the Screen Recording privacy pane if the prompt was already denied.",
                detailText: "macOS sometimes needs approval to be flipped manually after the first denial.",
                tone: .neutral,
                actionTitle: "Open Settings",
                isActionEnabled: true,
                isActionInProgress: false
            )
        ]
    }

    private var focusDetailLines: [String] {
        var lines = [
            "This meter follows the current macOS stereo output independently of Podcast Preview's in-app routed helper path.",
            "Selected source: \(snapshot.sourceText).",
            "Current backend: \(snapshot.capturePathText).",
            "Output device: \(snapshot.outputDeviceText).",
            "Last buffer source: \(snapshot.diagnostics.lastBufferSource)."
        ]

        if snapshot.selectedBackend == .virtualInput {
            lines.append("Virtual Input is currently targeting \(snapshot.virtualInputDeviceText), so this Mac is reading a routed stereo input rather than a native system-output tap.")
        }

        if snapshot.selectedSourceID != "system-mix" {
            lines.append("App-scoped metering tries to isolate one process rather than the whole machine mix, so silence usually means the selected app is not currently producing output on the active route.")
        }

        if !snapshot.isCaptureEnabled {
            lines.append("Stereo metering is currently turned off, so no audio callback work should be running for this card.")
        }

        if snapshot.isCaptureEnabled && snapshot.diagnostics.totalFrames == 0 {
            lines.append("No capture callbacks have arrived yet, which usually points to a backend or permission problem rather than a quiet signal.")
        } else if snapshot.isCaptureEnabled && snapshot.diagnostics.hotFrames == 0 {
            lines.append("Callbacks are arriving, but they have all been effectively silent so far.")
        }

        if let lastError = snapshot.diagnostics.lastErrorText, !lastError.isEmpty {
            lines.append("Last error: \(lastError)")
        }

        return lines
    }

    private var lastSignalText: String {
        guard let lastSignalDate = snapshot.lastSignalDate else { return "No signal yet" }
        let seconds = max(0, Int(Date().timeIntervalSince(lastSignalDate)))
        if seconds < 2 {
            return "Just now"
        }
        if seconds < 60 {
            return "\(seconds)s ago"
        }
        return "\(seconds / 60)m ago"
    }

    private var backendPreferenceText: String {
        switch snapshot.backendPreference {
        case .automatic:
            return "Automatic"
        case .coreAudioTap:
            return "Core Audio Tap"
        case .screenCapture:
            return "Screen Capture"
        case .virtualInput:
            return "Virtual Input"
        }
    }

    private var payloadText: String {
        let bytes = snapshot.diagnostics.lastPayloadBytes
        guard bytes > 0 else { return "0 B" }
        if bytes >= 1024 * 1024 {
            return String(format: "%.2f MB", Double(bytes) / 1_048_576.0)
        }
        if bytes >= 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        }
        return "\(bytes) B"
    }

    private var sampleCountText: String {
        let count = snapshot.diagnostics.lastSampleCount
        return count > 0 ? "\(count) samples" : "0 samples"
    }

    private var outputUIDText: String {
        snapshot.diagnostics.outputDeviceUID.isEmpty ? "Unavailable" : snapshot.diagnostics.outputDeviceUID
    }

    private var lastErrorText: String {
        snapshot.diagnostics.lastErrorText ?? "No backend errors recorded."
    }

    private func refreshFocusedStateIfNeeded() {
        guard activeFocusID == focusID,
              let focusState,
              let onFocusedStateChange else { return }
        onFocusedStateChange(focusState)
    }
}

struct SupportProcessesCard: View {
    @Environment(\.appUIScale) private var appUIScale
    let rows: [AppSupportProcessMonitor.Row]
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil
    var focusState: HardwareGraphFocusState? = nil

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledHeaderSpacing: CGFloat { 10 * appUIScale }
    private var scaledPadding: CGFloat { 12 * appUIScale }
    private var scaledTitleRowHeight: CGFloat { 24 * appUIScale }
    private var scaledTitleRowBottomPadding: CGFloat { 2 * appUIScale }
    private var scaledRowVerticalPadding: CGFloat { 8 * appUIScale }
    private var scaledStatusSpacing: CGFloat { 6 * appUIScale }
    private var scaledDotSize: CGFloat { 8 * appUIScale }
    private var scaledCardHeight: CGFloat {
        let baseHeight = 78 * appUIScale + scaledTitleRowHeight + scaledTitleRowBottomPadding
        let rowsHeight = CGFloat(max(rows.count, 1)) * 30 * appUIScale
        let footerHeight = 26 * appUIScale
        return baseHeight + rowsHeight + footerHeight
    }
    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }
    private var scaledCaption2FontSize: CGFloat { 11 * appUIScale }
    private var headerDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
            .padding(.horizontal, -scaledPadding)
    }
    private var focusRefreshSignature: Int {
        var hasher = Hasher()
        hasher.combine(focusState?.signatureHash ?? 0)
        return hasher.finalize()
    }

    var body: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius)
            .fill(Color.black.opacity(0.08))
            .overlay(
                ThemeRoundedRectangle(cornerRadius: scaledCornerRadius)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .frame(height: scaledCardHeight)
            .clipShape(ThemeRoundedRectangle(cornerRadius: scaledCornerRadius))
            .overlay(
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 12 * appUIScale) {
                        Text("Helper Services")
                            .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Spacer(minLength: 8 * appUIScale)

                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 24 * appUIScale, weight: .semibold))
                            .foregroundColor(.gray)
                            .frame(width: 28 * appUIScale, height: 28 * appUIScale)
                    }
                    .frame(height: scaledTitleRowHeight)
                    .padding(.bottom, scaledTitleRowBottomPadding)

                    headerDivider

                    VStack(alignment: .leading, spacing: scaledHeaderSpacing) {
                        if rows.isEmpty {
                            Text("No helper services tracked")
                                .font(.system(size: scaledCaptionFontSize, weight: .regular))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, scaledPadding)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                    HStack(spacing: 10 * appUIScale) {
                                        Text(row.name)
                                            .font(.system(size: scaledCaptionFontSize, weight: .regular))
                                            .lineLimit(1)

                                        Spacer(minLength: 8 * appUIScale)

                                        HStack(spacing: scaledStatusSpacing) {
                                            Circle()
                                                .fill(statusDotColor(for: row.status))
                                                .overlay(
                                                    Circle()
                                                        .stroke(Color.white.opacity(row.status == .unknown ? 0.18 : 0.10), lineWidth: 1)
                                                )
                                                .frame(width: scaledDotSize, height: scaledDotSize)

                                            Text(statusText(for: row))
                                                .font(.system(size: scaledCaption2FontSize, weight: .medium))
                                                .foregroundColor(statusTextColor(for: row.status))
                                        }
                                        .frame(width: 108 * appUIScale, alignment: .leading)
                                    }
                                    .padding(.vertical, scaledRowVerticalPadding)

                                    if index < rows.count - 1 {
                                        Rectangle()
                                            .fill(Color.white.opacity(0.10))
                                            .frame(height: 1)
                                    }
                                }
                            }
                        }

                        Text("Unknown can mean missing registration, approval required, or unsupported.")
                            .font(.system(size: scaledCaption2FontSize, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(scaledPadding)
            )
            .contentShape(ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous))
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
                refreshFocusedStateIfNeeded()
            }
    }

    private func statusText(for row: AppSupportProcessMonitor.Row) -> String {
        row.statusLabel ?? row.status.displayText
    }

    private func statusDotColor(for status: AppSupportProcessMonitor.Status) -> Color {
        switch status {
        case .unknown:
            return Color.black.opacity(0.72)
        case .idle:
            return Color(red: 0.78, green: 0.18, blue: 0.18)
        case .active:
            return Color(red: 0.17, green: 0.72, blue: 0.32)
        }
    }

    private func statusTextColor(for status: AppSupportProcessMonitor.Status) -> Color {
        switch status {
        case .unknown:
            return .secondary
        case .idle:
            return Color(red: 0.88, green: 0.34, blue: 0.30)
        case .active:
            return Color(red: 0.42, green: 0.88, blue: 0.56)
        }
    }

    private func refreshFocusedStateIfNeeded() {
        guard let focusState,
              focusState.id == activeFocusID,
              let onFocusedStateChange else { return }
        onFocusedStateChange(focusState)
    }
}

// MARK: - GPUUnitCard

struct GPUUnitCard: View {
    @Environment(\.appUIScale) private var appUIScale
    let gpuUnits: [GPUUnitMetadata]
    let gpuSampler: GPUStatsSampler
    var ramSnapshot: RAMStatsSampler.MemorySnapshot? = nil
    var cpuDisplayName: String? = nil
    var gpuUsage: Float? = nil
    var gpuHistory: [Float] = []
    var gpuLabel: String? = nil
    var gpuCurrentText: String? = nil
    var gpuDeltaText: String? = nil
    var gpuFocusInlineMeters: [HardwareGraphFocusInlineMeter] = []
    var gpuFocusLinePanels: [HardwareGraphFocusLinePanelSnapshot] = []
    var gpuFocusDetailVisuals: [HardwareGraphFocusDetailVisual] = []
    var gpuFocusContext: HardwareGraphFocusGPUContext? = nil
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledPadding: CGFloat { 12 * appUIScale }
    private var scaledStackSpacing: CGFloat { 8 * appUIScale }
    private var scaledDetailSpacing: CGFloat { 3 * appUIScale }
    private var scaledContentSpacing: CGFloat { 12 * appUIScale }
    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }
    private var scaledCaption2FontSize: CGFloat { 11 * appUIScale }
    private var scaledDetailLineHeight: CGFloat { 16 * appUIScale }
    private var scaledTitleHeight: CGFloat { 18 * appUIScale }
    private var scaledIndicatorColumnWidth: CGFloat { 60 * appUIScale }
    private var scaledIndicatorSize: CGFloat { 48 * appUIScale }
    private var scaledDividerPadding: CGFloat { 5 * appUIScale }
    private var hasGPUData: Bool { !gpuHistory.isEmpty || gpuUsage != nil }
    private var focusID: String {
        if hasGPUData, let context = gpuFocusContext {
            return "usage-gpu-\(context.deviceID)"
        }
        return "gpu-unit-card"
    }
    private var resolvedGPUIdentities: [SharedResolvedGPUIdentity] {
        sharedResolveGPUIdentities(liveGPUs: gpuSampler.gpus, metadataUnits: gpuUnits)
    }

    // MARK: Height computation

    private func visibleRowCount(for identity: SharedResolvedGPUIdentity) -> Int {
        var n = 1  // name row
        if identity.metadata?.bus != nil { n += 1 }
        if identity.metadata?.gpuType != nil { n += 1 }
        if identity.metadata?.metalFamily != nil { n += 1 }
        if identity.coreCount != nil { n += 1 }
        if sharedGPUMemorySummary(
            liveGPU: identity.liveGPU,
            metadata: identity.metadata,
            memorySnapshot: ramSnapshot,
            cpuDisplayName: cpuDisplayName
        ) != nil {
            n += 1
        }
        n += sharedGPUMemorySupplementalRows(
            liveGPU: identity.liveGPU,
            metadata: identity.metadata,
            memorySnapshot: ramSnapshot,
            cpuDisplayName: cpuDisplayName
        ).count
        if identity.metadata?.connectedDisplayCount != nil { n += 1 }
        if identity.metadata?.deviceID != nil  { n += 1 }
        if identity.metadata?.revisionID != nil { n += 1 }
        if identity.metadata?.pcieWidth != nil  { n += 1 }
        if identity.metadata?.isRemovable != nil { n += 1 }
        return n
    }

    private var scaledCardHeight: CGFloat {
        let header = scaledTitleHeight + scaledStackSpacing
        var content: CGFloat = 0
        for (i, identity) in resolvedGPUIdentities.enumerated() {
            if i > 0 { content += 1 + scaledDividerPadding * 2 }
            content += CGFloat(visibleRowCount(for: identity)) * (scaledDetailLineHeight + scaledDetailSpacing)
        }
        return max(160 * appUIScale, header + content + scaledPadding * 2)
    }

    // MARK: Background

    @ViewBuilder private var cardBackground: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius)
            .fill(Color.black.opacity(0.08))
            .overlay(
                ThemeRoundedRectangle(cornerRadius: scaledCornerRadius)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
    }

    // MARK: Content

    @ViewBuilder private var textContent: some View {
        VStack(alignment: .leading, spacing: scaledStackSpacing) {
            Text("GPU")
                .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: scaledTitleHeight, alignment: .leading)

            ForEach(Array(resolvedGPUIdentities.enumerated()), id: \.offset) { index, identity in
                if index > 0 {
                    Divider()
                        .opacity(0.25)
                        .padding(.vertical, scaledDividerPadding)
                }
                unitSection(identity)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: scaledCardHeight - scaledPadding * 2, alignment: .topLeading)
    }

    @ViewBuilder
    private func unitSection(_ identity: SharedResolvedGPUIdentity) -> some View {
        VStack(alignment: .leading, spacing: scaledDetailSpacing) {
            Text(identity.displayName)
                .font(.system(size: scaledCaptionFontSize, weight: .medium))
                .foregroundColor(.secondary.opacity(0.92))
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: scaledDetailLineHeight, alignment: .leading)

            if let bus = identity.metadata?.bus {
                detailRow(label: "Bus", value: bus)
            }
            if let gpuType = identity.metadata?.gpuType {
                detailRow(label: "Type", value: gpuType)
            }
            if let metal = identity.metadata?.metalFamily {
                detailRow(label: "Metal", value: metal)
            }

            if let cores = identity.coreCount {
                detailRow(label: "Cores", value: "\(cores)")
            }

            if let memorySummary = sharedGPUMemorySummary(
                liveGPU: identity.liveGPU,
                metadata: identity.metadata,
                memorySnapshot: ramSnapshot,
                cpuDisplayName: cpuDisplayName
            ) {
                detailRow(label: memorySummary.label, value: memorySummary.value, lineLimit: 2)
            }

            ForEach(Array(sharedGPUMemorySupplementalRows(
                liveGPU: identity.liveGPU,
                metadata: identity.metadata,
                memorySnapshot: ramSnapshot,
                cpuDisplayName: cpuDisplayName
            ).enumerated()), id: \.offset) { entry in
                detailRow(label: entry.element.label, value: entry.element.value)
            }

            if let displays = identity.metadata?.connectedDisplayCount {
                detailRow(label: "Displays", value: "\(displays)")
            }
            if let deviceID = identity.metadata?.deviceID {
                detailRow(label: "Device ID", value: deviceID)
            }
            if let revID = identity.metadata?.revisionID {
                detailRow(label: "Revision",  value: revID)
            }
            if let pcie = identity.metadata?.pcieWidth {
                detailRow(label: "PCIe",      value: pcie)
            }
            if let removable = identity.metadata?.isRemovable {
                detailRow(label: "Removable", value: removable ? "Yes" : "No")
            }
        }
    }

    @ViewBuilder
    private func detailRow(label: String, value: String?, lineLimit: Int = 1) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6 * appUIScale) {
            Text("\(label):")
                .font(.system(size: scaledCaption2FontSize, weight: .regular))
                .foregroundColor(.secondary)
            Text(value ?? "—")
                .font(.system(size: scaledCaptionFontSize, weight: .regular))
                .foregroundColor(value == nil ? .secondary.opacity(0.4) : .secondary.opacity(0.92))
                .lineLimit(lineLimit)
        }
        .frame(maxWidth: .infinity, minHeight: scaledDetailLineHeight, alignment: .leading)
    }

    @ViewBuilder private var indicatorColumn: some View {
        VStack {
            Spacer(minLength: 0)
            Image(systemName: "cpu.fill")
                .font(.system(size: 32 * appUIScale, weight: .regular))
                .foregroundColor(Color(red: 0.85, green: 0.20, blue: 0.20))
            Spacer(minLength: 0)
        }
        .frame(width: scaledIndicatorColumnWidth, height: scaledCardHeight - scaledPadding * 2, alignment: .top)
    }

    // MARK: Focus State

    private var gpuHardwareStats: [HardwareGraphFocusStat] {
        guard let primaryIdentity = resolvedGPUIdentities.first else { return [] }
        var stats: [HardwareGraphFocusStat] = []
        if let cores = primaryIdentity.coreCount { stats.append(.init(label: "Cores", value: "\(cores)")) }
        if let memorySummary = sharedGPUMemorySummary(
            liveGPU: primaryIdentity.liveGPU,
            metadata: primaryIdentity.metadata,
            memorySnapshot: ramSnapshot,
            cpuDisplayName: cpuDisplayName
        ) {
            stats.append(.init(label: memorySummary.label, value: memorySummary.value))
        }
        if let displays = primaryIdentity.metadata?.connectedDisplayCount { stats.append(.init(label: "Displays", value: "\(displays)")) }
        if let bus = primaryIdentity.metadata?.bus { stats.append(.init(label: "Bus", value: bus)) }
        if let gpuType = primaryIdentity.metadata?.gpuType { stats.append(.init(label: "Type", value: gpuType)) }
        if let metal = primaryIdentity.metadata?.metalFamily { stats.append(.init(label: "Metal", value: metal)) }
        return stats
    }

    private var gpuHardwareDetailLines: [String] {
        guard let primaryIdentity = resolvedGPUIdentities.first else { return [] }
        var lines: [String] = []
        if let bus = primaryIdentity.metadata?.bus { lines.append("Bus: \(bus)") }
        if let gpuType = primaryIdentity.metadata?.gpuType { lines.append("Type: \(gpuType)") }
        if let metal = primaryIdentity.metadata?.metalFamily { lines.append("Metal: \(metal)") }
        if let cores = primaryIdentity.coreCount { lines.append("Cores: \(cores)") }
        if let memorySummary = sharedGPUMemorySummary(
            liveGPU: primaryIdentity.liveGPU,
            metadata: primaryIdentity.metadata,
            memorySnapshot: ramSnapshot,
            cpuDisplayName: cpuDisplayName
        ) {
            lines.append("\(memorySummary.label): \(memorySummary.value)")
        }
        lines.append(contentsOf: sharedGPUMemorySupplementalRows(
            liveGPU: primaryIdentity.liveGPU,
            metadata: primaryIdentity.metadata,
            memorySnapshot: ramSnapshot,
            cpuDisplayName: cpuDisplayName
        ).map { "\($0.label): \($0.value)" })
        if let displays = primaryIdentity.metadata?.connectedDisplayCount { lines.append("Displays: \(displays)") }
        return lines
    }

    private func percentageString(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private var focusState: HardwareGraphFocusState? {
        guard let primaryIdentity = resolvedGPUIdentities.first else { return nil }

        if hasGPUData, let context = gpuFocusContext {
            // Combined focus state: GPU history chart + hardware identity details
            let accentColor = Color(red: 0.85, green: 0.20, blue: 0.20)
            let lineValues = gpuHistory.map { Optional(Double($0)) }
            let observed = lineValues.compactMap { $0 }

            var stats: [HardwareGraphFocusStat] = []
            if let gpuUsage {
                stats.append(.init(label: "Live", value: percentageString(Double(gpuUsage)), tint: accentColor))
            }
            if !observed.isEmpty {
                let average = observed.reduce(0, +) / Double(observed.count)
                stats.append(.init(label: "Window Avg", value: percentageString(average)))
                stats.append(.init(label: "Peak", value: percentageString(observed.max() ?? 0)))
                stats.append(.init(label: "Floor", value: percentageString(observed.min() ?? 0)))
                stats.append(.init(label: "Samples", value: "\(gpuHistory.count)"))
            }
            if let gpuDeltaText, !gpuDeltaText.isEmpty {
                stats.append(.init(label: "Trend", value: gpuDeltaText, tint: gpuDeltaText.hasPrefix("↑") ? Color(red: 0.90, green: 0.40, blue: 0.40) : Color(red: 0.30, green: 0.75, blue: 0.45)))
            }
            stats += gpuHardwareStats

            let leadingDetailLines = [gpuCurrentText].compactMap { detail -> String? in
                guard let detail, !detail.isEmpty else { return nil }
                return gpuHardwareDetailLines.contains(detail) ? nil : detail
            }
            let detailLines = leadingDetailLines + gpuHardwareDetailLines

            let subtitle = gpuLabel?.isEmpty == false ? gpuLabel : "Focused view of the visible history window"

            return HardwareGraphFocusState(
                id: focusID,
                title: "GPU",
                subtitle: subtitle,
                accentColor: accentColor,
                insightTarget: .gpu,
                heatmapTarget: .init(.gpu),
                attributionTarget: .init(.gpu),
                gpuContext: context,
                visualization: .lineChart([
                    HardwareGraphFocusSeries(
                        id: "primary",
                        label: "GPU",
                        color: accentColor,
                        values: lineValues
                    )
                ]),
                inlineMeters: gpuFocusInlineMeters,
                linePanelSnapshots: gpuFocusLinePanels,
                detailVisuals: gpuFocusDetailVisuals,
                stats: stats,
                detailLines: detailLines
            )
        }

        // Fallback: summary-only focus state when no GPU data available
        var detailLines: [String] = []
        detailLines = gpuHardwareDetailLines

        return HardwareGraphFocusState(
            id: focusID,
            title: "GPU Unit",
            subtitle: "Hardware identity information for the GPU unit(s) in this system.",
            accentColor: Color(red: 0.85, green: 0.20, blue: 0.20),
            visualization: .summary(
                HardwareGraphFocusSummarySnapshot(
                    title: primaryIdentity.displayName,
                    subtitle: "GPU hardware identity and configuration details.",
                    hero: nil,
                    tiles: gpuHardwareStats.map { .init(title: $0.label, value: $0.value, detail: nil, tint: Color(red: 0.85, green: 0.20, blue: 0.20)) },
                    rows: detailLines.map { .init(label: "", value: $0) }
                )
            ),
            stats: gpuHardwareStats,
            detailLines: detailLines
        )
    }

    private var focusRefreshSignature: Int {
        var hasher = Hasher()
        // GPU identity is static hardware info — count + primary GPU id is sufficient.
        hasher.combine(resolvedGPUIdentities.count)
        if let primary = resolvedGPUIdentities.first {
            hasher.combine(primary.liveGPU?.id)
            hasher.combine(primary.displayName)
        }
        // Live usage: single value captures current load.
        if let gpuUsage {
            hasher.combine(Int((Double(gpuUsage) * 1000).rounded()))
        }
        // History: count + most-recent sample instead of full array iteration.
        hasher.combine(gpuHistory.count)
        if let lastHistoryVal = gpuHistory.last {
            hasher.combine(Int((Double(lastHistoryVal) * 1000).rounded()))
        }
        hasher.combine(gpuLabel ?? "")
        hasher.combine(gpuCurrentText ?? "")
        hasher.combine(gpuDeltaText ?? "")
        if let context = gpuFocusContext {
            hasher.combine(context.deviceID)
        }
        return hasher.finalize()
    }

    private func refreshFocusedStateIfNeeded() {
        guard activeFocusID == focusID,
              let focusState,
              let onFocusedStateChange else { return }
        onFocusedStateChange(focusState)
    }

    // MARK: Body

    var body: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius).themed()
            .frame(height: scaledCardHeight)
            .overlay(
                HStack(alignment: .top, spacing: scaledContentSpacing) {
                    textContent
                        .layoutPriority(1)
                    indicatorColumn
                }
                .padding(scaledPadding)
            )
            .clipShape(ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous))
            .contentShape(Rectangle())
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
                refreshFocusedStateIfNeeded()
            }
    }
}

// MARK: - MemoryUnitCard

struct MemoryUnitCard: View {
    @Environment(\.appUIScale) private var appUIScale
    let memoryUnit: MemoryUnitMetadata
    var memorySnapshot: RAMStatsSampler.MemorySnapshot? = nil
    var ramUsage: Float? = nil
    var ramHistory: [Float] = []
    var ramLabel: String? = nil
    var ramCurrentText: String? = nil
    var ramDeltaText: String? = nil
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil

    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledPadding: CGFloat { 12 * appUIScale }
    private var scaledStackSpacing: CGFloat { 8 * appUIScale }
    private var scaledDetailSpacing: CGFloat { 3 * appUIScale }
    private var scaledContentSpacing: CGFloat { 12 * appUIScale }
    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }
    private var scaledCaption2FontSize: CGFloat { 11 * appUIScale }
    private var scaledDetailLineHeight: CGFloat { 16 * appUIScale }
    private var scaledTitleHeight: CGFloat { 18 * appUIScale }
    private var scaledIndicatorColumnWidth: CGFloat { 60 * appUIScale }
    private var scaledIndicatorSize: CGFloat { 48 * appUIScale }
    private var scaledDividerPadding: CGFloat { 5 * appUIScale }
    private var hasRAMData: Bool { !ramHistory.isEmpty || ramUsage != nil }
    private var focusID: String { hasRAMData ? "usage-ram" : "memory-unit-card" }
    private var hardwareRows: [(label: String, value: String)] { sharedMemoryHardwareRows(for: memoryUnit) }
    private var liveRows: [(label: String, value: String)] { sharedMemoryLiveRows(from: memorySnapshot) }

    // MARK: Height computation

    private var visibleRowCount: Int {
        var n = 1
        n += hardwareRows.count
        n += liveRows.count
        return n
    }

    private var scaledCardHeight: CGFloat {
        let header = scaledTitleHeight + scaledStackSpacing
        let content = CGFloat(visibleRowCount) * (scaledDetailLineHeight + scaledDetailSpacing)
        return max(160 * appUIScale, header + content + scaledPadding * 2)
    }

    // MARK: Background

    @ViewBuilder private var cardBackground: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius)
            .fill(Color.black.opacity(0.08))
            .overlay(
                ThemeRoundedRectangle(cornerRadius: scaledCornerRadius)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
    }

    // MARK: Content

    @ViewBuilder private var textContent: some View {
        VStack(alignment: .leading, spacing: scaledStackSpacing) {
            Text("Memory")
                .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: scaledTitleHeight, alignment: .leading)

            unifiedMemorySection

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: scaledCardHeight - scaledPadding * 2, alignment: .topLeading)
    }

    @ViewBuilder
    private var unifiedMemorySection: some View {
        VStack(alignment: .leading, spacing: scaledDetailSpacing) {
            ForEach(Array(hardwareRows.enumerated()), id: \.offset) { entry in
                detailRow(label: entry.element.label, value: entry.element.value)
            }

            if !liveRows.isEmpty {
                Divider()
                    .opacity(0.25)
                    .padding(.vertical, scaledDividerPadding)
                ForEach(Array(liveRows.enumerated()), id: \.offset) { entry in
                    detailRow(label: entry.element.label, value: entry.element.value)
                }
            }
        }
    }

    @ViewBuilder
    private func detailRow(label: String, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6 * appUIScale) {
            Text("\(label):")
                .font(.system(size: scaledCaption2FontSize, weight: .regular))
                .foregroundColor(.secondary)
            Text(value ?? "—")
                .font(.system(size: scaledCaptionFontSize, weight: .regular))
                .foregroundColor(value == nil ? .secondary.opacity(0.4) : .secondary.opacity(0.92))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: scaledDetailLineHeight, alignment: .leading)
    }

    @ViewBuilder private var indicatorColumn: some View {
        VStack {
            Spacer(minLength: 0)
            Image(systemName: "memorychip")
                .font(.system(size: 32 * appUIScale, weight: .regular))
                .foregroundColor(.green)
            Spacer(minLength: 0)
        }
        .frame(width: scaledIndicatorColumnWidth, height: scaledCardHeight - scaledPadding * 2, alignment: .top)
    }

    // MARK: Focus State

    private var memoryUnitStats: [HardwareGraphFocusStat] {
        var stats: [HardwareGraphFocusStat] = []
        for row in hardwareRows {
            stats.append(.init(label: row.label, value: row.value))
        }
        return stats
    }

    private var memoryUnitDetailLines: [String] {
        sharedMemoryDetailLines(for: memoryUnit, snapshot: memorySnapshot)
    }

    private func percentageString(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private var focusState: HardwareGraphFocusState? {
        if hasRAMData {
            // Combined focus state: RAM history chart + hardware identity details
            let accentColor = Color(red: 0.10, green: 0.65, blue: 0.28)
            let lineValues = ramHistory.map { Optional(Double($0)) }
            let observed = lineValues.compactMap { $0 }

            var stats: [HardwareGraphFocusStat] = []
            if let ramUsage {
                stats.append(.init(label: "Live", value: percentageString(Double(ramUsage)), tint: accentColor))
            }
            if !observed.isEmpty {
                let average = observed.reduce(0, +) / Double(observed.count)
                stats.append(.init(label: "Window Avg", value: percentageString(average)))
                stats.append(.init(label: "Peak", value: percentageString(observed.max() ?? 0)))
                stats.append(.init(label: "Floor", value: percentageString(observed.min() ?? 0)))
                stats.append(.init(label: "Samples", value: "\(ramHistory.count)"))
            }
            if let ramDeltaText, !ramDeltaText.isEmpty {
                stats.append(.init(label: "Trend", value: ramDeltaText, tint: ramDeltaText.hasPrefix("↑") ? Color(red: 0.90, green: 0.40, blue: 0.40) : Color(red: 0.30, green: 0.75, blue: 0.45)))
            }
            stats += memoryUnitStats

            let leadingDetailLines = [ramCurrentText].compactMap { detail -> String? in
                guard let detail, !detail.isEmpty else { return nil }
                return memoryUnitDetailLines.contains(detail) ? nil : detail
            }
            let detailLines = leadingDetailLines + memoryUnitDetailLines

            let subtitle = ramLabel?.isEmpty == false ? ramLabel : "Focused view of the visible history window"

            return HardwareGraphFocusState(
                id: focusID,
                title: "RAM",
                subtitle: subtitle,
                accentColor: accentColor,
                insightTarget: .memory,
                heatmapTarget: .init(.memory),
                attributionTarget: .init(.memory),
                visualization: .lineChart([
                    HardwareGraphFocusSeries(
                        id: "primary",
                        label: "RAM",
                        color: accentColor,
                        values: lineValues
                    )
                ]),
                stats: stats,
                detailLines: detailLines
            )
        }

        // Fallback: summary-only focus state when no RAM data available
        return HardwareGraphFocusState(
            id: focusID,
            title: "Memory Unit",
            subtitle: "Hardware identity information for the memory unit(s) in this system.",
            accentColor: .green,
            visualization: .summary(
                HardwareGraphFocusSummarySnapshot(
                    title: "Memory Configuration",
                    subtitle: "Memory hardware identity and configuration details.",
                    hero: nil,
                    tiles: memoryUnitStats.map { .init(title: $0.label, value: $0.value, detail: nil, tint: .green) },
                    rows: memoryUnitDetailLines.map { .init(label: "", value: $0) }
                )
            ),
            stats: memoryUnitStats,
            detailLines: memoryUnitDetailLines
        )
    }

    private var focusRefreshSignature: Int {
        var hasher = Hasher()
        // Static hardware identity — changes at most on cold start.
        hasher.combine(memoryUnit.totalMemory)
        hasher.combine(memoryUnit.type)
        hasher.combine(memoryUnit.modules.count)
        // Live memory pressure — coarser precision (1%) is fine for focus-refresh gating.
        if let memorySnapshot {
            hasher.combine(Int((memorySnapshot.pressureValue * 100).rounded()))
            hasher.combine(memorySnapshot.pressureLevel)
            hasher.combine(memorySnapshot.usedBytes / (1024 * 1024)) // MB resolution, not byte-level
        }
        // Live usage + history: current value + count + tail sample; no need to walk every bucket.
        if let ramUsage {
            hasher.combine(Int((Double(ramUsage) * 1000).rounded()))
        }
        hasher.combine(ramHistory.count)
        if let lastHistoryVal = ramHistory.last {
            hasher.combine(Int((Double(lastHistoryVal) * 1000).rounded()))
        }
        hasher.combine(ramLabel ?? "")
        hasher.combine(ramCurrentText ?? "")
        return hasher.finalize()
    }

    private func refreshFocusedStateIfNeeded() {
        guard activeFocusID == focusID,
              let focusState,
              let onFocusedStateChange else { return }
        onFocusedStateChange(focusState)
    }

    // MARK: Body

    var body: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius).themed()
            .frame(height: scaledCardHeight)
            .overlay(
                HStack(alignment: .top, spacing: scaledContentSpacing) {
                    textContent
                        .layoutPriority(1)
                    indicatorColumn
                }
                .padding(scaledPadding)
            )
            .clipShape(ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous))
            .contentShape(Rectangle())
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
                refreshFocusedStateIfNeeded()
            }
    }
}
