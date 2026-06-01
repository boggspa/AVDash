import SwiftUI
import PodcastPreviewCore
import PodcastPreviewShared

struct HardwareGraphFocusGPUContext: Hashable {
    let deviceID: String
    let modelName: String
}

struct HardwareGraphFocusState: Identifiable {
    enum Visualization {
        case lineChart([HardwareGraphFocusSeries])
        case heatmap(HardwareGraphFocusHeatmapSnapshot)
        case cpuCoreDetail(HardwareGraphFocusCPUCoreSnapshot)
        case summary(HardwareGraphFocusSummarySnapshot)
    }

    let id: String
    let title: String
    let subtitle: String?
    let accentColor: Color
    let insightTarget: HardwareGraphFocusInsightTarget?
    let heatmapTarget: HardwareGraphFocusHeatmapTarget?
    let selectableHeatmapTargets: [HardwareGraphFocusHeatmapTarget]
    let attributionTarget: HardwareGraphFocusAttributionTarget?
    let processTarget: HardwareGraphFocusProcessTarget?
    let gpuContext: HardwareGraphFocusGPUContext?
    let visualization: Visualization
    let inlineMeters: [HardwareGraphFocusInlineMeter]
    let linePanelSnapshots: [HardwareGraphFocusLinePanelSnapshot]
    let scatterSnapshots: [HardwareGraphFocusScatterSnapshot]
    let processLiveSnapshot: HardwareGraphFocusProcessLiveSnapshot?
    let mediaRecentSessions: [MediaEngineStatsSampler.RecentSession]
    let detailVisuals: [HardwareGraphFocusDetailVisual]
    let stats: [HardwareGraphFocusStat]
    let detailLines: [String]
    let detailActionHandler: ((String) -> Void)?

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(subtitle ?? "")
        hasher.combine(insightTarget?.rawValue ?? "none")
        hasher.combine(heatmapTarget?.rawValue ?? "none")
        for selectableHeatmapTarget in selectableHeatmapTargets {
            hasher.combine(selectableHeatmapTarget.rawValue)
        }
        hasher.combine(attributionTarget?.rawValue ?? "none")
        if let gpuContext {
            hasher.combine(gpuContext.deviceID)
            hasher.combine(gpuContext.modelName)
        } else {
            hasher.combine("no-gpu-context")
        }
        if let processTarget {
            hasher.combine(processTarget.identity.processKey)
            hasher.combine(Int((processTarget.currentCPUPercent * 100).rounded()))
            hasher.combine(Int((processTarget.currentRAMMB * 10).rounded()))
            hasher.combine(processTarget.isGPUActive)
            hasher.combine(Int(((processTarget.currentGPUShareRatio ?? 0) * 1000).rounded()))
            hasher.combine(Int(processTarget.uptimeSeconds.rounded()))
        } else {
            hasher.combine("no-process-target")
        }

        switch visualization {
        case .lineChart(let series):
            hasher.combine("line-chart")
            for item in series {
                hasher.combine(item.id)
                hasher.combine(item.label)
                for value in item.values {
                    hasher.combine(Int(((value ?? -1) * 1000).rounded()))
                }
            }
        case .heatmap(let snapshot):
            hasher.combine("heatmap")
            hasher.combine(snapshot.metricLabel)
            hasher.combine(snapshot.startLabel)
            hasher.combine(snapshot.endLabel)
            for column in snapshot.columns {
                for cell in column {
                    hasher.combine(Int((cell.intensity * 1000).rounded()))
                    hasher.combine(cell.slotStart?.timeIntervalSince1970 ?? -1)
                }
            }
        case .cpuCoreDetail(let snapshot):
            hasher.combine("cpu-core-detail")
            hasher.combine(snapshot.usageTitle)
            hasher.combine(snapshot.usageSubtitle ?? "")
            hasher.combine(snapshot.frequencyTitle)
            hasher.combine(snapshot.frequencySubtitle ?? "")
            for core in snapshot.cores {
                hasher.combine(core.id)
                hasher.combine(core.label)
                hasher.combine(core.clusterLabel ?? "")
                for value in core.usageValues {
                    hasher.combine(Int(((value ?? -1) * 1000).rounded()))
                }
                for value in core.frequencyGHzValues {
                    hasher.combine(Int(((value ?? -1) * 1000).rounded()))
                }
                hasher.combine(Int(((core.liveUsage ?? -1) * 1000).rounded()))
                hasher.combine(Int(((core.liveFrequencyGHz ?? -1) * 1000).rounded()))
            }
        case .summary(let snapshot):
            hasher.combine("summary")
            hasher.combine(snapshot.signatureHash)
        }

        for meter in inlineMeters {
            hasher.combine(meter.signatureHash)
        }
        for panel in linePanelSnapshots {
            hasher.combine(panel.signatureHash)
        }
        for scatter in scatterSnapshots {
            hasher.combine(scatter.signatureHash)
        }
        if let processLiveSnapshot {
            hasher.combine(processLiveSnapshot.title)
            hasher.combine(processLiveSnapshot.subtitle ?? "")
            hasher.combine(processLiveSnapshot.detailText ?? "")
            for series in processLiveSnapshot.series {
                hasher.combine(series.id)
                hasher.combine(series.label)
                for value in series.values {
                    hasher.combine(Int(((value ?? -1) * 1000).rounded()))
                }
            }
        } else {
            hasher.combine("no-process-live-snapshot")
        }
        for session in mediaRecentSessions {
            hasher.combine(session.id)
            hasher.combine(session.codecText)
            hasher.combine(session.roleText)
            hasher.combine(session.resolutionText ?? "")
            hasher.combine(session.framesProcessed ?? -1)
            hasher.combine(session.framesDropped ?? -1)
            hasher.combine(session.isCompleted)
        }
        for detailVisual in detailVisuals {
            hasher.combine(detailVisual.signatureHash)
        }
        for stat in stats {
            hasher.combine(stat.id)
            hasher.combine(stat.label)
            hasher.combine(stat.value)
        }
        for line in detailLines {
            hasher.combine(line)
        }
        return hasher.finalize()
    }

    init(
        id: String,
        title: String,
        subtitle: String?,
        accentColor: Color,
        insightTarget: HardwareGraphFocusInsightTarget? = nil,
        heatmapTarget: HardwareGraphFocusHeatmapTarget? = nil,
        selectableHeatmapTargets: [HardwareGraphFocusHeatmapTarget] = [],
        attributionTarget: HardwareGraphFocusAttributionTarget? = nil,
        processTarget: HardwareGraphFocusProcessTarget? = nil,
        gpuContext: HardwareGraphFocusGPUContext? = nil,
        visualization: Visualization,
        inlineMeters: [HardwareGraphFocusInlineMeter] = [],
        linePanelSnapshots: [HardwareGraphFocusLinePanelSnapshot] = [],
        scatterSnapshots: [HardwareGraphFocusScatterSnapshot] = [],
        processLiveSnapshot: HardwareGraphFocusProcessLiveSnapshot? = nil,
        mediaRecentSessions: [MediaEngineStatsSampler.RecentSession] = [],
        detailVisuals: [HardwareGraphFocusDetailVisual] = [],
        stats: [HardwareGraphFocusStat],
        detailLines: [String],
        detailActionHandler: ((String) -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.accentColor = accentColor
        self.insightTarget = insightTarget
        self.heatmapTarget = heatmapTarget
        self.selectableHeatmapTargets = selectableHeatmapTargets
        self.attributionTarget = attributionTarget
        self.processTarget = processTarget
        self.gpuContext = gpuContext
        self.visualization = visualization
        self.inlineMeters = inlineMeters
        self.linePanelSnapshots = linePanelSnapshots
        self.scatterSnapshots = scatterSnapshots
        self.processLiveSnapshot = processLiveSnapshot
        self.mediaRecentSessions = mediaRecentSessions
        self.detailVisuals = detailVisuals
        self.stats = stats
        self.detailLines = detailLines
        self.detailActionHandler = detailActionHandler
    }
}

struct HardwareGraphFocusSeries: Identifiable {
    let id: String
    let label: String
    let color: Color
    let values: [Double?]
}

struct HardwareGraphFocusStat: Identifiable {
    let id: String
    let label: String
    let value: String
    let tint: Color?

    init(id: String? = nil, label: String, value: String, tint: Color? = nil) {
        self.id = id ?? label.lowercased().replacingOccurrences(of: " ", with: "-")
        self.label = label
        self.value = value
        self.tint = tint
    }
}

struct HardwareGraphFocusHeatmapSnapshot {
    let metricLabel: String
    let columns: [[HardwareGraphFocusHeatmapCell]]
    let startLabel: String
    let endLabel: String

    var columnCount: Int {
        columns.count
    }

    var rowCount: Int {
        columns.first?.count ?? 0
    }
}

struct HardwareGraphFocusHeatmapCell {
    let intensity: Double
    let color: Color
    let slotStart: Date?
}

struct HardwareGraphFocusHeatmapDrillDownSnapshot {
    let title: String
    let subtitle: String
    let series: [HardwareGraphFocusSeries]
    let stats: [HardwareGraphFocusStat]
    let detailLines: [String]
}

struct HardwareGraphFocusScatterSnapshot: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let accentColor: Color
    let xAxisLabel: String
    let yAxisLabel: String
    let xMinimumLabel: String
    let xMaximumLabel: String
    let yMinimumLabel: String
    let yMaximumLabel: String
    let correlationLabel: String?
    let detailText: String?
    let points: [HardwareGraphFocusScatterPoint]
    let xRange: ClosedRange<Double>
    let yRange: ClosedRange<Double>

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(subtitle ?? "")
        hasher.combine(xAxisLabel)
        hasher.combine(yAxisLabel)
        hasher.combine(correlationLabel ?? "")
        hasher.combine(detailText ?? "")
        hasher.combine(Int((xRange.lowerBound * 100).rounded()))
        hasher.combine(Int((xRange.upperBound * 100).rounded()))
        hasher.combine(Int((yRange.lowerBound * 100).rounded()))
        hasher.combine(Int((yRange.upperBound * 100).rounded()))
        for point in points {
            hasher.combine(Int((point.x * 100).rounded()))
            hasher.combine(Int((point.y * 100).rounded()))
            hasher.combine(Int((point.emphasis * 100).rounded()))
        }
        return hasher.finalize()
    }
}

struct HardwareGraphFocusScatterPoint: Identifiable {
    let id: Int
    let x: Double
    let y: Double
    let emphasis: Double
}

struct HardwareGraphFocusInlineMeter: Identifiable {
    let id: String
    let usedMB: Double?
    let ceilingMB: Double?
    let allocatedMB: Double?
    let isUnifiedCeilingEstimate: Bool
    let detailText: String?

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(Int((usedMB ?? -1) * 10))
        hasher.combine(Int((ceilingMB ?? -1) * 10))
        hasher.combine(Int((allocatedMB ?? -1) * 10))
        hasher.combine(isUnifiedCeilingEstimate)
        hasher.combine(detailText ?? "")
        return hasher.finalize()
    }
}

struct HardwareGraphFocusLinePanelSnapshot: Identifiable {
    let id: String
    let title: String
    let chipTitle: String
    let subtitle: String?
    let detailText: String?
    let series: [HardwareGraphFocusSeries]

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(chipTitle)
        hasher.combine(subtitle ?? "")
        hasher.combine(detailText ?? "")
        for series in series {
            hasher.combine(series.id)
            hasher.combine(series.label)
            for value in series.values {
                hasher.combine(Int(((value ?? -1) * 1000).rounded()))
            }
        }
        return hasher.finalize()
    }
}

struct HardwareGraphFocusCPUCoreSnapshot {
    let usageTitle: String
    let usageSubtitle: String?
    let frequencyTitle: String
    let frequencySubtitle: String?
    let cores: [HardwareGraphFocusCPUCoreSeriesSnapshot]
}

struct HardwareGraphFocusCPUCoreSeriesSnapshot: Identifiable {
    let id: String
    let label: String
    let clusterLabel: String?
    let usageValues: [Double?]
    let frequencyGHzValues: [Double?]
    let liveUsage: Double?
    let liveFrequencyGHz: Double?
}

struct HardwareGraphFocusProcessLiveSnapshot {
    let title: String
    let subtitle: String?
    let series: [HardwareGraphFocusSeries]
    let detailText: String?
}

struct HardwareGraphFocusSummarySnapshot {
    let title: String
    let subtitle: String?
    let hero: HardwareGraphFocusSummaryHero?
    let tiles: [HardwareGraphFocusSummaryTile]
    let rows: [HardwareGraphFocusSummaryRow]

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(title)
        hasher.combine(subtitle ?? "")
        if let hero {
            hasher.combine(hero.signatureHash)
        } else {
            hasher.combine("no-hero")
        }
        for tile in tiles {
            hasher.combine(tile.signatureHash)
        }
        for row in rows {
            hasher.combine(row.signatureHash)
        }
        return hasher.finalize()
    }
}

enum HardwareGraphFocusSummaryHero {
    case machine(HardwareGraphFocusMachineHeroSnapshot)
    case storage(HardwareGraphFocusStorageHeroSnapshot)

    var signatureHash: Int {
        switch self {
        case .machine(let snapshot):
            return snapshot.signatureHash
        case .storage(let snapshot):
            return snapshot.signatureHash
        }
    }
}

struct HardwareGraphFocusMachineHeroSnapshot {
    let family: MacFamily
    let modelName: String
    let modelYear: String?
    let osText: String
    let badgeText: String?
    let supportingText: String?

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(family.rawValue)
        hasher.combine(modelName)
        hasher.combine(modelYear ?? "")
        hasher.combine(osText)
        hasher.combine(badgeText ?? "")
        hasher.combine(supportingText ?? "")
        return hasher.finalize()
    }
}

struct HardwareGraphFocusStorageHeroSnapshot {
    let title: String
    let subtitle: String?
    let usedRatio: Double
    let usedText: String
    let detailText: String?

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(title)
        hasher.combine(subtitle ?? "")
        hasher.combine(Int((usedRatio * 1000).rounded()))
        hasher.combine(usedText)
        hasher.combine(detailText ?? "")
        return hasher.finalize()
    }
}

struct HardwareGraphFocusSummaryTile: Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String?
    let tint: Color?
    let actionID: String?

    init(
        id: String? = nil,
        title: String,
        value: String,
        detail: String? = nil,
        tint: Color? = nil,
        actionID: String? = nil
    ) {
        self.id = id ?? title.lowercased().replacingOccurrences(of: " ", with: "-")
        self.title = title
        self.value = value
        self.detail = detail
        self.tint = tint
        self.actionID = actionID
    }

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(value)
        hasher.combine(detail ?? "")
        hasher.combine(actionID ?? "")
        return hasher.finalize()
    }
}

struct HardwareGraphFocusSummaryRow: Identifiable {
    let id: String
    let label: String
    let value: String

    init(id: String? = nil, label: String, value: String) {
        self.id = id ?? label.lowercased().replacingOccurrences(of: " ", with: "-")
        self.label = label
        self.value = value
    }

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(label)
        hasher.combine(value)
        return hasher.finalize()
    }
}

enum HardwareGraphFocusDetailVisual: Identifiable {
    case neuralEngine(HardwareGraphFocusNeuralEngineVisualSnapshot)
    case helperServices(HardwareGraphFocusHelperServicesSnapshot)
    case actions(HardwareGraphFocusActionsSnapshot)
    case networkInterfaces(HardwareGraphFocusNetworkInterfacesSnapshot)
    case gpuHardware(HardwareGraphFocusGPUHardwareSnapshot)

    var id: String {
        switch self {
        case .neuralEngine(let snapshot):
            return snapshot.id
        case .helperServices(let snapshot):
            return snapshot.id
        case .actions(let snapshot):
            return snapshot.id
        case .networkInterfaces(let snapshot):
            return snapshot.id
        case .gpuHardware(let snapshot):
            return snapshot.id
        }
    }

