import SwiftUI
import PodcastPreviewShared
import PodcastPreviewCore

struct HardwareStatsSidebar: View {
    let insightsService: HardwareInsightsService
    @ObservedObject var cpuSampler: CPUStatsSampler
    @ObservedObject var gpuSampler: GPUStatsSampler
    @ObservedObject var gpuIdentityProber: GPUIdentityProber
    @ObservedObject var memoryIdentityProber: MemoryIdentityProber
    @ObservedObject var ramSampler: RAMStatsSampler
    @ObservedObject var storageSampler: StorageStatsSampler
    @ObservedObject var aneSampler: ANEStatsSampler
    @ObservedObject var appSampler: AppStatsSampler
    @ObservedObject var otherAppsSampler: OtherAppsSampler
    @ObservedObject var gpuClientsSampler: GPUClientsSampler
    @ObservedObject var mediaEngineSampler: MediaEngineStatsSampler
    @ObservedObject var powerSampler: PowerStatsSampler
    @ObservedObject var networkSampler: NetworkStatsSampler
    @ObservedObject var networkInterfaceSampler: NetworkInterfaceSampler
    @Binding var showDebugConsoleSheet: Bool
    let appLaunchDate: Date
    var compactLayout: Bool = false
    var machineIdentity: RemoteMachineIdentity? = nil
    var sessionStartDate: Date? = nil
    var sessionStatusLabel: String = "App launched"
    var sessionSummaryLabel: String = "App has been monitoring"
    var sessionContextNoun: String = "monitoring session"
    var floatingSource: FloatingMonitorCardSource? = nil
    var onFocusInsights: ((HardwareInsightsFocusState) -> Void)? = nil
    var onFocusGraphCard: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedInsightsChange: ((HardwareInsightsFocusState) -> Void)? = nil
    var onFocusedGraphCardChange: ((HardwareGraphFocusState) -> Void)? = nil

    @ObservedObject private var remoteHardwareManager = RemoteHardwareManager.shared
    @Environment(\.appUIScale) private var appUIScale

    private var sidebarWidth: CGFloat { 260 * appUIScale }
    private var columnSpacing: CGFloat { 16 * appUIScale }

