import SwiftUI
import PodcastPreviewCore

enum HardwareGraphFocusInsightTarget: String {
    case cpu
    case gpu
    case memory
    case disk
    case network
    case power
    case ane
    case thermals
}

struct HardwareGraphFocusInsightSnapshot {
    let title: String
    let headline: String
    let detail: String
    let accentColor: Color
    let coverageLabel: String
    let contextFacts: [String]
}

struct HardwareGraphFocusInsightProvider {
    let insightsService: HardwareInsightsService
    let refreshAnchor: Date
    let hasNeuralEngine: Bool
    let primaryGPUID: String?
    let gpuCount: Int
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

    func snapshot(
        for target: HardwareGraphFocusInsightTarget,
        window: HardwareInsightWindow,
        gpuContext: HardwareGraphFocusGPUContext? = nil
    ) async -> HardwareGraphFocusInsightSnapshot? {
        switch target {
        case .cpu:
            return await cpuSnapshot(window: window)
        case .gpu:
            return await gpuSnapshot(window: window, gpuContext: gpuContext)
        case .memory:
            return await memorySnapshot(window: window)
        case .disk:
            return await diskSnapshot(window: window)
        case .network:
            return await networkSnapshot(window: window)
        case .power:
            return await powerSnapshot(window: window)
        case .ane:
            return hasNeuralEngine ? await aneSnapshot(window: window) : nil
        case .thermals:
            return await thermalSnapshot(window: window)
        }
    }

    private func cpuSnapshot(window: HardwareInsightWindow) async -> HardwareGraphFocusInsightSnapshot {
        let copywriter = HardwareInsightCopywriter(window: window)
        let cpuTask = Task { await insightsService.metricInsight(for: .cpuTotalUsage, window: window, anchorDate: refreshAnchor) }
        let effTask = Task { await insightsService.metricInsight(for: .cpuEfficiencyUsage, window: window, anchorDate: refreshAnchor) }
        let perfTask = Task { await insightsService.metricInsight(for: .cpuPerformanceUsage, window: window, anchorDate: refreshAnchor) }

        let cpu = await cpuTask.value
        let efficiency = await effTask.value
        let performance = await perfTask.value
        let summary = cpu.summary

        guard hasObservedMetricData(summary) else {
            return placeholderSnapshot(
                title: "CPU Insight",
                accentColor: .blue,
                coverageRatio: summary.coverageRatio,
                headline: "Not enough tracked CPU history",
                detail: "Leave monitoring running longer to surface CPU patterns."
            )
        }

        var details: [String] = [copywriter.cpuLoadDescription(for: summary.averageValue ?? summary.peakValue ?? 0)]
        if let dynamics = copywriter.dynamicsDescription(for: cpu, noun: "CPU") {
            details.append(dynamics)
        }
        if let busiest = busiestSummary(from: cpu, window: window, copywriter: copywriter) {
            details.append(busiest)
        } else if let peakSummary = peakWindowSummary(from: cpu.peakWindow, window: window) {
            details.append("Peaked around \(peakSummary)")
        }
        if cpu.spikeBucketCount > 0 {
            details.append("\(cpu.spikeBucketCount) spike window\(cpu.spikeBucketCount == 1 ? "" : "s")")
        }

        var contextFacts: [String] = []
        if let effAvg = efficiency.summary.averageValue, let perfAvg = performance.summary.averageValue {
            contextFacts.append(String(format: "Efficiency cores averaged %.0f%%, performance cores averaged %.0f%%.", effAvg * 100, perfAvg * 100))
            if effAvg > perfAvg * 1.5 {
                contextFacts.append("Workload leaned heavily on the efficiency cluster.")
            } else if perfAvg > effAvg * 1.5 {
                contextFacts.append("Performance cores carried most of the work.")
            }
        }
        if !perCoreFrequenciesHz.isEmpty && (efficiencyCoreCount > 0 || performanceCoreCount > 0) {
            let pCores = Array(perCoreFrequenciesHz.prefix(performanceCoreCount))
            let eCores = Array(perCoreFrequenciesHz.dropFirst(performanceCoreCount).prefix(efficiencyCoreCount))
            if let eAvg = eCores.isEmpty ? nil : eCores.reduce(0, +) / Double(eCores.count),
               let pAvg = pCores.isEmpty ? nil : pCores.reduce(0, +) / Double(pCores.count) {
                contextFacts.append(String(format: "Current clocks: E-cores %.2f GHz, P-cores %.2f GHz.", eAvg / 1_000_000_000, pAvg / 1_000_000_000))
            }
        }
        if let count = processCount, count > 0 {
            contextFacts.append("Running alongside \(count) active processes at insight time.")
        }
        contextFacts.append(contentsOf: patternContextFacts(for: cpu, noun: "CPU"))
        if let charFact = characterFact(for: cpu, noun: "CPU") {
            contextFacts.append(charFact)
        }

        return HardwareGraphFocusInsightSnapshot(
            title: "CPU Insight",
            headline: joinNonEmpty([
                formatRatio(summary.averageValue).map { "Avg \($0)" },
                formatRatio(summary.peakValue).map { "Peak \($0)" }
            ], separator: " · ") ?? "Tracked CPU usage",
            detail: sentenceJoin(details),
            accentColor: .blue,
            coverageLabel: coverageLabel(for: summary.coverageRatio),
            contextFacts: deduplicatedContextFacts(contextFacts)
        )
    }