    var signatureHash: Int {
        switch self {
        case .neuralEngine(let snapshot):
            return snapshot.signatureHash
        case .helperServices(let snapshot):
            return snapshot.signatureHash
        case .actions(let snapshot):
            return snapshot.signatureHash
        case .networkInterfaces(let snapshot):
            return snapshot.signatureHash
        case .gpuHardware(let snapshot):
            return snapshot.signatureHash
        }
    }
}

struct HardwareGraphFocusNeuralEngineVisualSnapshot: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let visibleCoreCount: Int
    let totalCoreCount: Int?
    let architectureText: String?
    let statusText: String
    let currentPowerText: String?
    let clientCount: Int
    let clients: [String]
    let isIdle: Bool
    let isActive: Bool

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(subtitle ?? "")
        hasher.combine(visibleCoreCount)
        hasher.combine(totalCoreCount ?? -1)
        hasher.combine(architectureText ?? "")
        hasher.combine(statusText)
        hasher.combine(currentPowerText ?? "")
        hasher.combine(clientCount)
        hasher.combine(isIdle)
        hasher.combine(isActive)
        for client in clients {
            hasher.combine(client)
        }
        return hasher.finalize()
    }
}

struct HardwareGraphFocusHelperServicesSnapshot: Identifiable {
    let id: String
    let subtitle: String?
    let rows: [HardwareGraphFocusHelperServiceRowSnapshot]

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(subtitle ?? "")
        for row in rows {
            hasher.combine(row.signatureHash)
        }
        return hasher.finalize()
    }
}

struct HardwareGraphFocusHelperServiceRowSnapshot: Identifiable {
    enum Tone: String {
        case active
        case attention
        case unknown
    }

    let id: String
    let name: String
    let statusText: String
    let uptimeText: String
    let detailText: String?
    let tone: Tone
    let actionID: String?
    let actionTitle: String?
    let actionInProgressTitle: String?
    let isActionEnabled: Bool
    let isActionInProgress: Bool
    let uninstallActionID: String?
    let uninstallActionTitle: String?
    let uninstallActionInProgressTitle: String?
    let isUninstallActionEnabled: Bool
    let isUninstallActionInProgress: Bool

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(statusText)
        hasher.combine(uptimeText)
        hasher.combine(detailText ?? "")
        hasher.combine(tone.rawValue)
        hasher.combine(actionID ?? "")
        hasher.combine(actionTitle ?? "")
        hasher.combine(actionInProgressTitle ?? "")
        hasher.combine(isActionEnabled)
        hasher.combine(isActionInProgress)
        hasher.combine(uninstallActionID ?? "")
        hasher.combine(uninstallActionTitle ?? "")
        hasher.combine(uninstallActionInProgressTitle ?? "")
        hasher.combine(isUninstallActionEnabled)
        hasher.combine(isUninstallActionInProgress)
        return hasher.finalize()
    }
}

struct HardwareGraphFocusNetworkInterfacesSnapshot: Identifiable {
    let id: String
    let subtitle: String?
    let rows: [HardwareGraphFocusNetworkInterfaceRowSnapshot]

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(subtitle ?? "")
        for row in rows {
            hasher.combine(row.signatureHash)
        }
        return hasher.finalize()
    }
}

struct HardwareGraphFocusNetworkInterfaceRowSnapshot: Identifiable {
    let id: String
    let name: String
    let connectionType: String
    let isActive: Bool
    let localIP: String?
    let subnetMask: String?
    let macAddress: String?

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(connectionType)
        hasher.combine(isActive)
        hasher.combine(localIP ?? "")
        hasher.combine(subnetMask ?? "")
        hasher.combine(macAddress ?? "")
        return hasher.finalize()
    }
}

struct HardwareGraphFocusGPUHardwareSnapshot: Identifiable {
    let id: String
    let name: String
    let bus: String?
    let gpuType: String?
    let metalFamily: String?
    let coreCount: Int?
    let memoryLabel: String?
    let memoryText: String?
    let connectedDisplayCount: Int?
    let deviceID: String?
    let revisionID: String?
    let pcieWidth: String?
    let isRemovable: Bool?

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(bus ?? "")
        hasher.combine(gpuType ?? "")
        hasher.combine(metalFamily ?? "")
        hasher.combine(coreCount ?? -1)
        hasher.combine(memoryLabel ?? "")
        hasher.combine(memoryText ?? "")
        hasher.combine(connectedDisplayCount ?? -1)
        hasher.combine(deviceID ?? "")
        hasher.combine(revisionID ?? "")
        hasher.combine(pcieWidth ?? "")
        hasher.combine(isRemovable ?? false)
        return hasher.finalize()
    }
}

struct HardwareGraphFocusActionsSnapshot: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let rows: [HardwareGraphFocusActionRowSnapshot]

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(title)
        hasher.combine(subtitle ?? "")
        for row in rows {
            hasher.combine(row.signatureHash)
        }
        return hasher.finalize()
    }
}

struct HardwareGraphFocusActionRowSnapshot: Identifiable {
    enum Tone: String {
        case neutral
        case attention
        case positive
    }

    let id: String
    let name: String
    let statusText: String
    let subtitleText: String?
    let detailText: String?
    let tone: Tone
    let actionTitle: String?
    let isActionEnabled: Bool
    let isActionInProgress: Bool

    var signatureHash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(statusText)
        hasher.combine(subtitleText ?? "")
        hasher.combine(detailText ?? "")
        hasher.combine(tone.rawValue)
        hasher.combine(actionTitle ?? "")
        hasher.combine(isActionEnabled)
        hasher.combine(isActionInProgress)
        return hasher.finalize()
    }
}

private enum HardwareGraphFocusSupplementaryPanel: Hashable, Identifiable {
    case linePanel(String)
    case scatter(String)
    case heatmap
    case heatmapDrillDown
    case processHistory
    case eventTimeline

    var id: String {
        switch self {
        case .linePanel(let id):
            return "line-panel-\(id)"
        case .scatter(let id):
            return "scatter-\(id)"
        case .heatmap:
            return "heatmap"
        case .heatmapDrillDown:
            return "heatmap-drill-down"
        case .processHistory:
            return "process-history"
        case .eventTimeline:
            return "event-timeline"
        }
    }
}

struct HardwareGraphFocusView: View {
    @Environment(\.appUIScale) private var appUIScale
    let focus: HardwareGraphFocusState
    let onBack: () -> Void
    var insightsProvider: HardwareGraphFocusInsightProvider? = nil
    var insightsRefreshAnchor: Date = Date()
    var heatmapProvider: HardwareGraphFocusHeatmapProvider? = nil
    var heatmapRefreshAnchor: Date = Date()
    var attributionProvider: HardwareGraphFocusAttributionProvider? = nil
    var attributionRefreshAnchor: Date = Date()
    var processHistoryProvider: HardwareGraphFocusProcessHistoryProvider? = nil
    var processHistoryRefreshAnchor: Date = Date()
    var eventTimelineProvider: HardwareGraphFocusEventTimelineProvider? = nil
    var eventTimelineRefreshAnchor: Date = Date()

    @State private var selectedInsightWindow: HardwareInsightWindow = .daily
    @State private var insightSnapshot: HardwareGraphFocusInsightSnapshot?
    @State private var isLoadingInsight = false
    @State private var activityHeatmapSnapshot: HardwareGraphFocusHeatmapSnapshot?
    @State private var isLoadingActivityHeatmap = false
    @State private var attributionSnapshot: HardwareGraphFocusAttributionSnapshot?
    @State private var isLoadingAttribution = false
    @State private var processHistorySnapshot: HardwareGraphFocusProcessHistorySnapshot?
    @State private var isLoadingProcessHistory = false
    @State private var eventTimelineSnapshot: HardwareGraphFocusEventTimelineSnapshot?
    @State private var isLoadingEventTimeline = false
    @State private var selectedSupplementaryPanelID: String?
    @State private var selectedCPUCoreID: String?
    @State private var selectedPrimaryHeatmapTarget: HardwareGraphFocusHeatmapTarget?
    @State private var primaryHeatmapSnapshot: HardwareGraphFocusHeatmapSnapshot?
    @State private var isLoadingPrimaryHeatmap = false
    @State private var selectedPrimaryHeatmapSlotStart: Date?
    @State private var primaryHeatmapDrillDownSnapshot: HardwareGraphFocusHeatmapDrillDownSnapshot?
    @State private var isLoadingPrimaryHeatmapDrillDown = false
    @State private var networkSettingsActionID: String?
    @State private var selectedPingInterval: Int = UserDefaults.standard.integer(forKey: "networkPingIntervalSeconds") != 0 ? UserDefaults.standard.integer(forKey: "networkPingIntervalSeconds") : 300
    @State private var customPingTarget: String = UserDefaults.standard.string(forKey: "networkPingTarget") ?? ""

    private var scaledOverlayHorizontalPadding: CGFloat { 26 * appUIScale }
    private var scaledOverlayVerticalPadding: CGFloat { 18 * appUIScale }
    private var scaledCornerRadius: CGFloat { 24 * appUIScale }
    private var scaledCardPadding: CGFloat { 22 * appUIScale }
    private var scaledHeaderSpacing: CGFloat { 16 * appUIScale }
    private var scaledPanelSpacing: CGFloat { 18 * appUIScale }
    private var scaledTitleFontSize: CGFloat { 22 * appUIScale }
    private var scaledSubtitleFontSize: CGFloat { 12 * appUIScale }
    private var scaledLabelFontSize: CGFloat { 11 * appUIScale }
    private var scaledBodyFontSize: CGFloat { 13 * appUIScale }
    private var scaledChartMinHeight: CGFloat { 360 * appUIScale }
    private var insightsRefreshToken: String {
        "\(focus.id)-\(effectiveInsightTarget?.rawValue ?? "none")-\(selectedInsightWindow.rawValue)-\(Int(insightsRefreshAnchor.timeIntervalSince1970 / 60))"
    }
    private var heatmapRefreshToken: String {
        "\(focus.id)-\(focus.heatmapTarget?.rawValue ?? "none")-\(Int(heatmapRefreshAnchor.timeIntervalSince1970 / 60))"
    }
    private var primaryHeatmapRefreshToken: String {
        "\(focus.id)-primary-\(resolvedPrimaryHeatmapTarget?.rawValue ?? "none")-\(Int(heatmapRefreshAnchor.timeIntervalSince1970 / 60))"
    }
    private var primaryHeatmapDrillDownRefreshToken: String {
        "\(focus.id)-drilldown-\(resolvedPrimaryHeatmapTarget?.rawValue ?? "none")-\(selectedPrimaryHeatmapSlotStart?.timeIntervalSince1970 ?? -1)-\(Int(heatmapRefreshAnchor.timeIntervalSince1970 / 60))"
    }
    private var attributionRefreshToken: String {
        "\(focus.id)-\(focus.attributionTarget?.rawValue ?? "none")-\(Int(attributionRefreshAnchor.timeIntervalSince1970 / 3.0))"
    }
    private var processHistoryRefreshToken: String {
        "\(focus.id)-\(focus.processTarget?.identity.processKey ?? "none")-\(selectedInsightWindow.rawValue)-\(Int(processHistoryRefreshAnchor.timeIntervalSince1970 / 60))"
    }
    private var eventTimelineRefreshToken: String {
        "\(focus.id)-\(selectedInsightWindow.rawValue)-\(Int(eventTimelineRefreshAnchor.timeIntervalSince1970 / 60))"
    }
    private var cpuCoreSnapshot: HardwareGraphFocusCPUCoreSnapshot? {
        if case let .cpuCoreDetail(snapshot) = focus.visualization {
            return snapshot
        }
        return nil
    }
    private var cpuCoreSelectionSignature: String {
        cpuCoreSnapshot?.cores.map(\.id).joined(separator: "|") ?? "none"
    }
    private var staticHeatmapSnapshot: HardwareGraphFocusHeatmapSnapshot? {
        if case let .heatmap(snapshot) = focus.visualization {
            return snapshot
        }
        return nil
    }
    private var usesInteractivePrimaryHeatmap: Bool {
        guard staticHeatmapSnapshot != nil else { return false }
        return heatmapProvider != nil && (focus.heatmapTarget != nil || !focus.selectableHeatmapTargets.isEmpty)
    }
    private var resolvedPrimaryHeatmapTarget: HardwareGraphFocusHeatmapTarget? {
        if let selectedPrimaryHeatmapTarget {
            return selectedPrimaryHeatmapTarget
        }
        return focus.heatmapTarget ?? focus.selectableHeatmapTargets.first
    }
    private var resolvedPrimaryHeatmapSnapshot: HardwareGraphFocusHeatmapSnapshot? {
        if usesInteractivePrimaryHeatmap {
            return primaryHeatmapSnapshot ?? staticHeatmapSnapshot
        }
        return staticHeatmapSnapshot
    }
    private var effectiveInsightTarget: HardwareGraphFocusInsightTarget? {
        if usesInteractivePrimaryHeatmap,
           let target = resolvedPrimaryHeatmapTarget {
            return focusInsightTarget(for: target)
        }
        return focus.insightTarget
    }
    private var activeAccentColor: Color {
        if usesInteractivePrimaryHeatmap,
           let target = resolvedPrimaryHeatmapTarget {
            return heatmapAccentColor(for: target)
        }
        return focus.accentColor
    }
    private var hasInlineMeters: Bool {
        !focus.inlineMeters.isEmpty
    }
    private var inlineMetersPanelHeight: CGFloat {
        hasInlineMeters ? 66 * appUIScale : 0
    }
    private var suppressEventTimelinePanel: Bool {
        if case .cpuCoreDetail = focus.visualization {
            return true
        }
        return false
    }
    private var supplementaryPanels: [HardwareGraphFocusSupplementaryPanel] {
        var panels = focus.linePanelSnapshots.map { HardwareGraphFocusSupplementaryPanel.linePanel($0.id) }
        panels.append(contentsOf: focus.scatterSnapshots.map { HardwareGraphFocusSupplementaryPanel.scatter($0.id) })
        if shouldShowActivityHeatmap {
            panels.append(.heatmap)
        }
        if usesInteractivePrimaryHeatmap {
            panels.append(.heatmapDrillDown)
        }
        if focus.processTarget != nil, processHistoryProvider != nil, focus.processLiveSnapshot != nil {
            panels.append(.processHistory)
        } else if focus.processTarget != nil, processHistoryProvider != nil, processHistorySnapshot == nil {
            panels.append(.processHistory)
        }
        if eventTimelineProvider != nil, suppressEventTimelinePanel == false {
            panels.append(.eventTimeline)
        }
        return panels
    }
    private var supplementaryPanelSignature: String {
        supplementaryPanels.map(\.id).joined(separator: "|")
    }
    private var selectedSupplementaryPanel: HardwareGraphFocusSupplementaryPanel? {
        supplementaryPanels.first(where: { $0.id == selectedSupplementaryPanelID }) ?? supplementaryPanels.first
    }
    private var hasSupplementaryPanels: Bool {
        !supplementaryPanels.isEmpty
    }
    private var usesLiveProcessPrimaryVisualization: Bool {
        focus.processTarget != nil && focus.processLiveSnapshot != nil
    }
    private var usesProcessHistoryPrimaryVisualization: Bool {
        focus.processTarget != nil && !usesLiveProcessPrimaryVisualization
    }
    private var displayedStats: [HardwareGraphFocusStat] {
        if usesInteractivePrimaryHeatmap,
           let interactiveHeatmapStats {
            return interactiveHeatmapStats
        }
        if usesProcessHistoryPrimaryVisualization,
           let processHistorySnapshot,
           !processHistorySnapshot.stats.isEmpty {
            return processHistorySnapshot.stats
        }
        return focus.stats
    }
    private var displayedDetailLines: [String] {
        if usesInteractivePrimaryHeatmap,
           let interactiveHeatmapDetailLines {
            return interactiveHeatmapDetailLines
        }
        guard usesProcessHistoryPrimaryVisualization else { return focus.detailLines }
        var lines = processHistorySnapshot?.detailLines ?? []
        for line in focus.detailLines where lines.contains(line) == false {
            lines.append(line)
        }
        return lines
    }
    private var shouldShowActivityHeatmap: Bool {
        guard focus.heatmapTarget != nil else { return false }
        if case .lineChart = focus.visualization {
            return true
        }
        return false
    }

