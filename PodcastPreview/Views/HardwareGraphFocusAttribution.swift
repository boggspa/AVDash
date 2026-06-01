import SwiftUI
import PodcastPreviewCore

enum HardwareGraphFocusAttributionTarget: String {
    case cpu
    case gpu
    case memory
    case power

    nonisolated init?(_ insightTarget: HardwareGraphFocusInsightTarget) {
        switch insightTarget {
        case .cpu:
            self = .cpu
        case .gpu:
            self = .gpu
        case .memory:
            self = .memory
        case .power:
            self = .power
        default:
            return nil
        }
    }

    var title: String {
        switch self {
        case .cpu:
            return "Live CPU Attribution"
        case .gpu:
            return "Live GPU Attribution"
        case .memory:
            return "Live Memory Attribution"
        case .power:
            return "Live Power Attribution"
        }
    }

    var subtitle: String {
        switch self {
        case .cpu:
            return "Current top processes ranked by CPU share."
        case .gpu:
            return "Apps recently observed by the GPU client sampler."
        case .memory:
            return "Current top processes ranked by resident memory."
        case .power:
            return "A live estimate blended from CPU, RAM, and GPU activity."
        }
    }

    var accentColor: Color {
        switch self {
        case .cpu:
            return .blue
        case .gpu:
            return Color(red: 0.85, green: 0.20, blue: 0.20)
        case .memory:
            return Color(red: 0.10, green: 0.65, blue: 0.28)
        case .power:
            return .orange
        }
    }
}

struct HardwareGraphFocusAttributionRow: Identifiable {
    let id: String
    let name: String
    let primaryValue: String
    let secondaryValue: String?
    let contribution: Double
    let tint: Color
}

struct HardwareGraphFocusAttributionSnapshot {
    let title: String
    let subtitle: String
    let accentColor: Color
    let rows: [HardwareGraphFocusAttributionRow]
    let isHeuristic: Bool
}

@MainActor
struct HardwareGraphFocusAttributionProvider {
    let topRowsProvider: () -> [OtherAppsSampler.Row]
    let gpuAppsProvider: () -> [GPUClientsSampler.GPUClientApp]
    let gpuCount: Int

    func snapshot(
        for target: HardwareGraphFocusAttributionTarget,
        gpuContext: HardwareGraphFocusGPUContext? = nil
    ) -> HardwareGraphFocusAttributionSnapshot? {
        if target == .gpu, gpuContext != nil, gpuCount > 1 {
            return nil
        }
        let candidates = mergedCandidates()
        guard !candidates.isEmpty else { return nil }

        switch target {
        case .cpu:
            let ranked = candidates
                .filter { $0.cpuPercent > 0.05 }
                .sorted { lhs, rhs in
                    if lhs.cpuPercent == rhs.cpuPercent { return lhs.ramMB > rhs.ramMB }
                    return lhs.cpuPercent > rhs.cpuPercent
                }
            let rows = ranked.prefix(5).map { candidate in
                makeRow(
                    candidate: candidate,
                    primaryValue: String(format: "CPU %.1f%%", candidate.cpuPercent),
                    contribution: candidate.cpuPercent / max(ranked.first?.cpuPercent ?? 1, 1),
                    tint: target.accentColor
                )
            }
            return rows.isEmpty ? nil : HardwareGraphFocusAttributionSnapshot(
                title: target.title,
                subtitle: target.subtitle,
                accentColor: target.accentColor,
                rows: rows,
                isHeuristic: false
            )

        case .memory:
            let ranked = candidates
                .filter { $0.ramMB > 1 }
                .sorted { lhs, rhs in
                    if lhs.ramMB == rhs.ramMB { return lhs.cpuPercent > rhs.cpuPercent }
                    return lhs.ramMB > rhs.ramMB
                }
            let rows = ranked.prefix(5).map { candidate in
                makeRow(
                    candidate: candidate,
                    primaryValue: "RAM \(formatMemory(candidate.ramMB))",
                    contribution: candidate.ramMB / max(ranked.first?.ramMB ?? 1, 1),
                    tint: target.accentColor
                )
            }
            return rows.isEmpty ? nil : HardwareGraphFocusAttributionSnapshot(
                title: target.title,
                subtitle: target.subtitle,
                accentColor: target.accentColor,
                rows: rows,
                isHeuristic: false
            )

        case .gpu:
            let ranked = candidates
                .filter { $0.isGPUActive || $0.effectiveGPUActivityNS > 0 }
                .sorted { lhs, rhs in
                    if lhs.isGPUActive != rhs.isGPUActive { return lhs.isGPUActive && !rhs.isGPUActive }
                    if lhs.effectiveGPUActivityNS == rhs.effectiveGPUActivityNS { return lhs.cpuPercent > rhs.cpuPercent }
                    return lhs.effectiveGPUActivityNS > rhs.effectiveGPUActivityNS
                }
            let peakTime = max(Double(ranked.first?.effectiveGPUActivityNS ?? 0), 1)
            let rows = ranked.prefix(5).map { candidate in
                let primary = candidate.effectiveGPUActivityNS > 0
                    ? "GPU \(formatGPUTime(candidate.effectiveGPUActivityNS))"
                    : (candidate.isGPUActive ? "GPU Active" : "Observed GPU Client")
                let contribution = candidate.isGPUActive
                    ? max(Double(candidate.effectiveGPUActivityNS) / peakTime, 0.2)
                    : Double(candidate.effectiveGPUActivityNS) / peakTime
                return makeRow(
                    candidate: candidate,
                    primaryValue: primary,
                    contribution: contribution,
                    tint: target.accentColor
                )
            }
            return rows.isEmpty ? nil : HardwareGraphFocusAttributionSnapshot(
                title: target.title,
                subtitle: target.subtitle,
                accentColor: target.accentColor,
                rows: rows,
                isHeuristic: false
            )

        case .power:
            let maxCPU = max(candidates.map(\.cpuPercent).max() ?? 0, 1)
            let maxRAM = max(candidates.map(\.ramMB).max() ?? 0, 1)
            let maxGPU = max(candidates.map { Double($0.effectiveGPUActivityNS) }.max() ?? 0, 1)

            let ranked = candidates
                .map { candidate -> (MergedCandidate, Double) in
                    let cpuShare = candidate.cpuPercent / maxCPU
                    let ramShare = candidate.ramMB / maxRAM
                    let gpuShare = Double(candidate.effectiveGPUActivityNS) / maxGPU
                    let gpuBonus = candidate.isGPUActive ? 0.15 : 0.0
                    let score = min(1.0, cpuShare * 0.55 + ramShare * 0.15 + gpuShare * 0.15 + gpuBonus)
                    return (candidate, score)
                }
                .filter { $0.1 > 0.05 }
                .sorted { lhs, rhs in
                    if lhs.1 == rhs.1 { return lhs.0.cpuPercent > rhs.0.cpuPercent }
                    return lhs.1 > rhs.1
                }

            let rows = ranked.prefix(5).map { candidate, score in
                makeRow(
                    candidate: candidate,
                    primaryValue: String(format: "Est. %.0f%%", score * 100),
                    contribution: score,
                    tint: target.accentColor
                )
            }

            return rows.isEmpty ? nil : HardwareGraphFocusAttributionSnapshot(
                title: target.title,
                subtitle: target.subtitle,
                accentColor: target.accentColor,
                rows: rows,
                isHeuristic: true
            )
        }
    }

