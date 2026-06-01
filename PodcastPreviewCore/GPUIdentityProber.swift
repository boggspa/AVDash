import Foundation

// MARK: - GPUUnitMetadata

/// Static hardware identity record for one GPU device.
/// Populated once on app launch via system_profiler; not tied to live usage sampling.
public struct GPUUnitMetadata: Identifiable, Codable, Sendable {
    public let id: String
    public var name: String?
    public var vendor: String?
    public var bus: String?
    public var gpuType: String?
    public var metalFamily: String?
    public var coreCount: Int?
    /// Static VRAM from system_profiler (e.g. "8 GB", "1.5 GB"). Nil on Apple silicon.
    public var vramDescription: String?
    public var deviceID: String?
    public var revisionID: String?
    public var isRemovable: Bool?
    public var pcieWidth: String?
    public var connectedDisplayCount: Int?

    public init(
        id: String,
        name: String? = nil,
        vendor: String? = nil,
        bus: String? = nil,
        gpuType: String? = nil,
        metalFamily: String? = nil,
        coreCount: Int? = nil,
        vramDescription: String? = nil,
        deviceID: String? = nil,
        revisionID: String? = nil,
        isRemovable: Bool? = nil,
        pcieWidth: String? = nil,
        connectedDisplayCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.bus = bus
        self.gpuType = gpuType
        self.metalFamily = metalFamily
        self.coreCount = coreCount
        self.vramDescription = vramDescription
        self.deviceID = deviceID
        self.revisionID = revisionID
        self.isRemovable = isRemovable
        self.pcieWidth = pcieWidth
        self.connectedDisplayCount = connectedDisplayCount
    }
}

#if os(macOS)
import Combine

// MARK: - GPUIdentityProber

/// Probes system_profiler SPDisplaysDataType once on app launch to populate static GPU
/// hardware metadata. Results are cached for the app lifetime; call triggerRefresh()
/// to re-probe (e.g. on eGPU attach/remove).
///
/// Uses two paths:
///   JSON path  — system_profiler -json piped through python3 (preferred, Apple silicon)
///   Text path  — plain system_profiler output filtered by key lines (Intel fallback)
public final class GPUIdentityProber: ObservableObject {
    @Published public var gpuUnits: [GPUUnitMetadata] = []
    @Published public var isLoading: Bool = false
    @Published public var lastProbeDate: Date? = nil

    public init() {}

    /// Probe once; no-op if results are already cached.
    public func start() {
        guard gpuUnits.isEmpty else { return }
        probe()
    }

    /// Force a fresh probe, discarding any cached results.
    public func triggerRefresh() {
        probe()
    }