    private func gpuSnapshot(
        window: HardwareInsightWindow,
        gpuContext: HardwareGraphFocusGPUContext?
    ) async -> HardwareGraphFocusInsightSnapshot {
        let copywriter = HardwareInsightCopywriter(window: window)
        let selectedGPUID = gpuContext?.deviceID ?? primaryGPUID
        guard let gpuID = selectedGPUID else {
            return placeholderSnapshot(
                title: "GPU Insight",
                accentColor: gpuAccentColor,
                coverageRatio: 0,
                headline: "No GPU history is available",
                detail: "A tracked GPU is needed before GPU insights can appear."
            )
        }

        let mainTask = Task {
            await insightsService.deviceMetricInsight(for: .utilizationRatio, deviceID: gpuID, deviceKind: .gpu, window: window, anchorDate: refreshAnchor)
        }
        let rendererTask = Task {
            await insightsService.deviceMetricInsight(for: .rendererUtilizationRatio, deviceID: gpuID, deviceKind: .gpu, window: window, anchorDate: refreshAnchor)
        }
        let tilerTask = Task {
            await insightsService.deviceMetricInsight(for: .tilerUtilizationRatio, deviceID: gpuID, deviceKind: .gpu, window: window, anchorDate: refreshAnchor)
        }
        let vramTask = Task {
            await insightsService.deviceMetricInsight(for: .vramUsedMegabytes, deviceID: gpuID, deviceKind: .gpu, window: window, anchorDate: refreshAnchor)
        }
        let allocTask = Task {
            await insightsService.deviceMetricInsight(for: .memoryAllocatedMegabytes, deviceID: gpuID, deviceKind: .gpu, window: window, anchorDate: refreshAnchor)
        }

        let main = await mainTask.value
        let renderer = await rendererTask.value
        let tiler = await tilerTask.value
        let vram = await vramTask.value
        let allocated = await allocTask.value
        let summary = main.summary

        guard hasObservedMetricData(summary) else {
            return placeholderSnapshot(
                title: "GPU Insight",
                accentColor: gpuAccentColor,
                coverageRatio: summary.coverageRatio,
                headline: "Not enough tracked GPU history",
                detail: "Leave monitoring running longer to surface GPU patterns."
            )
        }

        var details: [String] = [copywriter.gpuLoadDescription(for: summary.averageValue ?? summary.peakValue ?? 0)]
        let allowSharedGPUAppContext = gpuCount <= 1
        if allowSharedGPUAppContext,
           let appSummary = copywriter.gpuActiveAppsDescription(appNames: gpuActiveAppNames) {
            details.append(appSummary)
        }
        if let dynamics = copywriter.dynamicsDescription(for: main, noun: "GPU") {
            details.append(dynamics)
        }
        let subMetrics: [String] = [
            (hasObservedMetricData(renderer.summary) ? renderer.summary.averageValue : nil).map { "Renderer avg \(Int(($0 * 100).rounded()))%" },
            (hasObservedMetricData(tiler.summary) ? tiler.summary.averageValue : nil).map { "Tiler avg \(Int(($0 * 100).rounded()))%" }
        ].compactMap { $0 }
        if !subMetrics.isEmpty {
            details.append(subMetrics.joined(separator: " · "))
        }
        if let busiest = busiestSummary(from: main, window: window, copywriter: copywriter) {
            details.append(busiest)
        }
        if main.spikeBucketCount > 0 {
            details.append("\(main.spikeBucketCount) spike window\(main.spikeBucketCount == 1 ? "" : "s")")
        }

        var contextFacts: [String] = []
        if let vramAvg = vram.summary.averageValue, let vramPeak = vram.summary.peakValue {
            contextFacts.append(String(format: "VRAM averaged %.0f MB and peaked at %.0f MB.", vramAvg, vramPeak))
        } else if let vramAvg = vram.summary.averageValue {
            contextFacts.append(String(format: "VRAM averaged %.0f MB.", vramAvg))
        }
        if let allocAvg = allocated.summary.averageValue {
            contextFacts.append(String(format: "Allocated GPU memory averaged %.0f MB.", allocAvg))
        }
        if let rendererAvg = renderer.summary.averageValue, let tilerAvg = tiler.summary.averageValue,
           hasObservedMetricData(renderer.summary), hasObservedMetricData(tiler.summary) {
            if rendererAvg > tilerAvg * 2 {
                contextFacts.append("Renderer pressure clearly outpaced the tiler.")
            } else if tilerAvg > rendererAvg * 2 {
                contextFacts.append("Tiler pressure clearly outpaced the renderer.")
            }
        }
        if let media = mediaActivitySummary, media.activityState != .idle {
            var fact = "Media engine activity: \(media.activityState.rawValue)"
            if let codec = media.codec {
                fact += " (\(codec))"
            }
            contextFacts.append(fact + ".")
        }
        if allowSharedGPUAppContext && !gpuActiveAppNames.isEmpty {
            contextFacts.append("Active GPU clients: \(gpuActiveAppNames.prefix(5).joined(separator: ", ")).")
        }
        contextFacts.append(contentsOf: patternContextFacts(for: main, noun: "GPU"))
        if let charFact = characterFact(for: main, noun: "GPU") {
            contextFacts.append(charFact)
        }

        return HardwareGraphFocusInsightSnapshot(
            title: "GPU Insight",
            headline: joinNonEmpty([
                formatRatio(summary.averageValue).map { "Avg \($0)" },
                formatRatio(summary.peakValue).map { "Peak \($0)" }
            ], separator: " · ") ?? "Tracked GPU usage",
            detail: sentenceJoin(details),
            accentColor: gpuAccentColor,
            coverageLabel: coverageLabel(for: summary.coverageRatio),
            contextFacts: deduplicatedContextFacts(contextFacts)
        )
    }

