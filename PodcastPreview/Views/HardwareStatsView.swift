//
//  HardwareStatsView.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 17/12/2025.
//

import SwiftUI
import PodcastPreviewShared
import PodcastPreviewCore

// MARK: - HardwareStatsView

struct HardwareStatsView: View {
    private let hardwareMonitoringModel = HardwareMonitoringModel.shared

    init() {
        HardwareCollectionSettings.migrateLegacyGraphDisplayIntervalIfNeeded()
    }

    // Display interval affects density, while the time window also informs live-series retention.
    @AppStorage(HardwareCollectionSettings.graphWindowDefaultsKey)
    private var graphWindowSeconds: Int = HardwareCollectionSettings.defaultGraphWindowSeconds
    @AppStorage(HardwareCollectionSettings.graphDisplayIntervalDefaultsKey)
    private var graphDisplayIntervalSeconds: Int = HardwareCollectionSettings.defaultGraphDisplayIntervalSeconds
    @State private var showDebugConsoleSheet = false
    @State private var dashboardDemandToken: HardwareStatsDemandToken?
    @State private var focusedDemandToken: HardwareStatsDemandToken?

    // Graph visibility (persisted via AppStorage)
    @AppStorage("graphHidden_cpu") private var hiddenCPU = false
    @AppStorage("graphHidden_efficiencyCores") private var hiddenEfficiencyCores = false
    @AppStorage("graphHidden_performanceCores") private var hiddenPerformanceCores = false
    @AppStorage("graphHidden_gpuEmpty") private var hiddenGPUEmpty = false
    @State private var hiddenGPUs: [String: Bool] = [:]
    @State private var hiddenGPURenderer: [String: Bool] = [:]
    @State private var hiddenGPUTiler: [String: Bool] = [:]
    @AppStorage("graphHidden_ram") private var hiddenRAM = false
    @AppStorage("graphHidden_memoryPressure") private var hiddenMemoryPressure = false
    @AppStorage("graphHidden_swap") private var hiddenSwap = false
    @AppStorage("graphHidden_diskRead") private var hiddenDiskRead = false
    @AppStorage("graphHidden_diskWrite") private var hiddenDiskWrite = false
    @AppStorage("graphHidden_networkUpload") private var hiddenNetworkUpload = false
    @AppStorage("graphHidden_networkDownload") private var hiddenNetworkDownload = false
    @AppStorage("graphHidden_ane") private var hiddenANE = false
    @AppStorage("graphHidden_mediaEngine") private var hiddenMediaEngine = false
    @AppStorage("graphHidden_thermals") private var hiddenThermals = false
    @AppStorage("graphHidden_energy") private var hiddenEnergy = false
    @AppStorage("graphLayoutCompact") private var compactLayout = false
    @AppStorage("graphSidebarVisible") private var sidebarVisible = true
    @State private var focusedGraph: HardwareGraphFocusState?
    @State private var focusedInsights: HardwareInsightsFocusState?
    @Environment(\.appUIScale) private var appUIScale

    private var activeFocusID: String? {
        focusedGraph?.id ?? focusedInsights?.id
    }

    private var focusInsightsRefreshAnchor: Date {
        let timestamps =
            [
                hardwareMonitoringModel.cpuSampler.latestSnapshot?.timestamp,
                hardwareMonitoringModel.aneSampler.latestSnapshot?.timestamp,
                hardwareMonitoringModel.powerStatsSampler.latestSnapshot?.timestamp
            ].compactMap { $0 }
            + hardwareMonitoringModel.gpuSampler.latestDeviceSnapshots.map(\.timestamp)
        return timestamps.max() ?? processGloballyCachedLaunchDate
    }

