import Foundation
import Combine
import Darwin
#if os(macOS)
import IOKit
#endif

/// Sandbox-safe storage sampler using FileManager filesystem attributes.
/// Reports available and total capacity for the volume containing the app's home directory.
public final class StorageStatsSampler: ObservableObject {
    public struct CapacitySnapshot: Codable, Equatable, Sendable {
        public var freeBytes: Int64
        public var usedBytes: Int64
        public var totalBytes: Int64
        public var kindLabel: String?
        public var speedLabel: String?
        public var healthLabel: String?

        public init(
            freeBytes: Int64,
            usedBytes: Int64,
            totalBytes: Int64,
            kindLabel: String? = nil,
            speedLabel: String? = nil,
            healthLabel: String? = nil
        ) {
            self.freeBytes = freeBytes
            self.usedBytes = usedBytes
            self.totalBytes = totalBytes
            self.kindLabel = kindLabel
            self.speedLabel = speedLabel
            self.healthLabel = healthLabel
        }

        public var usedRatio: Float {
            guard totalBytes > 0 else { return 0 }
            return Float(Double(usedBytes) / Double(totalBytes))
        }

        public var storageLabel: String {
            let freeGB = Double(freeBytes) / 1_073_741_824.0
            let totalGB = Double(totalBytes) / 1_073_741_824.0
            let usedGB = Double(usedBytes) / 1_073_741_824.0
            return String(format: "%.1f GB free (%.1f / %.1f GB used)", freeGB, usedGB, totalGB)
        }
    }

    @Published public var storageLabel: String = "—"
    @Published public var storageUsedRatio: Float = 0
    @Published public var storageKindLabel: String = "Detecting…"
    @Published public var storageSpeedLabel: String = "Measuring…"
    @Published public var storageHealthLabel: String = "Checking…"
    @Published public private(set) var latestCapacitySnapshot: CapacitySnapshot? = nil

    private var timer: DispatchSourceTimer?
    private var didProbeStorageDetails = false
    private static let refreshIntervalSeconds = 30

    public init() {}

    public func start() {
        stop()
        didProbeStorageDetails = false
        latestCapacitySnapshot = nil
        storageKindLabel = "Detecting…"
        storageSpeedLabel = "Measuring…"
        storageHealthLabel = "Checking…"
        sample()

        let interval = Self.refreshIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in
            self?.sample()
        }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sample() {
        let path = NSHomeDirectory()

        // Big Sur compatible: attributesOfFileSystem
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
           let free = attrs[.systemFreeSize] as? NSNumber,
           let total = attrs[.systemSize] as? NSNumber {

            let freeBytes = free.int64Value
            let totalBytes = total.int64Value
            let usedBytes = max(0, totalBytes - freeBytes)

            let capacitySnapshot = CapacitySnapshot(
                freeBytes: freeBytes,
                usedBytes: usedBytes,
                totalBytes: totalBytes
            )

            DispatchQueue.main.async {
                self.latestCapacitySnapshot = capacitySnapshot
                self.storageLabel = capacitySnapshot.storageLabel
                self.storageUsedRatio = min(max(capacitySnapshot.usedRatio, 0), 1)
            }

            if !didProbeStorageDetails {
                didProbeStorageDetails = true
                let samplePath = path
                DispatchQueue.global(qos: .utility).async {
                    let details = Self.probeStorageDetails(forPath: samplePath)
                    DispatchQueue.main.async {
                        self.latestCapacitySnapshot = CapacitySnapshot(
                            freeBytes: freeBytes,
                            usedBytes: usedBytes,
                            totalBytes: totalBytes,
                            kindLabel: details.kindLabel,
                            speedLabel: details.speedLabel,
                            healthLabel: details.healthLabel
                        )
                        self.storageKindLabel = details.kindLabel
                        self.storageSpeedLabel = details.speedLabel
                        self.storageHealthLabel = details.healthLabel
                    }
                }
            }
            return
        }

        DispatchQueue.main.async {
            self.latestCapacitySnapshot = nil
            self.storageLabel = "Unavailable"
            self.storageUsedRatio = 0
            self.storageKindLabel = "Unknown Storage"
            self.storageSpeedLabel = "Speed unavailable"
            self.storageHealthLabel = "Health unavailable"
        }
    }

    private static func label(for snapshot: CapacitySnapshot) -> String {
        snapshot.storageLabel
    }

