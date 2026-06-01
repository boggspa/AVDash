import Foundation
import Combine
import AppKit
import PodcastPreviewCore
#if canImport(libproc)
import libproc
#endif

struct AppRunningApplicationProvider: HardwareRunningApplicationProvider {
    static let live = AppRunningApplicationProvider()

    /// Fallback for processes that NSRunningApplication doesn't know about
    /// (daemons, agents, XPC services, app helpers). Walks the executable
    /// path up to a containing `.app` bundle and reads its Info.plist.
    private let pathFallback = HeadlessRunningApplicationProvider.shared

    func applicationInfo(for pid: Int32) -> HardwareRunningApplicationInfo? {
        if let app = NSRunningApplication(processIdentifier: pid),
           !app.isTerminated,
           app.localizedName != nil || app.bundleIdentifier != nil {
            return HardwareRunningApplicationInfo(
                localizedName: app.localizedName,
                bundleIdentifier: app.bundleIdentifier,
                launchDate: app.launchDate
            )
        }
        return pathFallback.applicationInfo(for: pid)
    }

    func icon(for pid: Int32) -> NSImage? {
        if let app = NSRunningApplication(processIdentifier: pid),
           !app.isTerminated,
           let icon = app.icon {
            return icon
        }
        guard let executableURL = Self.executableURL(for: pid) else { return nil }
        let workspace = NSWorkspace.shared
        if let bundleURL = Self.bundleURL(containing: executableURL) {
            return workspace.icon(forFile: bundleURL.path)
        }
        if FileManager.default.fileExists(atPath: executableURL.path) {
            return workspace.icon(forFile: executableURL.path)
        }
        return nil
    }

    private static func executableURL(for pid: Int32) -> URL? {
        #if canImport(libproc)
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: pathBuffer))
        #else
        return nil
        #endif
    }

    private static func bundleURL(containing executableURL: URL) -> URL? {
        var currentURL = executableURL.deletingLastPathComponent()
        while currentURL.path != "/" && !currentURL.path.isEmpty {
            if currentURL.pathExtension == "app" {
                return currentURL
            }
            currentURL.deleteLastPathComponent()
        }
        return nil
    }
}

/// App-side display adapter for the core running-app sampler.
@MainActor
final class OtherAppsSampler: ObservableObject {
    struct LiveHistorySample {
        let timestamp: Date
        let cpuPercent: Double
        let ramMB: Double
        let gpuShareRatio: Double?
        let isGPUActive: Bool
        let diskReadMBps: Double
        let diskWriteMBps: Double
    }

    struct LiveHistorySnapshot {
        let identity: PersistedProcessIdentity
        let samples: [LiveHistorySample]
    }

    struct Row: Identifiable {
        let id: Int32
        let pid: Int32
        let name: String
        let bundleIdentifier: String?
        let icon: NSImage?
        let cpuPercent: Double
        let ramPercent: Double
        let ramMB: Double
        let uptimeSeconds: Double
        let uptimeText: String
        /// True when this app had non-zero GPU time in the latest sample cycle.
        let isGPUActive: Bool
        let gpuShareRatio: Double?
        let gpuPercent: Double?
        let gpuTimeNS: UInt64
        let gpuDeltaTimeNS: UInt64
        let diskReadMBps: Double
        let diskWriteMBps: Double
        let liveResourceScore: Double
        let cumulativeResourceScore: Double

        var cpuText: String { String(format: "%4.1f%%", cpuPercent) }
        var ramText: String { String(format: "%4.1f%% %4.0fMB", ramPercent, ramMB) }
        var diskReadText: String { AppStatsSampler.formatRate(diskReadMBps) }
        var diskWriteText: String { AppStatsSampler.formatRate(diskWriteMBps) }
    }

    @Published private(set) var topRows: [Row] = []
    @Published private(set) var resourceRankedRows: [Row] = []

    private let sampler: RunningAppsSampler
    private let gpuSampler: GPUStatsSampler?
    private let gpuClientsSampler: GPUClientsSampler?
    private let iconProvider: AppRunningApplicationProvider?
    private var cancellables: Set<AnyCancellable> = []
    private var liveHistoryByProcessKey: [String: [LiveHistorySample]] = [:]
    private var cumulativeResourceScoreByProcessKey: [String: Double] = [:]
    private var lastSeenResourceProcessDates: [String: Date] = [:]
    private var lastResourceScoreUpdateAt: Date?
    private let maxLiveHistorySamples = 90
    private let retainedResourceScoreLifetime: TimeInterval = 15 * 60

    init(
        sampler: RunningAppsSampler,
        gpuSampler: GPUStatsSampler? = nil,
        gpuClientsSampler: GPUClientsSampler? = nil,
        iconProvider: AppRunningApplicationProvider? = nil
    ) {
        self.sampler = sampler
        self.gpuSampler = gpuSampler
        self.gpuClientsSampler = gpuClientsSampler
        self.iconProvider = iconProvider
        rebuildRows()

        sampler.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildRows()
            }
            .store(in: &cancellables)