    private var focusInsightsProvider: HardwareGraphFocusInsightProvider {
        HardwareGraphFocusInsightProvider(
            insightsService: hardwareMonitoringModel.insightsService,
            refreshAnchor: focusInsightsRefreshAnchor,
            hasNeuralEngine: hardwareMonitoringModel.aneSampler.hasNeuralEngine,
            primaryGPUID: hardwareMonitoringModel.gpuSampler.gpus.first?.id,
            gpuCount: hardwareMonitoringModel.gpuSampler.gpus.count,
            storageSnapshot: hardwareMonitoringModel.storageSampler.latestCapacitySnapshot,
            mediaActivitySummary: hardwareMonitoringModel.mediaEngineSampler.latestActivitySummary,
            topMemoryRows: hardwareMonitoringModel.otherAppsSampler.topRows.prefix(3).map { (name: $0.name, ramMB: $0.ramMB) },
            gpuActiveAppNames: hardwareMonitoringModel.gpuClientsSampler.activeApps.filter(\.isActive).map(\.name),
            uptimeSeconds: hardwareMonitoringModel.powerStatsSampler.latestSystemSnapshot?.uptimeSeconds,
            cumulativeEnergyWh: hardwareMonitoringModel.powerStatsSampler.cumulativeCombinedEnergyWh,
            appLaunchDate: hardwareMonitoringModel.powerStatsSampler.monitoringSessionStartDate ?? processGloballyCachedLaunchDate,
            sessionSummaryLabel: "Monitoring has been active",
            sessionContextNoun: "monitoring session",
            processCount: hardwareMonitoringModel.powerStatsSampler.processCount,
            perCoreFrequenciesHz: hardwareMonitoringModel.powerStatsSampler.perCoreFrequenciesHz,
            efficiencyCoreCount: hardwareMonitoringModel.cpuSampler.efficiencyCoreCount,
            performanceCoreCount: hardwareMonitoringModel.cpuSampler.performanceCoreCount
        )
    }

    private var focusHeatmapProvider: HardwareGraphFocusHeatmapProvider {
        HardwareGraphFocusHeatmapProvider(
            historyReader: hardwareMonitoringModel.historyReader,
            primaryGPUID: hardwareMonitoringModel.gpuSampler.gpus.first?.id
        )
    }

    private var focusAttributionProvider: HardwareGraphFocusAttributionProvider {
        HardwareGraphFocusAttributionProvider(
            topRowsProvider: { hardwareMonitoringModel.otherAppsSampler.topRows },
            gpuAppsProvider: { hardwareMonitoringModel.gpuClientsSampler.activeApps },
            gpuCount: hardwareMonitoringModel.gpuSampler.gpus.count
        )
    }

    private var focusProcessHistoryProvider: HardwareGraphFocusProcessHistoryProvider {
        HardwareGraphFocusProcessHistoryProvider(
            reader: hardwareMonitoringModel.processHistoryReader
        )
    }

    private var focusEventTimelineProvider: HardwareGraphFocusEventTimelineProvider {
        HardwareGraphFocusEventTimelineProvider(
            reader: hardwareMonitoringModel.eventReader
        )
    }