    private func memorySnapshot(window: HardwareInsightWindow) async -> HardwareGraphFocusInsightSnapshot {
        let copywriter = HardwareInsightCopywriter(window: window)
        let memoryTask = Task { await insightsService.metricInsight(for: .ramUsageRatio, window: window, anchorDate: refreshAnchor) }
        let pressureTask = Task { await insightsService.metricInsight(for: .memoryPressureRatio, window: window, anchorDate: refreshAnchor) }
        let appTask = Task { await insightsService.metricInsight(for: .appMemoryGB, window: window, anchorDate: refreshAnchor) }
        let cachedTask = Task { await insightsService.metricInsight(for: .cachedMemoryGB, window: window, anchorDate: refreshAnchor) }
        let compressedTask = Task { await insightsService.metricInsight(for: .compressedMemoryGB, window: window, anchorDate: refreshAnchor) }
        let wiredTask = Task { await insightsService.metricInsight(for: .wiredMemoryGB, window: window, anchorDate: refreshAnchor) }
        let swapTask = Task { await insightsService.metricInsight(for: .swapUsageRatio, window: window, anchorDate: refreshAnchor) }

        let memory = await memoryTask.value
        let pressure = await pressureTask.value
        let appMem = await appTask.value
        let cached = await cachedTask.value
        let compressed = await compressedTask.value
        let wired = await wiredTask.value
        let swap = await swapTask.value

        let memorySummary = memory.summary
        let pressureSummary = pressure.summary
        let usesPressurePrimary = hasObservedMetricData(pressureSummary)
        let primaryInsight = usesPressurePrimary ? pressure : memory
        let primarySummary = usesPressurePrimary ? pressureSummary : memorySummary
        let effectiveCoverage = max(memorySummary.coverageRatio, pressureSummary.coverageRatio)

        guard hasObservedMetricData(memorySummary) || hasObservedMetricData(pressureSummary) else {
            return placeholderSnapshot(
                title: "Memory Insight",
                accentColor: memoryAccentColor,
                coverageRatio: effectiveCoverage,
                headline: "Not enough tracked memory history",
                detail: "Memory pressure summaries appear after more sampled history is retained."
            )
        }

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
            details.append(copywriter.memoryPressureDescription(
                spikeBucketCount: pressure.spikeBucketCount,
                peakValue: pressureSummary.peakValue ?? 0
            ))
        }
        if let dynamics = copywriter.dynamicsDescription(for: primaryInsight, noun: usesPressurePrimary ? "Memory pressure" : "Memory") {
            details.append(dynamics)
        }
        if let busiest = busiestSummary(from: primaryInsight, window: window, copywriter: copywriter) {
            details.append(busiest)
        }

        var contextFacts: [String] = []
        if usesPressurePrimary, let memoryAverage = memorySummary.averageValue {
            contextFacts.append(String(format: "Average RAM occupancy was %.0f%%, but pressure is the better gauge of real strain on macOS.", memoryAverage * 100))
        }
        let breakdownParts: [String] = [
            appMem.summary.averageValue.map { String(format: "App %.1f GB", $0) },
            cached.summary.averageValue.map { String(format: "Cached %.1f GB", $0) },
            compressed.summary.averageValue.map { String(format: "Compressed %.1f GB", $0) },
            wired.summary.averageValue.map { String(format: "Wired %.1f GB", $0) }
        ].compactMap { $0 }
        if !breakdownParts.isEmpty {
            contextFacts.append(breakdownParts.joined(separator: ", ") + ".")
        }
        if let compressionPeak = compressed.summary.peakValue, compressionPeak > 0.5 {
            contextFacts.append(String(format: "Compression peaked at %.1f GB.", compressionPeak))
        }
        if let swapAverage = swap.summary.averageValue, swapAverage > 0.05 {
            contextFacts.append(String(format: "Swap averaged %.0f%%.", swapAverage * 100))
        }
        let topApps = topMemoryRows.prefix(3).filter { $0.ramMB > 50 }
        if !topApps.isEmpty {
            let appDescription = topApps.map { String(format: "%@ %.0f MB", $0.name, $0.ramMB) }.joined(separator: ", ")
            contextFacts.append("Top memory consumers: \(appDescription).")
        }
        contextFacts.append(contentsOf: patternContextFacts(for: primaryInsight, noun: usesPressurePrimary ? "Memory pressure" : "Memory"))
        if let charFact = characterFact(for: primaryInsight, noun: usesPressurePrimary ? "Memory pressure" : "Memory") {
            contextFacts.append(charFact)
        }

