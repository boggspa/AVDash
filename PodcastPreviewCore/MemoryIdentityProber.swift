import Foundation

// MARK: - MemoryModule

/// Individual memory module record (e.g., a DIMM). Used on Intel Macs with modular memory.
public struct MemoryModule: Identifiable, Codable, Sendable {
    public let id: String
    public let size: String?
    public let type: String?
    public let speed: String?
    public let status: String?
    public let manufacturer: String?
    public let partNumber: String?
    public let serialNumber: String?

    public init(
        id: String,
        size: String? = nil,
        type: String? = nil,
        speed: String? = nil,
        status: String? = nil,
        manufacturer: String? = nil,
        partNumber: String? = nil,
        serialNumber: String? = nil
    ) {
        self.id = id
        self.size = size
        self.type = type
        self.speed = speed
        self.status = status
        self.manufacturer = manufacturer
        self.partNumber = partNumber
        self.serialNumber = serialNumber
    }
}

// MARK: - MemoryUnitMetadata

/// Static hardware identity record for memory configuration.
/// Populated once on app launch via system_profiler; not tied to live usage sampling.
public struct MemoryUnitMetadata: Identifiable, Codable, Sendable {
    public let id: String
    public let totalMemory: String?
    public let architecture: String?      // Unified / DIMM / SODIMM / Unknown
    public let type: String?
    public let speed: String?
    public let ecc: String?
    public let upgradeable: Bool?
    public let manufacturerSummary: String?
    public let moduleSummary: String?
    public let slotCount: Int?
    public let populatedSlotCount: Int?
    public let chip: String?
    public let machineModel: String?
    public let modules: [MemoryModule]

    public init(
        id: String,
        totalMemory: String? = nil,
        architecture: String? = nil,
        type: String? = nil,
        speed: String? = nil,
        ecc: String? = nil,
        upgradeable: Bool? = nil,
        manufacturerSummary: String? = nil,
        moduleSummary: String? = nil,
        slotCount: Int? = nil,
        populatedSlotCount: Int? = nil,
        chip: String? = nil,
        machineModel: String? = nil,
        modules: [MemoryModule] = []
    ) {
        self.id = id
        self.totalMemory = totalMemory
        self.architecture = architecture
        self.type = type
        self.speed = speed
        self.ecc = ecc
        self.upgradeable = upgradeable
        self.manufacturerSummary = manufacturerSummary
        self.moduleSummary = moduleSummary
        self.slotCount = slotCount
        self.populatedSlotCount = populatedSlotCount
        self.chip = chip
        self.machineModel = machineModel
        self.modules = modules
    }
}

#if os(macOS)
import Combine

// MARK: - MemoryIdentityProber

/// Probes system_profiler SPMemoryDataType once on app launch to populate static memory
/// hardware metadata. Results are cached for the app lifetime; call triggerRefresh()
/// to re-probe (e.g. on wake or manual refresh).
///
/// Uses two paths:
///   JSON path  — system_profiler SPMemoryDataType SPHardwareDataType -json (Apple silicon)
///   Text path  — plain system_profiler output filtered by key lines (Intel fallback)
public final class MemoryIdentityProber: ObservableObject {
    @Published public var memoryUnit: MemoryUnitMetadata?
    @Published public var isLoading: Bool = false
    @Published public var lastProbeDate: Date? = nil

    public init() {}