    private func probe() {
        guard !isLoading else { return }
        DispatchQueue.main.async { self.isLoading = true }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let units = self.runProbe()
            DispatchQueue.main.async {
                self.gpuUnits = units
                self.isLoading = false
                self.lastProbeDate = Date()
            }
        }
    }

    private func runProbe() -> [GPUUnitMetadata] {
        if let jsonUnits = probeViaJSON(), !jsonUnits.isEmpty { return jsonUnits }
        return probeViaPlainText()
    }

    // MARK: JSON path

    private func probeViaJSON() -> [GPUUnitMetadata]? {
        let script = """
import sys,json;\
data=json.load(sys.stdin);\
print(json.dumps([{"name":g.get("sppci_model"),"vendor":g.get("spdisplays_vendor"),\
"metalFamily":g.get("spdisplays_metalfamily") or g.get("spdisplays_mtlgpufamilysupport"),\
"bus":g.get("sppci_bus"),"type":g.get("sppci_device_type"),"cores":g.get("sppci_cores"),\
"vram":g.get("spdisplays_vram") or g.get("_spdisplays_vram") or g.get("spdisplays_vram_shared"),\
"deviceID":g.get("spdisplays_device-id"),"revisionID":g.get("spdisplays_revision-id"),\
"removable":g.get("spdisplays_gpu_removable"),"pcieWidth":g.get("spdisplays_pcie_width"),\
"displayCount":len(g.get("spdisplays_ndrvs",[]))} for g in data.get("SPDisplaysDataType",[])]))
"""
        let spTask = Process()
        spTask.launchPath = "/usr/sbin/system_profiler"
        spTask.arguments = ["SPDisplaysDataType", "-json"]
        let spOut = Pipe()
        spTask.standardOutput = spOut
        spTask.standardError = Pipe()
        guard (try? spTask.run()) != nil else { return nil }
        spTask.waitUntilExit()
        guard spTask.terminationStatus == 0 else { return nil }
        let jsonData = spOut.fileHandleForReading.readDataToEndOfFile()
        guard !jsonData.isEmpty else { return nil }

        let pyTask = Process()
        pyTask.launchPath = "/usr/bin/python3"
        pyTask.arguments = ["-c", script]
        let pyIn = Pipe(); let pyOut = Pipe()
        pyTask.standardInput = pyIn
        pyTask.standardOutput = pyOut
        pyTask.standardError = Pipe()
        guard (try? pyTask.run()) != nil else { return nil }
        pyIn.fileHandleForWriting.write(jsonData)
        pyIn.fileHandleForWriting.closeFile()
        pyTask.waitUntilExit()
        guard pyTask.terminationStatus == 0 else { return nil }

        let output = pyOut.fileHandleForReading.readDataToEndOfFile()
        guard let parsed = try? JSONSerialization.jsonObject(with: output) as? [[String: Any]] else { return nil }
        return parsed.enumerated().map { parseJSONEntry($1, index: $0) }
    }

    // MARK: Plain-text fallback

    private func probeViaPlainText() -> [GPUUnitMetadata] {
        let task = Process()
        task.launchPath = "/usr/sbin/system_profiler"
        task.arguments = ["SPDisplaysDataType"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return [] }
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return [] }
        return parsePlainText(output)
    }

    // MARK: - JSON parsing

    private func parseJSONEntry(_ dict: [String: Any], index: Int) -> GPUUnitMetadata {
        let rawName = dict["name"] as? String
        let id = rawName.map { $0.lowercased().replacingOccurrences(of: " ", with: "-") } ?? "gpu-\(index)"
        return GPUUnitMetadata(
            id: id,
            name: rawName,
            vendor: normalizeVendor(dict["vendor"] as? String),
            bus: normalizeBus(dict["bus"] as? String),
            gpuType: normalizeGPUType(dict["type"] as? String),
            metalFamily: normalizeMetalFamily(dict["metalFamily"] as? String),
            coreCount: (dict["cores"] as? String).flatMap(Int.init),
            vramDescription: normalizeVRAM(dict["vram"] as? String),
            deviceID: normalizeID(dict["deviceID"] as? String),
            revisionID: normalizeID(dict["revisionID"] as? String),
            isRemovable: normalizeRemovable(dict["removable"] as? String),
            pcieWidth: (dict["pcieWidth"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            connectedDisplayCount: dict["displayCount"] as? Int
        )
    }

    // MARK: - Plain-text parsing

    private func parsePlainText(_ output: String) -> [GPUUnitMetadata] {
        var gpus: [GPUUnitMetadata] = []
        var current: [String: String] = [:]
        var index = 0

        for line in output.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Chipset Model:") {
                if !current.isEmpty { gpus.append(buildFromPlainText(current, index: index)); index += 1 }
                current = [:]
            }
            let keys = ["Chipset Model:", "Type:", "Bus:", "VRAM (Total):", "VRAM (Dynamic, Max):",
                        "Vendor:", "Device ID:", "Revision ID:", "Metal Family:", "Metal:",
                        "GPU is Removable:", "PCIe Lane Width:"]
            for key in keys where t.hasPrefix(key) {
                current[key] = String(t.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        if !current.isEmpty { gpus.append(buildFromPlainText(current, index: index)) }
        return gpus
    }

    private func buildFromPlainText(_ dict: [String: String], index: Int) -> GPUUnitMetadata {
        let name = dict["Chipset Model:"]
        let id = name.map { $0.lowercased().replacingOccurrences(of: " ", with: "-") } ?? "gpu-\(index)"
        let rawVRAM = dict["VRAM (Total):"] ?? dict["VRAM (Dynamic, Max):"]
        return GPUUnitMetadata(
            id: id,
            name: name,
            vendor: normalizeVendor(dict["Vendor:"]),
            bus: normalizeBus(dict["Bus:"]),
            gpuType: normalizeGPUType(dict["Type:"]),
            metalFamily: normalizeMetalFamily(dict["Metal Family:"] ?? dict["Metal:"]),
            coreCount: nil,
            vramDescription: normalizeVRAM(rawVRAM),
            deviceID: normalizeID(dict["Device ID:"]),
            revisionID: normalizeID(dict["Revision ID:"]),
            isRemovable: normalizeRemovable(dict["GPU is Removable:"]),
            pcieWidth: dict["PCIe Lane Width:"].flatMap { $0.isEmpty ? nil : $0 },
            connectedDisplayCount: nil
        )
    }

    // MARK: - Normalisation helpers

    private func normalizeVendor(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let l = raw.lowercased()
        if l.contains("apple")  { return "Apple" }
        if l.contains("amd") || l.contains("0x1002") { return "AMD" }
        if l.contains("nvidia") { return "NVIDIA" }
        if l.contains("intel")  { return "Intel" }
        if raw.hasPrefix("sppci_vendor_") { return String(raw.dropFirst("sppci_vendor_".count)).capitalized }
        return raw
    }

    private func normalizeMetalFamily(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let l = raw.lowercased()
        if l.hasPrefix("spdisplays_metal") {
            let suffix = l.dropFirst("spdisplays_metal".count).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            return suffix.isEmpty ? "Metal" : "Metal \(suffix)"
        }
        if let r = raw.range(of: "GPUFamily macOS ", options: .caseInsensitive) {
            let n = String(raw[r.upperBound...].prefix(while: { $0.isNumber }))
            if !n.isEmpty { return "Metal \(n)" }
        }
        if let r = raw.range(of: "GPUFamily Apple ", options: .caseInsensitive) {
            let n = String(raw[r.upperBound...].prefix(while: { $0.isNumber }))
            if !n.isEmpty { return "Apple \(n)" }
        }
        return raw.count < 24 ? raw : nil
    }

    private func normalizeBus(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let l = raw.lowercased()
        if l.contains("builtin") || l.contains("built") { return "Built-In" }
        if l.contains("pcie") || l.contains("pci express") { return "PCIe" }
        if l.contains("thunderbolt") { return "Thunderbolt" }
        return raw
    }

    private func normalizeGPUType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let l = raw.lowercased()
        if l.contains("external") { return "External" }
        if l == "spdisplays_gpu" || l == "gpu" { return "Integrated" }
        return raw
    }

    private func normalizeVRAM(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.lowercased().contains("mb"),
           let mb = Int(raw.components(separatedBy: .whitespaces).first ?? "") {
            if mb >= 1024 && mb % 1024 == 0 { return "\(mb / 1024) GB" }
            if mb >= 1024 { return String(format: "%.1f GB", Double(mb) / 1024.0) }
            return "\(mb) MB"
        }
        return raw
    }

    private func normalizeID(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw != "0x0000" else { return nil }
        return raw
    }

    private func normalizeRemovable(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        return raw.lowercased() == "yes" ? true : raw.lowercased() == "no" ? false : nil
    }
}
#endif
