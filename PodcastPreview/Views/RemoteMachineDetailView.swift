//
//  RemoteMachineDetailView.swift
//  PodcastPreview
//
//  Shows a full hardware stats dashboard for a single remote Mac,
//  reusing the same HardwareStatsGraphColumn and HardwareStatsSidebar
//  as the local hardware view.
//

import SwiftUI
import PodcastPreviewCore
import PodcastPreviewShared

struct RemoteMachineDetailView: View {
    @ObservedObject var connection: RemoteMachineConnection
    @Environment(\.appUIScale) private var appUIScale
    private let topHeadroom: CGFloat = 70
    let onBack: () -> Void

    @ObservedObject private var bridge: RemoteMachineHardwareBridge

    // Graph settings (per-remote, not persisted — resets on close)
    @State private var graphWindowSeconds: Int = 120
    @State private var graphDisplayIntervalSeconds: Int = HardwareCollectionSettings.defaultGraphDisplayIntervalSeconds
    @State private var compactLayout = false
    @AppStorage("graphSidebarVisible") private var sidebarVisible = true
    @State private var hiddenCPU = false
    @State private var hiddenEfficiencyCores = false
    @State private var hiddenPerformanceCores = false
    @State private var hiddenGPUEmpty = false
    @State private var hiddenGPUs: [String: Bool] = [:]
    @State private var hiddenGPURenderer: [String: Bool] = [:]
    @State private var hiddenGPUTiler: [String: Bool] = [:]
    @State private var hiddenRAM = false
    @State private var hiddenMemoryPressure = false
    @State private var hiddenSwap = false
    @State private var hiddenDiskRead = false
    @State private var hiddenDiskWrite = false
    @State private var hiddenNetworkUpload = false
    @State private var hiddenNetworkDownload = false
    @State private var hiddenANE = false
    @State private var hiddenMediaEngine = false
    @State private var hiddenThermals = false
    @State private var hiddenEnergy = false
    @State private var focusedGraph: HardwareGraphFocusState?
    @State private var focusedInsights: HardwareInsightsFocusState?

    private var activeFocusID: String? {
        focusedGraph?.id ?? focusedInsights?.id
    }

    private var focusInsightsRefreshAnchor: Date {
        let timestamps =
            [
                bridge.cpuSampler.latestSnapshot?.timestamp,
                bridge.aneSampler.latestSnapshot?.timestamp,
                bridge.powerStatsSampler.latestSnapshot?.timestamp
            ].compactMap { $0 }
            + bridge.gpuSampler.latestDeviceSnapshots.map(\.timestamp)
        return timestamps.max() ?? (connection.sessionStartDate ?? Date())
    }

    private var focusInsightsProvider: HardwareGraphFocusInsightProvider {
        HardwareGraphFocusInsightProvider(
            insightsService: bridge.insightsService,
            refreshAnchor: focusInsightsRefreshAnchor,
            hasNeuralEngine: bridge.aneSampler.hasNeuralEngine,
            primaryGPUID: bridge.gpuSampler.gpus.first?.id,
            gpuCount: bridge.gpuSampler.gpus.count,
            storageSnapshot: bridge.storageSampler.latestCapacitySnapshot,
            mediaActivitySummary: bridge.mediaEngineSampler.latestActivitySummary,
            topMemoryRows: bridge.otherAppsSampler.topRows.prefix(3).map { (name: $0.name, ramMB: $0.ramMB) },
            gpuActiveAppNames: bridge.gpuClientsSampler.activeApps.filter(\.isActive).map(\.name),
            uptimeSeconds: bridge.powerStatsSampler.latestSystemSnapshot?.uptimeSeconds,
            cumulativeEnergyWh: bridge.powerStatsSampler.cumulativeCombinedEnergyWh,
            appLaunchDate: connection.sessionStartDate ?? Date(),
            sessionSummaryLabel: "Connection has been active",
            sessionContextNoun: "connection session",
            processCount: bridge.powerStatsSampler.processCount,
            perCoreFrequenciesHz: bridge.powerStatsSampler.perCoreFrequenciesHz,
            efficiencyCoreCount: bridge.cpuSampler.efficiencyCoreCount,
            performanceCoreCount: bridge.cpuSampler.performanceCoreCount
        )
    }