    var body: some View {
        let contentInset: CGFloat = 2 * appUIScale
        let contentTopPadding: CGFloat = 120 * appUIScale
        let contentBottomPadding: CGFloat = 25 * appUIScale
        let edgeFadeHeight: CGFloat = 80 * appUIScale
        let splitSpacing: CGFloat = 20 * appUIScale
        let sidebarCardWidth: CGFloat = 260 * appUIScale
        let sidebarColumnSpacing: CGFloat = 16 * appUIScale
        let sidebarInnerPadding: CGFloat = 16 * appUIScale
        let sidebarOuterPadding: CGFloat = 36 * appUIScale
        let minimumGraphPaneWidth: CGFloat = 420 * appUIScale
        let graphColumn = HardwareStatsGraphColumn(
            historyReader: hardwareMonitoringModel.historyReader,
            cpuSampler: hardwareMonitoringModel.cpuSampler,
            thermalSampler: hardwareMonitoringModel.thermalSampler,
            gpuSampler: hardwareMonitoringModel.gpuSampler,
            gpuIdentityProber: hardwareMonitoringModel.gpuIdentityProber,
            ramSampler: hardwareMonitoringModel.ramSampler,
            memoryIdentityProber: hardwareMonitoringModel.memoryIdentityProber,
            aneSampler: hardwareMonitoringModel.aneSampler,
            diskIOSampler: hardwareMonitoringModel.diskIOSampler,
            networkSampler: hardwareMonitoringModel.networkSampler,
            networkInterfaceSampler: hardwareMonitoringModel.networkInterfaceSampler,
            mediaEngineSampler: hardwareMonitoringModel.mediaEngineSampler,
            powerSampler: hardwareMonitoringModel.powerStatsSampler,
            graphWindowSeconds: $graphWindowSeconds,
            graphDisplayIntervalSeconds: $graphDisplayIntervalSeconds,
            compactLayout: $compactLayout,
            sidebarVisible: $sidebarVisible,
            hiddenCPU: $hiddenCPU,
            hiddenEfficiencyCores: $hiddenEfficiencyCores,
            hiddenPerformanceCores: $hiddenPerformanceCores,
            hiddenGPUEmpty: $hiddenGPUEmpty,
            hiddenGPUs: $hiddenGPUs,
            hiddenGPURenderer: $hiddenGPURenderer,
            hiddenGPUTiler: $hiddenGPUTiler,
            hiddenRAM: $hiddenRAM,
            hiddenMemoryPressure: $hiddenMemoryPressure,
            hiddenSwap: $hiddenSwap,
            hiddenDiskRead: $hiddenDiskRead,
            hiddenDiskWrite: $hiddenDiskWrite,
            hiddenNetworkUpload: $hiddenNetworkUpload,
            hiddenNetworkDownload: $hiddenNetworkDownload,
            hiddenANE: $hiddenANE,
            hiddenMediaEngine: $hiddenMediaEngine,
            hiddenThermals: $hiddenThermals,
            hiddenEnergy: $hiddenEnergy,
            floatingSource: .local,
            onFocusGraph: { focus in
                withAnimation(.easeInOut(duration: 0.2)) {
                    focusedInsights = nil
                    focusedGraph = focus
                }
            },
            activeFocusID: activeFocusID,
            onFocusedGraphChange: { updatedFocus in
                guard focusedGraph?.id == updatedFocus.id else { return }
                guard focusedGraph?.signatureHash != updatedFocus.signatureHash else { return }
                focusedGraph = updatedFocus
            }
        )
        ZStack {
            GeometryReader { geometry in
                let compactSidebarContentWidth = (sidebarCardWidth * 2) + sidebarColumnSpacing
                let sidebarHorizontalPadding = (contentInset * 2) + sidebarInnerPadding + sidebarOuterPadding
                // Keep the sidebar in a single column unless the graph pane still has enough room
                // to stay legible beside the split.
                let sidebarUsesCompactLayout =
                    compactLayout
                    && geometry.size.width - compactSidebarContentWidth - sidebarHorizontalPadding - splitSpacing >= minimumGraphPaneWidth
                let sidebarContentWidth = sidebarUsesCompactLayout ? compactSidebarContentWidth : sidebarCardWidth
                let sidebarPaneWidth = sidebarVisible ? sidebarContentWidth + sidebarHorizontalPadding : 0
                let graphPaneWidth = max(
                    geometry.size.width - (sidebarVisible ? sidebarPaneWidth + splitSpacing : 0),
                    1
                )
                let graphContentWidth = max(graphPaneWidth - (contentInset * 2), 1)
                let sidebarColumn = HardwareStatsSidebar(
                    insightsService: hardwareMonitoringModel.insightsService,
                    cpuSampler: hardwareMonitoringModel.cpuSampler,
                    gpuSampler: hardwareMonitoringModel.gpuSampler,
                    gpuIdentityProber: hardwareMonitoringModel.gpuIdentityProber,
                    memoryIdentityProber: hardwareMonitoringModel.memoryIdentityProber,
                    ramSampler: hardwareMonitoringModel.ramSampler,
                    storageSampler: hardwareMonitoringModel.storageSampler,
                    aneSampler: hardwareMonitoringModel.aneSampler,
                    appSampler: hardwareMonitoringModel.appSampler,
                    otherAppsSampler: hardwareMonitoringModel.otherAppsSampler,
                    gpuClientsSampler: hardwareMonitoringModel.gpuClientsSampler,
                    mediaEngineSampler: hardwareMonitoringModel.mediaEngineSampler,
                    powerSampler: hardwareMonitoringModel.powerStatsSampler,
                    networkSampler: hardwareMonitoringModel.networkSampler,
                    networkInterfaceSampler: hardwareMonitoringModel.networkInterfaceSampler,
                    showDebugConsoleSheet: $showDebugConsoleSheet,
                    appLaunchDate: hardwareMonitoringModel.powerStatsSampler.monitoringSessionStartDate ?? processGloballyCachedLaunchDate,
                    compactLayout: sidebarUsesCompactLayout,
                    sessionStartDate: hardwareMonitoringModel.powerStatsSampler.monitoringSessionStartDate,
                    sessionStatusLabel: "Monitoring",
                    sessionSummaryLabel: "Monitoring has been active",
                    floatingSource: .local,
                    onFocusInsights: { focus in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            focusedGraph = nil
                            focusedInsights = focus
                        }
                    },
                    onFocusGraphCard: { focus in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            focusedInsights = nil
                            focusedGraph = focus
                        }
                    },
                    activeFocusID: activeFocusID,
                    onFocusedInsightsChange: { updatedFocus in
                        guard focusedInsights?.id == updatedFocus.id else { return }
                        guard focusedInsights?.signatureHash != updatedFocus.signatureHash else { return }
                        focusedInsights = updatedFocus
                    },
                    onFocusedGraphCardChange: { updatedFocus in
                        guard focusedGraph?.id == updatedFocus.id else { return }
                        guard focusedGraph?.signatureHash != updatedFocus.signatureHash else { return }
                        focusedGraph = updatedFocus
                    }
                )

                if sidebarVisible {
                    HStack(spacing: 0) {
                        GraphiteSidebarBackground()
                            .frame(width: sidebarPaneWidth)
                            .graphiteSidebarSeparator(edge: .trailing)
                        Spacer(minLength: 0)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }

                ScrollView {
                    HStack(alignment: .top, spacing: splitSpacing) {
                        if sidebarVisible {
                            sidebarColumn
                                .frame(width: sidebarContentWidth, alignment: .topLeading)
                                .padding(contentInset)
                                .padding(.top, contentTopPadding)
                                .padding(.bottom, contentBottomPadding)
                                .padding(.leading, sidebarOuterPadding)
                                .padding(.trailing, sidebarInnerPadding)
                                .frame(width: sidebarPaneWidth, alignment: .topLeading)
                                .clipped()
                        }

                        graphColumn
                            .frame(width: graphContentWidth, alignment: .leading)
                            .padding(contentInset)
                            .padding(.top, contentTopPadding)
                            .padding(.bottom, contentBottomPadding)
                            .frame(width: graphPaneWidth, alignment: .topLeading)
                            .clipped()
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .hideScrollIndicators()
                .ignoresSafeArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(focusedGraph == nil && focusedInsights == nil)
            }
            if #available(macOS 13.0, *) {
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.28),
                            Color.black.opacity(0.14),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 18)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                .ignoresSafeArea()
            }

