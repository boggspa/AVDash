import SwiftUI
import PodcastPreviewCore

struct HardwareGraphFocusProcessTarget: Hashable {
    let identity: PersistedProcessIdentity
    let currentCPUPercent: Double
    let currentRAMMB: Double
    let isGPUActive: Bool
    let currentGPUShareRatio: Double?
    let uptimeSeconds: Double
}

struct HardwareGraphFocusProcessHistorySnapshot {
    let title: String
    let subtitle: String
    let series: [HardwareGraphFocusSeries]
    let stats: [HardwareGraphFocusStat]
    let detailLines: [String]
}

@MainActor
struct HardwareGraphFocusProcessHistoryProvider {
    let reader: any ProcessHistoryQuerying

    func snapshot(
        for target: HardwareGraphFocusProcessTarget,
        window: HardwareInsightWindow,
        anchorDate: Date
    ) async -> HardwareGraphFocusProcessHistorySnapshot? {
        let range = window.range(anchoredAt: anchorDate)
        let bucketIntervalSeconds = bucketInterval(for: window)
        let timeline = await reader.timeline(
            for: target.identity,
            in: range,
            bucketIntervalSeconds: bucketIntervalSeconds
        )
        let summary = await reader.summary(
            for: target.identity,
            in: range,
            bucketIntervalSeconds: bucketIntervalSeconds
        )

        guard !timeline.isEmpty else { return nil }

        let maxCPUPercent = max(timeline.map(\.peakCPUPercent).max() ?? 0, 0.01)
        let maxRAMMB = max(timeline.map(\.peakRAMMB).max() ?? 0, 1)
        let hasHistoricalGPUShare = summary.peakGPUShareRatio > 0 || timeline.contains { $0.averageGPUShareRatio > 0 }
        let cpuSeries = HardwareGraphFocusSeries(
            id: "process-cpu",
            label: "CPU",
            color: .blue,
            values: timeline.map { min(max($0.averageCPUPercent / maxCPUPercent, 0), 1) }
        )
        let ramSeries = HardwareGraphFocusSeries(
            id: "process-ram",
            label: "RAM",
            color: Color(red: 0.10, green: 0.65, blue: 0.28),
            values: timeline.map { min(max($0.averageRAMMB / maxRAMMB, 0), 1) }
        )
        let gpuSeries = HardwareGraphFocusSeries(
            id: "process-gpu",
            label: hasHistoricalGPUShare ? "GPU Share" : "GPU Activity",
            color: Color(red: 0.85, green: 0.20, blue: 0.20),
            values: timeline.map {
                if hasHistoricalGPUShare {
                    return min(max($0.averageGPUShareRatio, 0), 1)
                }
                return min(max($0.gpuActiveRatio, 0), 1)
            }
        )
        let powerSeries = HardwareGraphFocusSeries(
            id: "process-power",
            label: "Power",
            color: .orange,
            values: timeline.map { min(max($0.averagePowerScore, 0), 1) }
        )

        var stats: [HardwareGraphFocusStat] = [
            .init(label: "Avg CPU", value: formatCPUPercent(summary.averageCPUPercent), tint: .blue),
            .init(label: "Peak CPU", value: formatCPUPercent(summary.peakCPUPercent), tint: .blue),
            .init(label: "Avg RAM", value: formatMemory(summary.averageRAMMB), tint: Color(red: 0.10, green: 0.65, blue: 0.28)),
            .init(label: "Peak RAM", value: formatMemory(summary.peakRAMMB), tint: Color(red: 0.10, green: 0.65, blue: 0.28)),
            .init(label: "Power Score", value: String(format: "%.0f%%", summary.averagePowerScore * 100), tint: .orange)
        ]

        if hasHistoricalGPUShare {
            stats.append(
                .init(
                    label: "Avg GPU Share",
                    value: formatSharePercent(summary.averageGPUShareRatio),
                    tint: Color(red: 0.85, green: 0.20, blue: 0.20)
                )
            )
            stats.append(
                .init(
                    label: "Peak GPU Share",
                    value: formatSharePercent(summary.peakGPUShareRatio),
                    tint: Color(red: 0.85, green: 0.20, blue: 0.20)
                )
            )
        } else if let currentGPUShareRatio = target.currentGPUShareRatio, currentGPUShareRatio > 0 {
            stats.append(
                .init(
                    label: "Live GPU Share",
                    value: formatSharePercent(currentGPUShareRatio),
                    tint: Color(red: 0.85, green: 0.20, blue: 0.20)
                )
            )
        } else {
            stats.append(
                .init(
                    label: "GPU Active",
                    value: String(format: "%.0f%%", summary.averageGPUActiveRatio * 100),
                    tint: Color(red: 0.85, green: 0.20, blue: 0.20)
                )
            )
        }

        if let uptimeSeconds = summary.latestUptimeSeconds, uptimeSeconds > 0 {
            stats.append(.init(label: "Latest Uptime", value: formatUptime(uptimeSeconds)))
        }

        let dominantMetric = dominantMetricLabel(summary: summary)
        var details: [String] = [
            "Bucket cadence: \(bucketLabel(for: bucketIntervalSeconds)).",
            "Dominant historical signature: \(dominantMetric).",
            "History lines are normalized to each metric's peak within the selected window so low-intensity apps still show shape."
        ]
        if let bundleIdentifier = target.identity.bundleIdentifier, !bundleIdentifier.isEmpty {
            details.append("Bundle identifier: \(bundleIdentifier).")
        }
        if hasHistoricalGPUShare {
            details.append("GPU Share shows this app's share of recorded per-app GPU-client time across all observed apps in each bucket, not direct hardware utilization.")
        } else if summary.peakGPUTimeNS > 0 || target.currentGPUShareRatio != nil {
            details.append("GPU visibility is based on per-sample GPU client time deltas, not a direct per-process GPU percent.")
        }
        if target.isGPUActive {
            details.append("This app is currently present in the live GPU client sampler.")
        }

        return HardwareGraphFocusProcessHistorySnapshot(
            title: "Historical Footprint",
            subtitle: "Selected window: \(windowLabel(for: window)). CPU and RAM are direct rollups; GPU tracks relative sampled GPU-client share when available, and Power remains a correlated activity score.",
            series: [cpuSeries, ramSeries, gpuSeries, powerSeries],
            stats: stats,
            detailLines: details
        )
    }