    private var sessionAnchorDate: Date { sessionStartDate ?? appLaunchDate }
    private var powerMonitoringAnchorDate: Date {
        powerSampler.monitoringSessionStartDate ?? sessionAnchorDate
    }
    private var shouldShowSupportProcessesCard: Bool { machineIdentity == nil }
    private var insightsRefreshAnchor: Date {
        let timestamps =
            [
                cpuSampler.latestSnapshot?.timestamp,
                aneSampler.latestSnapshot?.timestamp,
                powerSampler.latestSnapshot?.timestamp
            ].compactMap { $0 }
            + gpuSampler.latestDeviceSnapshots.map(\.timestamp)
        return timestamps.max() ?? appLaunchDate
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

    var body: some View {
        Group {
            if compactLayout {
                compactBody
            } else {
                singleColumnBody
            }
        }
    }

    // MARK: - Single-column layout (normal mode)

    private var singleColumnBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            singleColumnCards
        }
    }

    @ViewBuilder
    private var singleColumnCards: some View {
        ObservedSubtree4(
            object1: cpuSampler,
            object2: gpuSampler,
            object3: ramSampler,
            object4: storageSampler
        ) {
            SystemSpecsCard(
                machineIdentity: machineIdentity,
                cpuDisplayName: cpuSampler.cpuDisplayName,
                gpuDisplayNames: gpuSampler.gpus.map(\.name),
                totalMemoryBytes: ramSampler.latestMemorySnapshot?.totalBytes,
                storageSnapshot: storageSampler.latestCapacitySnapshot,
                onFocus: onFocusGraphCard,
                activeFocusID: activeFocusID,
                onFocusedStateChange: onFocusedGraphCardChange
            )
            .frame(width: sidebarWidth)
        }

        #if DEBUG
        debugButtons
        #endif

        ObservedSubtree(primary: powerSampler) {
            PowerMiniCard(
                systemSnapshot: powerSampler.latestSystemSnapshot,
                powerSnapshot: powerSampler.latestReadingsSnapshot,
                combinedPowerSeries: powerSampler.combinedPowerSeries,
                cumulativeEnergySeries: powerSampler.cumulativeEnergySeries,
                sessionStartDate: powerMonitoringAnchorDate,
                sessionLabel: sessionStatusLabel,
                hardwareAgentUptimeSeconds: powerSampler.hardwareAgentUptimeSeconds,
                onFocus: onFocusGraphCard,
                activeFocusID: activeFocusID,
                onFocusedStateChange: onFocusedGraphCardChange
            )
            .frame(width: sidebarWidth)
        }

        ObservedSubtree2(primary: cpuSampler, secondary: powerSampler) {
            floatingCardMenu(.cpuCores) {
                CPUCoresCard(
                    cpuDisplayName: cpuSampler.cpuDisplayName,
                    coreUsages: cpuSampler.coreUsages,
                    perCoreFrequenciesHz: powerSampler.perCoreFrequenciesHz,
                    perCoreUsageSeries: cpuSampler.perCoreUsageSeries,
                    perCoreFrequencySeries: powerSampler.perCoreFrequencySeries,
                    efficiencyCoreCount: cpuSampler.efficiencyCoreCount,
                    performanceCoreCount: cpuSampler.performanceCoreCount,
                    onFocus: onFocusGraphCard,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphCardChange
                )
                .frame(width: sidebarWidth)
            }
        }

        ObservedSubtree4(
            object1: gpuIdentityProber,
            object2: gpuSampler,
            object3: ramSampler,
            object4: cpuSampler
        ) {
            floatingCardMenu(.gpuUnit) {
                if !gpuSampler.gpus.isEmpty || !gpuIdentityProber.gpuUnits.isEmpty {
                    let firstGPU = gpuSampler.gpus.first
                    let resolvedGPUIdentity = firstGPU.map {
                        sharedResolvedGPUIdentity(
                            for: $0,
                            liveGPUs: gpuSampler.gpus,
                            metadataUnits: gpuIdentityProber.gpuUnits
                        )
                    }
                    let gpuTitle = resolvedGPUIdentity.map(sharedGPUDisplayTitle)
                    let gpuFocusContext = firstGPU.flatMap { gpu in
                        gpuTitle.map { title in
                            HardwareGraphFocusGPUContext(deviceID: gpu.id, modelName: title)
                        }
                    }
                    GPUUnitCard(
                        gpuUnits: gpuIdentityProber.gpuUnits,
                        gpuSampler: gpuSampler,
                        ramSnapshot: ramSampler.latestMemorySnapshot,
                        cpuDisplayName: cpuSampler.cpuDisplayName,
                        gpuUsage: firstGPU?.usage,
                        gpuHistory: firstGPU?.usageHistory ?? [],
                        gpuLabel: gpuTitle,
                        gpuCurrentText: firstGPU.map { gpu in
                            let lines = [
                                "Renderer: \(Int((gpu.rendererUsage ?? 0) * 100))%",
                                "Tiler: \(Int((gpu.tilerUsage ?? 0) * 100))%"
                            ]
                            return lines.joined(separator: "  ·  ")
                        },
                        gpuFocusContext: gpuFocusContext,
                        onFocus: onFocusGraphCard,
                        activeFocusID: activeFocusID,
                        onFocusedStateChange: onFocusedGraphCardChange
                    )
                    .frame(width: sidebarWidth)
                }
            }
        }

        ObservedSubtree2(primary: memoryIdentityProber, secondary: ramSampler) {
            floatingCardMenu(.memoryUnit) {
                if let memoryUnit = memoryIdentityProber.memoryUnit {
                    MemoryUnitCard(
                        memoryUnit: memoryUnit,
                        memorySnapshot: ramSampler.latestMemorySnapshot,
                        ramUsage: ramSampler.ramUsage,
                        ramHistory: ramSampler.usageHistory,
                        ramLabel: ramSampler.ramLabel,
                        onFocus: onFocusGraphCard,
                        activeFocusID: activeFocusID,
                        onFocusedStateChange: onFocusedGraphCardChange
                    )
                    .frame(width: sidebarWidth)
                }
            }
        }

        ObservedSubtree(primary: storageSampler) {
            StorageCard(
                snapshot: storageSampler.latestCapacitySnapshot,
                isRemote: machineIdentity != nil,
                onFocus: onFocusGraphCard,
                activeFocusID: activeFocusID,
                onFocusedStateChange: onFocusedGraphCardChange
            )
            .frame(width: sidebarWidth)
        }

        ObservedSubtree2(primary: networkSampler, secondary: networkInterfaceSampler) {
            floatingCardMenu(.networkStats) {
                NetworkStatsMiniCard(
                    networkInterfaceSampler: networkInterfaceSampler,
                    onFocus: onFocusGraphCard,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphCardChange
                )
                .frame(width: sidebarWidth)
            }
        }

        ObservedSubtree(primary: aneSampler) {
            if aneSampler.hasNeuralEngine {
                NeuralEngineCard(
                    statusSnapshot: aneSampler.latestStatusSnapshot,
                    activitySeries: aneSampler.activitySeries,
                    powerSeries: aneSampler.powerSeries,
                    onResetPeak: { aneSampler.resetPeak() },
                    onFocus: onFocusGraphCard,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphCardChange
                )
                .frame(width: sidebarWidth)
            }
        }

        ObservedSubtree(primary: mediaEngineSampler) {
            if mediaEngineSampler.shouldShowCard {
                MediaEngineCard(
                    capabilityState: mediaEngineSampler.latestCapabilityState,
                    activitySummary: mediaEngineSampler.latestActivitySummary,
                    activitySeries: mediaEngineSampler.activitySeries,
                    recentSessions: mediaEngineSampler.recentSessions,
                    onFocus: onFocusGraphCard,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphCardChange
                )
                .frame(width: sidebarWidth)
            }
        }

        ObservedSubtree(primary: appSampler) {
            AppUsageMiniCard(
                metrics: appSampler.latestMetrics,
                cpuSeries: appSampler.cpuSeries,
                gpuSeries: appSampler.gpuSeries,
                memorySeries: appSampler.memorySeries,
                readSeries: appSampler.readSeries,
                writeSeries: appSampler.writeSeries,
                onFocus: onFocusGraphCard,
                activeFocusID: activeFocusID,
                onFocusedStateChange: onFocusedGraphCardChange
            )
            .frame(width: sidebarWidth)
        }

        ObservedSubtree(primary: otherAppsSampler) {
            floatingCardMenu(.topApps) {
                TopAppsCard(
                    rows: otherAppsSampler.resourceRankedRows,
                    liveHistoryProvider: { identity in
                        otherAppsSampler.liveHistorySnapshot(for: identity)
                    },
                    onFocus: onFocusGraphCard,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphCardChange
                )
                .frame(width: sidebarWidth)
            }
        }

        ObservedSubtree(primary: storageSampler) {
            ObservedSubtree7(
                object1: cpuSampler,
                object2: gpuSampler,
                object3: aneSampler,
                object4: otherAppsSampler,
                object5: gpuClientsSampler,
                object6: powerSampler,
                object7: mediaEngineSampler
            ) {
                floatingCardMenu(.hardwareInsights) {
                    HardwareInsightsCard(
                        insightsService: insightsService,
                        refreshAnchor: insightsRefreshAnchor,
                        hasNeuralEngine: aneSampler.hasNeuralEngine,
                        primaryGPUID: gpuSampler.gpus.first?.id,
                        storageSnapshot: storageSampler.latestCapacitySnapshot,
                        mediaActivitySummary: mediaEngineSampler.latestActivitySummary,
                        topMemoryRows: otherAppsSampler.topRows.prefix(3).map { (name: $0.name, ramMB: $0.ramMB) },
                        gpuActiveAppNames: gpuClientsSampler.activeApps.filter(\.isActive).map(\.name),
                        uptimeSeconds: powerSampler.latestSystemSnapshot?.uptimeSeconds,
                        cumulativeEnergyWh: powerSampler.cumulativeCombinedEnergyWh,
                        appLaunchDate: sessionAnchorDate,
                        sessionSummaryLabel: sessionSummaryLabel,
                        sessionContextNoun: sessionContextNoun,
                        processCount: powerSampler.processCount,
                        perCoreFrequenciesHz: powerSampler.perCoreFrequenciesHz,
                        efficiencyCoreCount: cpuSampler.efficiencyCoreCount,
                        performanceCoreCount: cpuSampler.performanceCoreCount,
                        topAppRows: otherAppsSampler.topRows.map {
                            HardwareInsightsCard.TopAppInsightRow(name: $0.name, bundleIdentifier: $0.bundleIdentifier, uptimeSeconds: $0.uptimeSeconds, ramMB: $0.ramMB, cpuPercent: $0.cpuPercent, isGPUActive: $0.isGPUActive)
                        },
                        onFocus: onFocusInsights,
                        activeFocusID: activeFocusID,
                        onFocusedStateChange: onFocusedInsightsChange
                    )
                    .frame(width: sidebarWidth)
                }
            }
        }

        if machineIdentity == nil {
            floatingCardMenu(.stereoOutput) {
                SystemOutputMeterHost(
                    onFocus: onFocusGraphCard,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedGraphCardChange
                )
                .frame(width: sidebarWidth)
            }
        }

        if shouldShowSupportProcessesCard {
            SupportProcessesHost(
                cpuSampler: cpuSampler,
                gpuSampler: gpuSampler,
                aneSampler: aneSampler,
                powerSampler: powerSampler,
                onFocus: onFocusGraphCard,
                activeFocusID: activeFocusID,
                onFocusedStateChange: onFocusedGraphCardChange
            )
            .frame(width: sidebarWidth)
        }

        // Remote Mac cards
        if !remoteHardwareManager.connectedMachines.isEmpty {
            ForEach(remoteHardwareManager.connectedMachines) { connection in
                RemoteMachineTile(
                    connection: connection,
                    onSelect: {
                        remoteHardwareManager.selectedMachineID = connection.id
                    },
                    onDisconnect: {
                        remoteHardwareManager.disconnect(machineID: connection.id)
                    }
                )
                .frame(width: sidebarWidth)
            }
        }
    }
    // MARK: - Two-column layout (compact mode)

    private var compactBody: some View {
        HStack(alignment: .top, spacing: columnSpacing) {
            // Column 1: specs, device metrics, network, and engines
            VStack(alignment: .leading, spacing: 16) {
                ObservedSubtree4(
                    object1: cpuSampler,
                    object2: gpuSampler,
                    object3: ramSampler,
                    object4: storageSampler
                ) {
                    SystemSpecsCard(
                        machineIdentity: machineIdentity,
                        cpuDisplayName: cpuSampler.cpuDisplayName,
                        gpuDisplayNames: gpuSampler.gpus.map(\.name),
                        totalMemoryBytes: ramSampler.latestMemorySnapshot?.totalBytes,
                        storageSnapshot: storageSampler.latestCapacitySnapshot,
                        onFocus: onFocusGraphCard,
                        activeFocusID: activeFocusID,
                        onFocusedStateChange: onFocusedGraphCardChange
                    )
                    .frame(width: sidebarWidth)
                }

                #if DEBUG
                debugButtons
                #endif

                ObservedSubtree2(primary: cpuSampler, secondary: powerSampler) {
                    floatingCardMenu(.cpuCores) {
                        CPUCoresCard(
                            cpuDisplayName: cpuSampler.cpuDisplayName,
                            coreUsages: cpuSampler.coreUsages,
                            perCoreFrequenciesHz: powerSampler.perCoreFrequenciesHz,
                            perCoreUsageSeries: cpuSampler.perCoreUsageSeries,
                            perCoreFrequencySeries: powerSampler.perCoreFrequencySeries,
                            efficiencyCoreCount: cpuSampler.efficiencyCoreCount,
                            performanceCoreCount: cpuSampler.performanceCoreCount,
                            onFocus: onFocusGraphCard,
                            activeFocusID: activeFocusID,
                            onFocusedStateChange: onFocusedGraphCardChange
                        )
                        .frame(width: sidebarWidth)
                    }
                }

                ObservedSubtree4(
                    object1: gpuIdentityProber,
                    object2: gpuSampler,
                    object3: ramSampler,
                    object4: cpuSampler
                ) {
                    floatingCardMenu(.gpuUnit) {
                        if !gpuSampler.gpus.isEmpty || !gpuIdentityProber.gpuUnits.isEmpty {
                            let firstGPU = gpuSampler.gpus.first
                            let resolvedGPUIdentity = firstGPU.map {
                                sharedResolvedGPUIdentity(
                                    for: $0,
                                    liveGPUs: gpuSampler.gpus,
                                    metadataUnits: gpuIdentityProber.gpuUnits
                                )
                            }
                            let gpuTitle = resolvedGPUIdentity.map(sharedGPUDisplayTitle)
                            let gpuFocusContext = firstGPU.flatMap { gpu in
                                gpuTitle.map { title in
                                    HardwareGraphFocusGPUContext(deviceID: gpu.id, modelName: title)
                                }
                            }
                            GPUUnitCard(
                                gpuUnits: gpuIdentityProber.gpuUnits,
                                gpuSampler: gpuSampler,
                                ramSnapshot: ramSampler.latestMemorySnapshot,
                                cpuDisplayName: cpuSampler.cpuDisplayName,
                                gpuUsage: firstGPU?.usage,
                                gpuHistory: firstGPU?.usageHistory ?? [],
                                gpuLabel: gpuTitle,
                                gpuCurrentText: firstGPU.map { gpu in
                                    let lines = [
                                        "Renderer: \(Int((gpu.rendererUsage ?? 0) * 100))%",
                                        "Tiler: \(Int((gpu.tilerUsage ?? 0) * 100))%"
                                    ]
                                    return lines.joined(separator: "  ·  ")
                                },
                                gpuFocusContext: gpuFocusContext,
                                onFocus: onFocusGraphCard,
                                activeFocusID: activeFocusID,
                                onFocusedStateChange: onFocusedGraphCardChange
                            )
                            .frame(width: sidebarWidth)
                        }
                    }
                }

                ObservedSubtree2(primary: memoryIdentityProber, secondary: ramSampler) {
                    floatingCardMenu(.memoryUnit) {
                        if let memoryUnit = memoryIdentityProber.memoryUnit {
                            MemoryUnitCard(
                                memoryUnit: memoryUnit,
                                memorySnapshot: ramSampler.latestMemorySnapshot,
                                ramUsage: ramSampler.ramUsage,
                                ramHistory: ramSampler.usageHistory,
                                ramLabel: ramSampler.ramLabel,
                                onFocus: onFocusGraphCard,
                                activeFocusID: activeFocusID,
                                onFocusedStateChange: onFocusedGraphCardChange
                            )
                            .frame(width: sidebarWidth)
                        }
                    }
                }

                ObservedSubtree(primary: storageSampler) {
                    StorageCard(
                        snapshot: storageSampler.latestCapacitySnapshot,
                        isRemote: machineIdentity != nil,
                        onFocus: onFocusGraphCard,
                        activeFocusID: activeFocusID,
                        onFocusedStateChange: onFocusedGraphCardChange
                    )
                    .frame(width: sidebarWidth)
                }

                ObservedSubtree2(primary: networkSampler, secondary: networkInterfaceSampler) {
                    floatingCardMenu(.networkStats) {
                        NetworkStatsMiniCard(
                            networkInterfaceSampler: networkInterfaceSampler,
                            onFocus: onFocusGraphCard,
                            activeFocusID: activeFocusID,
                            onFocusedStateChange: onFocusedGraphCardChange
                        )
                        .frame(width: sidebarWidth)
                    }
                }

                ObservedSubtree(primary: aneSampler) {
                    if aneSampler.hasNeuralEngine {
                        NeuralEngineCard(
                            statusSnapshot: aneSampler.latestStatusSnapshot,
                            activitySeries: aneSampler.activitySeries,
                            powerSeries: aneSampler.powerSeries,
                            onResetPeak: { aneSampler.resetPeak() },
                            onFocus: onFocusGraphCard,
                            activeFocusID: activeFocusID,
                            onFocusedStateChange: onFocusedGraphCardChange
                        )
                        .frame(width: sidebarWidth)
                    }
                }

                ObservedSubtree(primary: mediaEngineSampler) {
                    if mediaEngineSampler.shouldShowCard {
                        MediaEngineCard(
                            capabilityState: mediaEngineSampler.latestCapabilityState,
                            activitySummary: mediaEngineSampler.latestActivitySummary,
                            activitySeries: mediaEngineSampler.activitySeries,
                            recentSessions: mediaEngineSampler.recentSessions,
                            onFocus: onFocusGraphCard,
                            activeFocusID: activeFocusID,
                            onFocusedStateChange: onFocusedGraphCardChange
                        )
                        .frame(width: sidebarWidth)
                    }
                }

                ObservedSubtree(primary: powerSampler) {
                    PowerMiniCard(
                        systemSnapshot: powerSampler.latestSystemSnapshot,
                        powerSnapshot: powerSampler.latestReadingsSnapshot,
                        combinedPowerSeries: powerSampler.combinedPowerSeries,
                        cumulativeEnergySeries: powerSampler.cumulativeEnergySeries,
                        sessionStartDate: powerMonitoringAnchorDate,
                        sessionLabel: sessionStatusLabel,
                        hardwareAgentUptimeSeconds: powerSampler.hardwareAgentUptimeSeconds,
                        onFocus: onFocusGraphCard,
                        activeFocusID: activeFocusID,
                        onFocusedStateChange: onFocusedGraphCardChange
                    )
                    .frame(width: sidebarWidth)
                }
            }

            // Column 2: app usage, insights, audio, helpers, and remote cards
            VStack(alignment: .leading, spacing: 16) {
                ObservedSubtree(primary: appSampler) {
                    AppUsageMiniCard(
                        metrics: appSampler.latestMetrics,
                        cpuSeries: appSampler.cpuSeries,
                        gpuSeries: appSampler.gpuSeries,
                        memorySeries: appSampler.memorySeries,
                        readSeries: appSampler.readSeries,
                        writeSeries: appSampler.writeSeries,
                        onFocus: onFocusGraphCard,
                        activeFocusID: activeFocusID,
                        onFocusedStateChange: onFocusedGraphCardChange
                    )
                    .frame(width: sidebarWidth)
                }

                ObservedSubtree(primary: otherAppsSampler) {
                    floatingCardMenu(.topApps) {
                        TopAppsCard(
                            rows: otherAppsSampler.resourceRankedRows,
                            liveHistoryProvider: { identity in
                                otherAppsSampler.liveHistorySnapshot(for: identity)
                            },
                            onFocus: onFocusGraphCard,
                            activeFocusID: activeFocusID,
                            onFocusedStateChange: onFocusedGraphCardChange
                        )
                        .frame(width: sidebarWidth)
                    }
                }

                ObservedSubtree(primary: storageSampler) {
                    ObservedSubtree7(
                        object1: cpuSampler,
                        object2: gpuSampler,
                        object3: aneSampler,
                        object4: otherAppsSampler,
                        object5: gpuClientsSampler,
                        object6: powerSampler,
                        object7: mediaEngineSampler
                    ) {
                        floatingCardMenu(.hardwareInsights) {
                            HardwareInsightsCard(
                                insightsService: insightsService,
                                refreshAnchor: insightsRefreshAnchor,
                                hasNeuralEngine: aneSampler.hasNeuralEngine,
                                primaryGPUID: gpuSampler.gpus.first?.id,
                                storageSnapshot: storageSampler.latestCapacitySnapshot,
                                mediaActivitySummary: mediaEngineSampler.latestActivitySummary,
                                topMemoryRows: otherAppsSampler.topRows.prefix(3).map { (name: $0.name, ramMB: $0.ramMB) },
                                gpuActiveAppNames: gpuClientsSampler.activeApps.filter(\.isActive).map(\.name),
                                uptimeSeconds: powerSampler.latestSystemSnapshot?.uptimeSeconds,
                                cumulativeEnergyWh: powerSampler.cumulativeCombinedEnergyWh,
                                appLaunchDate: sessionAnchorDate,
                                sessionSummaryLabel: sessionSummaryLabel,
                                sessionContextNoun: sessionContextNoun,
                                processCount: powerSampler.processCount,
                                perCoreFrequenciesHz: powerSampler.perCoreFrequenciesHz,
                                efficiencyCoreCount: cpuSampler.efficiencyCoreCount,
                                performanceCoreCount: cpuSampler.performanceCoreCount,
                                topAppRows: otherAppsSampler.topRows.map {
                                    HardwareInsightsCard.TopAppInsightRow(name: $0.name, bundleIdentifier: $0.bundleIdentifier, uptimeSeconds: $0.uptimeSeconds, ramMB: $0.ramMB, cpuPercent: $0.cpuPercent, isGPUActive: $0.isGPUActive)
                                },
                                onFocus: onFocusInsights,
                                activeFocusID: activeFocusID,
                                onFocusedStateChange: onFocusedInsightsChange
                            )
                            .frame(width: sidebarWidth)
                        }
                    }
                }

                if machineIdentity == nil {
                    floatingCardMenu(.stereoOutput) {
                        SystemOutputMeterHost(
                            onFocus: onFocusGraphCard,
                            activeFocusID: activeFocusID,
                            onFocusedStateChange: onFocusedGraphCardChange
                        )
                        .frame(width: sidebarWidth)
                    }
                }

                if shouldShowSupportProcessesCard {
                    SupportProcessesHost(
                        cpuSampler: cpuSampler,
                        gpuSampler: gpuSampler,
                        aneSampler: aneSampler,
                        powerSampler: powerSampler,
                        onFocus: onFocusGraphCard,
                        activeFocusID: activeFocusID,
                        onFocusedStateChange: onFocusedGraphCardChange
                    )
                    .frame(width: sidebarWidth)
                }

                // Remote Mac cards (compact mode)
                if !remoteHardwareManager.connectedMachines.isEmpty {
                    ForEach(remoteHardwareManager.connectedMachines) { connection in
                        RemoteMachineTile(
                            connection: connection,
                            onSelect: {
                                remoteHardwareManager.selectedMachineID = connection.id
                            },
                            onDisconnect: {
                                remoteHardwareManager.disconnect(machineID: connection.id)
                            }
                        )
                        .frame(width: sidebarWidth)
                    }
                }
            }
        }
        .frame(width: sidebarWidth * 2 + columnSpacing)
    }
    // MARK: - Debug buttons (shared)

    #if DEBUG
    @ViewBuilder
    private var debugButtons: some View {
        Button("Open Console") {
            showDebugConsoleSheet = true
        }
        .buttonStyle(.bordered)
        .frame(width: sidebarWidth, alignment: .leading)

        Button("Debug: Dump GPU Stats Keys") {
            AppDebugConsole.log("Dump GPU Stats Keys requested", category: "GPU")
            gpuSampler.debugDumpPerformanceStatisticsKeys()
        }
        .buttonStyle(.bordered)
        .frame(width: sidebarWidth, alignment: .leading)

        Button("Dump Temp / Power Keys") {
            AppDebugConsole.log("Dump Temp / Power Keys requested", category: "POWER")
            gpuSampler.debugDumpTemperatureAndPowerKeys()
        }
        .buttonStyle(.bordered)
    }
    #endif
}