    private func makeRow(
        candidate: MergedCandidate,
        primaryValue: String,
        contribution: Double,
        tint: Color
    ) -> HardwareGraphFocusAttributionRow {
        HardwareGraphFocusAttributionRow(
            id: "\(candidate.pid)",
            name: candidate.name,
            primaryValue: primaryValue,
            secondaryValue: secondaryText(for: candidate),
            contribution: min(max(contribution, 0), 1),
            tint: tint
        )
    }

    private func secondaryText(for candidate: MergedCandidate) -> String? {
        var parts: [String] = []
        if candidate.cpuPercent > 0.05 {
            parts.append(String(format: "CPU %.1f%%", candidate.cpuPercent))
        }
        if candidate.ramMB > 1 {
            parts.append("RAM \(formatMemory(candidate.ramMB))")
        }
        if candidate.gpuDeltaTimeNS > 0 {
            parts.append("GPU \(formatGPUTime(candidate.gpuDeltaTimeNS))")
        }
        if candidate.isGPUActive {
            parts.append("GPU active")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private func mergedCandidates() -> [MergedCandidate] {
        var byPID: [Int32: MergedCandidate] = [:]

        for row in topRowsProvider() {
            byPID[row.pid] = MergedCandidate(
                pid: row.pid,
                name: row.name,
                cpuPercent: row.cpuPercent,
                ramMB: row.ramMB,
                isGPUActive: row.isGPUActive,
                gpuTimeNS: row.gpuTimeNS,
                gpuDeltaTimeNS: row.gpuDeltaTimeNS
            )
        }

        for gpuApp in gpuAppsProvider() {
            var existing = byPID[gpuApp.pid] ?? MergedCandidate(
                pid: gpuApp.pid,
                name: gpuApp.name,
                cpuPercent: 0,
                ramMB: 0,
                isGPUActive: false,
                gpuTimeNS: 0,
                gpuDeltaTimeNS: 0
            )
            existing.name = gpuApp.name
            existing.isGPUActive = existing.isGPUActive || gpuApp.isActive
            existing.gpuTimeNS = max(existing.gpuTimeNS, gpuApp.gpuTimeNS)
            existing.gpuDeltaTimeNS = max(existing.gpuDeltaTimeNS, gpuApp.gpuDeltaTimeNS ?? 0)
            byPID[gpuApp.pid] = existing
        }

        return Array(byPID.values)
    }

    private func formatMemory(_ ramMB: Double) -> String {
        if ramMB >= 1024 {
            return String(format: "%.2f GB", ramMB / 1024.0)
        }
        return String(format: "%.0f MB", ramMB)
    }

    private func formatGPUTime(_ gpuTimeNS: UInt64) -> String {
        let milliseconds = Double(gpuTimeNS) / 1_000_000.0
        if milliseconds >= 1000 {
            return String(format: "%.2fs", milliseconds / 1000.0)
        }
        return String(format: "%.0fms", milliseconds)
    }
}

private struct MergedCandidate {
    let pid: Int32
    var name: String
    let cpuPercent: Double
    let ramMB: Double
    var isGPUActive: Bool
    var gpuTimeNS: UInt64
    var gpuDeltaTimeNS: UInt64

    var effectiveGPUActivityNS: UInt64 {
        gpuDeltaTimeNS
    }
}