    var body: some View {
        GeometryReader { geometry in
            let containerWidth = max(720 * appUIScale, min(geometry.size.width - scaledOverlayHorizontalPadding * 2, 1320 * appUIScale))
            let containerHeight = max(520 * appUIScale, min(geometry.size.height - scaledOverlayVerticalPadding * 2, 980 * appUIScale))
            let useStackedLayout = geometry.size.width < 1100 * appUIScale
            let shellShape = ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous)

            ZStack {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()

                GlassBackground(.hud, cornerRadius: scaledCornerRadius, shape: shellShape)
                    .overlay(
                        shellShape
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .frame(width: containerWidth, height: containerHeight)
                    .overlay(
                        contentBody(width: containerWidth, height: containerHeight, stacked: useStackedLayout)
                            .padding(scaledCardPadding)
                    )
                    .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
            }
        }
        .onAppear {
            synchronizeSupplementarySelection(reset: true)
            synchronizeCPUCoreSelection(reset: true)
            synchronizePrimaryHeatmapTarget(reset: true)
            Task { await loadInsightSnapshot() }
            Task { await loadActivityHeatmapSnapshot() }
            Task { await loadPrimaryHeatmapSnapshot() }
            Task { await loadAttributionSnapshot() }
            Task { await loadProcessHistorySnapshot() }
            Task { await loadEventTimelineSnapshot() }
            Task { await loadPrimaryHeatmapDrillDownSnapshot() }
        }
        .onChange(of: focus.id) { _ in
            synchronizeSupplementarySelection(reset: true)
            synchronizeCPUCoreSelection(reset: true)
            synchronizePrimaryHeatmapTarget(reset: true)
        }
        .onChange(of: supplementaryPanelSignature) { _ in
            synchronizeSupplementarySelection()
        }
        .onChange(of: cpuCoreSelectionSignature) { _ in
            synchronizeCPUCoreSelection()
        }
        .onChange(of: primaryHeatmapRefreshToken) { _ in
            Task { await loadPrimaryHeatmapSnapshot() }
        }
        .onChange(of: primaryHeatmapDrillDownRefreshToken) { _ in
            Task { await loadPrimaryHeatmapDrillDownSnapshot() }
        }
        .onChange(of: insightsRefreshToken) { _ in
            Task { await loadInsightSnapshot() }
        }
        .onChange(of: heatmapRefreshToken) { _ in
            Task { await loadActivityHeatmapSnapshot() }
        }
        .onChange(of: attributionRefreshToken) { _ in
            Task { await loadAttributionSnapshot() }
        }
        .onChange(of: processHistoryRefreshToken) { _ in
            Task { await loadProcessHistorySnapshot() }
        }
        .onChange(of: eventTimelineRefreshToken) { _ in
            Task { await loadEventTimelineSnapshot() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NetworkSettingsActionTriggered"))) { notification in
            if let actionID = notification.object as? String {
                networkSettingsActionID = actionID
            }
        }
        .sheet(isPresented: Binding(
            get: { networkSettingsActionID == "network-ping-interval" },
            set: { if !$0 { networkSettingsActionID = nil } }
        )) {
            pingIntervalPickerSheet
        }
        .sheet(isPresented: Binding(
            get: { networkSettingsActionID == "network-ping-target" },
            set: { if !$0 { networkSettingsActionID = nil } }
        )) {
            pingTargetInputSheet
        }
    }

    private var pingIntervalPickerSheet: some View {
        let pingIntervalOptions: [(seconds: Int, label: String)] = [
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

        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ping Interval")
                    .font(.headline)
                Text("Select how often to check network latency")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(pingIntervalOptions, id: \.seconds) { option in
                        Button(action: {
                            selectedPingInterval = option.seconds
                        }) {
                            HStack {
                                Text(option.label)
                                    .foregroundColor(.primary)
                                Spacer()
                                if selectedPingInterval == option.seconds {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                        }
                        .buttonStyle(.plain)

                        if option.seconds != pingIntervalOptions.last?.seconds {
                            Divider()
                                .padding(.horizontal, 12)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                Spacer()
                Button("Done") {
                    UserDefaults.standard.set(selectedPingInterval, forKey: "networkPingIntervalSeconds")
                    networkSettingsActionID = nil
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 320, height: 400)
    }

    private var pingTargetInputSheet: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ping Target")
                    .font(.headline)
                Text("Enter the IP address or hostname to ping")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            Divider()

            VStack(spacing: 12) {
                TextField("IP address (e.g., 8.8.8.8)", text: $customPingTarget)
                    .textFieldStyle(.roundedBorder)

                Text("Leave empty to use router (auto-detect)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()

            Spacer()

            Divider()

            HStack(spacing: 12) {
                Button("Cancel") {
                    customPingTarget = UserDefaults.standard.string(forKey: "networkPingTarget") ?? ""
                    networkSettingsActionID = nil
                }
                Spacer()
                Button("Save") {
                    UserDefaults.standard.set(customPingTarget, forKey: "networkPingTarget")
                    networkSettingsActionID = nil
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 320, height: 260)
    }

    @ViewBuilder
    private func contentBody(width: CGFloat, height: CGFloat, stacked: Bool) -> some View {
        let detailWidth = detailColumnWidth(totalWidth: width)
        let primaryHeight = primaryVisualizationHeight(totalHeight: height, stacked: stacked)
        let supplementaryHeight = supplementarySectionHeight(totalHeight: height, stacked: stacked)

        VStack(alignment: .leading, spacing: scaledPanelSpacing) {
            header

            if stacked {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: scaledPanelSpacing) {
                        visualizationPanel(minHeight: primaryHeight)
                            .frame(minHeight: primaryHeight, alignment: .topLeading)

                        if hasInlineMeters {
                            inlineMetersPanel
                        }

                        if hasSupplementaryPanels {
                            supplementaryAnalysisSection(height: supplementaryHeight, stacked: true)
                        }

                        detailPanel
                    }
                    .padding(.bottom, 2)
                }
            } else {
                HStack(alignment: .top, spacing: scaledPanelSpacing) {
                    VStack(alignment: .leading, spacing: scaledPanelSpacing) {
                        visualizationPanel(minHeight: primaryHeight)
                            .frame(height: primaryHeight, alignment: .topLeading)
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                        if hasInlineMeters {
                            inlineMetersPanel
                        }

                        if hasSupplementaryPanels {
                            supplementaryAnalysisSection(height: supplementaryHeight, stacked: false)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        } else {
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    ScrollView(showsIndicators: false) {
                        detailPanel
                            .padding(.bottom, 2)
                    }
                    .frame(width: detailWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func detailColumnWidth(totalWidth: CGFloat) -> CGFloat {
        min(max(totalWidth * 0.35, 340 * appUIScale), 420 * appUIScale)
    }

    private func primaryVisualizationHeight(totalHeight: CGFloat, stacked: Bool) -> CGFloat {
        let available = max(360 * appUIScale, totalHeight - (scaledCardPadding * 2) - (78 * appUIScale))
        if !hasSupplementaryPanels {
            let reservedInlineHeight = hasInlineMeters ? inlineMetersPanelHeight + scaledPanelSpacing : 0
            return max(272 * appUIScale, available - reservedInlineHeight)
        }
        let ratio: CGFloat = stacked ? 0.42 : 0.47
        return max(272 * appUIScale, available * ratio)
    }

    private func supplementarySectionHeight(totalHeight: CGFloat, stacked: Bool) -> CGFloat {
        guard hasSupplementaryPanels else { return 0 }
        let available = max(360 * appUIScale, totalHeight - (scaledCardPadding * 2) - (78 * appUIScale))
        let inlineReservedHeight = hasInlineMeters ? inlineMetersPanelHeight + scaledPanelSpacing : 0
        let remaining = available - primaryVisualizationHeight(totalHeight: totalHeight, stacked: stacked) - scaledPanelSpacing - inlineReservedHeight
        let minimum = stacked ? 304 * appUIScale : 286 * appUIScale
        return max(minimum, remaining)
    }

    private func synchronizeSupplementarySelection(reset: Bool = false) {
        guard !supplementaryPanels.isEmpty else {
            selectedSupplementaryPanelID = nil
            return
        }
        if reset || supplementaryPanels.contains(where: { $0.id == selectedSupplementaryPanelID }) == false {
            selectedSupplementaryPanelID = supplementaryPanels.first?.id
        }
    }

    private func synchronizeCPUCoreSelection(reset: Bool = false) {
        guard let cpuCoreSnapshot, !cpuCoreSnapshot.cores.isEmpty else {
            selectedCPUCoreID = nil
            return
        }
        if reset || cpuCoreSnapshot.cores.contains(where: { $0.id == selectedCPUCoreID }) == false {
            selectedCPUCoreID = cpuCoreSnapshot.cores.first?.id
        }
    }

    private func synchronizePrimaryHeatmapTarget(reset: Bool = false) {
        guard usesInteractivePrimaryHeatmap else {
            selectedPrimaryHeatmapTarget = nil
            selectedPrimaryHeatmapSlotStart = nil
            return
        }

        let availableTargets = focus.selectableHeatmapTargets.isEmpty
            ? [focus.heatmapTarget].compactMap { $0 }
            : focus.selectableHeatmapTargets

        guard !availableTargets.isEmpty else { return }
        if reset || selectedPrimaryHeatmapTarget.map({ availableTargets.contains($0) }) != true {
            selectedPrimaryHeatmapTarget = focus.heatmapTarget ?? availableTargets.first
        }
    }

    private func synchronizePrimaryHeatmapSelection(reset: Bool = false) {
        guard let snapshot = resolvedPrimaryHeatmapSnapshot else {
            selectedPrimaryHeatmapSlotStart = nil
            return
        }

        let availableSlots = snapshot.columns
            .flatMap { $0 }
            .compactMap(\.slotStart)

        guard !availableSlots.isEmpty else {
            selectedPrimaryHeatmapSlotStart = nil
            return
        }

        if reset || selectedPrimaryHeatmapSlotStart.map({ availableSlots.contains($0) }) != true {
            selectedPrimaryHeatmapSlotStart = hottestHeatmapCell(in: snapshot)?.slotStart ?? availableSlots.last
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: scaledHeaderSpacing) {
            Button(action: onBack) {
                HStack(spacing: 6 * appUIScale) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: scaledBodyFontSize - 1, weight: .semibold))
                    Text("Back")
                        .font(.system(size: scaledBodyFontSize, weight: .semibold))
                }
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 12 * appUIScale)
                .padding(.vertical, 7 * appUIScale)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4 * appUIScale) {
                Text(focus.title)
                    .font(.system(size: scaledTitleFontSize, weight: .semibold))

                if let subtitle = focus.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: scaledSubtitleFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            Text("Focused View")
                .font(.system(size: scaledLabelFontSize, weight: .semibold))
                .foregroundColor(activeAccentColor.opacity(0.95))
                .padding(.horizontal, 10 * appUIScale)
                .padding(.vertical, 6 * appUIScale)
                .background(
                    Capsule(style: .continuous)
                        .fill(activeAccentColor.opacity(0.14))
                )
        }
    }

    private func visualizationPanel(minHeight: CGFloat) -> some View {
        focusPanelCard(minHeight: minHeight) {
            VStack(alignment: .leading, spacing: 12 * appUIScale) {
                if usesProcessHistoryPrimaryVisualization {
                    if isLoadingProcessHistory && processHistorySnapshot == nil {
                        loadingPrimaryVisualization
                    } else if let processHistorySnapshot {
                        lineVisualization(series: processHistorySnapshot.series, title: processHistorySnapshot.title)
                    } else {
                        primaryVisualizationEmptyState(
                            title: "Historical Footprint",
                            message: "No persisted process history has been recorded for this app yet."
                        )
                    }
                } else if let processLiveSnapshot = focus.processLiveSnapshot {
                    VStack(alignment: .leading, spacing: 12 * appUIScale) {
                        if let subtitle = processLiveSnapshot.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        lineVisualization(series: processLiveSnapshot.series, title: processLiveSnapshot.title)

                        if let detailText = processLiveSnapshot.detailText, !detailText.isEmpty {
                            Text(detailText)
                                .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    switch focus.visualization {
                    case let .lineChart(series):
                        lineVisualization(series: series, title: "History")
                    case .heatmap:
                        if usesInteractivePrimaryHeatmap {
                            interactiveHeatmapVisualization
                        } else if let snapshot = staticHeatmapSnapshot {
                            heatmapVisualization(snapshot: snapshot)
                        }
                    case let .cpuCoreDetail(snapshot):
                        cpuCoreDetailVisualization(snapshot)
                    case let .summary(snapshot):
                        summaryVisualization(snapshot)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var inlineMetersPanel: some View {
        focusPanelCard(padding: 14 * appUIScale, minHeight: inlineMetersPanelHeight) {
            VStack(alignment: .leading, spacing: 8 * appUIScale) {
                ForEach(focus.inlineMeters) { meter in
                    GPUMemoryPressureBar(
                        usedMB: meter.usedMB,
                        ceilingMB: meter.ceilingMB,
                        allocatedMB: meter.allocatedMB,
                        isUnifiedCeilingEstimate: meter.isUnifiedCeilingEstimate
                    )

                    if let detailText = meter.detailText, !detailText.isEmpty {
                        Text(detailText)
                            .font(.system(size: scaledLabelFontSize, weight: .regular))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var loadingPrimaryVisualization: some View {
        ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
            .fill(Color.white.opacity(0.03))
            .overlay(
                VStack(spacing: 10 * appUIScale) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading persisted process history…")
                        .font(.system(size: scaledBodyFontSize, weight: .medium))
                        .foregroundColor(.secondary)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func primaryVisualizationEmptyState(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 12 * appUIScale) {
            Text(title)
                .font(.system(size: scaledBodyFontSize, weight: .semibold))

            Spacer(minLength: 0)

            Text(message)
                .font(.system(size: scaledBodyFontSize, weight: .regular))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func supplementaryAnalysisSection(height: CGFloat, stacked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10 * appUIScale) {
            HStack(alignment: .center, spacing: 10 * appUIScale) {
                Text("Supporting Analysis")
                    .font(.system(size: scaledBodyFontSize, weight: .semibold))

                if let selectedSupplementaryPanel {
                    Text(supplementaryPanelTitle(for: selectedSupplementaryPanel))
                        .font(.system(size: scaledLabelFontSize, weight: .semibold))
                        .foregroundColor(activeAccentColor.opacity(0.95))
                        .padding(.horizontal, 8 * appUIScale)
                        .padding(.vertical, 4 * appUIScale)
                        .background(
                            Capsule(style: .continuous)
                                .fill(activeAccentColor.opacity(0.12))
                        )
                }

                Spacer(minLength: 0)
            }

            if supplementaryPanels.count > 1 {
                supplementaryPanelPicker
            }

            ScrollView(showsIndicators: false) {
                supplementaryPanelContent
                    .padding(.bottom, 2)
            }
            .frame(height: max(228 * appUIScale, height - (stacked ? 60 * appUIScale : 68 * appUIScale)))
        }
    }

    private var supplementaryPanelPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8 * appUIScale) {
                ForEach(supplementaryPanels) { panel in
                    let isSelected = panel.id == selectedSupplementaryPanel?.id
                    Button {
                        selectedSupplementaryPanelID = panel.id
                    } label: {
                        Text(supplementaryPanelChipTitle(for: panel))
                            .font(.system(size: scaledLabelFontSize, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? .white.opacity(0.95) : .secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 10 * appUIScale)
                            .padding(.vertical, 6 * appUIScale)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isSelected ? activeAccentColor.opacity(0.22) : Color.white.opacity(0.05))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(isSelected ? activeAccentColor.opacity(0.3) : Color.white.opacity(0.06), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var supplementaryPanelContent: some View {
        switch selectedSupplementaryPanel {
        case .linePanel(let snapshotID):
            if let snapshot = focus.linePanelSnapshots.first(where: { $0.id == snapshotID }) {
                linePanel(snapshot)
            }
        case .scatter(let snapshotID):
            if let snapshot = focus.scatterSnapshots.first(where: { $0.id == snapshotID }) {
                scatterPanel(snapshot)
            }
        case .heatmap:
            activityHeatmapPanel
        case .heatmapDrillDown:
            primaryHeatmapDrillDownPanel
        case .processHistory:
            processHistoryPanel
        case .eventTimeline:
            eventTimelinePanel
        case .none:
            EmptyView()
        }
    }

    private func supplementaryPanelTitle(for panel: HardwareGraphFocusSupplementaryPanel) -> String {
        switch panel {
        case .linePanel(let snapshotID):
            return focus.linePanelSnapshots.first(where: { $0.id == snapshotID })?.title ?? "History"
        case .scatter(let snapshotID):
            return focus.scatterSnapshots.first(where: { $0.id == snapshotID })?.title ?? "Scatter"
        case .heatmap:
            return "Activity Heatmap"
        case .heatmapDrillDown:
            return "Selected Hour"
        case .processHistory:
            return "Historical Footprint"
        case .eventTimeline:
            return "Event Timeline"
        }
    }

    private func supplementaryPanelChipTitle(for panel: HardwareGraphFocusSupplementaryPanel) -> String {
        switch panel {
        case .linePanel(let snapshotID):
            return focus.linePanelSnapshots.first(where: { $0.id == snapshotID })?.chipTitle ?? "History"
        case .scatter(let snapshotID):
            return focus.scatterSnapshots.first(where: { $0.id == snapshotID })?.title ?? "Scatter"
        case .heatmap:
            return "Heatmap"
        case .heatmapDrillDown:
            return "Selected Hour"
        case .processHistory:
            return "Footprint"
        case .eventTimeline:
            return "Timeline"
        }
    }

    private var activityHeatmapPanel: some View {
        focusPanelCard {
            VStack(alignment: .leading, spacing: 12 * appUIScale) {
                HStack(alignment: .center, spacing: 8 * appUIScale) {
                    Text("Activity Heatmap")
                        .font(.system(size: scaledBodyFontSize, weight: .semibold))

                    if let activityHeatmapSnapshot {
                        Text(activityHeatmapSnapshot.metricLabel)
                            .font(.system(size: scaledLabelFontSize, weight: .semibold))
                            .foregroundColor(activeAccentColor.opacity(0.95))
                            .padding(.horizontal, 8 * appUIScale)
                            .padding(.vertical, 4 * appUIScale)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(activeAccentColor.opacity(0.12))
                            )
                    }

                    Spacer(minLength: 0)
                }

                if isLoadingActivityHeatmap && activityHeatmapSnapshot == nil {
                    ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                        .overlay(
                            ProgressView()
                                .controlSize(.small)
                        )
                        .frame(height: 196 * appUIScale)
                } else if let activityHeatmapSnapshot {
                    HardwareGraphFocusHeatmapView(snapshot: activityHeatmapSnapshot)
                        .frame(height: 196 * appUIScale)

                    HStack {
                        Text(activityHeatmapSnapshot.startLabel)
                        Spacer()
                        Text(activityHeatmapSnapshot.endLabel)
                    }
                    .font(.system(size: scaledLabelFontSize))
                    .foregroundColor(.secondary)
                } else {
                    Text("No activity heatmap is available for this hardware type yet.")
                        .font(.system(size: scaledLabelFontSize + 1, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var primaryHeatmapDrillDownPanel: some View {
        focusPanelCard {
            VStack(alignment: .leading, spacing: 12 * appUIScale) {
                HStack(alignment: .center, spacing: 8 * appUIScale) {
                    Text(primaryHeatmapDrillDownSnapshot?.title ?? "Selected Hour")
                        .font(.system(size: scaledBodyFontSize, weight: .semibold))

                    if let target = resolvedPrimaryHeatmapTarget {
                        Text(heatmapTitle(for: target))
                            .font(.system(size: scaledLabelFontSize, weight: .semibold))
                            .foregroundColor(activeAccentColor.opacity(0.95))
                            .padding(.horizontal, 8 * appUIScale)
                            .padding(.vertical, 4 * appUIScale)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(activeAccentColor.opacity(0.12))
                            )
                    }

                    Spacer(minLength: 0)
                }

                if let snapshot = primaryHeatmapDrillDownSnapshot {
                    Text(snapshot.subtitle)
                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .top, spacing: 10 * appUIScale) {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("High")
                            Spacer()
                            Text("Mid")
                            Spacer()
                            Text("Low")
                        }
                        .font(.system(size: scaledLabelFontSize))
                        .foregroundColor(.secondary)
                        .frame(width: 28 * appUIScale)

                        HardwareGraphFocusLineChart(series: snapshot.series)
                            .frame(maxWidth: .infinity, minHeight: 180 * appUIScale, maxHeight: 180 * appUIScale)
                    }

                    if snapshot.series.count > 1 {
                        legend(for: snapshot.series)
                    }

                    if !snapshot.stats.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 112 * appUIScale), spacing: 10 * appUIScale)],
                            alignment: .leading,
                            spacing: 10 * appUIScale
                        ) {
                            ForEach(snapshot.stats) { stat in
                                statCard(stat)
                            }
                        }
                    }

                    if !snapshot.detailLines.isEmpty {
                        VStack(alignment: .leading, spacing: 8 * appUIScale) {
                            ForEach(Array(snapshot.detailLines.enumerated()), id: \.offset) { item in
                                HStack(alignment: .top, spacing: 8 * appUIScale) {
                                    Circle()
                                        .fill(activeAccentColor.opacity(0.75))
                                        .frame(width: 6 * appUIScale, height: 6 * appUIScale)
                                        .padding(.top, 6 * appUIScale)

                                    Text(item.element)
                                        .font(.system(size: scaledBodyFontSize, weight: .regular))
                                        .foregroundColor(.white.opacity(0.82))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                } else if isLoadingPrimaryHeatmapDrillDown {
                    ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                        .overlay(
                            ProgressView()
                                .controlSize(.small)
                        )
                        .frame(height: 180 * appUIScale)
                } else {
                    Text("Click a heatmap tile to inspect that hour in more detail.")
                        .font(.system(size: scaledLabelFontSize + 1, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var processHistoryPanel: some View {
        focusPanelCard {
            VStack(alignment: .leading, spacing: 12 * appUIScale) {
                HStack(alignment: .center, spacing: 8 * appUIScale) {
                    Text("Historical Footprint")
                        .font(.system(size: scaledBodyFontSize, weight: .semibold))

                    Spacer(minLength: 0)

                    Text(shortLabel(for: selectedInsightWindow))
                        .font(.system(size: scaledLabelFontSize, weight: .semibold))
                        .foregroundColor(activeAccentColor.opacity(0.95))
                        .padding(.horizontal, 8 * appUIScale)
                        .padding(.vertical, 4 * appUIScale)
                        .background(
                            Capsule(style: .continuous)
                                .fill(activeAccentColor.opacity(0.12))
                        )
                }

                if isLoadingProcessHistory && processHistorySnapshot == nil {
                    ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                        .overlay(
                            ProgressView()
                                .controlSize(.small)
                        )
                        .frame(height: 136 * appUIScale)
                } else if let processHistorySnapshot {
                    Text(processHistorySnapshot.subtitle)
                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .top, spacing: 10 * appUIScale) {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("High")
                            Spacer()
                            Text("Mid")
                            Spacer()
                            Text("Low")
                        }
                        .font(.system(size: scaledLabelFontSize))
                        .foregroundColor(.secondary)
                        .frame(width: 28 * appUIScale)

                        HardwareGraphFocusLineChart(series: processHistorySnapshot.series)
                            .frame(maxWidth: .infinity, minHeight: 180 * appUIScale, maxHeight: 180 * appUIScale)
                    }

                    legend(for: processHistorySnapshot.series)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 112 * appUIScale), spacing: 10 * appUIScale)],
                        alignment: .leading,
                        spacing: 10 * appUIScale
                    ) {
                        ForEach(processHistorySnapshot.stats) { stat in
                            statCard(stat)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8 * appUIScale) {
                        ForEach(Array(processHistorySnapshot.detailLines.enumerated()), id: \.offset) { item in
                            HStack(alignment: .top, spacing: 8 * appUIScale) {
                                Circle()
                                    .fill(focus.accentColor.opacity(0.75))
                                    .frame(width: 5 * appUIScale, height: 5 * appUIScale)
                                    .padding(.top, 7 * appUIScale)

                                Text(item.element)
                                    .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else {
                    Text("Historical per-app linkage has not recorded enough data for this target yet.")
                        .font(.system(size: scaledLabelFontSize + 1, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var eventTimelinePanel: some View {
        focusPanelCard {
            VStack(alignment: .leading, spacing: 12 * appUIScale) {
                HStack(alignment: .center, spacing: 8 * appUIScale) {
                    Text("Event Timeline")
                        .font(.system(size: scaledBodyFontSize, weight: .semibold))

                    Spacer(minLength: 0)

                    Text(shortLabel(for: selectedInsightWindow))
                        .font(.system(size: scaledLabelFontSize, weight: .semibold))
                        .foregroundColor(focus.accentColor.opacity(0.95))
                        .padding(.horizontal, 8 * appUIScale)
                        .padding(.vertical, 4 * appUIScale)
                        .background(
                            Capsule(style: .continuous)
                                .fill(focus.accentColor.opacity(0.12))
                        )
                }

                if isLoadingEventTimeline && eventTimelineSnapshot == nil {
                    ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                        .overlay(
                            ProgressView()
                                .controlSize(.small)
                        )
                        .frame(height: 98 * appUIScale)
                } else if let eventTimelineSnapshot {
                    Text(eventTimelineSnapshot.subtitle)
                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            ThemeRoundedRectangle(cornerRadius: 6 * appUIScale, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                                .frame(height: 8 * appUIScale)
                                .offset(y: 14 * appUIScale)

                            ForEach(eventTimelineSnapshot.events) { event in
                                VStack(spacing: 6 * appUIScale) {
                                    Circle()
                                        .fill(event.tint)
                                        .frame(width: 10 * appUIScale, height: 10 * appUIScale)

                                    Rectangle()
                                        .fill(event.tint.opacity(0.45))
                                        .frame(width: 2 * appUIScale, height: 14 * appUIScale)
                                }
                                .position(
                                    x: geometry.size.width * CGFloat(event.position),
                                    y: 18 * appUIScale
                                )
                            }
                        }
                    }
                    .frame(height: 46 * appUIScale)

                    HStack {
                        Text(eventTimelineSnapshot.startLabel)
                        Spacer()
                        Text(eventTimelineSnapshot.endLabel)
                    }
                    .font(.system(size: scaledLabelFontSize))
                    .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8 * appUIScale) {
                        ForEach(Array(eventTimelineSnapshot.events.suffix(6).reversed()), id: \.id) { event in
                            HStack(alignment: .top, spacing: 8 * appUIScale) {
                                Circle()
                                    .fill(event.tint)
                                    .frame(width: 7 * appUIScale, height: 7 * appUIScale)
                                    .padding(.top, 5 * appUIScale)

                                VStack(alignment: .leading, spacing: 2 * appUIScale) {
                                    HStack(spacing: 6 * appUIScale) {
                                        Text(event.title)
                                            .font(.system(size: scaledLabelFontSize + 1, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.9))

                                        Text(event.timestampText)
                                            .font(.system(size: scaledLabelFontSize, weight: .regular))
                                            .foregroundColor(.secondary)
                                    }

                                    if let detail = event.detail, !detail.isEmpty {
                                        Text(detail)
                                            .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Text("No timeline events were recorded in the selected window.")
                        .font(.system(size: scaledLabelFontSize + 1, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func scatterPanel(_ snapshot: HardwareGraphFocusScatterSnapshot) -> some View {
        focusPanelCard {
            VStack(alignment: .leading, spacing: 12 * appUIScale) {
                HStack(alignment: .center, spacing: 8 * appUIScale) {
                    Text(snapshot.title)
                        .font(.system(size: scaledBodyFontSize, weight: .semibold))

                    if let correlationLabel = snapshot.correlationLabel {
                        Text(correlationLabel)
                            .font(.system(size: scaledLabelFontSize, weight: .semibold))
                            .foregroundColor(snapshot.accentColor.opacity(0.95))
                            .padding(.horizontal, 8 * appUIScale)
                            .padding(.vertical, 4 * appUIScale)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(snapshot.accentColor.opacity(0.12))
                            )
                    }

                    Spacer(minLength: 0)
                }

                if let subtitle = snapshot.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                        .foregroundColor(.secondary)
                }

                HStack(alignment: .top, spacing: 10 * appUIScale) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(snapshot.yMaximumLabel)
                        Spacer()
                        Text(snapshot.yMinimumLabel)
                    }
                    .font(.system(size: scaledLabelFontSize))
                    .foregroundColor(.secondary)
                    .frame(width: 42 * appUIScale)

                    VStack(alignment: .leading, spacing: 8 * appUIScale) {
                        HardwareGraphFocusScatterPlot(snapshot: snapshot)
                            .frame(height: 210 * appUIScale)

                        HStack {
                            Text(snapshot.xMinimumLabel)
                            Spacer()
                            Text(snapshot.xMaximumLabel)
                        }
                        .font(.system(size: scaledLabelFontSize))
                        .foregroundColor(.secondary)
                    }
                }

                HStack(alignment: .center, spacing: 12 * appUIScale) {
                    Text(snapshot.xAxisLabel)
                        .font(.system(size: scaledLabelFontSize, weight: .medium))
                        .foregroundColor(.secondary)

                    Spacer(minLength: 0)

                    Text(snapshot.yAxisLabel)
                        .font(.system(size: scaledLabelFontSize, weight: .medium))
                        .foregroundColor(.secondary)
                }

                if let detailText = snapshot.detailText, !detailText.isEmpty {
                    Text(detailText)
                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func linePanel(_ snapshot: HardwareGraphFocusLinePanelSnapshot) -> some View {
        focusPanelCard {
            VStack(alignment: .leading, spacing: 12 * appUIScale) {
                Text(snapshot.title)
                    .font(.system(size: scaledBodyFontSize, weight: .semibold))

                if let subtitle = snapshot.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                lineVisualization(series: snapshot.series, title: "History")
                    .frame(minHeight: 208 * appUIScale, alignment: .topLeading)

                if let detailText = snapshot.detailText, !detailText.isEmpty {
                    Text(detailText)
                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func cpuCoreDetailVisualization(_ snapshot: HardwareGraphFocusCPUCoreSnapshot) -> some View {
        GeometryReader { geometry in
            let sectionSpacing = 18 * appUIScale
            let sectionHeight = max(176 * appUIScale, (geometry.size.height - sectionSpacing) / 2)

            VStack(alignment: .leading, spacing: sectionSpacing) {
                if let selectedCore = selectedCPUCoreSnapshot(from: snapshot) {
                    let clusterColor = cpuCoreClusterColor(for: selectedCore)
                    cpuCoreChartSection(
                        title: snapshot.usageTitle,
                        subtitle: usageSubtitle(for: selectedCore, fallback: snapshot.usageSubtitle),
                        snapshot: snapshot,
                        series: [
                            HardwareGraphFocusSeries(
                                id: "cpu-core-usage-\(selectedCore.id)",
                                label: selectedCore.label,
                                color: clusterColor,
                                values: selectedCore.usageValues
                            )
                        ],
                        yAxisLabels: ("100%", "50%", "0%"),
                        detailText: selectedCore.clusterLabel.map { "\($0) core history" },
                        height: sectionHeight,
                        accentColor: clusterColor
                    )

                    let frequencySeries = normalizedFrequencySeries(for: selectedCore)
                    cpuCoreChartSection(
                        title: snapshot.frequencyTitle,
                        subtitle: frequencySubtitle(for: selectedCore, fallback: snapshot.frequencySubtitle, peakGHz: frequencySeries.axisMaximumGHz),
                        snapshot: snapshot,
                        series: frequencySeries.series,
                        yAxisLabels: (
                            formattedGHzLabel(frequencySeries.axisMaximumGHz),
                            formattedGHzLabel(frequencySeries.axisMaximumGHz / 2.0),
                            "0.0"
                        ),
                        detailText: "Recorded GHz history for the selected core.",
                        height: sectionHeight,
                        accentColor: clusterColor
                    )
                } else {
                    VStack(alignment: .leading, spacing: 10 * appUIScale) {
                        Text("No core history is available yet.")
                            .font(.system(size: scaledBodyFontSize, weight: .semibold))

                        Text("Per-core usage and clock history will appear here once the sampler records a few CPU updates.")
                            .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func cpuCoreChartSection(
        title: String,
        subtitle: String?,
        snapshot: HardwareGraphFocusCPUCoreSnapshot,
        series: [HardwareGraphFocusSeries],
        yAxisLabels: (String, String, String),
        detailText: String?,
        height: CGFloat,
        accentColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10 * appUIScale) {
            HStack(alignment: .center, spacing: 8 * appUIScale) {
                Text(title)
                    .font(.system(size: scaledBodyFontSize, weight: .semibold))

                if let selectedCore = selectedCPUCoreSnapshot(from: snapshot) {
                    Text(selectedCore.label)
                        .font(.system(size: scaledLabelFontSize, weight: .semibold))
                        .foregroundColor(accentColor.opacity(0.95))
                        .padding(.horizontal, 8 * appUIScale)
                        .padding(.vertical, 4 * appUIScale)
                        .background(
                            Capsule(style: .continuous)
                                .fill(accentColor.opacity(0.12))
                        )
                }

                Spacer(minLength: 0)
            }

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            cpuCorePicker(snapshot: snapshot)

            HStack(alignment: .top, spacing: 10 * appUIScale) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(yAxisLabels.0)
                    Spacer()
                    Text(yAxisLabels.1)
                    Spacer()
                    Text(yAxisLabels.2)
                }
                .font(.system(size: scaledLabelFontSize))
                .foregroundColor(.secondary)
                .frame(width: 34 * appUIScale)

                HardwareGraphFocusLineChart(series: series)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)

            HStack {
                Text("Earlier")
                Spacer()
                Text("Latest")
            }
            .font(.system(size: scaledLabelFontSize))
            .foregroundColor(.secondary)

            if let detailText, !detailText.isEmpty {
                Text(detailText)
                    .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
    }

    private func cpuCorePicker(snapshot: HardwareGraphFocusCPUCoreSnapshot) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8 * appUIScale) {
                ForEach(snapshot.cores) { core in
                    let isSelected = core.id == selectedCPUCoreSnapshot(from: snapshot)?.id
                    let chipColor = cpuCoreClusterColor(for: core)
                    Button {
                        selectedCPUCoreID = core.id
                    } label: {
                        HStack(spacing: 6 * appUIScale) {
                            Text(core.label)
                            if let clusterLabel = core.clusterLabel {
                                Text(clusterLabel == "Efficiency" ? "E" : "P")
                                    .foregroundColor(isSelected ? chipColor.opacity(0.95) : chipColor.opacity(0.78))
                            }
                        }
                        .font(.system(size: scaledLabelFontSize, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? .white.opacity(0.95) : chipColor.opacity(0.88))
                        .lineLimit(1)
                        .padding(.horizontal, 10 * appUIScale)
                        .padding(.vertical, 6 * appUIScale)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? chipColor.opacity(0.22) : chipColor.opacity(0.08))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(isSelected ? chipColor.opacity(0.34) : chipColor.opacity(0.14), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func selectedCPUCoreSnapshot(from snapshot: HardwareGraphFocusCPUCoreSnapshot) -> HardwareGraphFocusCPUCoreSeriesSnapshot? {
        snapshot.cores.first(where: { $0.id == selectedCPUCoreID }) ?? snapshot.cores.first
    }

    private func usageSubtitle(
        for core: HardwareGraphFocusCPUCoreSeriesSnapshot,
        fallback: String?
    ) -> String {
        var components: [String] = [core.label]
        if let clusterLabel = core.clusterLabel {
            components.append(clusterLabel)
        }
        if let liveUsage = core.liveUsage {
            components.append(String(format: "%.0f%% live", liveUsage * 100))
        }
        if let fallback, !fallback.isEmpty {
            components.append(fallback)
        }
        return components.joined(separator: " · ")
    }

    private func frequencySubtitle(
        for core: HardwareGraphFocusCPUCoreSeriesSnapshot,
        fallback: String?,
        peakGHz: Double
    ) -> String {
        var components: [String] = [core.label]
        if let liveFrequencyGHz = core.liveFrequencyGHz {
            components.append(String(format: "%.2f GHz live", liveFrequencyGHz))
        }
        if peakGHz > 0 {
            components.append(String(format: "Peak %.2f GHz", peakGHz))
        }
        if let fallback, !fallback.isEmpty {
            components.append(fallback)
        }
        return components.joined(separator: " · ")
    }

    private func normalizedFrequencySeries(
        for core: HardwareGraphFocusCPUCoreSeriesSnapshot
    ) -> (series: [HardwareGraphFocusSeries], axisMaximumGHz: Double) {
        let observedValues = core.frequencyGHzValues.compactMap { $0 }
        let axisMaximumGHz = max(observedValues.max() ?? core.liveFrequencyGHz ?? 0, 0.1)
        let normalizedValues = core.frequencyGHzValues.map { value -> Double? in
            guard let value else { return nil }
            return min(max(value / axisMaximumGHz, 0), 1)
        }
        return (
            [
                HardwareGraphFocusSeries(
                    id: "cpu-core-frequency-\(core.id)",
                    label: core.label,
                    color: cpuCoreClusterColor(for: core),
                    values: normalizedValues
                )
            ],
            axisMaximumGHz
        )
    }

    private func cpuCoreClusterColor(for core: HardwareGraphFocusCPUCoreSeriesSnapshot) -> Color {
        switch core.clusterLabel {
        case "Efficiency":
            return Color(red: 0.05, green: 0.48, blue: 0.70)
        case "Performance":
            return Color(red: 0.22, green: 0.16, blue: 0.80)
        default:
            return focus.accentColor
        }
    }

    private func formattedGHzLabel(_ value: Double) -> String {
        String(format: "%.1f", max(value, 0))
    }

    private var interactiveHeatmapStats: [HardwareGraphFocusStat]? {
        guard usesInteractivePrimaryHeatmap,
              let snapshot = resolvedPrimaryHeatmapSnapshot,
              let target = resolvedPrimaryHeatmapTarget else {
            return nil
        }

        let peakRow = (0..<snapshot.rowCount).max { lhs, rhs in
            averageHeatmapIntensity(forRow: lhs, in: snapshot) < averageHeatmapIntensity(forRow: rhs, in: snapshot)
        }
        let hottestCell = hottestHeatmapCell(in: snapshot)
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "MMM d"

        return [
            HardwareGraphFocusStat(label: "Metric", value: heatmapTitle(for: target), tint: heatmapAccentColor(for: target)),
            HardwareGraphFocusStat(label: "Days", value: "\(snapshot.columnCount)"),
            HardwareGraphFocusStat(label: "Peak Hour", value: peakRow.map(heatmapHourLabel(for:)) ?? "—"),
            HardwareGraphFocusStat(
                label: "Busiest Day",
                value: hottestCell?.slotStart.map { dayFormatter.string(from: $0) } ?? "—"
            ),
            HardwareGraphFocusStat(
                label: "Hot Slot",
                value: hottestCell?.slotStart.map(formatHeatmapSlot) ?? "No activity"
            )
        ]
    }

    private var interactiveHeatmapDetailLines: [String]? {
        guard usesInteractivePrimaryHeatmap,
              let target = resolvedPrimaryHeatmapTarget else {
            return nil
        }

        switch target {
        case .overall:
            return [
                "Rows represent hours of the day and columns represent recent days, oldest to newest.",
                "Overall blends CPU, GPU, memory pressure, power, and network quality into one composite view."
            ]
        case .network:
            return [
                "Rows represent hours of the day and columns represent recent days, oldest to newest.",
                "Network tiles reflect throughput plus 30-minute ping probes so quiet-but-unhealthy slots still surface."
            ]
        default:
            return [
                "Rows represent hours of the day and columns represent recent days, oldest to newest.",
                "Each column is normalized against activity observed within that day so quieter days still remain readable."
            ]
        }
    }

    private func averageHeatmapIntensity(forRow row: Int, in snapshot: HardwareGraphFocusHeatmapSnapshot) -> Double {
        guard row >= 0, row < snapshot.rowCount, snapshot.columnCount > 0 else { return 0 }
        let values = snapshot.columns.compactMap { column -> Double? in
            guard row < column.count else { return nil }
            return column[row].intensity
        }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func hottestHeatmapCell(in snapshot: HardwareGraphFocusHeatmapSnapshot) -> HardwareGraphFocusHeatmapCell? {
        let cell = snapshot.columns
            .flatMap { $0 }
            .max { lhs, rhs in lhs.intensity < rhs.intensity }
        if (cell?.intensity ?? 0) <= 0.001 {
            return nil
        }
        return cell
    }

    private func heatmapTitle(for target: HardwareGraphFocusHeatmapTarget) -> String {
        switch target {
        case .overall:
            return "All"
        case .cpu:
            return "CPU"
        case .gpu:
            return "GPU"
        case .memory:
            return "Memory"
        case .disk:
            return "Disk"
        case .network:
            return "Network"
        case .power:
            return "Power"
        case .ane:
            return "ANE"
        case .thermals:
            return "Thermals"
        }
    }

    private func heatmapAccentColor(for target: HardwareGraphFocusHeatmapTarget) -> Color {
        switch target {
        case .overall:
            return .white
        case .cpu:
            return .blue
        case .gpu:
            return Color(red: 0.85, green: 0.20, blue: 0.20)
        case .memory:
            return Color(red: 0.10, green: 0.65, blue: 0.28)
        case .disk:
            return .diskWriteAccentColor
        case .network:
            return .networkAccentColor
        case .power:
            return .orange
        case .ane:
            return Color(red: 0.65, green: 0.00, blue: 0.65)
        case .thermals:
            return Color(red: 0.02, green: 0.65, blue: 0.65)
        }
    }

    private func focusInsightTarget(for target: HardwareGraphFocusHeatmapTarget) -> HardwareGraphFocusInsightTarget? {
        switch target {
        case .overall:
            return nil
        case .cpu:
            return .cpu
        case .gpu:
            return .gpu
        case .memory:
            return .memory
        case .disk:
            return .disk
        case .network:
            return .network
        case .power:
            return .power
        case .ane:
            return .ane
        case .thermals:
            return .thermals
        }
    }

    private func formatHeatmapSlot(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d · h a"
        return formatter.string(from: date)
    }

    private func heatmapHourLabel(for hour: Int) -> String {
        let normalized = hour % 12 == 0 ? 12 : hour % 12
        return "\(normalized)\(hour < 12 ? "a" : "p")"
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: scaledPanelSpacing) {
            if !displayedStats.isEmpty {
                detailSection(title: "Stats") {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 112 * appUIScale), spacing: 10 * appUIScale)],
                        alignment: .leading,
                        spacing: 10 * appUIScale
                    ) {
                        ForEach(displayedStats) { stat in
                            statCard(stat)
                        }
                    }
                }
            }

            if !focus.detailVisuals.isEmpty {
                ForEach(focus.detailVisuals) { detailVisual in
                    detailSection(title: detailVisualSectionTitle(for: detailVisual)) {
                        detailVisualPanel(detailVisual)
                    }
                }
            }

            if effectiveInsightTarget != nil {
                detailSection(title: "Related Insight") {
                    relatedInsightPanel
                }
            }

            if focus.attributionTarget != nil {
                detailSection(title: "Live Attribution") {
                    attributionPanel
                }
            }

            if !displayedDetailLines.isEmpty {
                detailSection(title: "Details") {
                    VStack(alignment: .leading, spacing: 10 * appUIScale) {
                        ForEach(Array(displayedDetailLines.enumerated()), id: \.offset) { item in
                            let line = item.element
                            HStack(alignment: .top, spacing: 8 * appUIScale) {
                                Circle()
                                    .fill(activeAccentColor.opacity(0.75))
                                    .frame(width: 6 * appUIScale, height: 6 * appUIScale)
                                    .padding(.top, 6 * appUIScale)

                                Text(line)
                                    .font(.system(size: scaledBodyFontSize, weight: .regular))
                                    .foregroundColor(.white.opacity(0.82))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            if !focus.mediaRecentSessions.isEmpty {
                detailSection(title: "Recent Media Sessions") {
                    mediaRecentSessionsPanel
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func detailVisualSectionTitle(for detailVisual: HardwareGraphFocusDetailVisual) -> String {
        switch detailVisual {
        case .neuralEngine:
            return "ANE Cores"
        case .helperServices:
            return "Services"
        case .actions(let snapshot):
            return snapshot.title
        case .networkInterfaces:
            return "Interfaces"
        case .gpuHardware:
            return "GPU Hardware"
        }
    }

    @ViewBuilder
    private func detailVisualPanel(_ detailVisual: HardwareGraphFocusDetailVisual) -> some View {
        switch detailVisual {
        case .neuralEngine(let snapshot):
            neuralEngineDetailVisual(snapshot)
        case .helperServices(let snapshot):
            helperServicesDetailVisual(snapshot)
        case .actions(let snapshot):
            actionRowsDetailVisual(snapshot)
        case .networkInterfaces(let snapshot):
            networkInterfacesDetailVisual(snapshot)
        case .gpuHardware(let snapshot):
            gpuHardwareDetailVisual(snapshot)
        }
    }

    private func detailSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        focusPanelCard(padding: 16 * appUIScale) {
            VStack(alignment: .leading, spacing: 10 * appUIScale) {
                Text(title)
                    .font(.system(size: scaledBodyFontSize, weight: .semibold))

                content()
            }
        }
    }

    private func statCard(_ stat: HardwareGraphFocusStat) -> some View {
        let tint = stat.tint ?? activeAccentColor

        return ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
            .fill(tint.opacity(0.08))
            .overlay(
                ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
                    .stroke(tint.opacity(0.16), lineWidth: 1)
            )
            .overlay(
                VStack(alignment: .leading, spacing: 4 * appUIScale) {
                    Text(stat.label.uppercased())
                        .font(.system(size: scaledLabelFontSize - 1, weight: .semibold))
                        .foregroundColor(.secondary)

                    Text(stat.value)
                        .font(.system(size: 17 * appUIScale, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .padding(12 * appUIScale)
                .frame(maxWidth: .infinity, alignment: .leading)
            )
            .frame(minHeight: 74 * appUIScale)
    }

    private func neuralEngineDetailVisual(_ snapshot: HardwareGraphFocusNeuralEngineVisualSnapshot) -> some View {
        let capsuleHeight = max(5 * appUIScale, 4.5 * appUIScale)
        let capsuleWidth = 56 * appUIScale
        let capsuleSpacing = CGFloat(1)
        let railPadding = 10 * appUIScale
        let topPadding = 6 * appUIScale
        let rowExtraHeight = 6 * appUIScale
        let capsuleRowsHeight = (CGFloat(max(snapshot.visibleCoreCount, 0)) * (capsuleHeight + rowExtraHeight))
            + (CGFloat(max(snapshot.visibleCoreCount - 1, 0)) * capsuleSpacing)
            + topPadding
            + (railPadding * 2)
        let contentHeight = max(160 * appUIScale, min(320 * appUIScale, capsuleRowsHeight))
        let visibleClients = Array(snapshot.clients.prefix(4))
        let statusTint = neuralEngineStatusAccentColor(for: snapshot)

        return insetPanelCard(
            fill: statusTint.opacity(0.07),
            stroke: statusTint.opacity(0.16)
        ) {
            HStack(alignment: .top, spacing: 14 * appUIScale) {
                VStack(alignment: .leading, spacing: 10 * appUIScale) {
                    Text(snapshot.title)
                        .font(.system(size: scaledBodyFontSize, weight: .semibold))
                        .foregroundColor(.white.opacity(0.94))

                    if let subtitle = snapshot.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 6 * appUIScale) {
                        neuralEngineMetadataRow(label: "Visible", value: snapshot.totalCoreCount.map { "\($0) cores" } ?? "\(snapshot.visibleCoreCount) cores")
                        neuralEngineMetadataRow(label: "Status", value: snapshot.statusText)
                        if let architectureText = snapshot.architectureText, !architectureText.isEmpty, architectureText != "—" {
                            neuralEngineMetadataRow(label: "Arch", value: architectureText)
                        }
                        if let currentPowerText = snapshot.currentPowerText, !currentPowerText.isEmpty, currentPowerText != "—" {
                            neuralEngineMetadataRow(label: "Power", value: currentPowerText)
                        }
                        neuralEngineMetadataRow(label: "Clients", value: "\(snapshot.clientCount)")
                    }

                    if !visibleClients.isEmpty {
                        VStack(alignment: .leading, spacing: 6 * appUIScale) {
                            Text("Active Clients")
                                .font(.system(size: scaledLabelFontSize, weight: .semibold))
                                .foregroundColor(.secondary)

                            ForEach(visibleClients, id: \.self) { client in
                                Text("• \(client)")
                                    .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                                    .foregroundColor(.white.opacity(0.82))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                NeuralEngineCapsuleMetalView(
                    visibleCapsuleCount: snapshot.visibleCoreCount,
                    isIdle: snapshot.isIdle,
                    isActive: snapshot.isActive,
                    statusColor: neuralEngineStatusGlowSIMD(for: snapshot),
                    capsuleColumnWidth: 92 * appUIScale,
                    cardContentHeight: contentHeight,
                    capsuleWidth: capsuleWidth,
                    capsuleHeight: capsuleHeight,
                    capsuleSpacing: capsuleSpacing,
                    capsuleRailPadding: railPadding,
                    capsuleTopPadding: topPadding
                )
                .frame(width: 92 * appUIScale, height: contentHeight, alignment: .top)
                .clipped()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func helperServicesDetailVisual(_ snapshot: HardwareGraphFocusHelperServicesSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12 * appUIScale) {
            if let subtitle = snapshot.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(snapshot.rows) { row in
                insetPanelCard(
                    fill: helperServiceToneColor(row.tone).opacity(0.08),
                    stroke: helperServiceToneColor(row.tone).opacity(0.16),
                    padding: 12 * appUIScale
                ) {
                    VStack(alignment: .leading, spacing: 10 * appUIScale) {
                        HStack(alignment: .top, spacing: 10 * appUIScale) {
                            VStack(alignment: .leading, spacing: 4 * appUIScale) {
                                Text(row.name)
                                    .font(.system(size: scaledBodyFontSize, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.94))

                                Text(row.uptimeText == "—" ? "Uptime unavailable" : "Uptime \(row.uptimeText)")
                                    .font(.system(size: scaledLabelFontSize + 0.25, weight: .regular))
                                    .foregroundColor(.secondary)
                            }

                            Spacer(minLength: 0)

                            Text(row.statusText)
                                .font(.system(size: scaledLabelFontSize + 0.25, weight: .semibold))
                                .foregroundColor(helperServiceToneColor(row.tone).opacity(0.95))
                                .padding(.horizontal, 9 * appUIScale)
                                .padding(.vertical, 5 * appUIScale)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(helperServiceToneColor(row.tone).opacity(0.14))
                                )
                        }

                        if let detailText = row.detailText, !detailText.isEmpty {
                            Text(detailText)
                                .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if row.actionTitle != nil || row.uninstallActionTitle != nil {
                            HStack(spacing: 8 * appUIScale) {
                                if let actionTitle = row.actionTitle {
                                    helperServiceActionButton(
                                        title: row.isActionInProgress ? (row.actionInProgressTitle ?? "Working...") : actionTitle,
                                        isEnabled: row.isActionEnabled,
                                        isInProgress: row.isActionInProgress,
                                        tint: Color.white.opacity(0.94)
                                    ) {
                                        focus.detailActionHandler?(row.actionID ?? row.id)
                                    }
                                }

                                if let uninstallTitle = row.uninstallActionTitle {
                                    helperServiceActionButton(
                                        title: row.isUninstallActionInProgress ? (row.uninstallActionInProgressTitle ?? "Uninstalling...") : uninstallTitle,
                                        isEnabled: row.isUninstallActionEnabled,
                                        isInProgress: row.isUninstallActionInProgress,
                                        tint: Color(red: 1.0, green: 0.52, blue: 0.42).opacity(0.95)
                                    ) {
                                        guard let actionID = row.uninstallActionID else { return }
                                        focus.detailActionHandler?(actionID)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func helperServiceActionButton(
        title: String,
        isEnabled: Bool,
        isInProgress: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8 * appUIScale) {
                if isInProgress {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(title)
                    .font(.system(size: scaledLabelFontSize + 0.5, weight: .semibold))
            }
            .foregroundColor(isEnabled || isInProgress ? tint : Color.white.opacity(0.45))
            .padding(.horizontal, 12 * appUIScale)
            .padding(.vertical, 8 * appUIScale)
            .background(
                ThemeRoundedRectangle(cornerRadius: 10 * appUIScale, style: .continuous)
                    .fill(tint.opacity(isEnabled || isInProgress ? 0.12 : 0.05))
            )
            .overlay(
                ThemeRoundedRectangle(cornerRadius: 10 * appUIScale, style: .continuous)
                    .stroke(tint.opacity(isEnabled || isInProgress ? 0.20 : 0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || isInProgress || focus.detailActionHandler == nil)
    }

    private func actionRowsDetailVisual(_ snapshot: HardwareGraphFocusActionsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12 * appUIScale) {
            if let subtitle = snapshot.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(snapshot.rows) { row in
                insetPanelCard(
                    fill: actionRowToneColor(row.tone).opacity(0.08),
                    stroke: actionRowToneColor(row.tone).opacity(0.16),
                    padding: 12 * appUIScale
                ) {
                    VStack(alignment: .leading, spacing: 10 * appUIScale) {
                        HStack(alignment: .top, spacing: 10 * appUIScale) {
                            VStack(alignment: .leading, spacing: 4 * appUIScale) {
                                Text(row.name)
                                    .font(.system(size: scaledBodyFontSize, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.94))

                                if let subtitleText = row.subtitleText, !subtitleText.isEmpty {
                                    Text(subtitleText)
                                        .font(.system(size: scaledLabelFontSize + 0.25, weight: .regular))
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer(minLength: 0)

                            Text(row.statusText)
                                .font(.system(size: scaledLabelFontSize + 0.25, weight: .semibold))
                                .foregroundColor(actionRowToneColor(row.tone).opacity(0.95))
                                .padding(.horizontal, 9 * appUIScale)
                                .padding(.vertical, 5 * appUIScale)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(actionRowToneColor(row.tone).opacity(0.14))
                                )
                        }

                        if let detailText = row.detailText, !detailText.isEmpty {
                            Text(detailText)
                                .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let actionTitle = row.actionTitle {
                            Button(action: {
                                focus.detailActionHandler?(row.id)
                            }) {
                                HStack(spacing: 8 * appUIScale) {
                                    if row.isActionInProgress {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                    Text(row.isActionInProgress ? "Working..." : actionTitle)
                                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .semibold))
                                }
                                .foregroundColor(.white.opacity(0.94))
                                .padding(.horizontal, 12 * appUIScale)
                                .padding(.vertical, 8 * appUIScale)
                                .background(
                                    ThemeRoundedRectangle(cornerRadius: 10 * appUIScale, style: .continuous)
                                        .fill(Color.white.opacity(row.isActionEnabled ? 0.10 : 0.05))
                                )
                                .overlay(
                                    ThemeRoundedRectangle(cornerRadius: 10 * appUIScale, style: .continuous)
                                        .stroke(Color.white.opacity(row.isActionEnabled ? 0.16 : 0.08), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(row.isActionEnabled == false || row.isActionInProgress || focus.detailActionHandler == nil)
                        }
                    }
                }
            }
        }
    }

    private func networkInterfacesDetailVisual(_ snapshot: HardwareGraphFocusNetworkInterfacesSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12 * appUIScale) {
            if let subtitle = snapshot.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(snapshot.rows) { row in
                insetPanelCard(
                    fill: Color.white.opacity(0.08),
                    stroke: Color.white.opacity(0.16),
                    padding: 12 * appUIScale
                ) {
                    VStack(alignment: .leading, spacing: 10 * appUIScale) {
                        HStack(alignment: .top, spacing: 10 * appUIScale) {
                            VStack(alignment: .leading, spacing: 4 * appUIScale) {
                                HStack(spacing: 8 * appUIScale) {
                                    Text(row.name)
                                        .font(.system(size: scaledBodyFontSize, weight: .semibold))
                                        .foregroundColor(.white)

                                    if row.isActive {
                                        Circle()
                                            .fill(Color(red: 0.30, green: 0.84, blue: 0.50))
                                            .frame(width: 8 * appUIScale, height: 8 * appUIScale)
                                    } else {
                                        Circle()
                                            .fill(Color.white.opacity(0.4))
                                            .frame(width: 8 * appUIScale, height: 8 * appUIScale)
                                    }
                                }

                                Text(row.connectionType)
                                    .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()
                        }

                        HStack(alignment: .top, spacing: 20 * appUIScale) {
                            if let localIP = row.localIP {
                                VStack(alignment: .leading, spacing: 2 * appUIScale) {
                                    Text("IP")
                                        .font(.system(size: scaledLabelFontSize, weight: .regular))
                                        .foregroundColor(.secondary)
                                    Text(localIP)
                                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .medium))
                                        .foregroundColor(.white)
                                }
                            }

                            if let subnetMask = row.subnetMask {
                                VStack(alignment: .leading, spacing: 2 * appUIScale) {
                                    Text("Subnet")
                                        .font(.system(size: scaledLabelFontSize, weight: .regular))
                                        .foregroundColor(.secondary)
                                    Text(subnetMask)
                                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .medium))
                                        .foregroundColor(.white)
                                }
                            }

                            if let macAddress = row.macAddress {
                                VStack(alignment: .leading, spacing: 2 * appUIScale) {
                                    Text("MAC")
                                        .font(.system(size: scaledLabelFontSize, weight: .regular))
                                        .foregroundColor(.secondary)
                                    Text(macAddress)
                                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .medium))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func gpuHardwareDetailVisual(_ snapshot: HardwareGraphFocusGPUHardwareSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12 * appUIScale) {
            Text(snapshot.name)
                .font(.system(size: scaledBodyFontSize, weight: .semibold))
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 6 * appUIScale) {
                gpuHardwareMetadataRow(label: "Bus", value: snapshot.bus)
                gpuHardwareMetadataRow(label: "Type", value: snapshot.gpuType)
                gpuHardwareMetadataRow(label: "Metal", value: snapshot.metalFamily)
                if let cores = snapshot.coreCount {
                    gpuHardwareMetadataRow(label: "Cores", value: "\(cores)")
                }
                if let memoryText = snapshot.memoryText {
                    gpuHardwareMetadataRow(label: snapshot.memoryLabel ?? "VRAM", value: memoryText)
                }
                if let displays = snapshot.connectedDisplayCount {
                    gpuHardwareMetadataRow(label: "Displays", value: "\(displays)")
                }
                if let deviceID = snapshot.deviceID {
                    gpuHardwareMetadataRow(label: "Device ID", value: deviceID)
                }
                if let revisionID = snapshot.revisionID {
                    gpuHardwareMetadataRow(label: "Revision", value: revisionID)
                }
                if let pcie = snapshot.pcieWidth {
                    gpuHardwareMetadataRow(label: "PCIe", value: pcie)
                }
                if let removable = snapshot.isRemovable {
                    gpuHardwareMetadataRow(label: "Removable", value: removable ? "Yes" : "No")
                }
            }
        }
    }

    private func gpuHardwareMetadataRow(label: String, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8 * appUIScale) {
            Text(label)
                .font(.system(size: scaledLabelFontSize, weight: .regular))
                .foregroundColor(.secondary)
                .frame(width: 72 * appUIScale, alignment: .leading)

            Text(value ?? "—")
                .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                .foregroundColor(value == nil ? .secondary.opacity(0.4) : .white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func helperServiceToneColor(_ tone: HardwareGraphFocusHelperServiceRowSnapshot.Tone) -> Color {
        switch tone {
        case .active:
            return Color(red: 0.30, green: 0.84, blue: 0.50)
        case .attention:
            return Color(red: 0.90, green: 0.42, blue: 0.32)
        case .unknown:
            return Color.white.opacity(0.68)
        }
    }

    private func actionRowToneColor(_ tone: HardwareGraphFocusActionRowSnapshot.Tone) -> Color {
        switch tone {
        case .neutral:
            return Color.white.opacity(0.72)
        case .attention:
            return Color(red: 0.90, green: 0.42, blue: 0.32)
        case .positive:
            return Color(red: 0.30, green: 0.84, blue: 0.50)
        }
    }

    private func neuralEngineMetadataRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8 * appUIScale) {
            Text(label.uppercased())
                .font(.system(size: scaledLabelFontSize - 1, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 52 * appUIScale, alignment: .leading)

            Text(value)
                .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                .foregroundColor(.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func neuralEngineStatusAccentColor(for snapshot: HardwareGraphFocusNeuralEngineVisualSnapshot) -> Color {
        switch snapshot.statusText.lowercased() {
        case "active":
            return .blue
        case "busy":
            return Color(red: 0.85, green: 0.20, blue: 0.20)
        default:
            return Color(red: 0.58, green: 0.18, blue: 0.80)
        }
    }

    private func neuralEngineStatusGlowSIMD(for snapshot: HardwareGraphFocusNeuralEngineVisualSnapshot) -> SIMD4<Float> {
        switch snapshot.statusText.lowercased() {
        case "active":
            return SIMD4<Float>(0.0, 0.48, 1.0, 0.55)
        case "busy":
            return SIMD4<Float>(0.85, 0.20, 0.20, 0.55)
        default:
            return SIMD4<Float>(0, 0, 0, 0)
        }
    }

    private var relatedInsightPanel: some View {
        VStack(alignment: .leading, spacing: 10 * appUIScale) {
            if isLoadingInsight && insightSnapshot == nil {
                ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
                    .fill(Color.white.opacity(0.03))
                    .overlay(
                        ProgressView()
                            .controlSize(.small)
                    )
                    .frame(height: 110 * appUIScale)
            } else if let insightSnapshot {
                insetPanelCard(
                    fill: insightSnapshot.accentColor.opacity(0.08),
                    stroke: insightSnapshot.accentColor.opacity(0.18)
                ) {
                    VStack(alignment: .leading, spacing: 10 * appUIScale) {
                        HStack(alignment: .center, spacing: 8 * appUIScale) {
                            Text(insightSnapshot.title)
                                .font(.system(size: scaledBodyFontSize, weight: .semibold))

                            Spacer(minLength: 0)

                            Text(insightSnapshot.coverageLabel)
                                .font(.system(size: scaledLabelFontSize, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8 * appUIScale)
                                .padding(.vertical, 4 * appUIScale)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.white.opacity(0.08))
                                )
                        }

                        Text(insightSnapshot.headline)
                            .font(.system(size: 15 * appUIScale, weight: .semibold))
                            .foregroundColor(.white.opacity(0.95))
                            .fixedSize(horizontal: false, vertical: true)

                        Text(insightSnapshot.detail)
                            .font(.system(size: scaledBodyFontSize, weight: .regular))
                            .foregroundColor(.white.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)

                        if !insightSnapshot.contextFacts.isEmpty {
                            VStack(alignment: .leading, spacing: 8 * appUIScale) {
                                ForEach(Array(insightSnapshot.contextFacts.prefix(4).enumerated()), id: \.offset) { item in
                                    HStack(alignment: .top, spacing: 8 * appUIScale) {
                                        Circle()
                                            .fill(insightSnapshot.accentColor.opacity(0.85))
                                            .frame(width: 5 * appUIScale, height: 5 * appUIScale)
                                            .padding(.top, 7 * appUIScale)

                                        Text(item.element)
                                            .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                                            .foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                Text("No related insight is available for this focused view yet.")
                    .font(.system(size: scaledLabelFontSize + 1, weight: .regular))
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer(minLength: 0)
                insightWindowPicker
            }
        }
    }

    private var attributionPanel: some View {
        VStack(alignment: .leading, spacing: 10 * appUIScale) {
            if isLoadingAttribution && attributionSnapshot == nil {
                ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
                    .fill(Color.white.opacity(0.03))
                    .overlay(
                        ProgressView()
                            .controlSize(.small)
                    )
                    .frame(height: 110 * appUIScale)
            } else if let attributionSnapshot {
                if attributionSnapshot.isHeuristic {
                    Text("Estimated from live CPU, RAM, and GPU activity rather than direct per-process power telemetry.")
                        .font(.system(size: scaledLabelFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10 * appUIScale) {
                    Text(attributionSnapshot.subtitle)
                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(attributionSnapshot.rows) { row in
                        attributionRow(row, accentColor: attributionSnapshot.accentColor)
                    }
                }
            } else {
                Text("No live app attribution is available for this focused view yet.")
                    .font(.system(size: scaledLabelFontSize + 1, weight: .regular))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func attributionRow(
        _ row: HardwareGraphFocusAttributionRow,
        accentColor: Color
    ) -> some View {
        insetPanelCard(
            fill: accentColor.opacity(0.08),
            stroke: accentColor.opacity(0.16)
        ) {
            VStack(alignment: .leading, spacing: 8 * appUIScale) {
                HStack(alignment: .center, spacing: 8 * appUIScale) {
                    Text(row.name)
                        .font(.system(size: scaledBodyFontSize, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Spacer(minLength: 0)

                    Text(row.primaryValue)
                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                }

                if let secondaryValue = row.secondaryValue, !secondaryValue.isEmpty {
                    Text(secondaryValue)
                        .font(.system(size: scaledLabelFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.05))

                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        row.tint.opacity(0.45),
                                        row.tint.opacity(0.9)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geometry.size.width * CGFloat(min(max(row.contribution, 0), 1)))
                    }
                }
                .frame(height: 7 * appUIScale)
                .clipShape(ThemeRoundedRectangle(cornerRadius: 3 * appUIScale, style: .continuous))
            }
        }
    }

    private var mediaRecentSessionsPanel: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10 * appUIScale) {
                ForEach(Array(focus.mediaRecentSessions.prefix(10).enumerated()), id: \.element.id) { _, session in
                    mediaSessionRow(session)
                }
            }
            .padding(.trailing, 2 * appUIScale)
        }
        .frame(maxWidth: .infinity, minHeight: 160 * appUIScale, maxHeight: 250 * appUIScale, alignment: .topLeading)
    }

    private func mediaSessionRow(_ session: MediaEngineStatsSampler.RecentSession) -> some View {
        let roleColor: Color = session.role == .encode
            ? focus.accentColor
            : Color(red: 0.32, green: 0.58, blue: 0.95)

        return insetPanelCard(
            fill: roleColor.opacity(0.08),
            stroke: roleColor.opacity(0.16)
        ) {
            VStack(alignment: .leading, spacing: 8 * appUIScale) {
                HStack(alignment: .center, spacing: 8 * appUIScale) {
                    Text(session.roleText)
                        .font(.system(size: scaledLabelFontSize, weight: .semibold))
                        .foregroundColor(roleColor.opacity(0.95))
                        .padding(.horizontal, 8 * appUIScale)
                        .padding(.vertical, 4 * appUIScale)
                        .background(
                            Capsule(style: .continuous)
                                .fill(roleColor.opacity(0.14))
                        )

                    Text(session.codecText)
                        .font(.system(size: scaledBodyFontSize, weight: .semibold))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(mediaSessionRelativeTimeString(since: session.lastActivityDate))
                        .font(.system(size: scaledLabelFontSize, weight: .medium))
                        .foregroundColor(.secondary)
                }

                if let resolutionText = session.resolutionText {
                    Text(resolutionText)
                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .medium))
                        .foregroundColor(.secondary)
                }

                let statsLine = mediaSessionStatsLine(for: session)
                if !statsLine.isEmpty {
                    Text(statsLine)
                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                        .foregroundColor(.white.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let clientName = session.lastClientName, !clientName.isEmpty {
                    Text("Client: \(clientName)")
                        .font(.system(size: scaledLabelFontSize, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func mediaSessionStatsLine(for session: MediaEngineStatsSampler.RecentSession) -> String {
        var parts: [String] = []
        if let input = session.framesInput, input > 0 {
            parts.append("\(input) in")
        }
        if let processed = session.framesProcessed, processed > 0 {
            parts.append("\(processed) processed")
        }
        if let dropped = session.framesDropped, dropped > 0 {
            parts.append("\(dropped) dropped")
        }
        parts.append(session.isCompleted ? "Completed" : "Observed")
        return parts.joined(separator: " · ")
    }

    private func mediaSessionRelativeTimeString(since date: Date) -> String {
        let delta = max(0, Date().timeIntervalSince(date))
        if delta < 1 { return "now" }
        if delta < 60 { return "\(Int(delta))s ago" }
        if delta < 3600 { return "\(Int(delta / 60))m ago" }
        return "\(Int(delta / 3600))h ago"
    }

    private var insightWindowPicker: some View {
        HStack(spacing: 4 * appUIScale) {
            ForEach(HardwareInsightWindow.allCases, id: \.rawValue) { window in
                let isSelected = window == selectedInsightWindow
                Button {
                    selectedInsightWindow = window
                } label: {
                    Text(shortLabel(for: window))
                        .font(.system(size: scaledLabelFontSize, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? focus.accentColor : .secondary)
                        .padding(.horizontal, 8 * appUIScale)
                        .padding(.vertical, 5 * appUIScale)
                        .background(
                            ThemeRoundedRectangle(cornerRadius: 7 * appUIScale, style: .continuous)
                                .fill(isSelected ? focus.accentColor.opacity(0.14) : Color.white.opacity(0.04))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func lineVisualization(series: [HardwareGraphFocusSeries], title: String) -> some View {
        VStack(alignment: .leading, spacing: 12 * appUIScale) {
            HStack(alignment: .center, spacing: 10 * appUIScale) {
                Text(title)
                    .font(.system(size: scaledBodyFontSize, weight: .semibold))

                Spacer(minLength: 0)

                if series.count > 1 {
                    legend(for: series)
                }
            }

            HStack(alignment: .top, spacing: 10 * appUIScale) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("100%")
                    Spacer()
                    Text("50%")
                    Spacer()
                    Text("0")
                }
                .font(.system(size: scaledLabelFontSize))
                .foregroundColor(.secondary)
                .frame(width: 28 * appUIScale)

                HardwareGraphFocusLineChart(series: series)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Text("Earlier")
                Spacer()
                Text("Latest")
            }
            .font(.system(size: scaledLabelFontSize))
            .foregroundColor(.secondary)
        }
    }

    private func summaryVisualization(_ snapshot: HardwareGraphFocusSummarySnapshot) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14 * appUIScale) {
                Text(snapshot.title)
                    .font(.system(size: scaledBodyFontSize, weight: .semibold))

                if let subtitle = snapshot.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let hero = snapshot.hero {
                    summaryHeroView(hero)
                }

                if !snapshot.tiles.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 140 * appUIScale), spacing: 10 * appUIScale)],
                        alignment: .leading,
                        spacing: 10 * appUIScale
                    ) {
                        ForEach(snapshot.tiles) { tile in
                            summaryTileCard(tile)
                        }
                    }
                }

                if !snapshot.rows.isEmpty {
                    focusPanelCard(padding: 14 * appUIScale) {
                        VStack(alignment: .leading, spacing: 10 * appUIScale) {
                            Text("Inventory")
                                .font(.system(size: scaledBodyFontSize, weight: .semibold))

                            VStack(spacing: 0) {
                                ForEach(Array(snapshot.rows.enumerated()), id: \.element.id) { index, row in
                                    HStack(alignment: .firstTextBaseline, spacing: 12 * appUIScale) {
                                        Text(row.label)
                                            .font(.system(size: scaledLabelFontSize + 0.5, weight: .medium))
                                            .foregroundColor(.secondary)
                                            .frame(width: 128 * appUIScale, alignment: .leading)

                                        Text(row.value)
                                            .font(.system(size: scaledLabelFontSize + 1, weight: .regular))
                                            .foregroundColor(.white.opacity(0.9))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.vertical, 8 * appUIScale)

                                    if index < snapshot.rows.count - 1 {
                                        Rectangle()
                                            .fill(Color.white.opacity(0.08))
                                            .frame(height: 1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.bottom, 2)
        }
    }

    private func heatmapVisualization(snapshot: HardwareGraphFocusHeatmapSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12 * appUIScale) {
            HStack(alignment: .center, spacing: 8 * appUIScale) {
                Text("Heatmap")
                    .font(.system(size: scaledBodyFontSize, weight: .semibold))

                Text(snapshot.metricLabel)
                    .font(.system(size: scaledLabelFontSize, weight: .semibold))
                    .foregroundColor(focus.accentColor.opacity(0.95))
                    .padding(.horizontal, 8 * appUIScale)
                    .padding(.vertical, 4 * appUIScale)
                    .background(
                        Capsule(style: .continuous)
                            .fill(focus.accentColor.opacity(0.12))
                    )

                Spacer(minLength: 0)
            }

            HardwareGraphFocusHeatmapView(snapshot: snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Text(snapshot.startLabel)
                Spacer()
                Text(snapshot.endLabel)
            }
            .font(.system(size: scaledLabelFontSize))
            .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func summaryHeroView(_ hero: HardwareGraphFocusSummaryHero) -> some View {
        switch hero {
        case .machine(let snapshot):
            machineSummaryHero(snapshot)
        case .storage(let snapshot):
            storageSummaryHero(snapshot)
        }
    }

    private func machineSummaryHero(_ snapshot: HardwareGraphFocusMachineHeroSnapshot) -> some View {
        insetPanelCard(
            fill: activeAccentColor.opacity(0.06),
            stroke: activeAccentColor.opacity(0.14)
        ) {
            HStack(alignment: .center, spacing: 18 * appUIScale) {
                MachineThumbnailView(family: snapshot.family)
                    .frame(width: 118 * appUIScale, height: 118 * appUIScale)

                VStack(alignment: .leading, spacing: 10 * appUIScale) {
                    HStack(alignment: .center, spacing: 8 * appUIScale) {
                        Text(snapshot.modelName)
                            .font(.system(size: scaledTitleFontSize - 2, weight: .semibold))
                            .foregroundColor(.white.opacity(0.94))

                        if let badgeText = snapshot.badgeText, !badgeText.isEmpty {
                            Text(badgeText)
                                .font(.system(size: scaledLabelFontSize, weight: .semibold))
                                .foregroundColor(activeAccentColor.opacity(0.95))
                                .padding(.horizontal, 8 * appUIScale)
                                .padding(.vertical, 4 * appUIScale)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(activeAccentColor.opacity(0.14))
                                )
                        }
                    }

                    if let modelYear = snapshot.modelYear, !modelYear.isEmpty, modelYear != "Unknown" {
                        Text(modelYear)
                            .font(.system(size: scaledBodyFontSize, weight: .semibold))
                            .foregroundColor(.white.opacity(0.86))
                    }

                    Text(snapshot.osText)
                        .font(.system(size: scaledLabelFontSize + 1, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let supportingText = snapshot.supportingText, !supportingText.isEmpty {
                        Text(supportingText)
                            .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func storageSummaryHero(_ snapshot: HardwareGraphFocusStorageHeroSnapshot) -> some View {
        insetPanelCard(
            fill: activeAccentColor.opacity(0.06),
            stroke: activeAccentColor.opacity(0.14)
        ) {
            VStack(alignment: .leading, spacing: 12 * appUIScale) {
                HStack(alignment: .center, spacing: 10 * appUIScale) {
                    Text(snapshot.title)
                        .font(.system(size: scaledBodyFontSize, weight: .semibold))
                        .foregroundColor(.white.opacity(0.94))

                    Spacer(minLength: 0)

                    Text(String(format: "%.0f%% used", min(max(snapshot.usedRatio, 0), 1) * 100))
                        .font(.system(size: scaledLabelFontSize + 1, weight: .semibold))
                        .foregroundColor(activeAccentColor.opacity(0.95))
                }

                if let subtitle = snapshot.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                        .foregroundColor(.secondary)
                }

                GeometryReader { geometry in
                    let width = geometry.size.width
                    let fillWidth = width * CGFloat(min(max(snapshot.usedRatio, 0), 1))
                    let storageGradient = LinearGradient(
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

                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))

                        Rectangle()
                            .fill(storageGradient)
                            .frame(width: width)
                            .mask(
                                HStack(spacing: 0) {
                                    Rectangle()
                                        .frame(width: fillWidth)
                                    Spacer(minLength: 0)
                                }
                            )
                    }
                }
                .frame(height: 18 * appUIScale)

                Text(snapshot.usedText)
                    .font(.system(size: scaledBodyFontSize, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))

                if let detailText = snapshot.detailText, !detailText.isEmpty {
                    Text(detailText)
                        .font(.system(size: scaledLabelFontSize + 0.5, weight: .regular))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func summaryTileCard(_ tile: HardwareGraphFocusSummaryTile) -> some View {
        let tint = tile.tint ?? activeAccentColor
        let isInteractive = tile.actionID != nil && focus.detailActionHandler != nil

        return ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
            .fill(tint.opacity(0.08))
            .overlay(
                ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
                    .stroke(tint.opacity(isInteractive ? 0.24 : 0.16), lineWidth: 1)
            )
            .overlay(
                VStack(alignment: .leading, spacing: 6 * appUIScale) {
                    Text(tile.title.uppercased())
                        .font(.system(size: scaledLabelFontSize - 1, weight: .semibold))
                        .foregroundColor(.secondary)

                    Text(tile.value)
                        .font(.system(size: 16 * appUIScale, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)

                    if let detail = tile.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: scaledLabelFontSize + 0.25, weight: .regular))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12 * appUIScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            )
            .frame(minHeight: 88 * appUIScale)
            .contentShape(ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous))
            .help(isInteractive ? "Double-click to open this media class in Finder." : "")
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    guard let actionID = tile.actionID else { return }
                    focus.detailActionHandler?(actionID)
                }
            )
    }

    private func focusPanelCard<Content: View>(
        padding: CGFloat? = nil,
        minHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let resolvedPadding = padding ?? (18 * appUIScale)
        return VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(resolvedPadding)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(
            ThemeRoundedRectangle(cornerRadius: 18 * appUIScale, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            ThemeRoundedRectangle(cornerRadius: 18 * appUIScale, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(ThemeRoundedRectangle(cornerRadius: 18 * appUIScale, style: .continuous))
    }

    private func insetPanelCard<Content: View>(
        fill: Color,
        stroke: Color,
        padding: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let resolvedPadding = padding ?? (12 * appUIScale)
        return VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(resolvedPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
                .fill(fill)
        )
        .overlay(
            ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
                .stroke(stroke, lineWidth: 1)
        )
        .clipShape(ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous))
    }

    private func legend(for series: [HardwareGraphFocusSeries]) -> some View {
        HStack(spacing: 10 * appUIScale) {
            ForEach(series) { item in
                HStack(spacing: 4 * appUIScale) {
                    Circle()
                        .fill(item.color)
                        .frame(width: 7 * appUIScale, height: 7 * appUIScale)

                    Text(item.label)
                        .font(.system(size: scaledLabelFontSize, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var interactiveHeatmapVisualization: some View {
        VStack(alignment: .leading, spacing: 12 * appUIScale) {
            HStack(alignment: .center, spacing: 8 * appUIScale) {
                Text("Heatmap")
                    .font(.system(size: scaledBodyFontSize, weight: .semibold))

                if let target = resolvedPrimaryHeatmapTarget {
                    Text(heatmapTitle(for: target))
                        .font(.system(size: scaledLabelFontSize, weight: .semibold))
                        .foregroundColor(activeAccentColor.opacity(0.95))
                        .padding(.horizontal, 8 * appUIScale)
                        .padding(.vertical, 4 * appUIScale)
                        .background(
                            Capsule(style: .continuous)
                                .fill(activeAccentColor.opacity(0.12))
                        )
                }

                Spacer(minLength: 0)
            }

            if focus.selectableHeatmapTargets.count > 1 {
                interactiveHeatmapMetricPicker
            }

            if isLoadingPrimaryHeatmap && resolvedPrimaryHeatmapSnapshot == nil {
                ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
                    .fill(Color.white.opacity(0.03))
                    .overlay(
                        ProgressView()
                            .controlSize(.small)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot = resolvedPrimaryHeatmapSnapshot {
                HardwareGraphFocusHeatmapView(
                    snapshot: snapshot,
                    selectedSlotStart: selectedPrimaryHeatmapSlotStart,
                    selectionAccent: activeAccentColor,
                    onSelectCell: { cell in
                        if let slotStart = cell.slotStart {
                            selectedPrimaryHeatmapSlotStart = slotStart
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack {
                    Text(snapshot.startLabel)
                    Spacer()
                    Text(snapshot.endLabel)
                }
                .font(.system(size: scaledLabelFontSize))
                .foregroundColor(.secondary)
            } else {
                primaryVisualizationEmptyState(
                    title: "Activity Heatmap",
                    message: "The focused heatmap will appear once enough retained history is available."
                )
            }
        }
    }

    private var interactiveHeatmapMetricPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8 * appUIScale) {
                ForEach(focus.selectableHeatmapTargets, id: \.rawValue) { target in
                    let isSelected = target == resolvedPrimaryHeatmapTarget
                    Button {
                        selectedPrimaryHeatmapTarget = target
                    } label: {
                        Text(heatmapTitle(for: target))
                            .font(.system(size: scaledLabelFontSize, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? .white.opacity(0.95) : .secondary)
                            .padding(.horizontal, 10 * appUIScale)
                            .padding(.vertical, 6 * appUIScale)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(isSelected ? heatmapAccentColor(for: target).opacity(0.22) : Color.white.opacity(0.05))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(
                                        isSelected ? heatmapAccentColor(for: target).opacity(0.30) : Color.white.opacity(0.06),
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func shortLabel(for window: HardwareInsightWindow) -> String {
        switch window {
        case .daily:
            return "24h"
        case .weekly:
            return "7d"
        case .monthly:
            return "30d"
        @unknown default:
            return window.rawValue
        }
    }

    @MainActor
    private func loadInsightSnapshot() async {
        guard let insightTarget = effectiveInsightTarget,
              let insightsProvider else {
            isLoadingInsight = false
            insightSnapshot = nil
            return
        }

        let refreshToken = insightsRefreshToken
        isLoadingInsight = true
        let snapshot = await insightsProvider.snapshot(
            for: insightTarget,
            window: selectedInsightWindow,
            gpuContext: focus.gpuContext
        )
        guard refreshToken == insightsRefreshToken else { return }
        insightSnapshot = snapshot
        isLoadingInsight = false
    }

    @MainActor
    private func loadPrimaryHeatmapSnapshot() async {
        guard usesInteractivePrimaryHeatmap,
              let target = resolvedPrimaryHeatmapTarget,
              let heatmapProvider else {
            isLoadingPrimaryHeatmap = false
            primaryHeatmapSnapshot = staticHeatmapSnapshot
            synchronizePrimaryHeatmapSelection(reset: true)
            return
        }

        let refreshToken = primaryHeatmapRefreshToken
        isLoadingPrimaryHeatmap = true
        let snapshot = await heatmapProvider.snapshot(
            for: target,
            gpuContext: focus.gpuContext,
            anchorDate: heatmapRefreshAnchor
        )
        guard refreshToken == primaryHeatmapRefreshToken else { return }
        primaryHeatmapSnapshot = snapshot
        isLoadingPrimaryHeatmap = false
        synchronizePrimaryHeatmapSelection(reset: false)
    }

    @MainActor
    private func loadActivityHeatmapSnapshot() async {
        guard shouldShowActivityHeatmap,
              let heatmapTarget = focus.heatmapTarget,
              let heatmapProvider else {
            isLoadingActivityHeatmap = false
            activityHeatmapSnapshot = nil
            return
        }

        let refreshToken = heatmapRefreshToken
        isLoadingActivityHeatmap = true
        let snapshot = await heatmapProvider.snapshot(
            for: heatmapTarget,
            gpuContext: focus.gpuContext,
            anchorDate: heatmapRefreshAnchor
        )
        guard refreshToken == heatmapRefreshToken else { return }
        activityHeatmapSnapshot = snapshot
        isLoadingActivityHeatmap = false
    }

    @MainActor
    private func loadPrimaryHeatmapDrillDownSnapshot() async {
        guard usesInteractivePrimaryHeatmap,
              let target = resolvedPrimaryHeatmapTarget,
              let slotStart = selectedPrimaryHeatmapSlotStart,
              let heatmapProvider else {
            isLoadingPrimaryHeatmapDrillDown = false
            primaryHeatmapDrillDownSnapshot = nil
            return
        }

        let refreshToken = primaryHeatmapDrillDownRefreshToken
        isLoadingPrimaryHeatmapDrillDown = true
        let snapshot = await heatmapProvider.drillDownSnapshot(
            for: target,
            slotStart: slotStart,
            gpuContext: focus.gpuContext,
            anchorDate: heatmapRefreshAnchor
        )
        guard refreshToken == primaryHeatmapDrillDownRefreshToken else { return }
        primaryHeatmapDrillDownSnapshot = snapshot
        isLoadingPrimaryHeatmapDrillDown = false
    }

    @MainActor
    private func loadAttributionSnapshot() async {
        guard let attributionTarget = focus.attributionTarget,
              let attributionProvider else {
            isLoadingAttribution = false
            attributionSnapshot = nil
            return
        }

        let refreshToken = attributionRefreshToken
        isLoadingAttribution = true
        let snapshot = attributionProvider.snapshot(for: attributionTarget, gpuContext: focus.gpuContext)
        guard refreshToken == attributionRefreshToken else { return }
        attributionSnapshot = snapshot
        isLoadingAttribution = false
    }

    @MainActor
    private func loadProcessHistorySnapshot() async {
        guard let processTarget = focus.processTarget,
              let processHistoryProvider else {
            isLoadingProcessHistory = false
            processHistorySnapshot = nil
            return
        }

        let refreshToken = processHistoryRefreshToken
        isLoadingProcessHistory = true
        let snapshot = await processHistoryProvider.snapshot(
            for: processTarget,
            window: selectedInsightWindow,
            anchorDate: processHistoryRefreshAnchor
        )
        guard refreshToken == processHistoryRefreshToken else { return }
        processHistorySnapshot = snapshot
        isLoadingProcessHistory = false
    }

    @MainActor
    private func loadEventTimelineSnapshot() async {
        guard let eventTimelineProvider else {
            isLoadingEventTimeline = false
            eventTimelineSnapshot = nil
            return
        }

        let refreshToken = eventTimelineRefreshToken
        isLoadingEventTimeline = true
        let snapshot = await eventTimelineProvider.snapshot(
            for: focus,
            window: selectedInsightWindow,
            anchorDate: eventTimelineRefreshAnchor
        )
        guard refreshToken == eventTimelineRefreshToken else { return }
        eventTimelineSnapshot = snapshot
        isLoadingEventTimeline = false
    }
}

private struct HardwareGraphFocusLineChart: View {
    @Environment(\.appUIScale) private var appUIScale
    let series: [HardwareGraphFocusSeries]

    private var pointCount: Int {
        series.map { $0.values.count }.max() ?? 0
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
                    .fill(Color.black.opacity(0.14))

                chartGrid(in: geometry.size)

                if pointCount > 1 {
                    if let primary = series.first, series.count == 1 {
                        areaPath(for: primary, in: geometry.size)
                            .fill(primary.color.opacity(0.12))
                    }

                    ForEach(series) { item in
                        linePath(for: item, in: geometry.size)
                            .stroke(item.color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
        .clipShape(ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous))
    }

    private func chartGrid(in size: CGSize) -> some View {
        Path { path in
            for level in [0.25, 0.5, 0.75] as [Double] {
                let y = size.height * CGFloat(1 - level)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(Color.white.opacity(0.07), lineWidth: 0.75)
    }

    private func linePath(for series: HardwareGraphFocusSeries, in size: CGSize) -> Path {
        Path { path in
            let count = max(series.values.count, 1)
            var penDown = false

            for (index, entry) in series.values.enumerated() {
                guard let value = entry else {
                    penDown = false
                    continue
                }

                let clamped = min(max(value, 0), 1)
                let x = size.width * CGFloat(index) / CGFloat(max(count - 1, 1))
                let y = size.height * CGFloat(1 - clamped)

                if penDown {
                    path.addLine(to: CGPoint(x: x, y: y))
                } else {
                    path.move(to: CGPoint(x: x, y: y))
                    penDown = true
                }
            }
        }
    }

    private func areaPath(for series: HardwareGraphFocusSeries, in size: CGSize) -> Path {
        Path { path in
            let count = max(series.values.count, 1)
            var firstPoint: CGPoint?
            var lastPoint: CGPoint?

            for (index, entry) in series.values.enumerated() {
                guard let value = entry else { continue }

                let clamped = min(max(value, 0), 1)
                let point = CGPoint(
                    x: size.width * CGFloat(index) / CGFloat(max(count - 1, 1)),
                    y: size.height * CGFloat(1 - clamped)
                )

                if firstPoint == nil {
                    firstPoint = point
                    path.move(to: CGPoint(x: point.x, y: size.height))
                    path.addLine(to: point)
                } else {
                    path.addLine(to: point)
                }
                lastPoint = point
            }

            guard let firstPoint, let lastPoint else { return }
            path.addLine(to: CGPoint(x: lastPoint.x, y: size.height))
            path.addLine(to: CGPoint(x: firstPoint.x, y: size.height))
            path.closeSubpath()
        }
    }
}

private struct HardwareGraphFocusScatterPlot: View {
    @Environment(\.appUIScale) private var appUIScale
    let snapshot: HardwareGraphFocusScatterSnapshot

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
                    .fill(Color.black.opacity(0.14))

                scatterGrid(in: geometry.size)

                ForEach(snapshot.points) { point in
                    let x = normalized(point.x, in: snapshot.xRange)
                    let y = normalized(point.y, in: snapshot.yRange)
                    let diameter = max(5 * appUIScale, (5 + point.emphasis * 5) * appUIScale)

                    Circle()
                        .fill(snapshot.accentColor.opacity(0.28 + point.emphasis * 0.6))
                        .frame(width: diameter, height: diameter)
                        .position(
                            x: geometry.size.width * CGFloat(x),
                            y: geometry.size.height * CGFloat(1 - y)
                        )
                }
            }
        }
        .clipShape(ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous))
    }

    private func scatterGrid(in size: CGSize) -> some View {
        Path { path in
            for level in [0.25, 0.5, 0.75] as [Double] {
                let y = size.height * CGFloat(1 - level)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))

                let x = size.width * CGFloat(level)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
        }
        .stroke(Color.white.opacity(0.06), lineWidth: 0.75)
    }

    private func normalized(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let span = max(range.upperBound - range.lowerBound, 0.0001)
        return min(max((value - range.lowerBound) / span, 0), 1)
    }
}

private struct HardwareGraphFocusHeatmapView: View {
    @Environment(\.appUIScale) private var appUIScale
    let snapshot: HardwareGraphFocusHeatmapSnapshot
    var selectedSlotStart: Date? = nil
    var selectionAccent: Color = .white
    var onSelectCell: ((HardwareGraphFocusHeatmapCell) -> Void)? = nil

    private var scaledLabelWidth: CGFloat { 26 * appUIScale }
    private var scaledFontSize: CGFloat { 10 * appUIScale }

    var body: some View {
        GeometryReader { geometry in
            let spacing = max(1 * appUIScale, min(2.4 * appUIScale, geometry.size.width / CGFloat(max(snapshot.columnCount, 1)) * 0.08))
            let availableWidth = max(0, geometry.size.width - scaledLabelWidth - spacing)
            let availableHeight = max(0, geometry.size.height)
            let cellWidth = max(2 * appUIScale, (availableWidth - CGFloat(max(snapshot.columnCount - 1, 0)) * spacing) / CGFloat(max(snapshot.columnCount, 1)))
            let cellHeight = max(2 * appUIScale, (availableHeight - CGFloat(max(snapshot.rowCount - 1, 0)) * spacing) / CGFloat(max(snapshot.rowCount, 1)))
            let cellCornerRadius = max(1, min(cellWidth, cellHeight) * 0.22)

            HStack(alignment: .top, spacing: spacing) {
                VStack(spacing: spacing) {
                    ForEach(0..<snapshot.rowCount, id: \.self) { row in
                        Text(row % 6 == 0 ? Self.hourLabel(row) : "")
                            .font(.system(size: scaledFontSize))
                            .foregroundColor(.secondary)
                            .frame(width: scaledLabelWidth, height: cellHeight, alignment: .trailing)
                    }
                }

                HStack(alignment: .top, spacing: spacing) {
                    ForEach(0..<snapshot.columnCount, id: \.self) { column in
                        VStack(spacing: spacing) {
                            ForEach(0..<snapshot.rowCount, id: \.self) { row in
                                let cell = snapshot.columns[column][row]
                                heatmapCell(
                                    cell,
                                    width: cellWidth,
                                    height: cellHeight,
                                    cornerRadius: cellCornerRadius
                                )
                            }
                        }
                    }
                }
            }
        }
        .clipShape(ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous))
        .background(
            ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous)
                .fill(Color.black.opacity(0.14))
        )
    }

    @ViewBuilder
    private func heatmapCell(
        _ cell: HardwareGraphFocusHeatmapCell,
        width: CGFloat,
        height: CGFloat,
        cornerRadius: CGFloat
    ) -> some View {
        let isSelected = cell.slotStart != nil && cell.slotStart == selectedSlotStart

        let baseCell = ThemeRoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(cell.color)
            .frame(width: width, height: height)
            .overlay(
                ThemeRoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(cell.intensity > 0.4 ? 0.06 : 0.0), lineWidth: 0.5)
            )
            .overlay(
                ThemeRoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(selectionAccent.opacity(isSelected ? 0.9 : 0.0), lineWidth: isSelected ? 1.4 : 0)
            )

        if let onSelectCell {
            Button {
                onSelectCell(cell)
            } label: {
                baseCell
            }
            .buttonStyle(.plain)
        } else {
            baseCell
        }
    }

    private static func hourLabel(_ hour: Int) -> String {
        let normalized = hour % 12 == 0 ? 12 : hour % 12
        return "\(normalized)\(hour < 12 ? "a" : "p")"
    }
}
