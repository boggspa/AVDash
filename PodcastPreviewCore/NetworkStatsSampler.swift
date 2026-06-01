import Foundation
import Combine
import Darwin

/// Best-effort sampler for overall system network throughput (In/Out MB/s).
/// Uses route statistics (AF_ROUTE) on macOS Big Sur and later.
public final class NetworkStatsSampler: ObservableObject {
    public struct RateSnapshot: Codable, Equatable, Sendable {
        public var totalReadBytes: UInt64
        public var totalWriteBytes: UInt64
        public var readMBps: Double
        public var writeMBps: Double
        public var interfaceCount: Int
        public var timestamp: Date?

        public init(
            totalReadBytes: UInt64 = 0,
            totalWriteBytes: UInt64 = 0,
            readMBps: Double = 0,
            writeMBps: Double = 0,
            interfaceCount: Int = 0,
            timestamp: Date? = nil
        ) {
            self.totalReadBytes = totalReadBytes
            self.totalWriteBytes = totalWriteBytes
            self.readMBps = readMBps
            self.writeMBps = writeMBps
            self.interfaceCount = interfaceCount
            self.timestamp = timestamp
        }

        public var totalMBps: Double { readMBps + writeMBps }
        public var readText: String { AppStatsSampler.formatRate(readMBps) }
        public var writeText: String { AppStatsSampler.formatRate(writeMBps) }
        public var totalText: String { AppStatsSampler.formatRate(totalMBps) }
    }

    @Published public var readText: String = "—"
    @Published public var writeText: String = "—"
    @Published public var totalText: String = "—"
    @Published public private(set) var latestSnapshot: RateSnapshot? = nil
    @Published public private(set) var readSeries = MetricSeries(key: .networkDownloadMBps, unit: .megabytesPerSecond)
    @Published public private(set) var writeSeries = MetricSeries(key: .networkUploadMBps, unit: .megabytesPerSecond)

    // Aliases for consistency with consuming code expectations
    public var uploadSeries: MetricSeries { writeSeries }
    public var downloadSeries: MetricSeries { readSeries }
    public var uploadMBps: Float? { latestSnapshot.map { Float($0.writeMBps) } }
    public var downloadMBps: Float? { latestSnapshot.map { Float($0.readMBps) } }
    public var uploadText: String { writeText }
    public var downloadText: String { readText }
    public var uploadPeakText: String { Self.formatPeakRate(writeSeries.peakObservedValue) }
    public var downloadPeakText: String { Self.formatPeakRate(readSeries.peakObservedValue) }

    // Computed properties for consuming code
    public var pingLatencyHistory: [Float] {
        pingLatencySeries.values().map(Float.init)
    }

    public var pingPacketLossHistory: [Float] {
        pingPacketLossSeries.values().map(Float.init)
    }

    // Ping monitoring state
    @Published public private(set) var pingLatencySeries = MetricSeries(key: .networkPingLatencyMilliseconds, unit: .milliseconds)
    @Published public private(set) var pingPacketLossSeries = MetricSeries(key: .networkPingPacketLossRatio, unit: .ratio)
    @Published public private(set) var pingLatencyMilliseconds: Double?
    @Published public private(set) var pingPacketLossRatio: Double?
    @Published public private(set) var pingLatencyText: String = "—"
    @Published public private(set) var pingPacketLossText: String = "—"
    @Published public private(set) var lastPingSampleDate: Date?
    @Published public private(set) var pingTargetLabel: String = "—"

    // Session tracking
    @Published public private(set) var sessionUploadMB: Double = 0
    @Published public private(set) var sessionDownloadMB: Double = 0

    private var timer: DispatchSourceTimer?
    private struct LastSample {
        let readBytes: UInt64
        let writeBytes: UInt64
        let time: TimeInterval
    }
    private var lastSample: LastSample?
    private static let refreshIntervalSeconds = 2
    static var liveSeriesCapacity: Int {
        HardwareCollectionSettings.liveSeriesCapacity(
            sampleIntervalSeconds: refreshIntervalSeconds
        )
    }

    public init() {}