private struct SystemOutputMeterHost: View {
    @ObservedObject private var meterModel: SystemAudioOutputMeterModel
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil

    init(
        meterModel: SystemAudioOutputMeterModel,
        onFocus: ((HardwareGraphFocusState) -> Void)? = nil,
        activeFocusID: String? = nil,
        onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil
    ) {
        self._meterModel = ObservedObject(wrappedValue: meterModel)
        self.onFocus = onFocus
        self.activeFocusID = activeFocusID
        self.onFocusedStateChange = onFocusedStateChange
    }

    init(
        onFocus: ((HardwareGraphFocusState) -> Void)? = nil,
        activeFocusID: String? = nil,
        onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil
    ) {
        self.init(
            meterModel: SystemAudioOutputMeterModel.shared,
            onFocus: onFocus,
            activeFocusID: activeFocusID,
            onFocusedStateChange: onFocusedStateChange
        )
    }

    var body: some View {
        Group {
            if meterModel.isSupportedPlatform {
                SystemOutputMeterCard(
                    snapshot: meterModel.snapshot,
                    onToggleEnabled: { isEnabled in
                        meterModel.setCaptureEnabled(isEnabled)
                    },
                    onDetailAction: { actionID in
                        meterModel.performFocusAction(actionID)
                    },
                    onFocus: onFocus,
                    activeFocusID: activeFocusID,
                    onFocusedStateChange: onFocusedStateChange
                )
            }
        }
        .onAppear {
            meterModel.activate()
        }
        .onDisappear {
            meterModel.deactivate()
        }
    }
}

