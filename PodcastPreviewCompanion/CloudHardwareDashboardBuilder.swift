import Foundation
import PodcastPreviewCore

@MainActor
struct CloudHardwareDashboardBuilder {
    private static let inlineSparklineSampleLimit = 180

    let machineIdentity: CompanionMachineIdentity
    let collectorService: HardwareCollectorService
    let historyReader: HardwareHistoryReader
    let processHistoryReader: ProcessHistoryReader
    let eventReader: HardwareEventReader
    let insightsService: HardwareInsightsService

    private struct TimelineSpec {
        let seriesKey: String
        let label: String
        let tint: CompanionTint
        let metricKey: HardwareMetricKey?
        let deviceMetricKey: HardwareDeviceMetricKey?
        let deviceID: String?
        let deviceKind: HardwareDeviceKind?

        static func metric(
            _ seriesKey: String,
            label: String,
            tint: CompanionTint,
            key: HardwareMetricKey
        ) -> TimelineSpec {
            TimelineSpec(
                seriesKey: seriesKey,
                label: label,
                tint: tint,
                metricKey: key,
                deviceMetricKey: nil,
                deviceID: nil,
                deviceKind: nil
            )
        }

        static func device(
            _ seriesKey: String,
            label: String,
            tint: CompanionTint,
            key: HardwareDeviceMetricKey,
            deviceID: String,
            deviceKind: HardwareDeviceKind = .gpu
        ) -> TimelineSpec {
            TimelineSpec(
                seriesKey: seriesKey,
                label: label,
                tint: tint,
                metricKey: nil,
                deviceMetricKey: key,
                deviceID: deviceID,
                deviceKind: deviceKind
            )
        }
    }

    func makeCurrentSnapshotPayload() -> CompanionCurrentSnapshotPayload {
        let updatedAt = collectorService.latestTelemetryFrame.isEmpty ? Date() : collectorService.latestTelemetryFrame.timestamp
        let liveSnapshot = makeLiveSnapshot()
        return CompanionCurrentSnapshotPayload(
            machineIdentity: machineIdentity,
            updatedAt: updatedAt,
            liveSnapshot: liveSnapshot
        )
    }

    func makeDashboardSnapshotPayload(
        currentSnapshot: CompanionCurrentSnapshotPayload,
        minuteTimeline: CompanionTimelinePayload,
        hourlyTimeline: CompanionTimelinePayload,
        processRollup: CompanionProcessRollupPayload,
        hardwareEvents: CompanionHardwareEventPayload
    ) -> CompanionDashboardSnapshot {
        return makeDashboardSnapshot(
            updatedAt: currentSnapshot.updatedAt,
            liveSnapshot: currentSnapshot.liveSnapshot,
            minuteTimeline: minuteTimeline,
            hourlyTimeline: hourlyTimeline,
            processRollup: processRollup,
            hardwareEvents: hardwareEvents
        )
    }

    func makeMinuteTimelinePayload() async -> CompanionTimelinePayload {
        let specs = makeMinuteTimelineSpecs()
        return await makeTimelinePayload(
            title: "Minute Rollup",
            range: HardwareInsightWindow.daily.range(anchoredAt: Date()),
            bucketIntervalSeconds: 60,
            specs: specs
        )
    }

    func makeHourlyTimelinePayload() async -> CompanionTimelinePayload {
        let specs = makeHourlyTimelineSpecs()
        return await makeTimelinePayload(
            title: "Hourly Rollup",
            range: HardwareInsightWindow.weekly.range(anchoredAt: Date()),
            bucketIntervalSeconds: 3600,
            specs: specs
        )
    }

    func makeProcessRollupPayload() async -> CompanionProcessRollupPayload {
        let rows = pollingRows().prefix(8).map { row in
            CompanionKeyValueRow(
                label: row.name,
                value: [
                    String(format: "%.0f%% CPU", row.cpuPercent),
                    String(format: "%.0f MB RAM", row.ramMB)
                ].joined(separator: "  ·  "),
                tint: row.cpuPercent >= 40 ? .orange : .blue
            )
        }

        return CompanionProcessRollupPayload(
            machineID: machineIdentity.machineID,
            updatedAt: Date(),
            rows: Array(rows)
        )
    }

    func makeHardwareEventPayload() async -> CompanionHardwareEventPayload {
        let range = HardwareInsightWindow.daily.range(anchoredAt: Date())
        let events = await eventReader.events(in: range, categories: nil, limit: 24)

        let entries = events.map { event in
            CompanionHardwareEventPayload.Entry(
                id: "\(event.id)",
                timestamp: event.timestamp,
                category: event.category.rawValue,
                severity: event.severity.rawValue,
                title: event.title,
                detail: event.detail
            )
        }

        return CompanionHardwareEventPayload(
            machineID: machineIdentity.machineID,
            updatedAt: Date(),
            entries: entries
        )
    }

    private func makeMinuteTimelineSpecs() -> [TimelineSpec] {
        var specs: [TimelineSpec] = [
            .metric("metric.cpu.total", label: "CPU", tint: .blue, key: .cpuTotalUsage),
            .metric("metric.cpu.efficiency", label: "Efficiency", tint: .teal, key: .cpuEfficiencyUsage),
            .metric("metric.cpu.performance", label: "Performance", tint: .indigo, key: .cpuPerformanceUsage),
            .metric("metric.memory.usage", label: "Memory", tint: .green, key: .ramUsageRatio),
            .metric("metric.memory.pressure", label: "Memory Pressure", tint: .green, key: .memoryPressureRatio),
            .metric("metric.memory.swap", label: "Swap", tint: .slate, key: .swapUsedGB),
            .metric("metric.disk.read", label: "Disk Read", tint: .cyan, key: .diskReadMBps),
            .metric("metric.disk.write", label: "Disk Write", tint: .amber, key: .diskWriteMBps),
            .metric("metric.network.upload", label: "Network Up", tint: .purple, key: .networkUploadMBps),
            .metric("metric.network.download", label: "Network Down", tint: .blue, key: .networkDownloadMBps),
            .metric("metric.power.combined", label: "Power", tint: .orange, key: .combinedPowerWatts),
            .metric("metric.thermal.level", label: "Thermals", tint: .red, key: .thermalLevel),
            .metric("metric.ane.activity", label: "ANE", tint: .pink, key: .aneActivityRatio),
            .metric("metric.media.activity", label: "Media", tint: .indigo, key: .mediaEngineActivityRatio)
        ]

        for gpu in orderedGPUSnapshots() {
            specs.append(.device(
                "device.gpu.\(gpu.id).utilization",
                label: "\(gpu.name) GPU",
                tint: .red,
                key: .utilizationRatio,
                deviceID: gpu.id
            ))
            specs.append(.device(
                "device.gpu.\(gpu.id).renderer",
                label: "\(gpu.name) Renderer",
                tint: .amber,
                key: .rendererUtilizationRatio,
                deviceID: gpu.id
            ))
            specs.append(.device(
                "device.gpu.\(gpu.id).tiler",
                label: "\(gpu.name) Tiler",
                tint: .orange,
                key: .tilerUtilizationRatio,
                deviceID: gpu.id
            ))
        }

        return specs
    }