    /// Probe once; no-op if results are already cached.
    public func start() {
        guard memoryUnit == nil else { return }
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
            let unit = self.runProbe()
            DispatchQueue.main.async {
                self.memoryUnit = unit
                self.isLoading = false
                self.lastProbeDate = Date()
            }
        }
    }

    private func runProbe() -> MemoryUnitMetadata? {
        let jsonUnit = probeViaJSON()
        let plainTextUnit = probeViaPlainText()
        return mergeProbeResults(json: jsonUnit, plainText: plainTextUnit)
    }

    // MARK: JSON path

    private func probeViaJSON() -> MemoryUnitMetadata? {
        let script = """
import sys,json;\
data=json.load(sys.stdin);\
mem=data.get("SPMemoryDataType",[]);\
if not mem: print(None); sys.exit(0);\
item=mem[0];\
print(json.dumps({"total":item.get("spm_memory_size"),"type":item.get("spm_memory_type"),\
"speed":item.get("spm_memory_speed"),"ecc":item.get("spm_memory_ecc"),\
"upgradeable":item.get("spm_memory_upgradeable"),"slots":item.get("spm_memory_slots"),\
"populated":item.get("spm_memory_slots_populated"),"chip":item.get("spm_memory_chip"),\
"manufacturer":item.get("spm_memory_manufacturer"),"modules":item.get("spm_memory_items",[])}))
"""
        let spTask = Process()
        spTask.launchPath = "/usr/sbin/system_profiler"
        spTask.arguments = ["SPMemoryDataType", "-json"]
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
        guard let outputStr = String(data: output, encoding: .utf8),
              outputStr != "None",
              let parsed = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else { return nil }
        return parseJSONEntry(parsed)
    }

    // MARK: Plain-text fallback

    private func probeViaPlainText() -> MemoryUnitMetadata? {
        let task = Process()
        task.launchPath = "/usr/sbin/system_profiler"
        task.arguments = ["SPMemoryDataType"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        return parsePlainText(output)
    }

    // MARK: - JSON parsing

    private func parseJSONEntry(_ dict: [String: Any]) -> MemoryUnitMetadata {
        let totalMemory = dict["total"] as? String
        let modules = (dict["modules"] as? [[String: Any]]).map { parseJSONModules($0) } ?? []
        let architecture = inferArchitecture(modules: modules, totalMemory: totalMemory)

        return MemoryUnitMetadata(
            id: "memory",
            totalMemory: totalMemory,
            architecture: architecture,
            type: dict["type"] as? String,
            speed: dict["speed"] as? String,
            ecc: dict["ecc"] as? String,
            upgradeable: parseBool(dict["upgradeable"] as? String),
            manufacturerSummary: dict["manufacturer"] as? String,
            moduleSummary: nil,
            slotCount: (dict["slots"] as? String).flatMap(Int.init),
            populatedSlotCount: (dict["populated"] as? String).flatMap(Int.init),
            chip: dict["chip"] as? String,
            machineModel: nil,
            modules: modules
        )
    }

    private func parseJSONModules(_ array: [[String: Any]]) -> [MemoryModule] {
        return array.enumerated().map { index, dict in
            MemoryModule(
                id: "module-\(index)",
                size: dict["size"] as? String,
                type: dict["type"] as? String,
                speed: dict["speed"] as? String,
                status: dict["status"] as? String,
                manufacturer: dict["manufacturer"] as? String,
                partNumber: dict["part_number"] as? String,
                serialNumber: dict["serial_number"] as? String
            )
        }
    }

    // MARK: - Plain-text parsing

    private func parsePlainText(_ output: String) -> MemoryUnitMetadata? {
        var totalMemory: String?
        var memoryType: String?
        var speed: String?
        var ecc: String?
        var upgradeable: String?
        var slots: String?
        var modules: [MemoryModule] = []
        var currentModule: [String: String] = [:]
        var moduleIndex = 0

        for line in output.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)

            if t.hasPrefix("Memory:") {
                totalMemory = extractValue(from: t, key: "Memory:")
            } else if t.hasPrefix("Type:") {
                memoryType = extractValue(from: t, key: "Type:")
            } else if t.hasPrefix("Speed:") {
                speed = extractValue(from: t, key: "Speed:")
            } else if t.hasPrefix("ECC:") {
                ecc = extractValue(from: t, key: "ECC:")
            } else if t.hasPrefix("Upgradeable:") {
                upgradeable = extractValue(from: t, key: "Upgradeable:")
            } else if t.hasPrefix("Slots:") {
                slots = extractValue(from: t, key: "Slots:")
            } else if t.hasPrefix("Bank:") || t.hasPrefix("DIMM") {
                if !currentModule.isEmpty {
                    if let module = buildModuleFromPlainText(currentModule, index: moduleIndex) {
                        modules.append(module)
                        moduleIndex += 1
                    }
                }
                currentModule = [:]
                currentModule["bank"] = t
            } else if t.hasPrefix("Size:") {
                currentModule["size"] = extractValue(from: t, key: "Size:")
            } else if t.hasPrefix("Type:") {
                currentModule["type"] = extractValue(from: t, key: "Type:")
            } else if t.hasPrefix("Speed:") {
                currentModule["speed"] = extractValue(from: t, key: "Speed:")
            } else if t.hasPrefix("Status:") {
                currentModule["status"] = extractValue(from: t, key: "Status:")
            } else if t.hasPrefix("Manufacturer:") {
                currentModule["manufacturer"] = extractValue(from: t, key: "Manufacturer:")
            } else if t.hasPrefix("Part Number:") {
                currentModule["part_number"] = extractValue(from: t, key: "Part Number:")
            } else if t.hasPrefix("Serial Number:") {
                currentModule["serial_number"] = extractValue(from: t, key: "Serial Number:")
            }
        }

        if !currentModule.isEmpty, let module = buildModuleFromPlainText(currentModule, index: moduleIndex) {
            modules.append(module)
        }

        let architecture = inferArchitecture(modules: modules, totalMemory: totalMemory)
        let populatedCount = modules.isEmpty ? nil : modules.count

        return MemoryUnitMetadata(
            id: "memory",
            totalMemory: totalMemory,
            architecture: architecture,
            type: memoryType,
            speed: speed,
            ecc: ecc,
            upgradeable: parseBool(upgradeable),
            manufacturerSummary: modules.compactMap { $0.manufacturer }.isEmpty ? nil : "Mixed",
            moduleSummary: nil,
            slotCount: slots.flatMap(Int.init),
            populatedSlotCount: populatedCount,
            chip: nil,
            machineModel: nil,
            modules: modules
        )
    }

    private func buildModuleFromPlainText(_ dict: [String: String], index: Int) -> MemoryModule? {
        guard let size = dict["size"] else { return nil }
        return MemoryModule(
            id: "module-\(index)",
            size: size,
            type: dict["type"],
            speed: dict["speed"],
            status: dict["status"],
            manufacturer: dict["manufacturer"],
            partNumber: dict["part_number"],
            serialNumber: dict["serial_number"]
        )
    }

    private func extractValue(from line: String, key: String) -> String {
        guard line.hasPrefix(key) else { return "" }
        return String(line.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
    }

    private func parseBool(_ value: String?) -> Bool? {
        guard let value = value else { return nil }
        let v = value.lowercased()
        return v == "yes" ? true : v == "no" ? false : nil
    }

    private func inferArchitecture(modules: [MemoryModule], totalMemory: String?) -> String? {
        if !modules.isEmpty {
            return "DIMM/SODIMM"
        }
        if let total = totalMemory, total.lowercased().contains("unified") {
            return "Unified"
        }
        #if arch(arm64)
        return "Unified"
        #else
        return "DIMM/SODIMM"
        #endif
    }

    private func mergeProbeResults(json: MemoryUnitMetadata?, plainText: MemoryUnitMetadata?) -> MemoryUnitMetadata? {
        guard let json = json else { return plainText }
        guard let plainText = plainText else { return json }

        // Prefer JSON but merge in modules from plain text if JSON has none
        let mergedModules = json.modules.isEmpty ? plainText.modules : json.modules
        let mergedArchitecture = json.architecture ?? plainText.architecture
        let mergedSlotCount = json.slotCount ?? plainText.slotCount
        let mergedPopulatedSlotCount = json.populatedSlotCount ?? plainText.populatedSlotCount

        return MemoryUnitMetadata(
            id: json.id,
            totalMemory: json.totalMemory ?? plainText.totalMemory,
            architecture: mergedArchitecture,
            type: json.type ?? plainText.type,
            speed: json.speed ?? plainText.speed,
            ecc: json.ecc ?? plainText.ecc,
            upgradeable: json.upgradeable ?? plainText.upgradeable,
            manufacturerSummary: json.manufacturerSummary ?? plainText.manufacturerSummary,
            moduleSummary: json.moduleSummary ?? plainText.moduleSummary,
            slotCount: mergedSlotCount,
            populatedSlotCount: mergedPopulatedSlotCount,
            chip: json.chip ?? plainText.chip,
            machineModel: json.machineModel ?? plainText.machineModel,
            modules: mergedModules
        )
    }
}
#endif