private struct SupportProcessesHost: View {
    @StateObject private var supportProcessMonitor = AppSupportProcessMonitor()
    @ObservedObject var cpuSampler: CPUStatsSampler
    @ObservedObject var gpuSampler: GPUStatsSampler
    @ObservedObject var aneSampler: ANEStatsSampler
    @ObservedObject var powerSampler: PowerStatsSampler
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil

    private var hardwareAgentEvidenceAnchor: Date? {
        let timestamps =
            [
                cpuSampler.latestSnapshot?.timestamp,
                aneSampler.latestSnapshot?.timestamp,
                powerSampler.latestSnapshot?.timestamp
            ].compactMap { $0 }
            + gpuSampler.latestDeviceSnapshots.map(\.timestamp)
        return timestamps.max()
    }

    private var hardwareAgentEvidenceToken: Int {
        guard let hardwareAgentEvidenceAnchor else { return -1 }
        return Int(hardwareAgentEvidenceAnchor.timeIntervalSince1970.rounded(.down))
    }

    private var focusRefreshSignature: Int {
        var hasher = Hasher()
        for row in supportProcessMonitor.rows {
            hasher.combine(row.id)
            hasher.combine(row.name)
            hasher.combine(row.status.rawValue)
            hasher.combine(row.uptimeText)
            hasher.combine(row.statusLabel ?? "")
            hasher.combine(row.detailText ?? "")
            hasher.combine(row.action?.id ?? "")
            hasher.combine(row.action?.title ?? "")
            hasher.combine(row.action?.inProgressTitle ?? "")
            hasher.combine(row.action?.isEnabled ?? false)
            hasher.combine(row.action?.isInProgress ?? false)
            hasher.combine(row.uninstallAction?.id ?? "")
            hasher.combine(row.uninstallAction?.title ?? "")
            hasher.combine(row.uninstallAction?.inProgressTitle ?? "")
            hasher.combine(row.uninstallAction?.isEnabled ?? false)
            hasher.combine(row.uninstallAction?.isInProgress ?? false)
        }
        return hasher.finalize()
    }