    private func bucketInterval(for window: HardwareInsightWindow) -> Int {
        switch window {
        case .daily:
            return 60
        case .weekly, .monthly:
            return 3600
        @unknown default:
            return 3600
        }
    }

    private func dominantMetricLabel(summary: ProcessHistorySummary) -> String {
        let candidates: [(String, Double)] = [
            ("CPU-led", summary.averageCPUPercent / 100.0),
            ("RAM-heavy", summary.averageRAMMB / max(summary.peakRAMMB, 1)),
            ("GPU-active", max(summary.averageGPUActiveRatio, summary.averageGPUShareRatio * 0.85)),
            ("Power-correlated", summary.averagePowerScore)
        ]
        return candidates.max(by: { $0.1 < $1.1 })?.0 ?? "Balanced"
    }

    private func formatMemory(_ ramMB: Double) -> String {
        if ramMB >= 1024 {
            return String(format: "%.2f GB", ramMB / 1024.0)
        }
        return String(format: "%.0f MB", ramMB)
    }

    private func formatCPUPercent(_ cpuPercent: Double) -> String {
        if cpuPercent < 0.1 {
            return String(format: "%.2f%%", cpuPercent)
        }
        if cpuPercent < 10 {
            return String(format: "%.1f%%", cpuPercent)
        }
        return String(format: "%.0f%%", cpuPercent)
    }

    private func formatUptime(_ seconds: Double) -> String {
        let integerSeconds = max(0, Int(seconds))
        let hours = integerSeconds / 3600
        let minutes = (integerSeconds % 3600) / 60
        if hours > 0 {
            return String(format: "%dh %dm", hours, minutes)
        }
        return String(format: "%dm", minutes)
    }

    private func bucketLabel(for seconds: Int) -> String {
        if seconds >= 3600 {
            return "\(seconds / 3600)h rollups"
        }
        return "\(seconds / 60)m rollups"
    }

    private func windowLabel(for window: HardwareInsightWindow) -> String {
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

    private func formatSharePercent(_ ratio: Double) -> String {
        let percent = min(max(ratio, 0), 1) * 100
        if percent < 10 {
            return String(format: "%.1f%%", percent)
        }
        return String(format: "%.0f%%", percent)
    }
}