    private func makeHourlyTimelineSpecs() -> [TimelineSpec] {
        var specs: [TimelineSpec] = [
            .metric("metric.cpu.total", label: "CPU", tint: .blue, key: .cpuTotalUsage),
            .metric("metric.memory.usage", label: "Memory", tint: .green, key: .ramUsageRatio),
            .metric("metric.power.combined", label: "Power", tint: .orange, key: .combinedPowerWatts),
            .metric("metric.network.download", label: "Network Down", tint: .blue, key: .networkDownloadMBps)
        ]

        if let primaryGPU = orderedGPUSnapshots().first {
            specs.append(.device(
                "device.gpu.\(primaryGPU.id).utilization",
                label: "\(primaryGPU.name) GPU",
                tint: .red,
                key: .utilizationRatio,
                deviceID: primaryGPU.id
            ))
        }

        return specs
    }

    private func makeTimelinePayload(
        title: String,
        range: DateInterval,
        bucketIntervalSeconds: Int,
        specs: [TimelineSpec]
    ) async -> CompanionTimelinePayload {
        let series = await withTaskGroup(of: CompanionTimelineSeriesPayload?.self) { group -> [CompanionTimelineSeriesPayload] in
            for spec in specs {
                group.addTask { [historyReader] in
                    let buckets: [HardwareHistoryMetricBucket]
                    if let metricKey = spec.metricKey {
                        buckets = await historyReader.metricTimeline(
                            for: metricKey,
                            in: range,
                            bucketIntervalSeconds: bucketIntervalSeconds
                        )
                    } else if let deviceMetricKey = spec.deviceMetricKey,
                              let deviceID = spec.deviceID,
                              let deviceKind = spec.deviceKind {
                        buckets = await historyReader.deviceMetricTimeline(
                            for: deviceMetricKey,
                            deviceID: deviceID,
                            deviceKind: deviceKind,
                            in: range,
                            bucketIntervalSeconds: bucketIntervalSeconds
                        )
                    } else {
                        buckets = []
                    }

                    let points = buckets.map { bucket in
                        CompanionTimelineBucket(timestamp: bucket.bucketStart, value: Self.compactMetricValue(bucket.lastValue))
                    }

                    guard !points.isEmpty else { return nil }

                    let peakValue = points.compactMap { $0.value }.max()

                    return CompanionTimelineSeriesPayload(
                        id: "\(machineIdentity.machineID).\(spec.seriesKey).\(bucketIntervalSeconds)",
                        label: spec.label,
                        seriesKey: spec.seriesKey,
                        tint: spec.tint,
                        bucketDurationSeconds: bucketIntervalSeconds,
                        points: points,
                        peakValue: peakValue
                    )
                }
            }

            var values: [CompanionTimelineSeriesPayload] = []
            for await result in group {
                if let result {
                    values.append(result)
                }
            }
            return values.sorted { $0.label < $1.label }
        }

        return CompanionTimelinePayload(
            machineID: machineIdentity.machineID,
            title: title,
            updatedAt: Date(),
            series: series
        )
    }