        let headline = usesPressurePrimary
            ? (joinNonEmpty([
                formatRatio(primarySummary.averageValue).map { "Avg \($0) pressure" },
                formatRatio(primarySummary.peakValue).map { "Peak \($0)" }
            ], separator: " · ") ?? "Tracked memory pressure")
            : (joinNonEmpty([
                formatRatio(primarySummary.averageValue).map { "Avg \($0) in use" },
                formatRatio(primarySummary.peakValue).map { "Peak \($0)" }
            ], separator: " · ") ?? "Tracked memory usage")

        return HardwareGraphFocusInsightSnapshot(
            title: "Memory Insight",
            headline: headline,
            detail: sentenceJoin(details),
            accentColor: memoryAccentColor,
            coverageLabel: coverageLabel(for: effectiveCoverage),
            contextFacts: deduplicatedContextFacts(contextFacts)
        )
    }

    private func diskSnapshot(window: HardwareInsightWindow) async -> HardwareGraphFocusInsightSnapshot {
        let copywriter = HardwareInsightCopywriter(window: window)
        let readTask = Task { await insightsService.metricInsight(for: .diskReadMBps, window: window, anchorDate: refreshAnchor) }
        let writeTask = Task { await insightsService.metricInsight(for: .diskWriteMBps, window: window, anchorDate: refreshAnchor) }
        let read = await readTask.value
        let write = await writeTask.value
        let readSummary = read.summary
        let writeSummary = write.summary
        let effectiveCoverage = max(readSummary.coverageRatio, writeSummary.coverageRatio)

        guard hasObservedMetricData(readSummary) || hasObservedMetricData(writeSummary) else {
            return placeholderSnapshot(
                title: "Disk Insight",
                accentColor: diskAccentColor,
                coverageRatio: effectiveCoverage,
                headline: "Not enough tracked disk history",
                detail: "Disk read and write summaries will appear after more sampled history is retained."
            )
        }

        let dominantInsight = (readSummary.peakValue ?? 0) >= (writeSummary.peakValue ?? 0) ? read : write
        var details: [String] = [copywriter.diskActivityDescription(
            readAvg: readSummary.averageValue ?? 0,
            writeAvg: writeSummary.averageValue ?? 0
        )]
        if let dynamics = copywriter.dynamicsDescription(for: dominantInsight, noun: "Disk I/O") {
            details.append(dynamics)
        }
        if let busiest = busiestSummary(from: dominantInsight, window: window, copywriter: copywriter) {
            details.append(busiest)
        }
        let totalSpikes = read.spikeBucketCount + write.spikeBucketCount
        if totalSpikes > 0 {
            details.append("\(totalSpikes) high-activity window\(totalSpikes == 1 ? "" : "s")")
        }

        var contextFacts: [String] = []
        let readAverage = readSummary.averageValue ?? 0
        let writeAverage = writeSummary.averageValue ?? 0
        if readAverage > 0 || writeAverage > 0 {
            let averageParts: [String] = [
                readAverage > 0 ? String(format: "Read avg %.1f MB/s", readAverage) : nil,
                writeAverage > 0 ? String(format: "Write avg %.1f MB/s", writeAverage) : nil
            ].compactMap { $0 }
            contextFacts.append(averageParts.joined(separator: ", ") + ".")
            if readAverage > writeAverage * 3 {
                contextFacts.append("The workload was strongly read-dominant.")
            } else if writeAverage > readAverage * 3 {
                contextFacts.append("The workload was strongly write-dominant.")
            }
        }
        if let snapshot = storageSnapshot {
            let usedGB = Double(snapshot.usedBytes) / 1_073_741_824
            let totalGB = Double(snapshot.totalBytes) / 1_073_741_824
            contextFacts.append(String(format: "Drive state: %.0f GB used of %.0f GB.", usedGB, totalGB))
            if let speed = snapshot.speedLabel {
                contextFacts.append("Benchmarked speed: \(speed).")
            }
        }
        contextFacts.append(contentsOf: patternContextFacts(for: dominantInsight, noun: "Disk I/O"))
        if let charFact = characterFact(for: dominantInsight, noun: "Disk I/O") {
            contextFacts.append(charFact)
        }

        return HardwareGraphFocusInsightSnapshot(
            title: "Disk Insight",
            headline: joinNonEmpty([
                formatMBps(readSummary.peakValue).map { "Peak R \($0)" },
                formatMBps(writeSummary.peakValue).map { "W \($0)" }
            ], separator: " · ") ?? "Tracked disk activity",
            detail: sentenceJoin(details),
            accentColor: diskAccentColor,
            coverageLabel: coverageLabel(for: effectiveCoverage),
            contextFacts: deduplicatedContextFacts(contextFacts)
        )
    }

    private func networkSnapshot(window: HardwareInsightWindow) async -> HardwareGraphFocusInsightSnapshot {
        let copywriter = HardwareInsightCopywriter(window: window)
        let uploadTask = Task { await insightsService.metricInsight(for: .networkUploadMBps, window: window, anchorDate: refreshAnchor) }
        let downloadTask = Task { await insightsService.metricInsight(for: .networkDownloadMBps, window: window, anchorDate: refreshAnchor) }
        let latencyTask = Task {
            await insightsService.metricInsight(
                for: .networkPingLatencyMilliseconds,
                window: window,
                anchorDate: refreshAnchor
            )
        }
        let lossTask = Task {
            await insightsService.metricInsight(
                for: .networkPingPacketLossRatio,
                window: window,
                anchorDate: refreshAnchor
            )
        }
        let upload = await uploadTask.value
        let download = await downloadTask.value
        let latency = await latencyTask.value
        let loss = await lossTask.value
        let upSummary = upload.summary
        let downSummary = download.summary
        let latencySummary = latency.summary
        let lossSummary = loss.summary
        let effectiveCoverage = [
            upSummary.coverageRatio,
            downSummary.coverageRatio,
            latencySummary.coverageRatio,
            lossSummary.coverageRatio
        ].max() ?? 0

        guard hasObservedMetricData(upSummary) || hasObservedMetricData(downSummary) else {
            return placeholderSnapshot(
                title: "Network Insight",
                accentColor: networkAccentColor,
                coverageRatio: effectiveCoverage,
                headline: "Not enough tracked network history",
                detail: "Upload and download summaries will appear after more sampled history is retained."
            )
        }

        let dominantInsight = (upSummary.peakValue ?? 0) >= (downSummary.peakValue ?? 0) ? upload : download
        var details: [String] = [copywriter.networkActivityDescription(
            upAvg: upSummary.averageValue ?? 0,
            downAvg: downSummary.averageValue ?? 0
        )]
        if let dynamics = copywriter.dynamicsDescription(for: dominantInsight, noun: "Network") {
            details.append(dynamics)
        }
        if let busiest = busiestSummary(from: dominantInsight, window: window, copywriter: copywriter) {
            details.append(busiest)
        }
        let totalSpikes = upload.spikeBucketCount + download.spikeBucketCount
        if totalSpikes > 0 {
            details.append("\(totalSpikes) high-activity window\(totalSpikes == 1 ? "" : "s")")
        }
        if let averageLatency = formatMilliseconds(latencySummary.averageValue) {
            if let peakLatency = formatMilliseconds(latencySummary.peakValue) {
                details.append("Ping response sat around \(averageLatency), with rougher moments reaching \(peakLatency)")
            } else {
                details.append("Ping response sat around \(averageLatency)")
            }
        }
        if let peakLoss = formatPacketLoss(lossSummary.peakValue), (lossSummary.peakValue ?? 0) > 0.001 {
            details.append("Packet loss peaked at \(peakLoss)")
        }

        var contextFacts: [String] = []
        let upAverage = upSummary.averageValue ?? 0
        let downAverage = downSummary.averageValue ?? 0
        if upAverage > 0 || downAverage > 0 {
            let averageParts: [String] = [
                upAverage > 0 ? String(format: "Upload avg %.1f MB/s", upAverage) : nil,
                downAverage > 0 ? String(format: "Download avg %.1f MB/s", downAverage) : nil
            ].compactMap { $0 }
            contextFacts.append(averageParts.joined(separator: ", ") + ".")
            if downAverage > upAverage * 3 {
                contextFacts.append("Traffic skewed strongly inbound.")
            } else if upAverage > downAverage * 3 {
                contextFacts.append("Traffic skewed strongly outbound.")
            }
        }
        if let averageLatency = formatMilliseconds(latencySummary.averageValue) {
            contextFacts.append("Average ping \(averageLatency).")
        }
        if let peakLatency = formatMilliseconds(latencySummary.peakValue),
           peakLatency != formatMilliseconds(latencySummary.averageValue) {
            contextFacts.append("Worst ping \(peakLatency).")
        }
        if let peakLoss = formatPacketLoss(lossSummary.peakValue) {
            if (lossSummary.peakValue ?? 0) > 0.001 {
                contextFacts.append("Peak packet loss \(peakLoss).")
            } else if hasObservedMetricData(lossSummary) {
                contextFacts.append("No packet loss was observed in the retained probe windows.")
            }
        }
        contextFacts.append(contentsOf: patternContextFacts(for: dominantInsight, noun: "Network"))
        if let charFact = characterFact(for: dominantInsight, noun: "Network") {
            contextFacts.append(charFact)
        }

        return HardwareGraphFocusInsightSnapshot(
            title: "Network Insight",
            headline: joinNonEmpty([
                formatMBps(upSummary.peakValue).map { "Peak ↑ \($0)" },
                formatMBps(downSummary.peakValue).map { "↓ \($0)" }
            ], separator: " · ") ?? "Tracked network activity",
            detail: sentenceJoin(details),
            accentColor: networkAccentColor,
            coverageLabel: coverageLabel(for: effectiveCoverage),
            contextFacts: deduplicatedContextFacts(contextFacts)
        )
    }

    private func powerSnapshot(window: HardwareInsightWindow) async -> HardwareGraphFocusInsightSnapshot {
        let copywriter = HardwareInsightCopywriter(window: window)
        let powerTask = Task { await insightsService.metricInsight(for: .combinedPowerWatts, window: window, anchorDate: refreshAnchor) }
        let thermalTask = Task { await insightsService.metricInsight(for: .thermalLevel, window: window, anchorDate: refreshAnchor) }
        let cpuTask = Task { await insightsService.metricInsight(for: .cpuPowerWatts, window: window, anchorDate: refreshAnchor) }
        let gpuTask = Task { await insightsService.metricInsight(for: .gpuPowerWatts, window: window, anchorDate: refreshAnchor) }
        let aneTask = Task { await insightsService.metricInsight(for: .anePowerWatts, window: window, anchorDate: refreshAnchor) }

        let power = await powerTask.value
        let thermal = await thermalTask.value
        let cpuPower = await cpuTask.value
        let gpuPower = await gpuTask.value
        let anePower = await aneTask.value

        let powerSummary = power.summary
        let thermalSummary = thermal.summary
        let effectiveCoverage = max(powerSummary.coverageRatio, thermalSummary.coverageRatio)

        if hasObservedMetricData(powerSummary) {
            var details: [String] = [copywriter.powerLoadDescription(for: powerSummary.averageValue ?? powerSummary.peakValue ?? 0)]
            if let dynamics = copywriter.dynamicsDescription(for: power, noun: "Power draw") {
                details.append(dynamics)
            }
            if let busiest = busiestSummary(from: power, window: window, copywriter: copywriter) {
                details.append(busiest)
            }
            if power.spikeBucketCount > 0 {
                details.append("\(power.spikeBucketCount) high-draw window\(power.spikeBucketCount == 1 ? "" : "s")")
            }
            if hasObservedMetricData(thermalSummary) {
                details.append(copywriter.thermalDescription(peakLevel: thermalSummary.peakValue ?? 0, spikeBucketCount: thermal.spikeBucketCount))
            }

            var contextFacts: [String] = []
            let breakdownParts: [String] = [
                cpuPower.summary.averageValue.map { String(format: "CPU %.1f W", $0) },
                gpuPower.summary.averageValue.map { String(format: "GPU %.1f W", $0) },
                anePower.summary.averageValue.map { String(format: "ANE %.1f W", $0) }
            ].compactMap { $0 }
            if !breakdownParts.isEmpty {
                contextFacts.append("Average breakdown: " + breakdownParts.joined(separator: ", ") + ".")
            }
            if let cpuAverage = cpuPower.summary.averageValue, let gpuAverage = gpuPower.summary.averageValue {
                if cpuAverage > gpuAverage * 1.5 {
                    contextFacts.append("CPU was the dominant power consumer.")
                } else if gpuAverage > cpuAverage * 1.5 {
                    contextFacts.append("GPU was the dominant power consumer.")
                }
            }
            if let uptime = uptimeSeconds, uptime > 60 {
                let hours = Int(uptime) / 3600
                let minutes = (Int(uptime) % 3600) / 60
                contextFacts.append("System uptime at insight time: \(hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m").")
            }
            if cumulativeEnergyWh > 0.01 {
                let elapsed = refreshAnchor.timeIntervalSince(appLaunchDate)
                let hours = elapsed / 3600
                if hours >= 0.05 {
                    let averageWatts = cumulativeEnergyWh / max(hours, 0.01)
                    contextFacts.append(String(format: "Tracked %.2f Wh over this %.1fh %@ (avg %.1f W).", cumulativeEnergyWh, hours, sessionContextNoun, averageWatts))
                } else {
                    contextFacts.append(String(format: "Tracked %.2f Wh since %@ began.", cumulativeEnergyWh, sessionContextNoun))
                }
            }
            let sessionMinutes = Int(refreshAnchor.timeIntervalSince(appLaunchDate) / 60)
            if sessionMinutes >= 5 {
                let hours = sessionMinutes / 60
                let minutes = sessionMinutes % 60
                contextFacts.append("\(sessionSummaryLabel) for \(hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m").")
            }
            contextFacts.append(contentsOf: patternContextFacts(for: power, noun: "Power draw"))
            if let charFact = characterFact(for: power, noun: "Power draw") {
                contextFacts.append(charFact)
            }

            return HardwareGraphFocusInsightSnapshot(
                title: "Power Insight",
                headline: joinNonEmpty([
                    formatWatts(powerSummary.averageValue).map { "Avg \($0)" },
                    formatWatts(powerSummary.peakValue).map { "Peak \($0)" }
                ], separator: " · ") ?? "Tracked power draw",
                detail: sentenceJoin(details),
                accentColor: .orange,
                coverageLabel: coverageLabel(for: effectiveCoverage),
                contextFacts: deduplicatedContextFacts(contextFacts)
            )
        }

        return await thermalSnapshot(window: window)
    }

    private func thermalSnapshot(window: HardwareInsightWindow) async -> HardwareGraphFocusInsightSnapshot {
        let copywriter = HardwareInsightCopywriter(window: window)
        let thermal = await insightsService.metricInsight(for: .thermalLevel, window: window, anchorDate: refreshAnchor)
        let summary = thermal.summary

        guard hasObservedMetricData(summary) else {
            return placeholderSnapshot(
                title: "Thermal Insight",
                accentColor: thermalAccentColor,
                coverageRatio: summary.coverageRatio,
                headline: "Not enough tracked thermal history",
                detail: "Thermal summaries will appear after more sampled history is retained."
            )
        }

        var details: [String] = [copywriter.thermalDescription(peakLevel: summary.peakValue ?? 0, spikeBucketCount: thermal.spikeBucketCount)]
        if let busiest = busiestSummary(from: thermal, window: window, copywriter: copywriter) {
            details.append(busiest)
        }

        var contextFacts = patternContextFacts(for: thermal, noun: "Thermals")
        if let charFact = characterFact(for: thermal, noun: "Thermals") {
            contextFacts.append(charFact)
        }

        return HardwareGraphFocusInsightSnapshot(
            title: "Thermal Insight",
            headline: copywriter.thermalHeadline(for: summary.averageValue ?? summary.peakValue ?? 0),
            detail: sentenceJoin(details),
            accentColor: thermalAccentColor,
            coverageLabel: coverageLabel(for: summary.coverageRatio),
            contextFacts: deduplicatedContextFacts(contextFacts)
        )
    }

    private func aneSnapshot(window: HardwareInsightWindow) async -> HardwareGraphFocusInsightSnapshot {
        let copywriter = HardwareInsightCopywriter(window: window)
        let activityTask = Task { await insightsService.metricInsight(for: .aneActivityRatio, window: window, anchorDate: refreshAnchor) }
        let clientTask = Task { await insightsService.metricInsight(for: .aneClientCount, window: window, anchorDate: refreshAnchor) }
        let activity = await activityTask.value
        let clientCount = await clientTask.value
        let summary = activity.summary

        guard hasObservedMetricData(summary) else {
            return placeholderSnapshot(
                title: "ANE Insight",
                accentColor: aneAccentColor,
                coverageRatio: summary.coverageRatio,
                headline: "Not enough tracked ANE history",
                detail: "Neural Engine summaries will appear after more sampled history is retained."
            )
        }

        var details: [String] = [copywriter.aneLoadDescription(for: summary.averageValue ?? summary.peakValue ?? 0)]
        if let dynamics = copywriter.dynamicsDescription(for: activity, noun: "Neural Engine") {
            details.append(dynamics)
        }
        if let busiest = busiestSummary(from: activity, window: window, copywriter: copywriter) {
            details.append(busiest)
        }
        if activity.spikeBucketCount > 0 {
            details.append("\(activity.spikeBucketCount) high-activity window\(activity.spikeBucketCount == 1 ? "" : "s")")
        }

        var contextFacts: [String] = []
        if let averageClients = clientCount.summary.averageValue, averageClients >= 1 {
            contextFacts.append(String(format: "Averaged %.1f concurrent ML client\(averageClients < 1.5 ? "" : "s").", averageClients))
        }
        if let peakClients = clientCount.summary.peakValue, peakClients >= 2 {
            contextFacts.append(String(format: "Peak concurrent clients: %.0f.", peakClients))
        }
        contextFacts.append(contentsOf: patternContextFacts(for: activity, noun: "Neural Engine"))
        if let charFact = characterFact(for: activity, noun: "Neural Engine") {
            contextFacts.append(charFact)
        }

        return HardwareGraphFocusInsightSnapshot(
            title: "Neural Engine Insight",
            headline: joinNonEmpty([
                formatRatio(summary.averageValue).map { "Avg \($0)" },
                formatRatio(summary.peakValue).map { "Peak \($0)" }
            ], separator: " · ") ?? "Tracked ANE activity",
            detail: sentenceJoin(details),
            accentColor: aneAccentColor,
            coverageLabel: coverageLabel(for: summary.coverageRatio),
            contextFacts: deduplicatedContextFacts(contextFacts)
        )
    }

    private func placeholderSnapshot(
        title: String,
        accentColor: Color,
        coverageRatio: Double,
        headline: String,
        detail: String
    ) -> HardwareGraphFocusInsightSnapshot {
        HardwareGraphFocusInsightSnapshot(
            title: title,
            headline: headline,
            detail: detail,
            accentColor: accentColor,
            coverageLabel: coverageLabel(for: coverageRatio),
            contextFacts: []
        )
    }

    private func hasObservedMetricData(_ summary: HardwareHistoryMetricSummary) -> Bool {
        summary.averageValue != nil || summary.peakValue != nil || summary.lastValue != nil
    }

    private func coverageLabel(for coverageRatio: Double) -> String {
        guard coverageRatio > 0 else { return "Warm-up" }
        return "\(Int((coverageRatio * 100).rounded()))% seen"
    }

    private func formatRatio(_ value: Double?) -> String? {
        guard let value else { return nil }
        return "\(Int((value * 100).rounded()))%"
    }

    private func formatWatts(_ value: Double?) -> String? {
        guard let value else { return nil }
        return value >= 10 ? String(format: "%.1f W", value) : String(format: "%.2f W", value)
    }

    private func formatMBps(_ value: Double?) -> String? {
        guard let value, value > 0.001 else { return nil }
        if value >= 1000 { return String(format: "%.1f GB/s", value / 1000.0) }
        if value >= 1 { return String(format: "%.1f MB/s", value) }
        return String(format: "%.0f KB/s", value * 1024)
    }

    private func formatMilliseconds(_ value: Double?) -> String? {
        guard let value else { return nil }
        if value >= 100 {
            return String(format: "%.0f ms", value)
        }
        return String(format: "%.1f ms", value)
    }

    private func formatPacketLoss(_ value: Double?) -> String? {
        guard let value else { return nil }
        return String(format: "%.1f%%", value * 100.0)
    }

    private func joinNonEmpty(_ components: [String?], separator: String) -> String? {
        let filtered = components.compactMap { $0 }.filter { !$0.isEmpty }
        guard !filtered.isEmpty else { return nil }
        return filtered.joined(separator: separator)
    }

    private func sentenceJoin(_ components: [String?]) -> String {
        let trimmed = components
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return "More tracked history is needed to generate a useful summary." }
        return trimmed.joined(separator: ". ") + "."
    }

    private func deduplicatedContextFacts(_ facts: [String]) -> [String] {
        var seen: Set<String> = []
        return facts.filter { seen.insert($0).inserted }
    }

    private func busiestSummary(
        from insight: HardwareMetricInsight,
        window: HardwareInsightWindow,
        copywriter: HardwareInsightCopywriter
    ) -> String? {
        copywriter.busiestSummary(
            daypartLabel: insight.busiestDaypart.map(displayLabel(for:)),
            formattedHour: insight.busiestHourOfDay.map(formatHour)
        )
    }

    private func peakWindowSummary(from peakWindow: HardwareInsightPeakWindow?, window: HardwareInsightWindow) -> String? {
        guard let peakWindow else { return nil }

        if #available(macOS 12, *) {
            switch window {
            case .daily:
                return peakWindow.bucketStart.formatted(.dateTime.hour().minute())
            case .weekly, .monthly:
                return peakWindow.bucketStart.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            @unknown default:
                return peakWindow.bucketStart.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            }
        } else {
            let formatter = DateFormatter()
            switch window {
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

    private func displayLabel(for daypart: HardwareInsightDaypart) -> String {
        switch daypart {
        case .overnight:
            return "overnight"
        case .morning:
            return "morning"
        case .afternoon:
            return "afternoon"
        case .evening:
            return "evening"
        @unknown default:
            return daypart.rawValue
        }
    }

    private func patternContextFacts(for insight: HardwareMetricInsight, noun: String) -> [String] {
        var facts: [String] = []

        switch insight.trendDirection {
        case .rising:
            facts.append("\(noun) ramped up as the window progressed.")
        case .falling:
            facts.append("\(noun) did more of its work early and eased off later.")
        case .oscillating:
            facts.append("\(noun) swung around instead of holding a clean line.")
        case .flat:
            break
        @unknown default:
            break
        }

        switch insight.activityCadence {
        case .quiet:
            if insight.longestIdleStreak >= 3 {
                facts.append("Longest quiet streak covered \(insight.longestIdleStreak) well-covered buckets.")
            }
        case .bursty:
            if let variability = insight.variabilityRatio, variability >= 0.45 {
                facts.append("Activity was highly bursty rather than sustained.")
            }
        case .steady:
            if let variability = insight.variabilityRatio, variability <= 0.12, insight.summary.observedBucketCount >= 6 {
                facts.append("The trace stayed unusually steady for most of the window.")
            }
        case .sustained:
            if insight.longestSpikeStreak >= 2 {
                facts.append("Longest sustained high-load run covered \(insight.longestSpikeStreak) buckets.")
            }
        @unknown default:
            break
        }

        if let peakRecency = insight.peakRecencyRatio {
            if peakRecency >= 0.75 {
                facts.append("The biggest peak happened late in the selected window.")
            } else if peakRecency <= 0.25 {
                facts.append("The biggest peak happened early in the selected window.")
            }
        }

        return facts
    }

    private func characterFact(for insight: HardwareMetricInsight, noun: String) -> String? {
        let observed = insight.summary.observedBucketCount
        guard observed >= 4 else { return nil }

        let idleRatio = Double(insight.idleBucketCount) / Double(observed)
        let spikeRatio = Double(insight.spikeBucketCount) / Double(observed)

        if idleRatio >= 0.75 {
            return "\(noun) spent most of this window near idle."
        } else if idleRatio >= 0.50 {
            return "\(noun) logged more downtime than active time."
        } else if spikeRatio >= 0.60 {
            return "\(noun) was pinned near its ceiling for much of the window."
        } else if spikeRatio >= 0.35 {
            return "\(noun) ran hard for a large portion of the window."
        }

        return nil
    }

    private var gpuAccentColor: Color {
        Color(red: 0.85, green: 0.20, blue: 0.20)
    }

    private var memoryAccentColor: Color {
        if #available(macOS 12, *) {
            return .mint
        }
        return Color(red: 0.0, green: 0.78, blue: 0.58)
    }

    private var diskAccentColor: Color {
        .diskWriteAccentColor
    }

    private var networkAccentColor: Color {
        Color.networkAccentColor
    }

    private var aneAccentColor: Color {
        Color(red: 0.65, green: 0.00, blue: 0.65)
    }

    private var thermalAccentColor: Color {
        Color(red: 0.02, green: 0.65, blue: 0.65)
    }
}