    private var focusState: HardwareGraphFocusState? {
        let rows = supportProcessMonitor.rows
        guard !rows.isEmpty else { return nil }

        let activeCount = rows.filter { $0.status == .active }.count
        let attentionCount = rows.filter { $0.status == .idle }.count
        let unknownCount = rows.filter { $0.status == .unknown }.count
        let actionableCount = rows.reduce(0) { partial, row in
            partial
                + (row.action?.isEnabled == true ? 1 : 0)
                + (row.uninstallAction?.isEnabled == true ? 1 : 0)
        }

        let serviceRows = rows.map { row in
            HardwareGraphFocusHelperServiceRowSnapshot(
                id: row.id,
                name: row.name,
                statusText: row.statusLabel ?? row.status.displayText,
                uptimeText: row.uptimeText,
                detailText: row.detailText,
                tone: tone(for: row.status),
                actionID: row.action?.id,
                actionTitle: row.action?.title,
                actionInProgressTitle: row.action?.inProgressTitle,
                isActionEnabled: row.action?.isEnabled ?? false,
                isActionInProgress: row.action?.isInProgress ?? false,
                uninstallActionID: row.uninstallAction?.id,
                uninstallActionTitle: row.uninstallAction?.title,
                uninstallActionInProgressTitle: row.uninstallAction?.inProgressTitle,
                isUninstallActionEnabled: row.uninstallAction?.isEnabled ?? false,
                isUninstallActionInProgress: row.uninstallAction?.isInProgress ?? false
            )
        }

        let detailVisuals: [HardwareGraphFocusDetailVisual] = {
            let visuals: [HardwareGraphFocusDetailVisual] = [
                .helperServices(
                    HardwareGraphFocusHelperServicesSnapshot(
                        id: "helper-services-list",
                        subtitle: supportProcessMonitor.helperServicesFocusSubtitle,
                        rows: serviceRows
                    )
                )
            ]

            return visuals
        }()

        return HardwareGraphFocusState(
            id: "helper-services-card",
            title: "Helper Services",
            subtitle: "Dense readout of the background services and helpers that power hardware collection, audio routing, virtual camera publishing, and privileged power sampling.",
            accentColor: Color(red: 0.42, green: 0.78, blue: 0.96),
            visualization: .summary(
                HardwareGraphFocusSummarySnapshot(
                    title: "Service Overview",
                    subtitle: "Use Install or Repair to refresh bundled helpers without leaving the hardware page.",
                    hero: nil,
                    tiles: [
                        .init(title: "Active", value: "\(activeCount)", detail: activeCount == 1 ? "service responding" : "services responding", tint: Color(red: 0.30, green: 0.84, blue: 0.50)),
                        .init(title: "Attention", value: "\(attentionCount)", detail: attentionCount == 1 ? "service needs a nudge" : "services need a nudge", tint: Color(red: 0.90, green: 0.42, blue: 0.32)),
                        .init(title: "Unknown", value: "\(unknownCount)", detail: unknownCount == 1 ? "service unclear" : "services unclear", tint: Color.white.opacity(0.72)),
                        .init(title: "Actions", value: "\(actionableCount)", detail: actionableCount == 1 ? "service action available" : "service actions available", tint: Color(red: 0.42, green: 0.78, blue: 0.96))
                    ],
                    rows: []
                )
            ),
            detailVisuals: detailVisuals,
            stats: [
                .init(label: "Active", value: "\(activeCount)", tint: Color(red: 0.30, green: 0.84, blue: 0.50)),
                .init(label: "Attention", value: "\(attentionCount)", tint: Color(red: 0.90, green: 0.42, blue: 0.32)),
                .init(label: "Unknown", value: "\(unknownCount)", tint: Color.white.opacity(0.75)),
                .init(label: "Actions", value: "\(actionableCount)", tint: Color(red: 0.42, green: 0.78, blue: 0.96))
            ],
            detailLines: supportProcessMonitor.helperServicesFocusDetailLines,
            detailActionHandler: { rowID in
                supportProcessMonitor.performDetailAction(for: rowID)
            }
        )
    }