    private func makeLiveSnapshot() -> CompanionLiveSnapshot {
        let polling = collectorService.pollingSnapshot
        let cpuSnapshot = polling.cpu.latestSnapshot
        let memorySnapshot = polling.ram.latestMemorySnapshot
        let powerSnapshot = polling.power.latestReadingsSnapshot
        let powerSystemSnapshot = polling.power.latestSystemSnapshot
        let aneSnapshot = polling.ane.latestStatusSnapshot
        let mediaSummary = polling.mediaEngine.latestActivitySummary
        let mediaCapability = polling.mediaEngine.latestCapabilityState
        let primaryInterface = polling.networkInterfaceSnapshot?.primaryInterface

        let cpu = CompanionLiveCPUSnapshot(
            displayName: polling.cpu.cpuDisplayName,
            totalUsageRatio: percentMetric(cpuSnapshot, .cpuTotalUsage),
            efficiencyUsageRatio: percentMetric(cpuSnapshot, .cpuEfficiencyUsage),
            performanceUsageRatio: percentMetric(cpuSnapshot, .cpuPerformanceUsage),
            systemUsageRatio: percentMetric(cpuSnapshot, .cpuSystemUsage),
            userUsageRatio: percentMetric(cpuSnapshot, .cpuUserUsage),
            idleUsageRatio: percentMetric(cpuSnapshot, .cpuIdleUsage),
            efficiencyCoreCount: polling.cpu.efficiencyCoreCount,
            performanceCoreCount: polling.cpu.performanceCoreCount,
            coreUsages: polling.cpu.coreUsages.map { clamp01(Double($0)) }
        )

        let gpus = orderedGPUSnapshots().map { gpu in
            CompanionLiveGPUSnapshot(
                id: gpu.id,
                name: gpu.name,
                utilizationRatio: clamp01(Double(gpu.usage ?? 0)),
                rendererUtilizationRatio: clamp01(Double(gpu.rendererUsage ?? 0)),
                tilerUtilizationRatio: clamp01(Double(gpu.tilerUsage ?? 0)),
                memoryAllocatedMB: gpu.gpuMemoryAllocatedMB.map(Double.init),
                memoryInUseMB: gpu.gpuMemoryInUseMB.map(Double.init),
                totalPowerWatts: gpu.totalPowerW.map(Double.init),
                temperatureCelsius: gpu.temperatureC.map(Double.init),
                coreCount: gpu.coreCount,
                connectedDisplayCount: metadata(for: gpu.id)?.connectedDisplayCount,
                metalFamily: metadata(for: gpu.id)?.metalFamily,
                bus: metadata(for: gpu.id)?.bus,
                gpuType: metadata(for: gpu.id)?.gpuType
            )
        }

        let memory = CompanionLiveMemorySnapshot(
            usageRatio: memorySnapshot.map { Double($0.ramUsageRatio) },
            usedGB: memorySnapshot.map { bytesToGB($0.usedBytes) },
            totalGB: memorySnapshot.map { bytesToGB($0.totalBytes) } ?? machineIdentity.totalRAMGB,
            pressureRatio: polling.ram.latestSnapshot?.metric(.memoryPressureRatio),
            pressureLabel: memorySnapshot?.pressureLabel ?? "Unknown",
            pressureSubtext: memorySnapshot?.pressureSubtext ?? "Awaiting pressure samples",
            swapUsedGB: memorySnapshot?.swapUsedGB,
            swapTotalGB: memorySnapshot?.swapTotalGB,
            cachedGB: memorySnapshot.map { bytesToGB($0.cachedBytes) },
            compressedGB: memorySnapshot.map { bytesToGB($0.compressedBytes) },
            wiredGB: memorySnapshot.map { bytesToGB($0.wiredBytes) },
            appMemoryGB: memorySnapshot?.appMemoryBytes.map(bytesToGB),
            architecture: polling.memoryIdentityUnit?.architecture,
            chip: polling.memoryIdentityUnit?.chip
        )

        let network = CompanionLiveNetworkSnapshot(
            uploadMBps: polling.network.latestSnapshot?.metric(.networkUploadMBps),
            downloadMBps: polling.network.latestSnapshot?.metric(.networkDownloadMBps),
            pingLatencyMilliseconds: polling.network.pingLatencyMilliseconds,
            packetLossRatio: polling.network.pingPacketLossRatio,
            pingTargetLabel: polling.network.pingTargetLabel,
            connectionLabel: connectionLabel(from: polling.networkInterfaceSnapshot),
            interfaceName: primaryInterface?.displayName,
            localIP: primaryInterface?.primaryLocalIP,
            subnetMask: primaryInterface?.primarySubnetMask,
            router: primaryInterface?.router,
            dnsServers: primaryInterface?.dnsServers ?? [],
            searchDomains: primaryInterface?.searchDomains ?? [],
            ethernetSpeed: primaryInterface?.ethernetSpeed,
            configMethod: primaryInterface?.configMethod.rawValue
        )

        let power = CompanionLivePowerSnapshot(
            cpuPowerWatts: powerSnapshot?.cpuPowerWatts,
            gpuPowerWatts: powerSnapshot?.gpuPowerWatts,
            anePowerWatts: powerSnapshot?.anePowerWatts,
            combinedPowerWatts: powerSnapshot?.combinedPowerWatts,
            peakCombinedPowerWatts: powerSnapshot?.peakCombinedPowerWatts ?? 0,
            cumulativeEnergyWh: powerSnapshot?.cumulativeCombinedEnergyWh ?? 0,
            uptimeSeconds: powerSystemSnapshot?.uptimeSeconds,
            processCount: powerSystemSnapshot?.processCount,
            gpuFrequencyMHz: powerSnapshot?.gpuFrequencyMHz,
            perCoreFrequenciesGHz: powerSnapshot?.perCoreFrequenciesHz.map { $0 / 1_000_000_000.0 } ?? [],
            powermetricsText: powerSnapshot?.livePowerReadingsText
        )

        let ane = aneSnapshot.map { status in
            CompanionLiveANESnapshot(
                activityRatio: clamp01(status.activityValue),
                currentPowerWatts: status.currentPowerMilliwatts / 1000.0,
                peakPowerWatts: status.peakPowerMilliwatts / 1000.0,
                clientCount: status.clientCount,
                statusText: status.statusText,
                coreCountText: status.coreCountText,
                architectureText: status.architectureText,
                engineStatusText: status.engineStatus
            )
        }

        let media = (mediaSummary != nil || mediaCapability != nil) ? CompanionLiveMediaSnapshot(
            activityRatio: mediaSummary.map { clamp01($0.activityValue) },
            activityStateText: mediaSummary?.statusText ?? "Idle",
            codec: mediaSummary?.codec,
            recentProcessedFrames: mediaSummary?.recentProcessedFrames ?? 0,
            retainedSessionCount: mediaSummary?.retainedSessionCount ?? 0,
            recentEncoderPathCount: mediaSummary?.recentEncoderPathCount ?? 0,
            activeSessionCount: mediaSummary?.activeSessionCount ?? 0,
            capabilityTitle: mediaCapability?.displayTitle,
            supportedEncodeCodecs: mediaCapability?.supportedEncodeCodecs ?? [],
            supportedDecodeCodecs: mediaCapability?.supportedDecodeCodecs ?? []
        ) : nil

        let topProcesses = pollingRows().prefix(10).map { row in
            CompanionLiveProcessSnapshot(
                processKey: PersistedProcessIdentity.makeKey(bundleIdentifier: row.bundleIdentifier, name: row.name),
                displayName: row.name,
                bundleIdentifier: row.bundleIdentifier,
                cpuPercent: row.cpuPercent,
                ramMB: row.ramMB,
                gpuActive: polling.gpuClients?.activeApps.contains(where: { $0.pid == row.pid && $0.isActive }) ?? false,
                gpuDeltaTimeNS: polling.gpuClients?.activeApps.first(where: { $0.pid == row.pid })?.gpuDeltaTimeNS,
                diskReadMBps: row.diskReadMBps,
                diskWriteMBps: row.diskWriteMBps,
                uptimeText: row.uptimeText
            )
        }

        return CompanionLiveSnapshot(
            cpu: cpu,
            gpus: gpus,
            memory: memory,
            storage: CompanionLiveStorageSnapshot(
                usedRatio: Double(polling.storage.storageUsedRatio),
                label: polling.storage.storageLabel,
                kindLabel: polling.storage.storageKindLabel,
                speedLabel: polling.storage.storageSpeedLabel,
                healthLabel: polling.storage.storageHealthLabel,
                diskReadMBps: polling.diskIO.latestSnapshot?.metric(.diskReadMBps),
                diskWriteMBps: polling.diskIO.latestSnapshot?.metric(.diskWriteMBps)
            ),
            network: network,
            power: power,
            ane: ane,
            media: media,
            topProcesses: Array(topProcesses),
            hardwareInsights: makeHardwareInsightsRows(cpu: cpu, gpus: gpus, memory: memory, ane: ane, media: media)
        )
    }