        gpuClientsSampler?.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildRows()
            }
            .store(in: &cancellables)

        gpuSampler?.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildRows()
            }
            .store(in: &cancellables)
    }

    private func rebuildRows() {
        let gpuApps = gpuClientsSampler?.activeApps ?? []
        let gpuAppsByPID = Dictionary(uniqueKeysWithValues: gpuApps.map { ($0.pid, $0) })
        let totalGPUTimeNS = gpuApps.reduce(UInt64(0)) { partialResult, next in
            partialResult &+ (next.gpuDeltaTimeNS ?? 0)
        }
        let totalGPUUsagePercent = gpuSampler.map { sampler in
            min(
                sampler.gpus.compactMap(\.usage).reduce(0.0) { partialResult, usage in
                    partialResult + Double(usage)
                },
                1.0
            ) * 100.0
        }
        let sampleTimestamp = Date()

        let baseRows = sampler.topRows.map { row in
            let gpuApp = gpuAppsByPID[row.pid]
            let gpuDeltaTimeNS = gpuApp?.gpuDeltaTimeNS ?? 0
            let gpuShareRatio: Double? = totalGPUTimeNS > 0
                ? Double(gpuDeltaTimeNS) / Double(totalGPUTimeNS)
                : nil
            let gpuPercent = gpuShareRatio.flatMap { shareRatio in
                totalGPUUsagePercent.map { min(max($0 * shareRatio, 0), 100) }
            }
            let processIdentity = PersistedProcessIdentity(
                processKey: PersistedProcessIdentity.makeKey(bundleIdentifier: row.bundleIdentifier, name: row.name),
                displayName: row.name,
                bundleIdentifier: row.bundleIdentifier
            )
            let liveResourceScore = row.cpuPercent + (row.ramMB / 1024.0) + (gpuPercent ?? 0)
            return (
                sourceRow: row,
                processKey: processIdentity.processKey,
                icon: iconProvider?.icon(for: row.pid),
                isGPUActive: gpuApp?.isActive ?? false,
                gpuShareRatio: gpuShareRatio,
                gpuPercent: gpuPercent,
                gpuTimeNS: gpuApp?.gpuTimeNS ?? 0,
                gpuDeltaTimeNS: gpuDeltaTimeNS,
                liveResourceScore: liveResourceScore
            )
        }

        accumulateResourceScores(for: baseRows, at: sampleTimestamp)

        let rebuiltRows = baseRows.map { base in
            Row(
                id: base.sourceRow.id,
                pid: base.sourceRow.pid,
                name: base.sourceRow.name,
                bundleIdentifier: base.sourceRow.bundleIdentifier,
                icon: base.icon,
                cpuPercent: base.sourceRow.cpuPercent,
                ramPercent: base.sourceRow.ramPercent,
                ramMB: base.sourceRow.ramMB,
                uptimeSeconds: base.sourceRow.uptimeSeconds,
                uptimeText: base.sourceRow.uptimeText,
                isGPUActive: base.isGPUActive,
                gpuShareRatio: base.gpuShareRatio,
                gpuPercent: base.gpuPercent,
                gpuTimeNS: base.gpuTimeNS,
                gpuDeltaTimeNS: base.gpuDeltaTimeNS,
                diskReadMBps: base.sourceRow.diskReadMBps,
                diskWriteMBps: base.sourceRow.diskWriteMBps,
                liveResourceScore: base.liveResourceScore,
                cumulativeResourceScore: cumulativeResourceScoreByProcessKey[base.processKey] ?? 0
            )
        }

        let coalescedRows = coalesceByAppIdentity(rebuiltRows)
        topRows = coalescedRows
        resourceRankedRows = coalescedRows.sorted(by: resourceRankedOrder(_:_:))
        appendLiveHistorySamples(from: coalescedRows, timestamp: sampleTimestamp)
    }

    /// Merge rows that share the same display name + bundle ID (same app, multiple PIDs).
    /// Metrics are summed; uptime reflects the longest-running instance; the first PID
    /// encountered becomes the representative id for SwiftUI identity stability.
    private func coalesceByAppIdentity(_ rows: [Row]) -> [Row] {
        var indexByKey: [String: Int] = [:]
        var result: [Row] = []

        for row in rows {
            let key = "\(row.name.lowercased())|\(row.bundleIdentifier ?? "")"
            if let idx = indexByKey[key] {
                let e = result[idx]
                let useExistingUptime = e.uptimeSeconds >= row.uptimeSeconds
                result[idx] = Row(
                    id: e.id,
                    pid: e.pid,
                    name: e.name,
                    bundleIdentifier: e.bundleIdentifier,
                    icon: e.icon ?? row.icon,
                    cpuPercent: e.cpuPercent + row.cpuPercent,
                    ramPercent: e.ramPercent + row.ramPercent,
                    ramMB: e.ramMB + row.ramMB,
                    uptimeSeconds: max(e.uptimeSeconds, row.uptimeSeconds),
                    uptimeText: useExistingUptime ? e.uptimeText : row.uptimeText,
                    isGPUActive: e.isGPUActive || row.isGPUActive,
                    gpuShareRatio: addOptional(e.gpuShareRatio, row.gpuShareRatio),
                    gpuPercent: addOptional(e.gpuPercent, row.gpuPercent),
                    gpuTimeNS: e.gpuTimeNS + row.gpuTimeNS,
                    gpuDeltaTimeNS: e.gpuDeltaTimeNS + row.gpuDeltaTimeNS,
                    diskReadMBps: e.diskReadMBps + row.diskReadMBps,
                    diskWriteMBps: e.diskWriteMBps + row.diskWriteMBps,
                    liveResourceScore: e.liveResourceScore + row.liveResourceScore,
                    cumulativeResourceScore: e.cumulativeResourceScore + row.cumulativeResourceScore
                )
            } else {
                indexByKey[key] = result.count
                result.append(row)
            }
        }

        return result
    }

    private func addOptional(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case let (x?, y?): return x + y
        case let (x?, nil): return x
        case let (nil, y?): return y
        case (nil, nil): return nil
        }
    }

    func liveHistorySnapshot(for identity: PersistedProcessIdentity, maxSamples: Int = 90) -> LiveHistorySnapshot? {
        guard let samples = liveHistoryByProcessKey[identity.processKey], !samples.isEmpty else {
            return nil
        }

        return LiveHistorySnapshot(
            identity: identity,
            samples: Array(samples.suffix(max(1, min(maxSamples, maxLiveHistorySamples))))
        )
    }

    private func appendLiveHistorySamples(from rows: [Row], timestamp: Date) {
        guard !rows.isEmpty else { return }

        for row in rows {
            let identity = PersistedProcessIdentity(
                processKey: PersistedProcessIdentity.makeKey(bundleIdentifier: row.bundleIdentifier, name: row.name),
                displayName: row.name,
                bundleIdentifier: row.bundleIdentifier
            )
            let sample = LiveHistorySample(
                timestamp: timestamp,
                cpuPercent: row.cpuPercent,
                ramMB: row.ramMB,
                gpuShareRatio: row.gpuShareRatio,
                isGPUActive: row.isGPUActive,
                diskReadMBps: row.diskReadMBps,
                diskWriteMBps: row.diskWriteMBps
            )

            var samples = liveHistoryByProcessKey[identity.processKey] ?? []
            samples.append(sample)
            if samples.count > maxLiveHistorySamples {
                samples.removeFirst(samples.count - maxLiveHistorySamples)
            }
            liveHistoryByProcessKey[identity.processKey] = samples
        }
    }

    private func accumulateResourceScores(
        for rows: [(sourceRow: RunningAppsSampler.Row, processKey: String, icon: NSImage?, isGPUActive: Bool, gpuShareRatio: Double?, gpuPercent: Double?, gpuTimeNS: UInt64, gpuDeltaTimeNS: UInt64, liveResourceScore: Double)],
        at timestamp: Date
    ) {
        let deltaSeconds = lastResourceScoreUpdateAt.map { max(0, timestamp.timeIntervalSince($0)) } ?? 0
        lastResourceScoreUpdateAt = timestamp

        for row in rows {
            lastSeenResourceProcessDates[row.processKey] = timestamp
            guard deltaSeconds > 0 else { continue }
            cumulativeResourceScoreByProcessKey[row.processKey, default: 0] += row.liveResourceScore * deltaSeconds
        }

        let expirationDate = timestamp.addingTimeInterval(-retainedResourceScoreLifetime)
        let staleKeys = lastSeenResourceProcessDates.compactMap { key, date in
            date < expirationDate ? key : nil
        }
        for key in staleKeys {
            lastSeenResourceProcessDates.removeValue(forKey: key)
            cumulativeResourceScoreByProcessKey.removeValue(forKey: key)
            liveHistoryByProcessKey.removeValue(forKey: key)
        }
    }

    private func resourceRankedOrder(_ lhs: Row, _ rhs: Row) -> Bool {
        if abs(lhs.cumulativeResourceScore - rhs.cumulativeResourceScore) > 0.0001 {
            return lhs.cumulativeResourceScore > rhs.cumulativeResourceScore
        }
        if abs(lhs.liveResourceScore - rhs.liveResourceScore) > 0.0001 {
            return lhs.liveResourceScore > rhs.liveResourceScore
        }
        if abs(lhs.cpuPercent - rhs.cpuPercent) > 0.01 {
            return lhs.cpuPercent > rhs.cpuPercent
        }
        if abs(lhs.ramMB - rhs.ramMB) > 0.1 {
            return lhs.ramMB > rhs.ramMB
        }
        if let lhsGPUPercent = lhs.gpuPercent, let rhsGPUPercent = rhs.gpuPercent,
           abs(lhsGPUPercent - rhsGPUPercent) > 0.01 {
            return lhsGPUPercent > rhsGPUPercent
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}