    var body: some View {
        SupportProcessesCard(
            rows: supportProcessMonitor.rows,
            onFocus: onFocus,
            activeFocusID: activeFocusID,
            onFocusedStateChange: onFocusedStateChange,
            focusState: focusState
        )
            .onAppear {
                supportProcessMonitor.start()
                supportProcessMonitor.updateHardwareDataEvidenceDate(hardwareAgentEvidenceAnchor)
            }
            .onChange(of: hardwareAgentEvidenceToken) { _ in
                supportProcessMonitor.updateHardwareDataEvidenceDate(hardwareAgentEvidenceAnchor)
            }
            .onChange(of: focusRefreshSignature) { _ in
                refreshFocusedStateIfNeeded()
            }
            .onDisappear {
                supportProcessMonitor.stop()
            }
    }

    private func tone(for status: AppSupportProcessMonitor.Status) -> HardwareGraphFocusHelperServiceRowSnapshot.Tone {
        switch status {
        case .active:
            return .active
        case .idle:
            return .attention
        case .unknown:
            return .unknown
        }
    }

    private func refreshFocusedStateIfNeeded() {
        guard let focusState,
              focusState.id == activeFocusID,
              let onFocusedStateChange else { return }
        onFocusedStateChange(focusState)
    }
}

private struct ObservedSubtree<Object: ObservableObject, Content: View>: View {
    @ObservedObject var primary: Object
    let content: () -> Content

    init(primary: Object, @ViewBuilder content: @escaping () -> Content) {
        self._primary = ObservedObject(wrappedValue: primary)
        self.content = content
    }

    var body: some View {
        content()
    }
}

private struct ObservedSubtree2<Object1: ObservableObject, Object2: ObservableObject, Content: View>: View {
    @ObservedObject var primary: Object1
    @ObservedObject var secondary: Object2
    let content: () -> Content

    init(primary: Object1, secondary: Object2, @ViewBuilder content: @escaping () -> Content) {
        self._primary = ObservedObject(wrappedValue: primary)
        self._secondary = ObservedObject(wrappedValue: secondary)
        self.content = content
    }

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

    init(
        object1: Object1,
        object2: Object2,
        object3: Object3,
        object4: Object4,
        object5: Object5,
        object6: Object6,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._object1 = ObservedObject(wrappedValue: object1)
        self._object2 = ObservedObject(wrappedValue: object2)
        self._object3 = ObservedObject(wrappedValue: object3)
        self._object4 = ObservedObject(wrappedValue: object4)
        self._object5 = ObservedObject(wrappedValue: object5)
        self._object6 = ObservedObject(wrappedValue: object6)
        self.content = content
    }

    var body: some View {
        content()
    }
}

private struct ObservedSubtree7<
    Object1: ObservableObject,
    Object2: ObservableObject,
    Object3: ObservableObject,
    Object4: ObservableObject,
    Object5: ObservableObject,
    Object6: ObservableObject,
    Object7: ObservableObject,
    Content: View
>: View {
    @ObservedObject var object1: Object1
    @ObservedObject var object2: Object2
    @ObservedObject var object3: Object3
    @ObservedObject var object4: Object4
    @ObservedObject var object5: Object5
    @ObservedObject var object6: Object6
    @ObservedObject var object7: Object7
    let content: () -> Content

    init(
        object1: Object1,
        object2: Object2,
        object3: Object3,
        object4: Object4,
        object5: Object5,
        object6: Object6,
        object7: Object7,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._object1 = ObservedObject(wrappedValue: object1)
        self._object2 = ObservedObject(wrappedValue: object2)
        self._object3 = ObservedObject(wrappedValue: object3)
        self._object4 = ObservedObject(wrappedValue: object4)
        self._object5 = ObservedObject(wrappedValue: object5)
        self._object6 = ObservedObject(wrappedValue: object6)
        self._object7 = ObservedObject(wrappedValue: object7)
        self.content = content
    }

    var body: some View {
        content()
    }
}

struct CPUCoresCard: View {
    @Environment(\.appUIScale) private var appUIScale
    private struct CoreClusterLayout {
        let labelsByCoreIndex: [Int: String]

        var efficiencyCount: Int {
            labelsByCoreIndex.values.filter { $0 == "Efficiency" }.count
        }

        var performanceCount: Int {
            labelsByCoreIndex.values.filter { $0 == "Performance" }.count
        }

        func label(for index: Int) -> String? {
            labelsByCoreIndex[index]
        }
    }

    let cpuDisplayName: String
    let coreUsages: [Float]
    let perCoreFrequenciesHz: [Double]
    let perCoreUsageSeries: [MetricSeries]
    let perCoreFrequencySeries: [MetricSeries]
    let efficiencyCoreCount: Int
    let performanceCoreCount: Int
    var onFocus: ((HardwareGraphFocusState) -> Void)? = nil
    var activeFocusID: String? = nil
    var onFocusedStateChange: ((HardwareGraphFocusState) -> Void)? = nil