    private var focusHeatmapProvider: HardwareGraphFocusHeatmapProvider {
        HardwareGraphFocusHeatmapProvider(
            historyReader: bridge.historyReader,
            primaryGPUID: bridge.gpuSampler.gpus.first?.id
        )
    }

    private var focusAttributionProvider: HardwareGraphFocusAttributionProvider {
        HardwareGraphFocusAttributionProvider(
            topRowsProvider: { bridge.otherAppsSampler.topRows },
            gpuAppsProvider: { bridge.gpuClientsSampler.activeApps },
            gpuCount: bridge.gpuSampler.gpus.count
        )
    }

    init(connection: RemoteMachineConnection, onBack: @escaping () -> Void) {
        self.connection = connection
        self.onBack = onBack
        self._bridge = ObservedObject(wrappedValue: RemoteMachineBridgeStore.shared.bridge(for: connection))
    }

    var body: some View {
        let contentInset: CGFloat = 2 * appUIScale
        let contentTopPadding: CGFloat = topHeadroom
        let contentBottomPadding: CGFloat = 25 * appUIScale
        let splitSpacing: CGFloat = 20 * appUIScale
        let sidebarCardWidth: CGFloat = 260 * appUIScale
        let sidebarColumnSpacing: CGFloat = 16 * appUIScale
        let sidebarInnerPadding: CGFloat = 16 * appUIScale
        let sidebarOuterPadding: CGFloat = 36 * appUIScale
        let sidebarContentWidth: CGFloat = compactLayout ? (sidebarCardWidth * 2) + sidebarColumnSpacing : sidebarCardWidth
        let sidebarPaneWidth: CGFloat = sidebarVisible ? sidebarContentWidth + (contentInset * 2) + sidebarInnerPadding + sidebarOuterPadding : 0

        VStack(spacing: 0) {
            // Navigation header
            machineHeader

            // Full hardware stats
            ZStack {
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
                            HardwareStatsSidebar(
                                insightsService: bridge.insightsService,
                                cpuSampler: bridge.cpuSampler,
                                gpuSampler: bridge.gpuSampler,
                                gpuIdentityProber: bridge.gpuIdentityProber,
                                memoryIdentityProber: bridge.memoryIdentityProber,
                                ramSampler: bridge.ramSampler,
                                storageSampler: bridge.storageSampler,
                                aneSampler: bridge.aneSampler,
                                appSampler: bridge.appSampler,
                                otherAppsSampler: bridge.otherAppsSampler,
                                gpuClientsSampler: bridge.gpuClientsSampler,
                                mediaEngineSampler: bridge.mediaEngineSampler,
                                powerSampler: bridge.powerStatsSampler,
                                networkSampler: bridge.networkSampler,
                                networkInterfaceSampler: bridge.networkInterfaceSampler,
                                showDebugConsoleSheet: .constant(false),
                                appLaunchDate: connection.sessionStartDate ?? Date(),
                                compactLayout: compactLayout,
                                machineIdentity: connection.identity,
                                sessionStartDate: connection.sessionStartDate,
                                sessionStatusLabel: "Connected",
                                sessionSummaryLabel: "Connection has been active",
                                sessionContextNoun: "connection session",
                                floatingSource: .remote(connection),
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
                            .frame(width: sidebarContentWidth, alignment: .topLeading)
                            .padding(contentInset)
                            .padding(.top, contentTopPadding)
                            .padding(.bottom, contentBottomPadding)
                            .padding(.leading, sidebarOuterPadding)
                            .padding(.trailing, sidebarInnerPadding)
                            .frame(width: sidebarPaneWidth, alignment: .topLeading)
                            .clipped()
                        }

                        HardwareStatsGraphColumn(
                            historyReader: bridge.historyReader,
                            cpuSampler: bridge.cpuSampler,
                            thermalSampler: bridge.thermalSampler,
                            gpuSampler: bridge.gpuSampler,
                            gpuIdentityProber: bridge.gpuIdentityProber,
                            ramSampler: bridge.ramSampler,
                            memoryIdentityProber: bridge.memoryIdentityProber,
                            aneSampler: bridge.aneSampler,
                            diskIOSampler: bridge.diskIOSampler,
                            networkSampler: bridge.networkSampler,
                            networkInterfaceSampler: bridge.networkInterfaceSampler,
                            mediaEngineSampler: bridge.mediaEngineSampler,
                            powerSampler: bridge.powerStatsSampler,
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
                            floatingSource: .remote(connection),
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(contentInset)
                        .padding(.top, contentTopPadding)
                        .padding(.bottom, contentBottomPadding)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .allowsHitTesting(focusedGraph == nil && focusedInsights == nil)

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
                        attributionRefreshAnchor: focusInsightsRefreshAnchor
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
        }
    }

    // MARK: - Machine Header

    private var machineHeader: some View {
        HStack(spacing: 12 * appUIScale) {
            Button(action: onBack) {
                HStack(spacing: 4 * appUIScale) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12 * appUIScale, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 13 * appUIScale, weight: .medium))
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)

            Divider()
                .frame(height: 20 * appUIScale)

            Image(systemName: machineIconName)
                .font(.system(size: 18 * appUIScale))
                .foregroundColor(.white.opacity(0.6))

            VStack(alignment: .leading, spacing: 1) {
                Text(connection.identity?.displayName ?? connection.machineName)
                    .font(.system(size: 15 * appUIScale, weight: .semibold))
                    .foregroundColor(.white)

                if let identity = connection.identity {
                    Text([
                        identity.chipType,
                        RemoteSystemDisplayFormatter.macOSDisplayString(from: identity.macOSVersion) ?? identity.macOSVersion
                    ].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11 * appUIScale))
                        .foregroundColor(.white.opacity(0.45))
                }
            }

            Spacer()

            // Connection status
            HStack(spacing: 6 * appUIScale) {
                Circle()
                    .fill(connection.state == .connected ? Color.green : Color.orange)
                    .frame(width: 7 * appUIScale, height: 7 * appUIScale)

                Text(connectionLabel)
                    .font(.system(size: 11 * appUIScale))
                    .foregroundColor(.white.opacity(0.5))
            }

            Button(action: {
                RemoteHardwareManager.shared.disconnect(machineID: connection.id)
                onBack()
            }) {
                Text("Disconnect")
                    .font(.system(size: 12 * appUIScale, weight: .medium))
                    .foregroundColor(.red.opacity(0.8))
                    .padding(.horizontal, 10 * appUIScale)
                    .padding(.vertical, 5 * appUIScale)
                    .background(
                        ThemeRoundedRectangle(cornerRadius: 6 * appUIScale, style: .continuous).themed(fill: Color.red.opacity(0.1), stroke: Color.clear)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16 * appUIScale)
        .padding(.vertical, 10 * appUIScale)
        .background(Color.white.opacity(0.03))
    }

    private var machineIconName: String {
        guard let model = connection.identity?.modelIdentifier else { return "desktopcomputer" }
        if model.contains("MacBook") { return "laptopcomputer" }
        if model.contains("MacPro") { return "macpro.gen3" }
        if model.contains("iMac") { return "desktopcomputer" }
        if model.contains("Macmini") || model.contains("Mac14") { return "macmini" }
        return "desktopcomputer"
    }

    private var connectionLabel: String {
        switch connection.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .authenticating: return "Authenticating..."
        case .awaitingApproval: return "Waiting for approval..."
        case .failed(let reason): return "Failed: \(reason)"
        case .disconnected: return "Disconnected"
        }
    }
}
