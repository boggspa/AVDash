import SwiftUI
import PodcastPreviewCore

enum HardwareGraphFocusHeatmapTarget: String {
    case overall
    case cpu
    case gpu
    case memory
    case disk
    case network
    case power
    case ane
    case thermals
}

struct HardwareGraphFocusHeatmapProvider {
    let historyReader: any HardwareHistoryQuerying
    let primaryGPUID: String?
    var columnCount: Int = 30

    func snapshot(
        for target: HardwareGraphFocusHeatmapTarget,
        gpuContext: HardwareGraphFocusGPUContext? = nil,
        anchorDate: Date
    ) async -> HardwareGraphFocusHeatmapSnapshot? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: anchorDate)
        let startDay = calendar.date(byAdding: .day, value: -(max(columnCount, 1) - 1), to: today) ?? today
        let range = DateInterval(start: startDay, end: anchorDate)
        let formatter = DateFormatter()
        formatter.dateFormat = columnCount > 14 ? "MMM d" : "EEE"

        if target == .overall {
            let columns = await overallColumns(in: range, startDay: startDay, calendar: calendar)
            return HardwareGraphFocusHeatmapSnapshot(
                metricLabel: target.heatmapMetricLabel,
                columns: columns,
                startLabel: formatter.string(from: startDay),
                endLabel: formatter.string(from: today)
            )
        }

        if target == .network {
            let columns = await networkColumns(in: range, startDay: startDay, calendar: calendar)
            return HardwareGraphFocusHeatmapSnapshot(
                metricLabel: target.heatmapMetricLabel,
                columns: columns,
                startLabel: formatter.string(from: startDay),
                endLabel: formatter.string(from: today)
            )
        }

        let resolvedGPUID = gpuContext?.deviceID ?? primaryGPUID
        let buckets = await buckets(for: target, gpuDeviceID: resolvedGPUID, in: range)
        guard !(buckets.isEmpty && target == .gpu) || resolvedGPUID != nil else { return nil }

        let normalizedColumns = normalizedColumns(from: buckets, startDay: startDay, calendar: calendar)

        return HardwareGraphFocusHeatmapSnapshot(
            metricLabel: target.heatmapMetricLabel,
            columns: normalizedColumns.enumerated().map { dayIndex, column in
                column.enumerated().map { hour, intensity in
                    HardwareGraphFocusHeatmapCell(
                        intensity: intensity,
                        color: heatmapCellColor(for: intensity, accent: target.heatmapAccentColor),
                        slotStart: slotStart(forDayIndex: dayIndex, hour: hour, startDay: startDay, calendar: calendar)
                    )
                }
            },
            startLabel: formatter.string(from: startDay),
            endLabel: formatter.string(from: today)
        )
    }

    private func buckets(
        for target: HardwareGraphFocusHeatmapTarget,
        gpuDeviceID: String?,
        in range: DateInterval
    ) async -> [HardwareHistoryMetricBucket] {
        switch target {
        case .overall:
            return []
        case .cpu:
            return await historyReader.metricTimeline(
                for: .cpuTotalUsage,
                in: range,
                bucketIntervalSeconds: 3600
            )
        case .gpu:
            guard let gpuDeviceID else { return [] }
            return await historyReader.deviceMetricTimeline(
                for: .utilizationRatio,
                deviceID: gpuDeviceID,
                deviceKind: .gpu,
                in: range,
                bucketIntervalSeconds: 3600
            )
        case .memory:
            return await historyReader.metricTimeline(
                for: .memoryPressureRatio,
                in: range,
                bucketIntervalSeconds: 3600
            )
        case .disk:
            let read = await historyReader.metricTimeline(
                for: .diskReadMBps,
                in: range,
                bucketIntervalSeconds: 3600
            )
            let write = await historyReader.metricTimeline(
                for: .diskWriteMBps,
                in: range,
                bucketIntervalSeconds: 3600
            )
            return combinedBuckets(read, write)
        case .network:
            let upload = await historyReader.metricTimeline(
                for: .networkUploadMBps,
                in: range,
                bucketIntervalSeconds: 3600
            )
            let download = await historyReader.metricTimeline(
                for: .networkDownloadMBps,
                in: range,
                bucketIntervalSeconds: 3600
            )
            return combinedBuckets(upload, download)
        case .power:
            return await historyReader.metricTimeline(
                for: .combinedPowerWatts,
                in: range,
                bucketIntervalSeconds: 3600
            )
        case .ane:
            return await historyReader.metricTimeline(
                for: .aneActivityRatio,
                in: range,
                bucketIntervalSeconds: 3600
            )
        case .thermals:
            return await historyReader.metricTimeline(
                for: .thermalLevel,
                in: range,
                bucketIntervalSeconds: 3600
            )
        }
    }

    private func overallColumns(
        in range: DateInterval,
        startDay: Date,
        calendar: Calendar
    ) async -> [[HardwareGraphFocusHeatmapCell]] {
        let days = max(columnCount, 1)
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

        let gpuTimeline: [HardwareHistoryMetricBucket]
        if let primaryGPUID {
            gpuTimeline = await historyReader.deviceMetricTimeline(
                for: .utilizationRatio,
                deviceID: primaryGPUID,
                deviceKind: .gpu,
                in: range,
                bucketIntervalSeconds: 3600
            )
        } else {
            gpuTimeline = []
        }

        let emptyCell = OverallHeatmapCell(gpu: primaryGPUID != nil ? 0 : nil)
        var compositeCells = Array(
            repeating: Array(repeating: emptyCell, count: 24),
            count: days
        )

        apply(normalizedRatioBuckets(cpuTimeline), to: &compositeCells, calendar: calendar, startDay: startDay) {
            $0.cpu = $1
        }
        apply(normalizedRatioBuckets(memoryTimeline), to: &compositeCells, calendar: calendar, startDay: startDay) {
            $0.memory = $1
        }
        apply(normalizedAbsoluteBuckets(powerTimeline), to: &compositeCells, calendar: calendar, startDay: startDay) {
            $0.power = $1
        }
        apply(
            normalizedNetworkBuckets(
                uploadTimeline: networkUploadTimeline,
                downloadTimeline: networkDownloadTimeline,
                latencyTimeline: await historyReader.metricTimeline(
                    for: .networkPingLatencyMilliseconds,
                    in: range,
                    bucketIntervalSeconds: 3600
                ),
                lossTimeline: await historyReader.metricTimeline(
                    for: .networkPingPacketLossRatio,
                    in: range,
                    bucketIntervalSeconds: 3600
                )
            ),
            to: &compositeCells,
            calendar: calendar,
            startDay: startDay
        ) {
            $0.network = $1
        }
        if primaryGPUID != nil {
            apply(normalizedRatioBuckets(gpuTimeline), to: &compositeCells, calendar: calendar, startDay: startDay) {
                $0.gpu = $1
            }
        }

        return compositeCells.enumerated().map { dayIndex, column in
            column.enumerated().map { hour, cell in
                HardwareGraphFocusHeatmapCell(
                    intensity: cell.displayIntensity,
                    color: overallCellColor(cell),
                    slotStart: slotStart(forDayIndex: dayIndex, hour: hour, startDay: startDay, calendar: calendar)
                )
            }
        }
    }

    private func networkColumns(
        in range: DateInterval,
        startDay: Date,
        calendar: Calendar
    ) async -> [[HardwareGraphFocusHeatmapCell]] {
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

        let normalizedColumns = columns(
            from: normalizedNetworkBuckets(
                uploadTimeline: uploadTimeline,
                downloadTimeline: downloadTimeline,
                latencyTimeline: latencyTimeline,
                lossTimeline: lossTimeline
            ),
            startDay: startDay,
            calendar: calendar
        )

        return normalizedColumns.enumerated().map { dayIndex, column in
            column.enumerated().map { hour, intensity in
                HardwareGraphFocusHeatmapCell(
                    intensity: intensity,
                    color: heatmapCellColor(
                        for: intensity,
                        accent: HardwareGraphFocusHeatmapTarget.network.heatmapAccentColor
                    ),
                    slotStart: slotStart(forDayIndex: dayIndex, hour: hour, startDay: startDay, calendar: calendar)
                )
            }
        }
    }

    func drillDownSnapshot(
        for target: HardwareGraphFocusHeatmapTarget,
        slotStart: Date,
        gpuContext: HardwareGraphFocusGPUContext? = nil,
        anchorDate: Date
    ) async -> HardwareGraphFocusHeatmapDrillDownSnapshot? {
        let slotEnd = min(slotStart.addingTimeInterval(3600), anchorDate)
        guard slotEnd > slotStart else { return nil }

        let range = DateInterval(start: slotStart, end: slotEnd)
        let slotFormatter = DateFormatter()
        slotFormatter.dateFormat = "MMM d · h a"

        switch target {
        case .overall:
            return await overallDrillDownSnapshot(in: range, slotLabel: slotFormatter.string(from: slotStart), gpuContext: gpuContext)
        case .cpu:
            let timeline = await historyReader.metricTimeline(for: .cpuTotalUsage, in: range, bucketIntervalSeconds: 60)
            return drillDownSnapshot(
                title: "Selected Hour",
                subtitle: "CPU activity for \(slotFormatter.string(from: slotStart))",
                series: [
                    makeSeries(
                        id: "cpu-hour",
                        label: "CPU",
                        color: target.heatmapAccentColor,
                        values: normalizedRatioSeries(from: timeline, in: range)
                    )
                ],
                stats: minuteDrillDownStats(label: "CPU", range: range, timeline: timeline, tint: target.heatmapAccentColor),
                detailLines: [
                    "Each point represents one minute within the selected hour.",
                    "CPU usage stays in native ratio space, so peaks map directly to the busier minutes."
                ]
            )
        case .gpu:
            guard let gpuDeviceID = gpuContext?.deviceID ?? primaryGPUID else { return nil }
            let timeline = await historyReader.deviceMetricTimeline(
                for: .utilizationRatio,
                deviceID: gpuDeviceID,
                deviceKind: .gpu,
                in: range,
                bucketIntervalSeconds: 60
            )
            return drillDownSnapshot(
                title: "Selected Hour",
                subtitle: "\(gpuContext?.modelName ?? "GPU") activity for \(slotFormatter.string(from: slotStart))",
                series: [
                    makeSeries(
                        id: "gpu-hour",
                        label: gpuContext?.modelName ?? "GPU",
                        color: target.heatmapAccentColor,
                        values: normalizedRatioSeries(from: timeline, in: range)
                    )
                ],
                stats: minuteDrillDownStats(label: "GPU", range: range, timeline: timeline, tint: target.heatmapAccentColor),
                detailLines: [
                    "This drill-down stays pinned to the currently selected GPU.",
                    "Each point represents one minute within the selected hour."
                ]
            )
        case .memory:
            let timeline = await historyReader.metricTimeline(for: .memoryPressureRatio, in: range, bucketIntervalSeconds: 60)
            return drillDownSnapshot(
                title: "Selected Hour",
                subtitle: "Memory pressure for \(slotFormatter.string(from: slotStart))",
                series: [
                    makeSeries(
                        id: "memory-hour",
                        label: "Memory",
                        color: target.heatmapAccentColor,
                        values: normalizedRatioSeries(from: timeline, in: range)
                    )
                ],
                stats: minuteDrillDownStats(label: "Memory", range: range, timeline: timeline, tint: target.heatmapAccentColor),
                detailLines: [
                    "Higher values mean the machine was pushing harder against memory headroom.",
                    "Each point represents one minute within the selected hour."
                ]
            )
        case .disk:
            let readTimeline = await historyReader.metricTimeline(for: .diskReadMBps, in: range, bucketIntervalSeconds: 60)
            let writeTimeline = await historyReader.metricTimeline(for: .diskWriteMBps, in: range, bucketIntervalSeconds: 60)
            return drillDownSnapshot(
                title: "Selected Hour",
                subtitle: "Disk I/O for \(slotFormatter.string(from: slotStart))",
                series: [
                    makeSeries(id: "disk-read-hour", label: "Read", color: Color(red: 0.72, green: 0.72, blue: 0.56), values: normalizedPeakSeries(from: readTimeline, in: range)),
                    makeSeries(id: "disk-write-hour", label: "Write", color: .diskWriteAccentColor, values: normalizedPeakSeries(from: writeTimeline, in: range))
                ],
                stats: minuteDrillDownStats(
                    label: "Disk",
                    range: range,
                    timeline: combinedBuckets(readTimeline, writeTimeline),
                    tint: target.heatmapAccentColor
                ),
                detailLines: [
                    "Read and write lines are normalized independently so short bursts still stay visible.",
                    "Each point represents one minute within the selected hour."
                ]
            )
        case .network:
            let uploadTimeline = await historyReader.metricTimeline(for: .networkUploadMBps, in: range, bucketIntervalSeconds: 60)
            let downloadTimeline = await historyReader.metricTimeline(for: .networkDownloadMBps, in: range, bucketIntervalSeconds: 60)
            let latencyTimeline = await historyReader.metricTimeline(for: .networkPingLatencyMilliseconds, in: range, bucketIntervalSeconds: 60)
            let lossTimeline = await historyReader.metricTimeline(for: .networkPingPacketLossRatio, in: range, bucketIntervalSeconds: 60)
            return drillDownSnapshot(
                title: "Selected Hour",
                subtitle: "Network behavior for \(slotFormatter.string(from: slotStart))",
                series: [
                    makeSeries(id: "network-upload-hour", label: "Upload", color: .networkAccentColor, values: normalizedPeakSeries(from: uploadTimeline, in: range)),
                    makeSeries(id: "network-download-hour", label: "Download", color: .networkAccentColorDimmed, values: normalizedPeakSeries(from: downloadTimeline, in: range)),
                    makeSeries(id: "network-latency-hour", label: "Latency", color: Color(red: 0.80, green: 0.58, blue: 0.22), values: normalizedLatencySeries(from: latencyTimeline, in: range)),
                    makeSeries(id: "network-loss-hour", label: "Loss", color: Color(red: 0.92, green: 0.33, blue: 0.33), values: normalizedPacketLossSeries(from: lossTimeline, in: range))
                ],
                stats: minuteDrillDownStats(
                    label: "Network",
                    range: range,
                    timeline: combinedBuckets(uploadTimeline, downloadTimeline),
                    tint: target.heatmapAccentColor,
                    extraStats: [
                        latencyTimeline.compactMap(\.averageValue).last.map { HardwareGraphFocusStat(label: "RTT", value: String(format: "%.0f ms", $0)) },
                        lossTimeline.compactMap(\.averageValue).last.map { HardwareGraphFocusStat(label: "Loss", value: String(format: "%.1f%%", $0 * 100.0)) }
                    ].compactMap { $0 }
                ),
                detailLines: [
                    "Upload and download show traffic volume; latency and loss show link quality when a probe landed in this hour.",
                    "The quality probes run every 30 minutes, so those lines are intentionally sparse."
                ]
            )
        case .power:
            let timeline = await historyReader.metricTimeline(for: .combinedPowerWatts, in: range, bucketIntervalSeconds: 60)
            return drillDownSnapshot(
                title: "Selected Hour",
                subtitle: "Power draw for \(slotFormatter.string(from: slotStart))",
                series: [
                    makeSeries(
                        id: "power-hour",
                        label: "Power",
                        color: target.heatmapAccentColor,
                        values: normalizedPeakSeries(from: timeline, in: range)
                    )
                ],
                stats: minuteDrillDownStats(label: "Power", range: range, timeline: timeline, tint: target.heatmapAccentColor),
                detailLines: [
                    "Power is normalized within the selected hour so short bursts remain visible.",
                    "Each point represents one minute within the selected hour."
                ]
            )
        case .ane:
            let timeline = await historyReader.metricTimeline(for: .aneActivityRatio, in: range, bucketIntervalSeconds: 60)
            return drillDownSnapshot(
                title: "Selected Hour",
                subtitle: "ANE activity for \(slotFormatter.string(from: slotStart))",
                series: [
                    makeSeries(
                        id: "ane-hour",
                        label: "ANE",
                        color: target.heatmapAccentColor,
                        values: normalizedRatioSeries(from: timeline, in: range)
                    )
                ],
                stats: minuteDrillDownStats(label: "ANE", range: range, timeline: timeline, tint: target.heatmapAccentColor),
                detailLines: [
                    "Each point represents one minute within the selected hour.",
                    "Higher values mean the Neural Engine stayed more occupied."
                ]
            )
        case .thermals:
            let timeline = await historyReader.metricTimeline(for: .thermalLevel, in: range, bucketIntervalSeconds: 60)
            return drillDownSnapshot(
                title: "Selected Hour",
                subtitle: "Thermal load for \(slotFormatter.string(from: slotStart))",
                series: [
                    makeSeries(
                        id: "thermal-hour",
                        label: "Thermals",
                        color: target.heatmapAccentColor,
                        values: normalizedPeakSeries(from: timeline, in: range)
                    )
                ],
                stats: minuteDrillDownStats(label: "Thermals", range: range, timeline: timeline, tint: target.heatmapAccentColor),
                detailLines: [
                    "Thermal level is normalized inside the hour so warmer spells are easier to spot.",
                    "Each point represents one minute within the selected hour."
                ]
            )
        }
    }

    private func normalizedColumns(
        from buckets: [HardwareHistoryMetricBucket],
        startDay: Date,
        calendar: Calendar
    ) -> [[Double]] {
        let days = max(columnCount, 1)
        var rawCells = Array(repeating: Array<Double?>(repeating: nil, count: 24), count: days)
        var perDayPeaks = Array(repeating: 0.0, count: days)

        for bucket in buckets {
            guard bucket.coverageRatio >= 0.1, let averageValue = bucket.averageValue else { continue }

            let dayStart = calendar.startOfDay(for: bucket.bucketStart)
            let dayIndex = calendar.dateComponents([.day], from: startDay, to: dayStart).day ?? -1
            let hour = calendar.component(.hour, from: bucket.bucketStart)

            guard dayIndex >= 0, dayIndex < days else { continue }
            guard hour >= 0, hour < 24 else { continue }

            let value = max(averageValue, 0.0)
            rawCells[dayIndex][hour] = max(rawCells[dayIndex][hour] ?? 0.0, value)
            perDayPeaks[dayIndex] = max(perDayPeaks[dayIndex], value)
        }

        return zip(rawCells, perDayPeaks).map { dayValues, peak in
            let normalizedPeak = max(peak, 0.01)
            return dayValues.map { value in
                guard let value else { return 0.0 }
                return min(max(value / normalizedPeak, 0.0), 1.0)
            }
        }
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

    private func columns(
        from normalizedBuckets: [NormalizedBucketValue],
        startDay: Date,
        calendar: Calendar
    ) -> [[Double]] {
        let days = max(columnCount, 1)
        var result = Array(repeating: Array(repeating: 0.0, count: 24), count: days)

        for bucket in normalizedBuckets {
            let dayStart = calendar.startOfDay(for: bucket.bucketStart)
            let dayIndex = calendar.dateComponents([.day], from: startDay, to: dayStart).day ?? -1
            let hour = calendar.component(.hour, from: bucket.bucketStart)

            guard dayIndex >= 0, dayIndex < days else { continue }
            guard hour >= 0, hour < 24 else { continue }
            result[dayIndex][hour] = max(result[dayIndex][hour], min(max(bucket.value, 0.0), 1.0))
        }

        return result
    }

    private func overallDrillDownSnapshot(
        in range: DateInterval,
        slotLabel: String,
        gpuContext: HardwareGraphFocusGPUContext?
    ) async -> HardwareGraphFocusHeatmapDrillDownSnapshot {
        let cpuTimeline = await historyReader.metricTimeline(for: .cpuTotalUsage, in: range, bucketIntervalSeconds: 60)
        let memoryTimeline = await historyReader.metricTimeline(for: .memoryPressureRatio, in: range, bucketIntervalSeconds: 60)
        let powerTimeline = await historyReader.metricTimeline(for: .combinedPowerWatts, in: range, bucketIntervalSeconds: 60)
        let uploadTimeline = await historyReader.metricTimeline(for: .networkUploadMBps, in: range, bucketIntervalSeconds: 60)
        let downloadTimeline = await historyReader.metricTimeline(for: .networkDownloadMBps, in: range, bucketIntervalSeconds: 60)
        let latencyTimeline = await historyReader.metricTimeline(for: .networkPingLatencyMilliseconds, in: range, bucketIntervalSeconds: 60)
        let lossTimeline = await historyReader.metricTimeline(for: .networkPingPacketLossRatio, in: range, bucketIntervalSeconds: 60)

        let gpuTimeline: [HardwareHistoryMetricBucket]
        if let gpuDeviceID = gpuContext?.deviceID ?? primaryGPUID {
            gpuTimeline = await historyReader.deviceMetricTimeline(
                for: .utilizationRatio,
                deviceID: gpuDeviceID,
                deviceKind: .gpu,
                in: range,
                bucketIntervalSeconds: 60
            )
        } else {
            gpuTimeline = []
        }

        let combinedNetworkTimeline = combinedBuckets(uploadTimeline, downloadTimeline)

        return HardwareGraphFocusHeatmapDrillDownSnapshot(
            title: "Selected Hour",
            subtitle: "All hardware activity for \(slotLabel)",
            series: [
                makeSeries(id: "overall-cpu-hour", label: "CPU", color: HardwareGraphFocusHeatmapTarget.cpu.heatmapAccentColor, values: normalizedRatioSeries(from: cpuTimeline, in: range)),
                makeSeries(id: "overall-gpu-hour", label: "GPU", color: HardwareGraphFocusHeatmapTarget.gpu.heatmapAccentColor, values: normalizedRatioSeries(from: gpuTimeline, in: range)),
                makeSeries(id: "overall-memory-hour", label: "Memory", color: HardwareGraphFocusHeatmapTarget.memory.heatmapAccentColor, values: normalizedRatioSeries(from: memoryTimeline, in: range)),
                makeSeries(id: "overall-power-hour", label: "Power", color: HardwareGraphFocusHeatmapTarget.power.heatmapAccentColor, values: normalizedPeakSeries(from: powerTimeline, in: range)),
                makeSeries(
                    id: "overall-network-hour",
                    label: "Network",
                    color: HardwareGraphFocusHeatmapTarget.network.heatmapAccentColor,
                    values: normalizedBucketSeries(
                        from: mergedNormalizedBuckets([
                            normalizedCombinedAbsoluteBuckets(uploadTimeline, downloadTimeline),
                            normalizedLatencyBuckets(latencyTimeline),
                            normalizedPacketLossBuckets(lossTimeline)
                        ]),
                        in: range
                    )
                )
            ],
            stats: minuteDrillDownStats(label: "All", range: range, timeline: combinedNetworkTimeline, tint: .white),
            detailLines: [
                "Each lane is normalized within the selected hour so shape matters more than raw scale.",
                "Network includes throughput alongside latency and packet-loss anomalies when probe data exists."
            ]
        )
    }

    private func drillDownSnapshot(
        title: String,
        subtitle: String,
        series: [HardwareGraphFocusSeries],
        stats: [HardwareGraphFocusStat],
        detailLines: [String]
    ) -> HardwareGraphFocusHeatmapDrillDownSnapshot {
        HardwareGraphFocusHeatmapDrillDownSnapshot(
            title: title,
            subtitle: subtitle,
            series: series.filter { $0.values.contains(where: { $0 != nil }) },
            stats: stats,
            detailLines: detailLines
        )
    }

    private func minuteDrillDownStats(
        label: String,
        range: DateInterval,
        timeline: [HardwareHistoryMetricBucket],
        tint: Color,
        extraStats: [HardwareGraphFocusStat] = []
    ) -> [HardwareGraphFocusStat] {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let peakBucket = timeline
            .compactMap { bucket -> (Date, Double)? in
                guard let value = bucket.maxValue else { return nil }
                return (bucket.bucketStart, value)
            }
            .max { lhs, rhs in lhs.1 < rhs.1 }

        return [
            HardwareGraphFocusStat(label: "Metric", value: label, tint: tint),
            HardwareGraphFocusStat(label: "Minutes", value: "\(max(1, Int(ceil(range.duration / 60.0))))"),
            HardwareGraphFocusStat(label: "Samples", value: "\(timeline.reduce(0) { $0 + $1.observedSampleCount })"),
            HardwareGraphFocusStat(label: "Peak Minute", value: peakBucket.map { formatter.string(from: $0.0) } ?? "—")
        ] + extraStats
    }

    private func normalizedRatioSeries(
        from timeline: [HardwareHistoryMetricBucket],
        in range: DateInterval
    ) -> [Double?] {
        normalizedBucketSeries(
            from: timeline.compactMap { bucket in
                guard let averageValue = bucket.averageValue else { return nil }
                return NormalizedBucketValue(
                    bucketStart: bucket.bucketStart,
                    value: min(max(averageValue, 0.0), 1.0)
                )
            },
            in: range
        )
    }

    private func normalizedPeakSeries(
        from timeline: [HardwareHistoryMetricBucket],
        in range: DateInterval
    ) -> [Double?] {
        let peak = timeline.compactMap(\.averageValue).max() ?? 0
        guard peak > 0 else {
            return normalizedBucketSeries(from: [], in: range)
        }
        return normalizedBucketSeries(
            from: timeline.compactMap { bucket in
                guard let averageValue = bucket.averageValue else { return nil }
                return NormalizedBucketValue(
                    bucketStart: bucket.bucketStart,
                    value: min(max(averageValue / peak, 0.0), 1.0)
                )
            },
            in: range
        )
    }

    private func normalizedLatencySeries(
        from timeline: [HardwareHistoryMetricBucket],
        in range: DateInterval
    ) -> [Double?] {
        normalizedBucketSeries(from: normalizedLatencyBuckets(timeline), in: range)
    }

    private func normalizedPacketLossSeries(
        from timeline: [HardwareHistoryMetricBucket],
        in range: DateInterval
    ) -> [Double?] {
        normalizedBucketSeries(from: normalizedPacketLossBuckets(timeline), in: range)
    }

    private func normalizedBucketSeries(
        from buckets: [NormalizedBucketValue],
        in range: DateInterval
    ) -> [Double?] {
        let minuteCount = max(1, Int(ceil(range.duration / 60.0)))
        var values = Array<Double?>(repeating: nil, count: minuteCount)

        for bucket in buckets {
            let minuteIndex = Int(bucket.bucketStart.timeIntervalSince(range.start) / 60.0)
            guard minuteIndex >= 0, minuteIndex < minuteCount else { continue }
            values[minuteIndex] = max(values[minuteIndex] ?? 0.0, min(max(bucket.value, 0.0), 1.0))
        }

        return values
    }

    private func makeSeries(
        id: String,
        label: String,
        color: Color,
        values: [Double?]
    ) -> HardwareGraphFocusSeries {
        HardwareGraphFocusSeries(id: id, label: label, color: color, values: values)
    }

    private func slotStart(
        forDayIndex dayIndex: Int,
        hour: Int,
        startDay: Date,
        calendar: Calendar
    ) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: dayIndex, to: startDay) else { return nil }
        return calendar.date(byAdding: .hour, value: hour, to: day)
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

            return HardwareHistoryMetricBucket(
                bucketStart: bucketStart,
                bucketDurationSeconds: max(
                    firstBucket?.bucketDurationSeconds ?? 0,
                    secondBucket?.bucketDurationSeconds ?? 0
                ),
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

    private func heatmapCellColor(for intensity: Double, accent: Color) -> Color {
        guard intensity > 0.001 else { return Color.white.opacity(0.035) }
        return accent.opacity(0.14 + intensity * 0.78)
    }

    private func apply(
        _ values: [NormalizedBucketValue],
        to cells: inout [[OverallHeatmapCell]],
        calendar: Calendar,
        startDay: Date,
        update: (inout OverallHeatmapCell, Double) -> Void
    ) {
        for bucket in values {
            let dayStart = calendar.startOfDay(for: bucket.bucketStart)
            let dayIndex = calendar.dateComponents([.day], from: startDay, to: dayStart).day ?? -1
            let hour = calendar.component(.hour, from: bucket.bucketStart)

            guard dayIndex >= 0, dayIndex < cells.count else { continue }
            guard hour >= 0, hour < 24 else { continue }
            update(&cells[dayIndex][hour], bucket.value)
        }
    }

    private func overallCellColor(_ cell: OverallHeatmapCell) -> Color {
        let activeComponents = cell.components.filter { $0.1 > 0.001 }
        guard !activeComponents.isEmpty else { return RGBTriplet.idle.color }

        let totalWeight = activeComponents.reduce(0.0) { sum, pair in
            sum + pair.1 * OverallHeatmapCell.overallBlendInfluence(for: pair.0)
        }
        let blended = activeComponents.reduce(RGBTriplet(red: 0, green: 0, blue: 0)) { partial, component in
            let w = component.1 * OverallHeatmapCell.overallBlendInfluence(for: component.0)
            let weight = totalWeight > 0 ? w / totalWeight : 0
            let rgb = component.0.heatmapAccentRGB
            return RGBTriplet(
                red: partial.red + rgb.red * weight,
                green: partial.green + rgb.green * weight,
                blue: partial.blue + rgb.blue * weight
            )
        }

        let tinted = RGBTriplet.idle.interpolated(to: blended, amount: pow(cell.displayIntensity, 0.82))
        let whitened = tinted.interpolated(to: .white, amount: pow(cell.sharedBusyRatio, 1.08))
        return whitened.color
    }
}