    private func makeDashboardSnapshot(
        updatedAt: Date,
        liveSnapshot: CompanionLiveSnapshot,
        minuteTimeline: CompanionTimelinePayload,
        hourlyTimeline: CompanionTimelinePayload,
        processRollup: CompanionProcessRollupPayload,
        hardwareEvents: CompanionHardwareEventPayload
    ) -> CompanionDashboardSnapshot {
        let liveCollectorSnapshot = collectorService.liveSnapshot
        _ = minuteTimeline
        _ = hourlyTimeline

        let primaryGPUUsageSeries = liveCollectorSnapshot.gpu.usageSeriesByGPU[liveSnapshot.gpus.first?.id ?? ""]
        let energyCurrent = blendedEnergyCurrent(
            cpu: liveSnapshot.cpu.totalUsageRatio,
            gpu: liveSnapshot.gpus.first?.utilizationRatio,
            ram: liveSnapshot.memory.usageRatio
        )
        let energyHistory = blendedEnergyHistory(
            cpuHistory: liveCollectorSnapshot.cpu.totalUsageSeries.values().map(Float.init),
            gpuHistory: primaryGPUUsageSeries?.values().map(Float.init) ?? [],
            ramHistory: liveCollectorSnapshot.ram.usageSeries.values().map(Float.init)
        )

        let summaryChips = [
            CompanionSummaryChip(
                id: "\(machineIdentity.machineID).cpu",
                label: "CPU",
                value: formatPercent(liveSnapshot.cpu.totalUsageRatio),
                tint: .blue,
                caption: "Current load"
            ),
            CompanionSummaryChip(
                id: "\(machineIdentity.machineID).gpu",
                label: "GPU",
                value: formatPercent(liveSnapshot.gpus.first?.utilizationRatio),
                tint: .red,
                caption: liveSnapshot.gpus.first?.name ?? "No GPU"
            ),
            CompanionSummaryChip(
                id: "\(machineIdentity.machineID).memory",
                label: "Memory",
                value: memorySummaryValue(liveSnapshot.memory),
                tint: .green,
                caption: liveSnapshot.memory.pressureLabel
            ),
            CompanionSummaryChip(
                id: "\(machineIdentity.machineID).power",
                label: "Power",
                value: formatWatts(liveSnapshot.power.combinedPowerWatts),
                tint: .orange,
                caption: "Combined draw"
            )
        ]

        var graphSections: [CompanionDashboardSection] = [
            CompanionDashboardSection(
                id: "\(machineIdentity.machineID).cpu",
                title: "CPU",
                subtitle: liveSnapshot.cpu.displayName,
                cards: [
                    CompanionDashboardCard(
                        id: "\(machineIdentity.machineID).cpu.total",
                        title: "CPU",
                        subtitle: "Live aggregate",
                        detail: "Current CPU load across all cores.",
                        kind: .chart,
                        tint: .blue,
                        primaryValue: formatPercent(liveSnapshot.cpu.totalUsageRatio),
                        series: makeCardSeries(
                            from: liveCollectorSnapshot.cpu.totalUsageSeries,
                            label: "CPU",
                            tint: .blue
                        ),
                        focusID: "metric.cpu.total",
                        footnote: "Recent rolling window"
                    ),
                    CompanionDashboardCard(
                        id: "\(machineIdentity.machineID).cpu.efficiency",
                        title: "Efficiency Cores",
                        subtitle: "\(liveSnapshot.cpu.efficiencyCoreCount) cores",
                        detail: "Low-power core activity.",
                        kind: .chart,
                        tint: .teal,
                        primaryValue: formatPercent(liveSnapshot.cpu.efficiencyUsageRatio),
                        series: makeCardSeries(
                            from: liveCollectorSnapshot.cpu.efficiencyUsageSeries,
                            label: "Efficiency",
                            tint: .teal
                        ),
                        focusID: "metric.cpu.efficiency"
                    ),
                    CompanionDashboardCard(
                        id: "\(machineIdentity.machineID).cpu.performance",
                        title: "Performance Cores",
                        subtitle: "\(liveSnapshot.cpu.performanceCoreCount) cores",
                        detail: "High-performance core activity.",
                        kind: .chart,
                        tint: .indigo,
                        primaryValue: formatPercent(liveSnapshot.cpu.performanceUsageRatio),
                        series: makeCardSeries(
                            from: liveCollectorSnapshot.cpu.performanceUsageSeries,
                            label: "Performance",
                            tint: .indigo
                        ),
                        focusID: "metric.cpu.performance"
                    )
                ]
            )
        ]

        for gpu in liveSnapshot.gpus {
            graphSections.append(
                CompanionDashboardSection(
                    id: "\(machineIdentity.machineID).gpu.\(gpu.id)",
                    title: "GPU",
                    subtitle: gpu.name,
                    cards: [
                        CompanionDashboardCard(
                            id: "\(machineIdentity.machineID).gpu.\(gpu.id).total",
                            title: "GPU",
                            subtitle: gpu.gpuType ?? "Graphics",
                            detail: "Overall GPU utilization.",
                            kind: .chart,
                            tint: .red,
                            primaryValue: formatPercent(gpu.utilizationRatio),
                            series: makeCardSeries(
                                from: liveCollectorSnapshot.gpu.usageSeriesByGPU[gpu.id],
                                label: "GPU",
                                tint: .red
                            ),
                            focusID: "device.gpu.\(gpu.id).utilization"
                        ),
                        CompanionDashboardCard(
                            id: "\(machineIdentity.machineID).gpu.\(gpu.id).renderer",
                            title: "Renderer",
                            subtitle: allocatedMemoryText(gpu.memoryAllocatedMB),
                            detail: "Renderer utilization over time.",
                            kind: .chart,
                            tint: .amber,
                            primaryValue: formatPercent(gpu.rendererUtilizationRatio),
                            series: makeCardSeries(
                                from: liveCollectorSnapshot.gpu.rendererSeriesByGPU[gpu.id],
                                label: "Renderer",
                                tint: .amber
                            ),
                            focusID: "device.gpu.\(gpu.id).renderer"
                        ),
                        CompanionDashboardCard(
                            id: "\(machineIdentity.machineID).gpu.\(gpu.id).tiler",
                            title: "Tiler",
                            subtitle: gpu.metalFamily ?? "Tile processing",
                            detail: "Tiler utilization over time.",
                            kind: .chart,
                            tint: .orange,
                            primaryValue: formatPercent(gpu.tilerUtilizationRatio),
                            series: makeCardSeries(
                                from: liveCollectorSnapshot.gpu.tilerSeriesByGPU[gpu.id],
                                label: "Tiler",
                                tint: .orange
                            ),
                            focusID: "device.gpu.\(gpu.id).tiler"
                        )
                    ]
                )
            )
        }

        graphSections.append(
            CompanionDashboardSection(
                id: "\(machineIdentity.machineID).memory",
                title: "Memory",
                subtitle: "Unified memory and pressure",
                cards: [
                    CompanionDashboardCard(
                        id: "\(machineIdentity.machineID).memory.ram",
                        title: "RAM",
                        subtitle: formatGB(liveSnapshot.memory.totalGB),
                        detail: memorySummaryValue(liveSnapshot.memory),
                        kind: .meter,
                        tint: .green,
                        primaryValue: formatPercent(liveSnapshot.memory.usageRatio),
                        progress: liveSnapshot.memory.usageRatio,
                        focusID: "metric.memory.usage"
                    ),
                    CompanionDashboardCard(
                        id: "\(machineIdentity.machineID).memory.pressure",
                        title: "Memory Pressure",
                        subtitle: liveSnapshot.memory.pressureLabel,
                        detail: liveSnapshot.memory.pressureSubtext,
                        kind: .chart,
                        tint: .green,
                        primaryValue: formatPercent(liveSnapshot.memory.pressureRatio),
                        series: makeCardSeries(
                            from: liveCollectorSnapshot.ram.pressureSeries,
                            label: "Pressure",
                            tint: .green
                        ),
                        focusID: "metric.memory.pressure"
                    ),
                    CompanionDashboardCard(
                        id: "\(machineIdentity.machineID).memory.swap",
                        title: "Swap",
                        subtitle: liveSnapshot.memory.swapTotalGB == nil ? "Inactive" : "Swap in use",
                        detail: swapSummaryValue(liveSnapshot.memory),
                        kind: .chart,
                        tint: .slate,
                        primaryValue: formatPercent(swapUsageRatio(liveSnapshot.memory)),
                        series: makeCardSeries(
                            from: liveCollectorSnapshot.ram.swapUsageSeries,
                            label: "Swap",
                            tint: .slate
                        ),
                        focusID: "metric.memory.swap"
                    )
                ]
            )
        )

        graphSections.append(
            CompanionDashboardSection(
                id: "\(machineIdentity.machineID).disk",
                title: "Disk",
                subtitle: "Read and write throughput",
                cards: [
                    CompanionDashboardCard(
                        id: "\(machineIdentity.machineID).disk.read",
                        title: "Disk Read",
                        subtitle: "Live throughput",
                        detail: [liveCollectorSnapshot.diskIO.readText, liveCollectorSnapshot.diskIO.readPeakText]
                            .compactMap { $0 == "—" ? nil : $0 }
                            .joined(separator: "  ·  "),
                        kind: .chart,
                        tint: .cyan,
                        primaryValue: formatPercent(
                            peakScaledValues(
                                values: liveCollectorSnapshot.diskIO.readSeries.values(),
                                current: liveSnapshot.storage.diskReadMBps,
                                floor: 0.05
                            ).current.map(Double.init)
                        ),
                        series: makeCardSeries(
                            from: peakScaledValues(
                                values: liveCollectorSnapshot.diskIO.readSeries.values(),
                                current: liveSnapshot.storage.diskReadMBps,
                                floor: 0.05
                            ).history,
                            label: "Read",
                            tint: .cyan
                        ),
                        focusID: "metric.disk.read"
                    ),
                    CompanionDashboardCard(
                        id: "\(machineIdentity.machineID).disk.write",
                        title: "Disk Write",
                        subtitle: "Live throughput",
                        detail: [liveCollectorSnapshot.diskIO.writeText, liveCollectorSnapshot.diskIO.writePeakText]
                            .compactMap { $0 == "—" ? nil : $0 }
                            .joined(separator: "  ·  "),
                        kind: .chart,
                        tint: .amber,
                        primaryValue: formatPercent(
                            peakScaledValues(
                                values: liveCollectorSnapshot.diskIO.writeSeries.values(),
                                current: liveSnapshot.storage.diskWriteMBps,
                                floor: 0.05
                            ).current.map(Double.init)
                        ),
                        series: makeCardSeries(
                            from: peakScaledValues(
                                values: liveCollectorSnapshot.diskIO.writeSeries.values(),
                                current: liveSnapshot.storage.diskWriteMBps,
                                floor: 0.05
                            ).history,
                            label: "Write",
                            tint: .amber
                        ),
                        focusID: "metric.disk.write"
                    )
                ]
            )
        )

        graphSections.append(
            CompanionDashboardSection(
                id: "\(machineIdentity.machineID).network",
                title: "Network",
                subtitle: liveSnapshot.network.connectionLabel,
                cards: [
                    CompanionDashboardCard(
                        id: "\(machineIdentity.machineID).network.upload",
                        title: "Network Upload",
                        subtitle: liveSnapshot.network.interfaceName ?? "Interface",
                        detail: [liveCollectorSnapshot.network.uploadText, liveCollectorSnapshot.network.uploadPeakText]
                            .compactMap { $0 == "—" ? nil : $0 }
                            .joined(separator: "  ·  "),
                        kind: .chart,
                        tint: .purple,
                        primaryValue: formatPercent(
                            peakScaledValues(
                                values: liveCollectorSnapshot.network.uploadSeries.values(),
                                current: liveSnapshot.network.uploadMBps,
                                floor: 0.1
                            ).current.map(Double.init)
                        ),
                        series: makeCardSeries(
                            from: peakScaledValues(
                                values: liveCollectorSnapshot.network.uploadSeries.values(),
                                current: liveSnapshot.network.uploadMBps,
                                floor: 0.1
                            ).history,
                            label: "Upload",
                            tint: .purple
                        ),
                        focusID: "metric.network.upload"
                    ),
                    CompanionDashboardCard(
                        id: "\(machineIdentity.machineID).network.download",
                        title: "Network Download",
                        subtitle: liveSnapshot.network.interfaceName ?? "Interface",
                        detail: [liveCollectorSnapshot.network.downloadText, liveCollectorSnapshot.network.downloadPeakText]
                            .compactMap { $0 == "—" ? nil : $0 }
                            .joined(separator: "  ·  "),
                        kind: .chart,
                        tint: .blue,
                        primaryValue: formatPercent(
                            peakScaledValues(
                                values: liveCollectorSnapshot.network.downloadSeries.values(),
                                current: liveSnapshot.network.downloadMBps,
                                floor: 0.1
                            ).current.map(Double.init)
                        ),
                        series: makeCardSeries(
                            from: peakScaledValues(
                                values: liveCollectorSnapshot.network.downloadSeries.values(),
                                current: liveSnapshot.network.downloadMBps,
                                floor: 0.1
                            ).history,
                            label: "Download",
                            tint: .blue
                        ),
                        focusID: "metric.network.download"
                    )
                ]
            )
        )

        var systemCards: [CompanionDashboardCard] = [
            CompanionDashboardCard(
                id: "\(machineIdentity.machineID).system.power",
                title: "Combined Power",
                subtitle: "System draw",
                detail: liveCollectorSnapshot.power.livePowerReadingsText,
                kind: .chart,
                tint: .orange,
                primaryValue: formatPercent(energyCurrent),
                series: makeCardSeries(
                    from: energyHistory,
                    label: "Energy",
                    tint: .orange
                ),
                focusID: "metric.power.combined"
            ),
            CompanionDashboardCard(
                id: "\(machineIdentity.machineID).system.thermal",
                title: "Thermals",
                subtitle: thermalLabel(),
                detail: "Thermal state sampled from the source Mac.",
                kind: .chart,
                tint: .red,
                primaryValue: thermalLabel(),
                series: makeCardSeries(
                    from: liveCollectorSnapshot.thermal.thermalSeries,
                    label: "Thermals",
                    tint: .red,
                    scale: 1.0 / 3.0
                ),
                focusID: "metric.thermal.level"
            )
        ]

        if let ane = liveSnapshot.ane {
            systemCards.append(
                CompanionDashboardCard(
                    id: "\(machineIdentity.machineID).system.ane",
                    title: "Neural Engine",
                    subtitle: ane.statusText,
                    detail: "Current ANE activity and power.",
                    kind: .chart,
                    tint: .pink,
                    primaryValue: formatPercent(ane.activityRatio),
                    series: makeCardSeries(
                        from: liveCollectorSnapshot.ane.activitySeries,
                        label: "ANE",
                        tint: .pink
                    ),
                    focusID: "metric.ane.activity"
                )
            )
        }

        if let media = liveSnapshot.media {
            systemCards.append(
                CompanionDashboardCard(
                    id: "\(machineIdentity.machineID).system.media",
                    title: "Media Engines",
                    subtitle: media.activityStateText,
                    detail: media.codec ?? "Hardware encode/decode activity",
                    kind: .chart,
                    tint: .indigo,
                    primaryValue: media.codec ?? "Idle",
                    series: makeCardSeries(
                        from: liveCollectorSnapshot.mediaEngine.activitySeries,
                        label: "Media",
                        tint: .indigo
                    ),
                    focusID: "metric.media.activity"
                )
            )
        }

        graphSections.append(
            CompanionDashboardSection(
                id: "\(machineIdentity.machineID).system",
                title: "System",
                subtitle: "Power, thermal, and accelerator activity",
                cards: systemCards
            )
        )

        let sidebarSections = makeSidebarSections(
            updatedAt: updatedAt,
            liveSnapshot: liveSnapshot,
            processRollup: processRollup,
            hardwareEvents: hardwareEvents
        )

        return CompanionDashboardSnapshot(
            machineIdentity: machineIdentity,
            updatedAt: updatedAt,
            summaryChips: summaryChips,
            graphSections: graphSections,
            sidebarSections: sidebarSections,
            focus: nil
        )
    }