    public func start() {
        #if os(macOS)
        stop()
        lastSample = nil
        readSeries.removeAll()
        writeSeries.removeAll()
        sample()

        let interval = Self.refreshIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in
            self?.sample()
        }
        t.resume()
        timer = t
        #endif
    }

    private static func formatPeakRate(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return String(format: "Peak %.2f MB/s", value)
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sample() {
        #if os(macOS)
        let now = Date().timeIntervalSince1970
        let (totalRead, totalWrite, count) = Self.readRouteStatistics()

        var snapshot = RateSnapshot(
            totalReadBytes: totalRead,
            totalWriteBytes: totalWrite,
            interfaceCount: count
        )

        if let lastSample = lastSample {
            let dt = max(0.001, now - lastSample.time)
            let deltaRead = totalRead >= lastSample.readBytes ? totalRead - lastSample.readBytes : 0
            let deltaWrite = totalWrite >= lastSample.writeBytes ? totalWrite - lastSample.writeBytes : 0

            snapshot.readMBps = Double(deltaRead) / dt / 1_048_576.0
            snapshot.writeMBps = Double(deltaWrite) / dt / 1_048_576.0
        }

        lastSample = LastSample(readBytes: totalRead, writeBytes: totalWrite, time: now)
        let sampleDate = Date()

        DispatchQueue.main.async {
            self.latestSnapshot = RateSnapshot(
                totalReadBytes: totalRead,
                totalWriteBytes: totalWrite,
                readMBps: snapshot.readMBps,
                writeMBps: snapshot.writeMBps,
                interfaceCount: count,
                timestamp: sampleDate
            )
            self.readText = snapshot.readText
            self.writeText = snapshot.writeText
            self.totalText = snapshot.totalText
            self.readSeries.append(snapshot.readMBps, at: sampleDate, capacity: Self.liveSeriesCapacity)
            self.writeSeries.append(snapshot.writeMBps, at: sampleDate, capacity: Self.liveSeriesCapacity)
        }
        #endif
    }

    #if os(macOS)
    private static func readRouteStatistics() -> (read: UInt64, write: UInt64, count: Int) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len: Int = 0

        if sysctl(&mib, 6, nil, &len, nil, 0) < 0 {
            return (0, 0, 0)
        }

        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: len)
        defer { buffer.deallocate() }

        if sysctl(&mib, 6, buffer, &len, nil, 0) < 0 {
            return (0, 0, 0)
        }

        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        var count = 0

        var offset = 0
        while offset < len {
            let ptr = buffer.advanced(by: offset)
            let ifm = ptr.withMemoryRebound(to: if_msghdr.self, capacity: 1) { $0.pointee }

            let rtm_ifinfo2: Int32 = 0x12
            if Int32(ifm.ifm_type) == rtm_ifinfo2 {
                let if2m = ptr.withMemoryRebound(to: if_msghdr2.self, capacity: 1) { $0.pointee }
                totalRead += if2m.ifm_data.ifi_ibytes
                totalWrite += if2m.ifm_data.ifi_obytes
                count += 1
            }

            offset += Int(ifm.ifm_msglen)
        }

        return (totalRead, totalWrite, count)
    }
    #endif

    public static func runPing(host: String) -> Double? {
        #if os(macOS)
        let process = Process()
        process.launchPath = "/sbin/ping"
        process.arguments = ["-c", "1", "-W", "1000", host]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let pattern = "time=([0-9\\.]+) ms"
                if let range = output.range(of: pattern, options: .regularExpression) {
                    let substring = String(output[range])
                    let numericPart = substring.replacingOccurrences(of: "time=", with: "").replacingOccurrences(of: " ms", with: "")
                    return Double(numericPart)
                }
            }
        } catch {
            return nil
        }
        #endif
        return nil
    }

    public static func checkInternetConnectivity() -> Bool {
        #if os(macOS)
        let process = Process()
        process.launchPath = "/usr/bin/nc"
        process.arguments = ["-zw", "1", "1.1.1.1", "53"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
        #else
        return true
        #endif
    }

    // MARK: - Ping Control Methods

    public func updatePingInterval(_ interval: TimeInterval) {
        // Stub implementation - would update ping interval in a real implementation
    }

    public func updatePingInterval(_ interval: Int) {
        updatePingInterval(TimeInterval(interval))
    }

    public func updatePingTarget(_ target: String) {
        pingTargetLabel = target
        // Stub implementation - would update ping target in a real implementation
    }

    public func triggerSample() {
        sample()
    }

    // MARK: - External Clock Support

    public func initializeForExternalClock() {
        stop()
        lastSample = nil
        DispatchQueue.main.async {
            self.readText = "—"
            self.writeText = "—"
            self.totalText = "—"
            self.latestSnapshot = nil
            self.readSeries = MetricSeries(key: .networkDownloadMBps, unit: .megabytesPerSecond)
            self.writeSeries = MetricSeries(key: .networkUploadMBps, unit: .megabytesPerSecond)
            self.pingLatencySeries = MetricSeries(key: .networkPingLatencyMilliseconds, unit: .milliseconds)
            self.pingPacketLossSeries = MetricSeries(key: .networkPingPacketLossRatio, unit: .ratio)
            self.pingLatencyMilliseconds = nil
            self.pingPacketLossRatio = nil
            self.pingLatencyText = "—"
            self.pingPacketLossText = "—"
            self.lastPingSampleDate = nil
        }
        sample()
    }

    // MARK: - Quality Snapshots

    public func drainPendingQualitySnapshots() -> [RateSnapshot] {
        // Stub implementation - would drain pending quality snapshots
        return []
    }
}