    private var coreRows: Int { max(coreUsages.count, 1) }
    private var scaledCornerRadius: CGFloat { 16 * appUIScale }
    private var scaledHeaderSpacing: CGFloat { 8 * appUIScale }
    private var scaledPadding: CGFloat { 12 * appUIScale }
    private var scaledRowStride: CGFloat { 26 * appUIScale }
    private var scaledRowLabelHeight: CGFloat { 14 * appUIScale }
    private var scaledLabelColumnWidth: CGFloat { 52 * appUIScale }
    private var scaledValueColumnWidth: CGFloat { 92 * appUIScale }
    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledTitleRowHeight: CGFloat { 24 * appUIScale }
    private var scaledTitleRowBottomPadding: CGFloat { 4 * appUIScale }
    private var scaledCoreMetersTopPadding: CGFloat { 8 * appUIScale }
    private var scaledHeaderDividerHeight: CGFloat { 1 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }
    private var scaledCaption2FontSize: CGFloat { 11 * appUIScale }
    private var coreCardHeight: CGFloat { CGFloat(coreRows) * scaledRowStride + 66 * appUIScale }
    private var headerDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: scaledHeaderDividerHeight)
            .padding(.horizontal, -scaledPadding)
    }
    private var focusID: String { "cpu-cores-focus" }
    private var coreClusterLayout: CoreClusterLayout? {
        inferCoreClusterLayout(coreCount: max(coreUsages.count, max(perCoreUsageSeries.count, perCoreFrequencySeries.count)))
    }
    private var resolvedEfficiencyCoreCount: Int {
        efficiencyCoreCount > 0 ? efficiencyCoreCount : (coreClusterLayout?.efficiencyCount ?? 0)
    }
    private var resolvedPerformanceCoreCount: Int {
        performanceCoreCount > 0 ? performanceCoreCount : (coreClusterLayout?.performanceCount ?? 0)
    }
    private var focusRefreshSignature: Int {
        var hasher = Hasher()
        hasher.combine(cpuDisplayName)
        hasher.combine(efficiencyCoreCount)
        hasher.combine(performanceCoreCount)
        hasher.combine(coreClusterLayout?.efficiencyCount ?? -1)
        hasher.combine(coreClusterLayout?.performanceCount ?? -1)
        for usage in coreUsages {
            hasher.combine(Int((Double(usage) * 1000).rounded()))
        }
        for frequency in perCoreFrequenciesHz {
            hasher.combine(Int((frequency / 1_000_000).rounded()))
        }
        for series in perCoreUsageSeries {
            hasher.combine(series.samples.count)
            hasher.combine(Int(series.latestSample?.timestamp.timeIntervalSince1970 ?? 0))
            hasher.combine(Int(((series.latestSample?.value ?? -1) * 1000).rounded()))
        }
        for series in perCoreFrequencySeries {
            hasher.combine(series.samples.count)
            hasher.combine(Int(series.latestSample?.timestamp.timeIntervalSince1970 ?? 0))
            hasher.combine(Int(((series.latestSample?.value ?? -1) * 10).rounded()))
        }
        return hasher.finalize()
    }
    var body: some View {
        ThemeRoundedRectangle(cornerRadius: scaledCornerRadius).themed()
            .frame(height: coreCardHeight)
            .overlay(
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 12 * appUIScale) {
                        Text("CPU Cores")
                            .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Spacer(minLength: 8 * appUIScale)

                        Image(systemName: "cpu")
                            .font(.system(size: 24 * appUIScale, weight: .semibold))
                            .foregroundColor(.blue)
                            .frame(width: 28 * appUIScale, height: 28 * appUIScale)
                    }
                    .frame(height: scaledTitleRowHeight)
                    .padding(.bottom, scaledTitleRowBottomPadding)

                    headerDivider

                    HStack(alignment: .top, spacing: scaledHeaderSpacing) {
                        VStack(alignment: .leading, spacing: 12 * appUIScale) {
                            ForEach(coreUsages.indices, id: \.self) { index in
                                Text("Core \(index + 1)")
                                    .font(.system(size: scaledCaptionFontSize, weight: .regular))
                                    .frame(height: scaledRowLabelHeight, alignment: .center)
                            }
                        }
                        .frame(width: scaledLabelColumnWidth, alignment: .leading)

                        MetalCPUCoreMetersView(cores: coreUsages)
                            .frame(maxWidth: .infinity, minHeight: CGFloat(coreRows) * scaledRowStride, maxHeight: CGFloat(coreRows) * scaledRowStride)
                            .offset(y: -6 * appUIScale)

                        VStack(alignment: .trailing, spacing: 12 * appUIScale) {
                            ForEach(coreUsages.indices, id: \.self) { index in
                                let frequencyHz = index < perCoreFrequenciesHz.count
                                    ? perCoreFrequenciesHz[index]
                                    : 0
                                let frequencyText = PowerStatsSampler.formatCoreFrequency(frequencyHz)

                                Text("\(String(format: "%3.0f%%", coreUsages[index] * 100)) · \(frequencyText)")
                                    .font(.system(size: scaledCaption2FontSize, weight: .regular))
                                    .frame(height: scaledRowLabelHeight, alignment: .center)
                            }
                        }
                        .frame(width: scaledValueColumnWidth, alignment: .trailing)
                    }
                    .padding(.top, scaledCoreMetersTopPadding)
                }
                .padding(scaledPadding)
            )
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    guard let onFocus,
                          let focusState = focusState else { return }
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

    private var focusState: HardwareGraphFocusState? {
        let coreCount = max(coreUsages.count, max(perCoreUsageSeries.count, perCoreFrequencySeries.count))
        guard coreCount > 0 else { return nil }

        let coreSnapshots = (0..<coreCount).map { index in
            HardwareGraphFocusCPUCoreSeriesSnapshot(
                id: "core-\(index)",
                label: coreLabel(for: index),
                clusterLabel: clusterLabel(for: index),
                usageValues: seriesValues(at: index, from: perCoreUsageSeries),
                frequencyGHzValues: seriesValues(at: index, from: perCoreFrequencySeries).map { $0.map { $0 / 1000.0 } },
                liveUsage: index < coreUsages.count ? Double(coreUsages[index]) : nil,
                liveFrequencyGHz: index < perCoreFrequenciesHz.count ? perCoreFrequenciesHz[index] / 1_000_000_000.0 : nil
            )
        }

        let liveAverageUsage = coreUsages.isEmpty
            ? nil
            : Double(coreUsages.reduce(0, +)) / Double(coreUsages.count)
        let observedFrequenciesGHz = perCoreFrequenciesHz.map { $0 / 1_000_000_000.0 }
        let liveAverageGHz = observedFrequenciesGHz.isEmpty
            ? nil
            : observedFrequenciesGHz.reduce(0, +) / Double(observedFrequenciesGHz.count)
        let hottestCoreIndex = coreUsages.enumerated().max(by: { $0.element < $1.element })?.offset
        let hottestUsage = hottestCoreIndex.flatMap { index in
            index < coreUsages.count ? Double(coreUsages[index]) : nil
        }
        let sampleCount = max(
            perCoreUsageSeries.map(\.samples.count).max() ?? 0,
            perCoreFrequencySeries.map(\.samples.count).max() ?? 0
        )

        var stats: [HardwareGraphFocusStat] = []
        if let liveAverageUsage {
            stats.append(.init(label: "Live Avg", value: String(format: "%.0f%%", liveAverageUsage * 100), tint: .blue))
        }
        if let hottestCoreIndex, let hottestUsage {
            stats.append(.init(label: "Hot Core", value: "\(coreLabel(for: hottestCoreIndex)) · \(Int((hottestUsage * 100).rounded()))%", tint: .blue))
        }
        if let liveAverageGHz {
            stats.append(.init(label: "Avg GHz", value: String(format: "%.2f GHz", liveAverageGHz), tint: Color(red: 0.18, green: 0.82, blue: 0.86)))
        }
        if let peakGHz = coreSnapshots.compactMap({ $0.frequencyGHzValues.compactMap { $0 }.max() }).max() {
            stats.append(.init(label: "Peak GHz", value: String(format: "%.2f GHz", peakGHz), tint: Color(red: 0.18, green: 0.82, blue: 0.86)))
        }
        stats.append(.init(label: "Cores", value: "\(coreCount)"))
        if sampleCount > 0 {
            stats.append(.init(label: "Samples", value: "\(sampleCount)"))
        }

        var detailLines: [String] = []
        if resolvedEfficiencyCoreCount > 0 || resolvedPerformanceCoreCount > 0 {
            detailLines.append("Core layout: \(resolvedEfficiencyCoreCount) efficiency, \(resolvedPerformanceCoreCount) performance.")
        } else if let coreClusterLayout {
            detailLines.append("Core layout: \(coreClusterLayout.efficiencyCount) efficiency, \(coreClusterLayout.performanceCount) performance.")
        }
        if let liveAverageGHz {
            detailLines.append(String(format: "Live average core clock is %.2f GHz across the current sample.", liveAverageGHz))
        }
        detailLines.append("Top chart tracks per-core CPU load history; lower chart tracks the same core's recorded clock history.")

        return HardwareGraphFocusState(
            id: focusID,
            title: "CPU Cores",
            subtitle: focusSubtitle(for: coreCount),
            accentColor: .blue,
            insightTarget: .cpu,
            attributionTarget: .cpu,
            visualization: .cpuCoreDetail(
                HardwareGraphFocusCPUCoreSnapshot(
                    usageTitle: "Core Usage History",
                    usageSubtitle: "Recorded per-core CPU load.",
                    frequencyTitle: "Core GHz History",
                    frequencySubtitle: "Recorded per-core clock speed.",
                    cores: coreSnapshots
                )
            ),
            stats: stats,
            detailLines: detailLines
        )
    }

    private func seriesValues(at index: Int, from seriesCollection: [MetricSeries]) -> [Double?] {
        guard index < seriesCollection.count else { return [] }
        return seriesCollection[index].samples.map(\.value)
    }

    private func coreLabel(for index: Int) -> String {
        "Core \(index + 1)"
    }

    private func clusterLabel(for index: Int) -> String? {
        coreClusterLayout?.label(for: index)
    }

    private func focusSubtitle(for coreCount: Int) -> String {
        guard resolvedEfficiencyCoreCount > 0 || resolvedPerformanceCoreCount > 0 else {
            guard let coreClusterLayout else { return cpuDisplayName }

            let parts = cpuDisplayName
                .components(separatedBy: "—")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            guard parts.count >= 2 else {
                return "CPU — \(cpuDisplayName) — P:\(coreClusterLayout.performanceCount) E:\(coreClusterLayout.efficiencyCount)"
            }

            let cpuPrefix = parts[0]
            let chipName = parts[1]
            let coreSummary = parts.first(where: { $0.contains("C/") && $0.contains("T") }) ?? "\(coreCount) cores"
            return "\(cpuPrefix) — \(chipName) — P:\(coreClusterLayout.performanceCount) E:\(coreClusterLayout.efficiencyCount) — \(coreSummary)"
        }

        let parts = cpuDisplayName
            .components(separatedBy: "—")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard parts.count >= 2 else {
            return "CPU — \(cpuDisplayName) — P:\(resolvedPerformanceCoreCount) E:\(resolvedEfficiencyCoreCount)"
        }

        let cpuPrefix = parts[0]
        let chipName = parts[1]
        let coreSummary = parts.first(where: { $0.contains("C/") && $0.contains("T") }) ?? "\(coreCount) cores"
        return "\(cpuPrefix) — \(chipName) — P:\(resolvedPerformanceCoreCount) E:\(resolvedEfficiencyCoreCount) — \(coreSummary)"
    }

    private func inferCoreClusterLayout(coreCount: Int) -> CoreClusterLayout? {
        guard coreCount >= 4 else { return nil }

        let representativeGHzByCore = (0..<coreCount).compactMap { index -> (Int, Double)? in
            let historicalGHz = seriesValues(at: index, from: perCoreFrequencySeries).compactMap { value -> Double? in
                guard let value else { return nil }
                return value / 1000.0
            }
            let representativeGHz: Double?
            if let historicalPeak = historicalGHz.max(), historicalPeak > 0.1 {
                representativeGHz = historicalPeak
            } else if index < perCoreFrequenciesHz.count {
                let liveGHz = perCoreFrequenciesHz[index] / 1_000_000_000.0
                representativeGHz = liveGHz > 0.1 ? liveGHz : nil
            } else {
                representativeGHz = nil
            }

            guard let representativeGHz else { return nil }
            return (index, representativeGHz)
        }

        guard representativeGHzByCore.count >= 4 else { return nil }

        let sorted = representativeGHzByCore.sorted { $0.1 < $1.1 }
        var bestSplitIndex: Int?
        var bestGap: Double = 0

        for index in 0..<(sorted.count - 1) {
            let gap = sorted[index + 1].1 - sorted[index].1
            if gap > bestGap {
                bestGap = gap
                bestSplitIndex = index
            }
        }

        guard let bestSplitIndex else { return nil }

        let lowerClusterCount = bestSplitIndex + 1
        let upperClusterCount = sorted.count - lowerClusterCount
        guard lowerClusterCount >= 1, upperClusterCount >= 1 else { return nil }
        guard bestGap >= 0.18 else { return nil }

        let lowerAverage = sorted.prefix(lowerClusterCount).map { $0.1 }.reduce(0, +) / Double(lowerClusterCount)
        let upperAverage = sorted.suffix(upperClusterCount).map { $0.1 }.reduce(0, +) / Double(upperClusterCount)
        guard upperAverage > lowerAverage + 0.12 else { return nil }

        let efficiencyIndices = Set(sorted.prefix(lowerClusterCount).map { $0.0 })
        let performanceIndices = Set(sorted.suffix(upperClusterCount).map { $0.0 })
        guard efficiencyIndices.isDisjoint(with: performanceIndices) else { return nil }

        var labelsByCoreIndex: [Int: String] = [:]
        for index in efficiencyIndices {
            labelsByCoreIndex[index] = "Efficiency"
        }
        for index in performanceIndices {
            labelsByCoreIndex[index] = "Performance"
        }

        return labelsByCoreIndex.isEmpty ? nil : CoreClusterLayout(labelsByCoreIndex: labelsByCoreIndex)
    }

    private func refreshFocusedStateIfNeeded() {
        guard activeFocusID == focusID,
              let onFocusedStateChange,
              let focusState else { return }
        onFocusedStateChange(focusState)
    }
}