    private struct StorageProbeDetails {
        var kindLabel: String
        var speedLabel: String
        var healthLabel: String
    }

    #if os(macOS)
    private static var ioMainPort: mach_port_t {
        if #available(macOS 12.0, *) {
            return kIOMainPortDefault
        } else {
            return kIOMasterPortDefault
        }
    }
    #endif

    private static func probeStorageDetails(forPath path: String) -> StorageProbeDetails {
        let url = URL(fileURLWithPath: path)
        let resourceValues = try? url.resourceValues(forKeys: [
            .volumeLocalizedFormatDescriptionKey,
            .volumeIsInternalKey,
            .volumeNameKey
        ])

        let volumeDescription = resourceValues?.volumeLocalizedFormatDescription
        let isInternal = resourceValues?.volumeIsInternal

        #if os(macOS)
        let bsdName = bsdNameForPath(path)

        var physicalInterconnect: String? = nil
        var mediumType: String? = nil
        var solidState: Bool? = nil
        var modelName: String? = nil
        var ioService: io_service_t = 0

        if let bsdName {
            let match = IOBSDNameMatching(ioMainPort, 0, bsdName)
            let service = IOServiceGetMatchingService(ioMainPort, match)
            if service != 0 {
                ioService = service
                physicalInterconnect = recursiveStringProperty(service, key: "Physical Interconnect")
                    ?? recursiveStringProperty(service, key: "Physical Interconnect Type")
                mediumType = recursiveStringProperty(service, key: "Medium Type")
                solidState = recursiveBoolProperty(service, key: "Solid State")
                modelName = recursiveStringProperty(service, key: "Model")
                    ?? recursiveStringProperty(service, key: "Device Model")
                    ?? recursiveStringProperty(service, key: "Product Name")
            }
        }

        let kindLabel = classifyStorageKind(
            isInternal: isInternal,
            physicalInterconnect: physicalInterconnect,
            mediumType: mediumType,
            solidState: solidState,
            modelName: modelName,
            volumeDescription: volumeDescription
        )
        #else
        let kindLabel = volumeDescription ?? (isInternal == true ? "Internal Storage" : "Storage")
        let physicalInterconnect: String? = nil
        let solidState: Bool? = nil
        let modelName: String? = nil
        #endif

        let benchmark = runOneShotBenchmark(atPath: path)
        let speedLabel: String
        if let benchmark {
            speedLabel = String(format: "R %.0f MB/s · W %.0f MB/s", benchmark.readMBps, benchmark.writeMBps)
        } else {
            speedLabel = estimatedSpeedLabel(
                kindLabel: kindLabel,
                physicalInterconnect: physicalInterconnect,
                solidState: solidState
            )
        }

        #if os(macOS)
        let healthLabel = detectDriveHealth(
            service: ioService,
            solidState: solidState,
            modelName: modelName
        )

        if ioService != 0 {
            IOObjectRelease(ioService)
        }
        #else
        let healthLabel = "Available"
        #endif

        return StorageProbeDetails(kindLabel: kindLabel, speedLabel: speedLabel, healthLabel: healthLabel)
    }

    private static func bsdNameForPath(_ path: String) -> String? {
        var sfs = statfs()
        guard path.withCString({ statfs($0, &sfs) }) == 0 else { return nil }
        let from = withUnsafePointer(to: &sfs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
                String(cString: $0)
            }
        }
        guard from.hasPrefix("/dev/") else { return nil }
        return String(from.dropFirst(5))
    }

    #if os(macOS)
    private static func recursiveStringProperty(_ service: io_registry_entry_t, key: String) -> String? {
        guard let value = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        ) else {
            return nil
        }

        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let data = value as? Data, !data.isEmpty {
            let bytes = [UInt8](data)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            if end > 0 {
                return String(bytes: bytes[0..<end], encoding: .utf8)
            }
        }
        return nil
    }

    private static func recursiveBoolProperty(_ service: io_registry_entry_t, key: String) -> Bool? {
        guard let value = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        ) else {
            return nil
        }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    private static func classifyStorageKind(
        isInternal: Bool?,
        physicalInterconnect: String?,
        mediumType: String?,
        solidState: Bool?,
        modelName: String?,
        volumeDescription: String?
    ) -> String {
        let interconnect = physicalInterconnect?.lowercased() ?? ""
        let medium = mediumType?.lowercased() ?? ""
        let model = modelName?.lowercased() ?? ""
        let internalPrefix = (isInternal == true) ? "Internal" : "External"

        if interconnect.contains("nvme") || model.contains("nvme") || model.contains("apple ans") {
            return "\(internalPrefix) NVMe SSD"
        }
        if interconnect.contains("sata") || interconnect.contains("ahci") {
            if solidState == false || medium.contains("rotational") {
                return "\(internalPrefix) SATA HDD"
            }
            return "\(internalPrefix) SATA SSD"
        }
        if interconnect.contains("usb") {
            if solidState == false || medium.contains("rotational") {
                return "External USB HDD"
            }
            return "External USB SSD"
        }
        if interconnect.contains("thunderbolt") {
            if solidState == false || medium.contains("rotational") {
                return "External Thunderbolt HDD"
            }
            return "External Thunderbolt SSD"
        }
        if solidState == true || medium.contains("ssd") || volumeDescription?.lowercased().contains("ssd") == true {
            return "\(internalPrefix) SSD"
        }
        if solidState == false || medium.contains("rotational") || volumeDescription?.lowercased().contains("hard disk") == true {
            return "\(internalPrefix) HDD"
        }
        return volumeDescription ?? "Storage"
    }
    #endif

    private static func estimatedSpeedLabel(
        kindLabel: String,
        physicalInterconnect: String?,
        solidState: Bool?
    ) -> String {
        let lower = kindLabel.lowercased()
        let interconnect = physicalInterconnect?.lowercased() ?? ""

        if lower.contains("nvme") {
            return "Est. 2,500–7,000 MB/s"
        }
        if interconnect.contains("thunderbolt") {
            return lower.contains("hdd") ? "Est. 120–220 MB/s" : "Est. 1,500–3,000 MB/s"
        }
        if interconnect.contains("usb") {
            return lower.contains("hdd") ? "Est. 100–180 MB/s" : "Est. 400–1,000 MB/s"
        }
        if lower.contains("sata ssd") {
            return "Est. 450–550 MB/s"
        }
        if lower.contains("hdd") || solidState == false {
            return "Est. 80–220 MB/s"
        }
        return "Speed estimate unavailable"
    }

    private static func runOneShotBenchmark(atPath volumePath: String) -> (readMBps: Double, writeMBps: Double)? {
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: volumePath).appendingPathComponent(".storage-probe", isDirectory: true)
        let fileURL = tempDir.appendingPathComponent("probe.bin")

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        defer {
            try? fm.removeItem(at: fileURL)
            try? fm.removeItem(at: tempDir)
        }

        let totalBytes = 32 * 1_048_576
        let chunkSize = 4 * 1_048_576
        let chunk = Data(repeating: 0xA5, count: chunkSize)
        let chunkCount = totalBytes / chunkSize

        let writeStart = DispatchTime.now().uptimeNanoseconds
        guard fm.createFile(atPath: fileURL.path, contents: nil) else { return nil }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            for _ in 0..<chunkCount {
                try handle.write(contentsOf: chunk)
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            return nil
        }
        let writeEnd = DispatchTime.now().uptimeNanoseconds

        let readStart = DispatchTime.now().uptimeNanoseconds
        guard let readData = try? Data(contentsOf: fileURL, options: [.uncached]), readData.count == totalBytes else {
            return nil
        }
        let readEnd = DispatchTime.now().uptimeNanoseconds

        let writeSeconds = Double(writeEnd - writeStart) / 1_000_000_000.0
        let readSeconds = Double(readEnd - readStart) / 1_000_000_000.0
        guard writeSeconds > 0, readSeconds > 0 else { return nil }

        let megabytes = Double(totalBytes) / 1_048_576.0
        let writeMBps = megabytes / writeSeconds
        let readMBps = megabytes / readSeconds
        return (readMBps, writeMBps)
    }

    // MARK: - Drive Health Detection

    #if os(macOS)
    private static func detectDriveHealth(
        service: io_service_t,
        solidState: Bool?,
        modelName: String?
    ) -> String {
        guard service != 0 else {
            return heuristicHealth(solidState: solidState, modelName: modelName)
        }

        if let smartData = readSMARTData(service: service) {
            return evaluateSMARTHealth(smartData)
        }

        return heuristicHealth(solidState: solidState, modelName: modelName)
    }

    private static func readSMARTData(service: io_service_t) -> [String: Any]? {
        let smartKeys = [
            "SMART Data",
            "SMARTData",
            "S.M.A.R.T. Data",
            "ATASMARTData"
        ]

        for key in smartKeys {
            if let smartDict = IORegistryEntrySearchCFProperty(
                service,
                kIOServicePlane,
                key as CFString,
                kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            ) as? [String: Any] {
                return smartDict
            }
        }

        return nil
    }

    private static func evaluateSMARTHealth(_ smartData: [String: Any]) -> String {
        var criticalIssues = 0
        var warningIssues = 0

        if let smartStatus = smartData["SMART Status"] as? String {
            if smartStatus.lowercased().contains("fail") || smartStatus.lowercased().contains("bad") {
                return "Critical"
            }
        }

        if let smartStatus = smartData["SMARTStatus"] as? Bool, !smartStatus {
            return "Critical"
        }

        if let attributes = smartData["Attributes"] as? [[String: Any]] {
            for attr in attributes {
                guard let id = attr["ID"] as? Int ?? attr["AttributeID"] as? Int,
                      let rawValue = attr["RawValue"] as? Int ?? attr["Value"] as? Int else {
                    continue
                }

                switch id {
                case 0x05: // Reallocated Sector Count
                    if rawValue > 0 { criticalIssues += min(rawValue, 10) }
                case 0xC4: // Reallocation Event Count
                    if rawValue > 0 { criticalIssues += min(rawValue / 2, 5) }
                case 0xC5: // Current Pending Sector Count
                    if rawValue > 0 { criticalIssues += min(rawValue, 10) }
                case 0xC6: // Uncorrectable Sector Count
                    if rawValue > 0 { return "Critical" }
                case 0xE8: // Available Reserved Space (SSD)
                    let threshold = attr["Threshold"] as? Int ?? 10
                    if rawValue < threshold { criticalIssues += 5 }
                    else if rawValue < threshold * 2 { warningIssues += 3 }
                case 0xE9: // Media Wearout Indicator (SSD)
                    if rawValue > 90 { criticalIssues += 5 }
                    else if rawValue > 70 { warningIssues += 3 }
                    else if rawValue > 50 { warningIssues += 1 }
                default:
                    break
                }
            }
        }

        if let powerOnHours = smartData["PowerOnHours"] as? Int ?? smartData["Power_On_Hours"] as? Int {
            let years = Double(powerOnHours) / 8760.0
            if years > 5 { warningIssues += Int(years - 5) }
        }

        if criticalIssues >= 5 { return "Critical" }
        else if criticalIssues >= 2 || warningIssues >= 5 { return "Poor" }
        else if criticalIssues == 1 || warningIssues >= 3 { return "Fair" }
        else if warningIssues > 0 { return "Good" }
        else { return "Excellent" }
    }

    private static func heuristicHealth(solidState: Bool?, modelName: String?) -> String {
        let model = modelName?.lowercased() ?? ""
        if model.contains("apple") || model.contains("ans") || model.contains("t2") { return "Excellent (estimated)" }
        if model.contains("nvme") { return "Good (estimated)" }
        if solidState == true { return "Good (estimated)" }
        if solidState == false { return "Fair (estimated)" }
        return "Unknown"
    }
    #endif
}

extension StorageStatsSampler {
    public var liveSnapshot: StorageStatsSamplerLiveSnapshot {
        StorageStatsSamplerLiveSnapshot(
            latestCapacitySnapshot: latestCapacitySnapshot,
            storageLabel: storageLabel,
            storageUsedRatio: storageUsedRatio,
            storageKindLabel: storageKindLabel,
            storageSpeedLabel: storageSpeedLabel,
            storageHealthLabel: storageHealthLabel
        )
    }

    public func applyRemoteSnapshot(_ snapshot: StorageStatsSamplerLiveSnapshot) {
        latestCapacitySnapshot = snapshot.latestCapacitySnapshot
        storageLabel = snapshot.storageLabel
        storageUsedRatio = snapshot.storageUsedRatio
        storageKindLabel = snapshot.storageKindLabel
        storageSpeedLabel = snapshot.storageSpeedLabel
        storageHealthLabel = snapshot.storageHealthLabel
    }
}