            // Top fade-to-blur effect (content bleeds under tab bar)
            VStack(spacing: 0) {
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color.black.opacity(0.4), location: 0),
                        .init(color: Color.black.opacity(0.2), location: 0.6),
                        .init(color: .clear, location: 1)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: edgeFadeHeight)
                .blur(radius: 30)

                Spacer()

                // Bottom fade-to-blur effect
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: Color.black.opacity(0.2), location: 0.4),
                        .init(color: Color.black.opacity(0.4), location: 1)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: edgeFadeHeight)
                .blur(radius: 30)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()

            if let focusedGraph {
                HardwareGraphFocusView(
                    focus: focusedGraph,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.focusedGraph = nil
                        }
                    },
                    insightsProvider: focusInsightsProvider,
                    insightsRefreshAnchor: focusInsightsRefreshAnchor,
                    heatmapProvider: focusHeatmapProvider,
                    heatmapRefreshAnchor: focusInsightsRefreshAnchor,
                    attributionProvider: focusAttributionProvider,
                    attributionRefreshAnchor: focusInsightsRefreshAnchor,
                    processHistoryProvider: focusProcessHistoryProvider,
                    processHistoryRefreshAnchor: focusInsightsRefreshAnchor,
                    eventTimelineProvider: focusEventTimelineProvider,
                    eventTimelineRefreshAnchor: focusInsightsRefreshAnchor
                )
                .transition(.opacity)
            }

            if let focusedInsights {
                HardwareInsightsFocusView(
                    focus: focusedInsights,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.focusedInsights = nil
                        }
                    }
                )
                .transition(.opacity)
            }
        }
        .ignoresSafeArea(.all)
        .onAppear {
            beginDashboardDemandIfNeeded()
            updateFocusedDemand()
        }
        .onDisappear {
            focusedDemandToken?.invalidate()
            focusedDemandToken = nil
            dashboardDemandToken?.invalidate()
            dashboardDemandToken = nil
        }
        .onChange(of: activeFocusID) { _ in
            updateFocusedDemand()
        }
#if DEBUG
        .sheet(isPresented: $showDebugConsoleSheet) {
            AppDebugConsoleView()
        }
#endif
    }

    private func beginDashboardDemandIfNeeded() {
        guard dashboardDemandToken == nil else { return }
        dashboardDemandToken = hardwareMonitoringModel.beginHardwareStatsDemand(.dashboard)
    }

    private func updateFocusedDemand() {
        if activeFocusID != nil {
            guard focusedDemandToken == nil else { return }
            focusedDemandToken = hardwareMonitoringModel.beginHardwareStatsDemand(.focusedHighResolution)
        } else {
            focusedDemandToken?.invalidate()
            focusedDemandToken = nil
        }
    }
}

private let processGloballyCachedLaunchDate = Date()

#Preview {
    HardwareStatsView()
}