    private func makeSidebarSections(
        updatedAt: Date,
        liveSnapshot: CompanionLiveSnapshot,
        processRollup: CompanionProcessRollupPayload,
        hardwareEvents: CompanionHardwareEventPayload
    ) -> [CompanionDashboardSection] {
        var sections: [CompanionDashboardSection] = []

        sections.append(
            CompanionDashboardSection(
                id: "\(machineIdentity.machineID).identity",
                title: "This Mac",
                subtitle: machineIdentity.displayName,
                cards: [
                    CompanionDashboardCard(
                        id: "\(machineIdentity.machineID).identity.card",
                        title: machineIdentity.displayName,
                        subtitle: machineIdentity.modelIdentifier,
                        detail: machineIdentity.cpuName ?? machineIdentity.chipType ?? "Mac",
                        kind: .identity,
                        tint: accentTint(),
                        primaryValue: machineIdentity.macOSVersion,
                        rows: [
                            CompanionKeyValueRow(label: "Chip", value: machineIdentity.chipType ?? "Unknown", tint: accentTint()),
                            CompanionKeyValueRow(label: "Memory", value: formatGB(machineIdentity.totalRAMGB), tint: .green),
                            CompanionKeyValueRow(label: "Updated", value: updatedTimeString(updatedAt), tint: .slate)
                        ]
                    )
                ]
            )
        )

        sections.append(
            CompanionDashboardSection(
                id: "\(machineIdentity.machineID).power",
                title: "Power Stats",
                subtitle: "Live energy usage",
                cards: [
                    CompanionDashboardCard(
                        id: "\(machineIdentity.machineID).power.card",
                        title: "Power",
                        subtitle: "Combined and package draw",
                        detail: "Power, energy, and uptime sampled from the source Mac.",
                        kind: .list,
                        tint: .orange,
                        rows: [
                            CompanionKeyValueRow(label: "Combined", value: formatWatts(liveSnapshot.power.combinedPowerWatts), tint: .orange),
                            CompanionKeyValueRow(label: "CPU", value: formatWatts(liveSnapshot.power.cpuPowerWatts), tint: .blue),
                            CompanionKeyValueRow(label: "GPU", value: formatWatts(liveSnapshot.power.gpuPowerWatts), tint: .red),
                            CompanionKeyValueRow(label: "ANE", value: formatWatts(liveSnapshot.power.anePowerWatts), tint: .pink),
                            CompanionKeyValueRow(label: "Energy", value: formatEnergy(liveSnapshot.power.cumulativeEnergyWh), tint: .green),
                            CompanionKeyValueRow(label: "Uptime", value: formatDuration(liveSnapshot.power.uptimeSeconds), tint: .slate),
                            CompanionKeyValueRow(label: "Processes", value: "\(liveSnapshot.power.processCount ?? 0)", tint: .slate)
                        ],
                        focusID: "sidebar.power"
                    )
                ]
            )
        )

        if !liveSnapshot.cpu.coreUsages.isEmpty {
            let frequencyRows = liveSnapshot.power.perCoreFrequenciesGHz
            let coreRows = liveSnapshot.cpu.coreUsages.enumerated().map { index, usage in
                let frequencyText: String
                if index < frequencyRows.count {
                    frequencyText = String(format: "%.2f GHz", frequencyRows[index])
                } else {
                    frequencyText = "—"
                }
                return CompanionKeyValueRow(
                    label: "Core \(index + 1)",
                    value: "\(formatPercent(usage))  ·  \(frequencyText)",
                    tint: usage >= 0.7 ? .orange : .blue
                )
            }

            sections.append(
                CompanionDashboardSection(
                    id: "\(machineIdentity.machineID).cpu.cores",
                    title: "CPU Cores",
                    subtitle: "Live core mix",
                    cards: [
                        CompanionDashboardCard(
                            id: "\(machineIdentity.machineID).cpu.cores.card",
                            title: "CPU Cores",
                            subtitle: "Per-core load and frequency",
                            detail: "Usage and frequency from the current snapshot.",
                            kind: .list,
                            tint: .blue,
                            rows: coreRows,
                            focusID: "sidebar.cpuCores"
                        )
                    ]
                )
            )
        }

        if !liveSnapshot.gpus.isEmpty {
            sections.append(
                CompanionDashboardSection(
                    id: "\(machineIdentity.machineID).gpu.sidebar",
                    title: "GPU",
                    subtitle: "Device details",
                    cards: liveSnapshot.gpus.map { gpu in
                        CompanionDashboardCard(
                            id: "\(machineIdentity.machineID).gpu.sidebar.\(gpu.id)",
                            title: gpu.name,
                            subtitle: gpu.gpuType ?? "Graphics",
                            detail: gpu.metalFamily,
                            kind: .list,
                            tint: .red,
                            rows: [
                                CompanionKeyValueRow(label: "Usage", value: formatPercent(gpu.utilizationRatio), tint: .red),
                                CompanionKeyValueRow(label: "Renderer", value: formatPercent(gpu.rendererUtilizationRatio), tint: .amber),
                                CompanionKeyValueRow(label: "Tiler", value: formatPercent(gpu.tilerUtilizationRatio), tint: .orange),
                                CompanionKeyValueRow(label: "Allocated", value: allocatedMemoryText(gpu.memoryAllocatedMB), tint: .slate),
                                CompanionKeyValueRow(label: "In Use", value: allocatedMemoryText(gpu.memoryInUseMB), tint: .slate),
                                CompanionKeyValueRow(label: "Temperature", value: formatTemperature(gpu.temperatureCelsius), tint: .slate)
                            ],
                            focusID: "device.gpu.\(gpu.id).utilization"
                        )
                    }
                )
            )
        }

        sections.append(
            CompanionDashboardSection(
                id: "\(machineIdentity.machineID).memory.sidebar",
                title: "Memory",
                subtitle: "Capacity and pressure",
                cards: [
                    CompanionDashboardCard(
                        id: "\(machineIdentity.machineID).memory.sidebar.card",
                        title: "Memory",
                        subtitle: liveSnapshot.memory.architecture ?? "System memory",
                        detail: liveSnapshot.memory.chip,
                        kind: .list,
                        tint: .green,
                        rows: [
                            CompanionKeyValueRow(label: "Usage", value: memorySummaryValue(liveSnapshot.memory), tint: .green),
                            CompanionKeyValueRow(label: "Pressure", value: liveSnapshot.memory.pressureLabel, tint: .green),
                            CompanionKeyValueRow(label: "Cached", value: formatGB(liveSnapshot.memory.cachedGB), tint: .slate),
                            CompanionKeyValueRow(label: "Compressed", value: formatGB(liveSnapshot.memory.compressedGB), tint: .slate),
                            CompanionKeyValueRow(label: "Wired", value: formatGB(liveSnapshot.memory.wiredGB), tint: .slate),
                            CompanionKeyValueRow(label: "App Memory", value: formatGB(liveSnapshot.memory.appMemoryGB), tint: .slate)
                        ],
                        focusID: "sidebar.memory"
                    )
                ]
            )
        )

        sections.append(
            CompanionDashboardSection(
                id: "\(machineIdentity.machineID).storage.sidebar",
                title: "Storage",
                subtitle: "Capacity and health",
                cards: [
                    CompanionDashboardCard(
                        id: "\(machineIdentity.machineID).storage.sidebar.card",
                        title: "Storage",
                        subtitle: liveSnapshot.storage.kindLabel,
                        detail: liveSnapshot.storage.speedLabel,
                        kind: .list,
                        tint: .amber,
                        rows: [
                            CompanionKeyValueRow(label: "Used", value: liveSnapshot.storage.label, tint: .amber),
                            CompanionKeyValueRow(label: "Kind", value: liveSnapshot.storage.kindLabel, tint: .slate),
                            CompanionKeyValueRow(label: "Speed", value: liveSnapshot.storage.speedLabel, tint: .slate),
                            CompanionKeyValueRow(label: "Health", value: liveSnapshot.storage.healthLabel, tint: .green)
                        ],
                        focusID: "sidebar.storage"
                    )
                ]
            )
        )

        sections.append(
            CompanionDashboardSection(
                id: "\(machineIdentity.machineID).network.sidebar",
                title: "Network Stats",
                subtitle: liveSnapshot.network.connectionLabel,
                cards: [
                    CompanionDashboardCard(
                        id: "\(machineIdentity.machineID).network.sidebar.card",
                        title: "Network",
                        subtitle: liveSnapshot.network.interfaceName ?? "No primary interface",
                        detail: liveSnapshot.network.localIP,
                        kind: .list,
                        tint: .purple,
                        rows: [
                            CompanionKeyValueRow(label: "Upload", value: formatRate(liveSnapshot.network.uploadMBps), tint: .purple),
                            CompanionKeyValueRow(label: "Download", value: formatRate(liveSnapshot.network.downloadMBps), tint: .blue),
                            CompanionKeyValueRow(label: "Ping", value: pingSummary(liveSnapshot.network), tint: .cyan),
                            CompanionKeyValueRow(label: "Local IP", value: liveSnapshot.network.localIP ?? "—", tint: .slate),
                            CompanionKeyValueRow(label: "Router", value: liveSnapshot.network.router ?? "—", tint: .slate),
                            CompanionKeyValueRow(label: "DNS", value: liveSnapshot.network.dnsServers.first ?? "—", tint: .slate)
                        ],
                        focusID: "sidebar.network"
                    )
                ]
            )
        )

        sections.append(
            CompanionDashboardSection(
                id: "\(machineIdentity.machineID).top-apps",
                title: "Top Apps",
                subtitle: "Current process pressure",
                cards: [
                    CompanionDashboardCard(
                        id: "\(machineIdentity.machineID).top-apps.card",
                        title: "Top Apps",
                        subtitle: "Live process list",
                        detail: "CPU, memory, and GPU-active processes from the latest snapshot.",
                        kind: .list,
                        tint: .cyan,
                        rows: processRollup.rows,
                        focusID: "sidebar.processes"
                    )
                ]
            )
        )

        sections.append(
            CompanionDashboardSection(
                id: "\(machineIdentity.machineID).insights",
                title: "Hardware Insights",
                subtitle: "Live health summary",
                cards: [
                    CompanionDashboardCard(
                        id: "\(machineIdentity.machineID).insights.card",
                        title: "Hardware Insights",
                        subtitle: "Current state",
                        detail: "Live status distilled from the source Mac.",
                        kind: .insight,
                        tint: .green,
                        rows: liveSnapshot.hardwareInsights,
                        focusID: "sidebar.insights",
                        footnote: "Synced from the latest CloudKit payload"
                    )
                ]
            )
        )

        if !hardwareEvents.entries.isEmpty {
            sections.append(
                CompanionDashboardSection(
                    id: "\(machineIdentity.machineID).events",
                    title: "Recent Events",
                    subtitle: "Last 24 hours",
                    cards: [
                        CompanionDashboardCard(
                            id: "\(machineIdentity.machineID).events.card",
                            title: "Events",
                            subtitle: "\(hardwareEvents.entries.count) recent events",
                            detail: "Recent hardware and monitoring events.",
                            kind: .list,
                            tint: .gray,
                            rows: hardwareEvents.entries.prefix(5).map { entry in
                                CompanionKeyValueRow(
                                    label: entry.title,
                                    value: entry.detail ?? entry.category.capitalized,
                                    tint: tint(forSeverity: entry.severity)
                                )
                            },
                            focusID: "sidebar.events"
                        )
                    ]
                )
            )
        }

        return sections
    }