extension NetworkStatsSampler {
    public var liveSnapshot: NetworkStatsSamplerLiveSnapshot {
        NetworkStatsSamplerLiveSnapshot(
            uploadMBps: latestSnapshot.map { Float($0.writeMBps) },
            downloadMBps: latestSnapshot.map { Float($0.readMBps) },
            uploadText: uploadText,
            downloadText: downloadText,
            uploadPeakText: uploadPeakText,
            downloadPeakText: downloadPeakText,
            uploadHistory: [],
            downloadHistory: [],
            pingLatencyHistory: pingLatencySeries.values().map(Float.init),
            pingPacketLossHistory: pingPacketLossSeries.values().map(Float.init),
            uploadSeries: writeSeries,
            downloadSeries: readSeries,
            pingLatencySeries: pingLatencySeries,
            pingPacketLossSeries: pingPacketLossSeries,
            latestSnapshot: latestSnapshot.map {
                var snapshot = HardwareSnapshot(timestamp: $0.timestamp ?? Date())
                snapshot.setMetric(.networkDownloadMBps, value: $0.readMBps)
                snapshot.setMetric(.networkUploadMBps, value: $0.writeMBps)
                return snapshot
            },
            sessionUploadMB: sessionUploadMB,
            sessionDownloadMB: sessionDownloadMB,
            pingTargetLabel: pingTargetLabel,
            pingLatencyMilliseconds: pingLatencyMilliseconds,
            pingPacketLossRatio: pingPacketLossRatio,
            pingLatencyText: pingLatencyText,
            pingPacketLossText: pingPacketLossText,
            lastPingSampleDate: lastPingSampleDate
        )
    }

    public func applyRemoteSnapshot(_ snapshot: NetworkStatsSamplerLiveSnapshot) {
        readText = snapshot.downloadText
        writeText = snapshot.uploadText
        totalText = "—" // Combined total if needed
        latestSnapshot = snapshot.latestSnapshot.map {
            RateSnapshot(
                totalReadBytes: 0,
                totalWriteBytes: 0,
                readMBps: $0.metric(.networkDownloadMBps) ?? snapshot.downloadMBps.map(Double.init) ?? 0,
                writeMBps: $0.metric(.networkUploadMBps) ?? snapshot.uploadMBps.map(Double.init) ?? 0,
                interfaceCount: 0,
                timestamp: $0.timestamp
            )
        }
        readSeries = snapshot.downloadSeries
        writeSeries = snapshot.uploadSeries

        // Apply ping and session tracking from remote snapshot
        pingLatencySeries = snapshot.pingLatencySeries
        pingPacketLossSeries = snapshot.pingPacketLossSeries
        pingLatencyMilliseconds = snapshot.pingLatencyMilliseconds
        pingPacketLossRatio = snapshot.pingPacketLossRatio
        pingLatencyText = snapshot.pingLatencyText
        pingPacketLossText = snapshot.pingPacketLossText
        lastPingSampleDate = snapshot.lastPingSampleDate
        pingTargetLabel = snapshot.pingTargetLabel
        sessionUploadMB = snapshot.sessionUploadMB
        sessionDownloadMB = snapshot.sessionDownloadMB
    }
}