private extension HardwareGraphFocusHeatmapTarget {
    var heatmapMetricLabel: String {
        switch self {
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

    var heatmapAccentColor: Color {
        switch self {
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

    var heatmapAccentRGB: RGBTriplet {
        switch self {
        case .overall:
            return .white
        case .cpu:
            return RGBTriplet(red: 0.16, green: 0.49, blue: 0.95)
        case .gpu:
            return RGBTriplet(red: 0.85, green: 0.20, blue: 0.20)
        case .memory:
            return RGBTriplet(red: 0.10, green: 0.65, blue: 0.28)
        case .disk:
            return RGBTriplet(red: 0.98, green: 0.80, blue: 0.16)
        case .network:
            return RGBTriplet(red: 0.40, green: 0.40, blue: 0.50)
        case .power:
            return RGBTriplet(red: 0.98, green: 0.54, blue: 0.12)
        case .ane:
            return RGBTriplet(red: 0.65, green: 0.00, blue: 0.65)
        case .thermals:
            return RGBTriplet(red: 0.02, green: 0.65, blue: 0.65)
        }
    }
}

extension HardwareGraphFocusHeatmapTarget {
    nonisolated init(_ insightTarget: HardwareGraphFocusInsightTarget) {
        switch insightTarget {
        case .cpu:
            self = .cpu
        case .gpu:
            self = .gpu
        case .memory:
            self = .memory
        case .disk:
            self = .disk
        case .network:
            self = .network
        case .power:
            self = .power
        case .ane:
            self = .ane
        case .thermals:
            self = .thermals
        }
    }
}

private struct NormalizedBucketValue {
    let bucketStart: Date
    let value: Double
}

private struct OverallHeatmapCell {
    var cpu: Double = 0
    var gpu: Double? = nil
    var memory: Double = 0
    var power: Double = 0
    var network: Double = 0

    /// Matches Activity Heatmap "All": memory + power are useful alone but tend to dominate the blend.
    fileprivate static func overallBlendInfluence(for target: HardwareGraphFocusHeatmapTarget) -> Double {
        switch target {
        case .memory, .power:
            return 0.45
        case .cpu, .gpu, .network, .overall, .ane, .disk, .thermals:
            return 1.0
        }
    }

    var components: [(HardwareGraphFocusHeatmapTarget, Double)] {
        var out: [(HardwareGraphFocusHeatmapTarget, Double)] = [(.cpu, cpu)]
        if let gpu {
            out.append((.gpu, gpu))
        }
        out.append((.memory, memory))
        out.append((.power, power))
        out.append((.network, network))
        return out
    }

    private var influencedValues: [Double] {
        components.map { target, value in value * Self.overallBlendInfluence(for: target) }
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

private struct RGBTriplet {
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
