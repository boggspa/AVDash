import Foundation
import Combine
#if os(macOS)
import IOKit
#endif

/// Disk I/O sampler for read and write rates (boot volume only).
public final class DiskIOSampler: ObservableObject {
    @Published public var readMBps: Float? = nil
    @Published public var writeMBps: Float? = nil
    @Published public var readText: String = "—"
    @Published public var writeText: String = "—"
    @Published public var readPeakText: String = "—"
    @Published public var writePeakText: String = "—"
    @Published public var readHistory: [Float] = []
    @Published public var writeHistory: [Float] = []
    @Published public private(set) var readSeries = DiskIOSampler.makeReadSeries()
    @Published public private(set) var writeSeries = DiskIOSampler.makeWriteSeries()
    @Published public private(set) var latestSnapshot: HardwareSnapshot? = nil

    #if os(macOS)
    private var timer: DispatchSourceTimer?
    private var readSeriesBuffer = DiskIOSampler.makeReadSeries()
    private var writeSeriesBuffer = DiskIOSampler.makeWriteSeries()
    private var previousStats: (read: UInt64, write: UInt64, timestamp: Date)?

    private static var ioMainPort: mach_port_t {
        if #available(macOS 12.0, *) {
            return kIOMainPortDefault
        } else {
            return kIOMasterPortDefault
        }
    }
    #endif

    private static var historyCapacity: Int {
        HardwareCollectionSettings.liveSeriesCapacity()
    }

    public init() {}

    public func initialize() {
        #if os(macOS)
        stop()
        readSeriesBuffer = Self.makeReadSeries()
        writeSeriesBuffer = Self.makeWriteSeries()
        previousStats = nil
        DispatchQueue.main.async {
            self.readHistory = []
            self.writeHistory = []
            self.readMBps = nil
            self.writeMBps = nil
            self.readText = "—"
            self.writeText = "—"
            self.readPeakText = "—"
            self.writePeakText = "—"
            self.readSeries = Self.makeReadSeries()
            self.writeSeries = Self.makeWriteSeries()
            self.latestSnapshot = nil
        }
        sample()
        #endif
    }

    public func start() {
        #if os(macOS)
        initialize()

        let interval = HardwareCollectionSettings.collectorIntervalSeconds()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in
            self?.sample()
        }
        t.resume()
        timer = t
        #endif
    }

    public func stop() {
        #if os(macOS)
        timer?.cancel()
        timer = nil
        #endif
    }

    private static func makeReadSeries() -> MetricSeries {
        MetricSeries(key: .diskReadMBps, unit: .megabytesPerSecond)
    }

    private static func makeWriteSeries() -> MetricSeries {
        MetricSeries(key: .diskWriteMBps, unit: .megabytesPerSecond)
    }

    private static func formatRate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f MB/s", value)
    }

    private static func formatPeak(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return String(format: "Peak %.2f MB/s", value)
    }

    #if os(macOS)
    func sample() {
        let stats = Self.readBootVolumeDiskIO()
        let now = Date()

        var readSpeedMBps: Double? = nil
        var writeSpeedMBps: Double? = nil

        if let current = stats, let previous = previousStats {
            let elapsed = now.timeIntervalSince(previous.timestamp)
            guard elapsed > 0 else { return }

            let readDelta = current.read > previous.read ? current.read - previous.read : 0
            let writeDelta = current.write > previous.write ? current.write - previous.write : 0

            let readBytesPerSec = Double(readDelta) / elapsed
            let writeBytesPerSec = Double(writeDelta) / elapsed

            readSpeedMBps = readBytesPerSec / 1_048_576.0
            writeSpeedMBps = writeBytesPerSec / 1_048_576.0
        }

        if let stats = stats {
            previousStats = (stats.read, stats.write, now)
        }

        readSeriesBuffer.append(readSpeedMBps, at: now, capacity: Self.historyCapacity)
        writeSeriesBuffer.append(writeSpeedMBps, at: now, capacity: Self.historyCapacity)

        var snapshot = HardwareSnapshot(timestamp: now)
        if let readSpeedMBps {
            snapshot.setMetric(.diskReadMBps, value: readSpeedMBps)
        }
        if let writeSpeedMBps {
            snapshot.setMetric(.diskWriteMBps, value: writeSpeedMBps)
        }

        let readSeries = readSeriesBuffer
        let writeSeries = writeSeriesBuffer
        let readHistory = readSeries.values().map { Float(min($0 / 500.0, 1.0)) }
        let writeHistory = writeSeries.values().map { Float(min($0 / 500.0, 1.0)) }
        let latestSnapshot = snapshot.isEmpty ? nil : snapshot

        DispatchQueue.main.async {
            self.latestSnapshot = latestSnapshot
            self.readSeries = readSeries
            self.writeSeries = writeSeries
            self.readMBps = readSeries.latestObservedValue.map(Float.init)
            self.writeMBps = writeSeries.latestObservedValue.map(Float.init)
            self.readText = Self.formatRate(readSeries.latestObservedValue)
            self.writeText = Self.formatRate(writeSeries.latestObservedValue)
            self.readPeakText = Self.formatPeak(readSeries.peakObservedValue)
            self.writePeakText = Self.formatPeak(writeSeries.peakObservedValue)
            self.readHistory = readHistory
            self.writeHistory = writeHistory
        }
    }

    private static func readBootVolumeDiskIO() -> (read: UInt64, write: UInt64)? {
        guard let bootVolumeBSD = getBootVolumeBSDName() else {
            return readAllDiskIO()
        }

        if let stats = readWholeMediaDiskIO(named: bootVolumeBSD) {
            return stats
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            ioMainPort,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        )

        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }

            if let bsdName = searchRegistryProperty(
                service,
                key: "BSD Name",
                options: IOOptionBits(kIORegistryIterateRecursively)
            ) as? String {
                if bsdName.hasPrefix(bootVolumeBSD) || bootVolumeBSD.hasPrefix(bsdName) {
                    if let stats = readDiskIOStatistics(for: service) {
                        return stats
                    }
                }
            }

            service = IOIteratorNext(iterator)
        }

        return readAllDiskIO()
    }

    private static func getBootVolumeBSDName() -> String? {
        var sfs = statfs()
        guard statfs("/", &sfs) == 0 else { return nil }

        let device = withUnsafePointer(to: &sfs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
                String(cString: $0)
            }
        }

        if device.hasPrefix("/dev/") {
            let bsdName = String(device.dropFirst(5))
            if let digitIndex = bsdName.firstIndex(where: { $0.isNumber }) {
                let afterDisk = bsdName[digitIndex...]
                if let sIndex = afterDisk.firstIndex(of: "s") {
                    return "disk" + String(afterDisk[..<sIndex])
                } else {
                    return "disk" + String(afterDisk)
                }
            }
        }

        return nil
    }

    private static func readWholeMediaDiskIO(named targetBSDName: String) -> (read: UInt64, write: UInt64)? {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            ioMainPort,
            IOServiceMatching("IOMedia"),
            &iterator
        )

        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }

            let bsdName = copyRegistryProperty(service, key: "BSD Name") as? String
            let isWhole = (copyRegistryProperty(service, key: "Whole") as? NSNumber)?.boolValue ?? false

            if isWhole, bsdName == targetBSDName, let stats = readDiskIOStatistics(for: service) {
                return stats
            }

            service = IOIteratorNext(iterator)
        }

        return nil
    }

    private static func readDiskIOStatistics(for service: io_registry_entry_t) -> (read: UInt64, write: UInt64)? {
        if let stats = copyRegistryProperty(service, key: "Statistics") as? [String: Any],
           let counters = extractDiskIOCounters(from: stats) {
            return counters
        }

        if let stats = searchRegistryProperty(
            service,
            key: "Statistics",
            options: IOOptionBits(kIORegistryIterateParents)
        ) as? [String: Any],
           let counters = extractDiskIOCounters(from: stats) {
            return counters
        }

        if let stats = searchRegistryProperty(
            service,
            key: "Statistics",
            options: IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        ) as? [String: Any],
           let counters = extractDiskIOCounters(from: stats) {
            return counters
        }

        return nil
    }

    private static func copyRegistryProperty(
        _ service: io_registry_entry_t,
        key: String
    ) -> Any? {
        IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }

    private static func searchRegistryProperty(
        _ service: io_registry_entry_t,
        key: String,
        options: IOOptionBits
    ) -> Any? {
        IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            options
        )
    }

    private static func extractDiskIOCounters(from stats: [String: Any]) -> (read: UInt64, write: UInt64)? {
        func firstCounter(matching keys: [String]) -> UInt64? {
            for key in keys {
                if let number = stats[key] as? NSNumber {
                    return number.uint64Value
                }
            }
            return nil
        }

        let readKeys = [
            "Bytes (Read)",
            "Bytes read from block device",
            "Bytes read by user"
        ]
        let writeKeys = [
            "Bytes (Write)",
            "Bytes written to block device",
            "Bytes written by user"
        ]

        guard let read = firstCounter(matching: readKeys),
              let write = firstCounter(matching: writeKeys) else {
            return nil
        }

        return (read, write)
    }

    private static func readAllDiskIO() -> (read: UInt64, write: UInt64)? {
        var totalRead: UInt64 = 0
        var totalWrite: UInt64 = 0
        var iterator: io_iterator_t = 0

        let result = IOServiceGetMatchingServices(
            ioMainPort,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        )

        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service) }

            if let stats = copyRegistryProperty(service, key: "Statistics") as? [String: Any],
               let counters = extractDiskIOCounters(from: stats) {
                totalRead += counters.read
                totalWrite += counters.write
            }

            service = IOIteratorNext(iterator)
        }

        return (totalRead, totalWrite)
    }
    #endif
}

extension DiskIOSampler {
    public var liveSnapshot: DiskIOSamplerLiveSnapshot {
        DiskIOSamplerLiveSnapshot(
            readMBps: readMBps,
            writeMBps: writeMBps,
            readText: readText,
            writeText: writeText,
            readPeakText: readPeakText,
            writePeakText: writePeakText,
            readHistory: readHistory,
            writeHistory: writeHistory,
            readSeries: readSeries,
            writeSeries: writeSeries,
            latestSnapshot: latestSnapshot
        )
    }

    public func applyRemoteSnapshot(_ snapshot: DiskIOSamplerLiveSnapshot) {
        readMBps = snapshot.readMBps
        writeMBps = snapshot.writeMBps
        readText = snapshot.readText
        writeText = snapshot.writeText
        readPeakText = snapshot.readPeakText
        writePeakText = snapshot.writePeakText
        readHistory = snapshot.readHistory
        writeHistory = snapshot.writeHistory
        readSeries = snapshot.readSeries
        writeSeries = snapshot.writeSeries
        latestSnapshot = snapshot.latestSnapshot
    }
}