    private func orderedGPUSnapshots() -> [GPUStatsSampler.GPUUnit] {
        collectorService.pollingSnapshot.gpu.gpus.sorted { lhs, rhs in
            if lhs.name == rhs.name {
                return lhs.id < rhs.id
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func metadata(for gpuID: String) -> GPUUnitMetadata? {
        collectorService.pollingSnapshot.gpuIdentityUnits?.first(where: { $0.id == gpuID })
    }

    private func pollingRows() -> [RunningAppsSampler.Row] {
        collectorService.pollingSnapshot.runningApps.topRows
    }

    private func makeCardSeries(
        from values: [Float],
        label: String,
        tint: CompanionTint,
        scale: Double = 1.0
    ) -> [CompanionSeries] {
        guard !values.isEmpty else { return [] }
        let recentValues = values.suffix(Self.inlineSparklineSampleLimit).map {
            Self.compactRatio(Double($0) * scale)
        }
        return [
            CompanionSeries(
                id: "\(machineIdentity.machineID).\(label.lowercased().replacingOccurrences(of: " ", with: "-")).series",
                label: label,
                tint: tint,
                values: recentValues
            )
        ]
    }

    private func makeCardSeries(
        from series: MetricSeries?,
        label: String,
        tint: CompanionTint,
        scale: Double = 1.0
    ) -> [CompanionSeries] {
        guard let series else { return [] }
        let recentValues = Array(series.samples.suffix(Self.inlineSparklineSampleLimit)).map { sample -> Double? in
            guard let value = sample.value else { return nil }
            return Self.compactRatio(value * scale)
        }
        guard !recentValues.isEmpty else { return [] }
        return [
            CompanionSeries(
                id: "\(machineIdentity.machineID).\(series.key.rawValue).series",
                label: label,
                tint: tint,
                values: recentValues
            )
        ]
    }

    private func makeCardSeries(
        from series: HardwareDeviceMetricSeries?,
        label: String,
        tint: CompanionTint,
        scale: Double = 1.0
    ) -> [CompanionSeries] {
        guard let series else { return [] }
        let recentValues = Array(series.samples.suffix(Self.inlineSparklineSampleLimit)).map { sample -> Double? in
            guard let value = sample.value else { return nil }
            return Self.compactRatio(value * scale)
        }
        guard !recentValues.isEmpty else { return [] }
        return [
            CompanionSeries(
                id: "\(machineIdentity.machineID).\(series.deviceID).\(series.key.rawValue).series",
                label: label,
                tint: tint,
                values: recentValues
            )
        ]
    }

    private func peakScaledValues(
        values: [Double],
        current: Double?,
        floor: Double
    ) -> (current: Float?, history: [Float]) {
        let recentValues = Array(values.suffix(Self.inlineSparklineSampleLimit))
        let windowPeak = recentValues.max() ?? 0
        let effectiveMax = niceMax(max(floor, max(current ?? 0, windowPeak)))

        let normHistory = recentValues.map { Float(Self.compactRatio($0 / effectiveMax) ?? 0) }
        let normCurrent = current.map { Float(Self.compactRatio($0 / effectiveMax) ?? 0) }
        return (normCurrent, normHistory)
    }

    private nonisolated static func compactRatio(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        let clamped = min(max(value, 0), 1)
        let ratioPrecision = 1_000.0
        return (clamped * ratioPrecision).rounded() / ratioPrecision
    }

    private nonisolated static func compactMetricValue(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        let magnitude = abs(value)
        let precision: Double
        if magnitude < 1 {
            precision = 1_000
        } else if magnitude < 100 {
            precision = 100
        } else {
            precision = 10
        }
        return (value * precision).rounded() / precision
    }

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

    private func blendedEnergyCurrent(
        cpu: Double?,
        gpu: Double?,
        ram: Double?
    ) -> Double? {
        if cpu == nil && gpu == nil && ram == nil {
            return nil
        }

        let score = ((cpu ?? 0) * 0.55) + ((gpu ?? 0) * 0.30) + ((ram ?? 0) * 0.15)
        return min(max(score, 0), 1)
    }

    private func makeHardwareInsightsRows(
        cpu: CompanionLiveCPUSnapshot,
        gpus: [CompanionLiveGPUSnapshot],
        memory: CompanionLiveMemorySnapshot,
        ane: CompanionLiveANESnapshot?,
        media: CompanionLiveMediaSnapshot?
    ) -> [CompanionKeyValueRow] {
        [
            CompanionKeyValueRow(label: "CPU", value: cpuInsight(cpu), tint: .blue),
            CompanionKeyValueRow(label: "GPU", value: gpuInsight(gpus), tint: .red),
            CompanionKeyValueRow(label: "Memory", value: memoryInsight(memory), tint: .green),
            CompanionKeyValueRow(label: "Neural Engine", value: ane?.statusText ?? "Unavailable", tint: .pink),
            CompanionKeyValueRow(label: "Media", value: media?.activityStateText ?? "Idle", tint: .indigo)
        ]
    }

    private func cpuInsight(_ cpu: CompanionLiveCPUSnapshot) -> String {
        guard let ratio = cpu.totalUsageRatio else { return "Awaiting samples" }
        switch ratio {
        case 0.75...:
            return "High load"
        case 0.45...:
            return "Busy"
        default:
            return "Stable"
        }
    }

    private func gpuInsight(_ gpus: [CompanionLiveGPUSnapshot]) -> String {
        guard let ratio = gpus.compactMap(\.utilizationRatio).max() else { return "Idle" }
        switch ratio {
        case 0.7...:
            return "Rendering hard"
        case 0.3...:
            return "Active"
        default:
            return "Calm"
        }
    }

    private func memoryInsight(_ memory: CompanionLiveMemorySnapshot) -> String {
        if memory.pressureLabel.lowercased().contains("critical") {
            return "Critical pressure"
        }
        if memory.pressureLabel.lowercased().contains("high") || (memory.usageRatio ?? 0) >= 0.85 {
            return "Elevated usage"
        }
        return "Healthy"
    }

    private func connectionLabel(from snapshot: NetworkInterfaceSnapshot?) -> String {
        guard let snapshot else { return "Disconnected" }
        let labels = snapshot.connectionTypes.map(\.rawValue).sorted()
        return labels.isEmpty ? "Disconnected" : labels.joined(separator: " + ")
    }

    private func accentTint() -> CompanionTint {
        let hints = [
            machineIdentity.chipType?.lowercased(),
            machineIdentity.cpuName?.lowercased()
        ].compactMap { $0 }

        if hints.contains(where: { $0.contains("m4") || $0.contains("m3") }) {
            return .cyan
        }
        if hints.contains(where: { $0.contains("m2") || $0.contains("m1") }) {
            return .blue
        }
        return .teal
    }

    private func updatedTimeString(_ date: Date) -> String {
        if #available(macOS 12.0, *) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }

    private func formatPercent(_ ratio: Double?) -> String {
        guard let ratio else { return "—" }
        return "\(Int((clamp01(ratio) * 100).rounded()))%"
    }

    private func formatRate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: value >= 10 ? "%.0f MB/s" : "%.1f MB/s", value)
    }

    private func formatWatts(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 10 ? String(format: "%.1f W", value) : String(format: "%.2f W", value)
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

    private func allocatedMemoryText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 1024 ? String(format: "%.1f GB", value / 1024.0) : String(format: "%.0f MB", value)
    }

    private func memorySummaryValue(_ memory: CompanionLiveMemorySnapshot) -> String {
        guard let used = memory.usedGB, let total = memory.totalGB else { return "—" }
        return String(format: "%.1f / %.0f GB", used, total)
    }

    private func swapSummaryValue(_ memory: CompanionLiveMemorySnapshot) -> String {
        guard let total = memory.swapTotalGB, total > 0, let used = memory.swapUsedGB else { return "Inactive" }
        return String(format: "%.1f / %.1f GB", used, total)
    }

    private func swapUsageRatio(_ memory: CompanionLiveMemorySnapshot) -> Double? {
        guard let total = memory.swapTotalGB, total > 0, let used = memory.swapUsedGB else { return nil }
        return min(max(used / total, 0), 1)
    }

    private func thermalLabel() -> String {
        let snapshot = collectorService.pollingSnapshot.thermal.latestSnapshot
        if let label = snapshot?.dimension(.thermalState) {
            return label
        }
        if let level = snapshot?.metric(.thermalLevel) {
            switch level {
            case ..<1: return "Nominal"
            case ..<2: return "Fair"
            case ..<3: return "Serious"
            default: return "Critical"
            }
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

    private func percentMetric(_ snapshot: HardwareSnapshot?, _ key: HardwareMetricKey) -> Double? {
        snapshot?.metric(key).map { clamp01($0) }
    }

    private func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func bytesToGB(_ value: UInt64) -> Double {
        Double(value) / 1_073_741_824.0
    }
}
