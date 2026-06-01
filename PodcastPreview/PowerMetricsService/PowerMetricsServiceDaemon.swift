// File: PowerMetricsServiceDaemon.swift
// PodcastPreview Helper (daemon target)
// Helper-side implementation that conforms to the XPC protocol.

import Foundation
import Darwin
import os.log

final class PowerMetricsServiceDaemon: NSObject, PowerMetricsXPCProtocol {
    private static let powermetricsTimeout: TimeInterval = 5.0
    private static let sampleReuseWindow: TimeInterval = 4.5
    private static let usableSampleGraceWindow: TimeInterval = 8.0
    private static let maxPowerWatts: Double = 1_000
    private static let maxCPUFrequencyHz: Double = 10_000_000_000
    private static let maxGPUFrequencyHz: Double = 10_000_000_000
    private static let diagnosticTimestampFormatter = ISO8601DateFormatter()

    private let logger = Logger(subsystem: PowerMetricsServiceConstants.activeHelperBundleID, category: "Daemon")
    private let samplingStateQueue = DispatchQueue(
        label: "com.chrisizatt.PodcastPreview.PowerMetricsServiceDaemon"
    )
    private var pendingReplies: [(Data?) -> Void] = []
    private var isSampling = false
    private var lastSampleData: Data?
    private var lastSampleDate: Date?
    private var lastUsableSampleData: Data?
    private var lastUsableSampleDate: Date?
    private var consecutiveFailureCount = 0
    private var lastFailureReason: String?
    private var lastExitStatus: Int32?
    private var lastDurationSeconds: TimeInterval?
    private var lastStderrSuffix: String?
    private var lastPayloadTopLevelKeys: [String] = []

    func ping(withReply reply: @escaping (String) -> Void) {
        reply("pong")
    }

    func fetchHealth(withReply reply: @escaping (Data?) -> Void) {
        samplingStateQueue.async {
            let snapshot = PowerMetricsHealthSnapshot(
                isSampling: self.isSampling,
                lastSampleDate: self.lastSampleDate,
                lastUsableSampleDate: self.lastUsableSampleDate,
                consecutiveFailureCount: self.consecutiveFailureCount,
                lastFailureReason: self.lastFailureReason,
                lastExitStatus: self.lastExitStatus,
                lastDurationSeconds: self.lastDurationSeconds,
                lastStderrSuffix: self.lastStderrSuffix,
                lastPayloadTopLevelKeys: self.lastPayloadTopLevelKeys
            )
            reply(try? PropertyListEncoder.powerMetricsHealthEncoder.encode(snapshot))
        }
    }

    func fetchPowerMetricsSample(withReply reply: @escaping (Data?) -> Void) {
        samplingStateQueue.async {
            let now = Date()

            if let lastSampleData = self.lastSampleData,
               let lastSampleDate = self.lastSampleDate,
               now.timeIntervalSince(lastSampleDate) < Self.sampleReuseWindow {
                reply(lastSampleData)
                return
            }

            self.pendingReplies.append(reply)
            guard !self.isSampling else { return }
            self.isSampling = true

            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let (data, isUsable) = self.resolvePowerMetricsSample()

                self.samplingStateQueue.async {
                    let completionDate = Date()
                    var resolvedData = data

                    if isUsable, let data {
                        self.lastUsableSampleData = data
                        self.lastUsableSampleDate = completionDate
                        self.consecutiveFailureCount = 0
                        self.lastFailureReason = nil
                    } else if let lastUsableSampleData = self.lastUsableSampleData,
                              let lastUsableSampleDate = self.lastUsableSampleDate,
                              completionDate.timeIntervalSince(lastUsableSampleDate) < Self.usableSampleGraceWindow {
                        resolvedData = lastUsableSampleData
                        self.consecutiveFailureCount += 1
                        self.writeDiagnostic("reusing recent usable power sample after helper refresh failed")
                    } else {
                        self.consecutiveFailureCount += 1
                    }

                    self.lastSampleData = resolvedData
                    self.lastSampleDate = completionDate
                    self.isSampling = false

                    let replies = self.pendingReplies
                    self.pendingReplies.removeAll()
                    replies.forEach { $0(resolvedData) }

                    if self.consecutiveFailureCount >= 3 {
                        self.writeDiagnostic("exiting after \(self.consecutiveFailureCount) consecutive power sample failures")
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
                            exit(EX_TEMPFAIL)
                        }
                    }
                }
            }
        }
    }

    private func writeDiagnostic(_ message: String) {
        let timestamp = Self.diagnosticTimestampFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    private struct NormalizedSample {
        let data: Data
        let isUsable: Bool
        let topLevelKeys: [String]
    }

    private func resolvePowerMetricsSample() -> (Data?, Bool) {
        do {
            let result = try runPowermetricsOnce()
            lastExitStatus = result.exitStatus
            lastDurationSeconds = result.durationSeconds
            lastStderrSuffix = result.stderrSuffix

            if result.timedOut {
                lastFailureReason = "powermetrics-timeout"
                logger.error("powermetrics timed out after \(Self.powermetricsTimeout, format: .fixed(precision: 1))s")
                if !result.stderrSuffix.isEmpty {
                    writeDiagnostic("powermetrics timeout stderr: \(result.stderrSuffix)")
                }
                return (makeDiagnosticFallbackPayload(reason: "powermetrics-timeout"), false)
            }

            if result.exitStatus != 0 {
                lastFailureReason = "powermetrics-exit-\(result.exitStatus)"
                if !result.stderrSuffix.isEmpty {
                    writeDiagnostic("powermetrics exited \(result.exitStatus): \(result.stderrSuffix)")
                } else {
                    writeDiagnostic("powermetrics exited with status \(result.exitStatus) and no stderr")
                }
                return (makeDiagnosticFallbackPayload(reason: "powermetrics-exit-\(result.exitStatus)"), false)
            }

            if !result.stdoutData.isEmpty {
                if let normalized = try normalizedPowerMetricsPayload(from: result.stdoutData) {
                    lastPayloadTopLevelKeys = normalized.topLevelKeys
                    return (normalized.data, normalized.isUsable)
                }

                lastFailureReason = "unusable-powermetrics-payload"
                writeDiagnostic("powermetrics returned data, but normalization produced no usable payload")
            } else {
                lastFailureReason = "powermetrics-empty-stdout"
                writeDiagnostic("powermetrics exited 0 with empty stdout after \(String(format: "%.2f", result.durationSeconds))s")
            }
        } catch {
            logger.error("powermetrics execution error: \(String(describing: error as NSError))")
            lastFailureReason = "powermetrics-execution-error"
            writeDiagnostic("powermetrics execution error: \(error.localizedDescription)")
        }

        writeDiagnostic("returning diagnostic fallback payload instead of numeric power readings")
        return (makeDiagnosticFallbackPayload(reason: lastFailureReason ?? "powermetrics-unavailable"), false)
    }

    private func makeDiagnosticFallbackPayload(reason: String) -> Data? {
        let payload: [String: Any] = [
            "processor": [:],
            "gpu": [:],
            "generated_by": "PowerMetricsServiceDaemon diagnostic fallback",
            "diagnostic": [
                "reason": reason
            ]
        ]
        return try? PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
    }

    private func normalizedPowerMetricsPayload(from data: Data) throws -> NormalizedSample? {
        let plist = try PropertyListSerialization.propertyList(from: data.trimmingTrailingNULBytes(), options: [], format: nil)
        guard let root = plist as? [String: Any] else { return nil }
        let topLevelKeys = root.keys.sorted()

        let processor = root["processor"] as? [String: Any] ?? [:]
        let gpu = root["gpu"] as? [String: Any] ?? [:]

        // Extract power values with fallback calculation for Intel Macs
        let cpuPower = extractCPUPower(from: processor)
        let gpuPower = Self.sanitizedPowerMilliwatts(processor["gpu_power"])
        let anePower = Self.sanitizedPowerMilliwatts(processor["ane_power"]) // Will be nil on Intel
        
        // Combined power: prefer explicit value, fall back to package_watts, then sum
        let combinedPower: Double? = {
            if let combined = Self.sanitizedPowerMilliwatts(processor["combined_power"]) {
                return combined
            }
            if let packageWatts = Self.sanitizedPowerWatts(processor["package_watts"]) {
                return packageWatts * 1000.0 // Convert watts to milliwatts
            }
            let components = [cpuPower, gpuPower, anePower].compactMap { $0 }
            return components.isEmpty ? nil : components.reduce(0, +)
        }()

        let perCoreFrequencies = extractPerCoreFrequencies(from: processor)
        let gpuFrequencyHz = Self.sanitizedFrequencyHz(gpu["freq_hz"], maximumHz: Self.maxGPUFrequencyHz)

        var normalizedProcessor: [String: Any] = [:]
        if let cpuPower { normalizedProcessor["cpu_power"] = cpuPower }
        if let gpuPower { normalizedProcessor["gpu_power"] = gpuPower }
        if let anePower { normalizedProcessor["ane_power"] = anePower }
        if let combinedPower { normalizedProcessor["combined_power"] = combinedPower }
        if perCoreFrequencies.contains(where: { $0 > 0 }) {
            normalizedProcessor["per_core_frequencies_hz"] = perCoreFrequencies
        }

        var normalizedGPU: [String: Any] = [:]
        if let gpuFrequencyHz { normalizedGPU["freq_hz"] = gpuFrequencyHz }

        let isUsable = [cpuPower, gpuPower, anePower, combinedPower].compactMap { $0 }.contains(where: { $0 > 0 })
            || (gpuFrequencyHz ?? 0) > 0
            || perCoreFrequencies.contains(where: { $0 > 0 })
        guard isUsable else {
            lastFailureReason = "no-usable-power-fields"
            return nil
        }

        let normalized: [String: Any] = [
            "processor": normalizedProcessor,
            "gpu": normalizedGPU,
            "thermal": root["thermal"] as? [String: Any] ?? [:],
            "generated_by": "PowerMetricsServiceDaemon normalized"
        ]

        let serializedData = try PropertyListSerialization.data(
            fromPropertyList: normalized,
            format: .xml,
            options: 0
        )
        return NormalizedSample(data: serializedData, isUsable: isUsable, topLevelKeys: topLevelKeys)
    }
    
    /// Extracts CPU power with fallback for Intel Macs
    /// Intel Macs: Look for package_watts (covers CPU+GPU+SA), convert to milliwatts
    /// Apple Silicon: Direct cpu_power value
    private func extractCPUPower(from processor: [String: Any]) -> Double? {
        if let cpuPower = Self.sanitizedPowerMilliwatts(processor["cpu_power"]) {
            return cpuPower
        }
        
        // Intel Mac fallback: package_watts includes CPU+GPU+SA (System Agent)
        // We'll use it as an approximation for combined power
        if let packageWatts = Self.sanitizedPowerWatts(processor["package_watts"]) {
            // Convert watts to milliwatts
            // Note: This is package power, not pure CPU, but it's the best we have on Intel
            return packageWatts * 1000.0
        }
        
        return nil
    }

    private func extractPerCoreFrequencies(from processor: [String: Any]) -> [Double] {
        var frequencyByCPUIndex: [Int: Double] = [:]

        // Try Apple Silicon path first: clusters → cpus
        if let clusters = processor["clusters"] as? [[String: Any]] {
            for cluster in clusters {
                guard let cpus = cluster["cpus"] as? [[String: Any]] else { continue }

                for cpu in cpus {
                    guard let cpuIndex = cpu["cpu"] as? Int else { continue }

                    if let freq = Self.sanitizedFrequencyHz(cpu["freq_hz"], maximumHz: Self.maxCPUFrequencyHz) {
                        frequencyByCPUIndex[cpuIndex] = freq
                    }
                }
            }
        }
        // Try Intel path: packages → cores → cpus
        else if let packages = processor["packages"] as? [[String: Any]] {
            for package in packages {
                guard let cores = package["cores"] as? [[String: Any]] else { continue }
                
                for core in cores {
                    guard let cpus = core["cpus"] as? [[String: Any]] else { continue }
                    
                    for cpu in cpus {
                        guard let cpuIndex = cpu["cpu"] as? Int else { continue }

                        if let freq = Self.sanitizedFrequencyHz(cpu["freq_hz"], maximumHz: Self.maxCPUFrequencyHz) {
                            frequencyByCPUIndex[cpuIndex] = freq
                        }
                    }
                }
            }
        }

        guard let maxCPUIndex = frequencyByCPUIndex.keys.max() else { return [] }
        let frequencies = (0...maxCPUIndex).map { frequencyByCPUIndex[$0] ?? 0.0 }
        return frequencies.contains(where: { $0 > 0 }) ? frequencies : []
    }

    private struct PowermetricsRunResult {
        let stdoutData: Data
        let stderrSuffix: String
        let exitStatus: Int32
        let timedOut: Bool
        let durationSeconds: TimeInterval
    }

    private func runPowermetricsOnce() throws -> PowermetricsRunResult {
        let startDate = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: PowerMetricsServiceConstants.powermetricsPath)
        process.arguments = PowerMetricsServiceConstants.powermetricsArgs

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let ioQueue = DispatchQueue(label: "com.chrisizatt.PodcastPreview.PowerMetricsServiceDaemon.powermetricsIO")
        var stdoutData = Data()
        var stderrData = Data()

        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            ioQueue.async {
                stdoutData.append(chunk)
            }
        }

        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            ioQueue.async {
                stderrData.append(chunk)
            }
        }

        let exitSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            exitSemaphore.signal()
        }

        try process.run()
        let waitResult = exitSemaphore.wait(timeout: .now() + Self.powermetricsTimeout)
        var timedOut = false
        if waitResult != .success {
            timedOut = true
            if process.isRunning {
                process.terminate()
                if exitSemaphore.wait(timeout: .now() + 0.5) != .success, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exitSemaphore.wait(timeout: .now() + 1.0)
                }
            }
        }

        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil

        if !process.isRunning {
            let remainingOut = out.fileHandleForReading.readDataToEndOfFile()
            let remainingErr = err.fileHandleForReading.readDataToEndOfFile()
            ioQueue.sync {
                stdoutData.append(remainingOut)
                stderrData.append(remainingErr)
            }
        } else {
            ioQueue.sync {}
        }

        return PowermetricsRunResult(
            stdoutData: stdoutData,
            stderrSuffix: Self.diagnosticSuffix(from: stderrData),
            exitStatus: process.isRunning ? -1 : process.terminationStatus,
            timedOut: timedOut,
            durationSeconds: Date().timeIntervalSince(startDate)
        )
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    private static func sanitizedPowerMilliwatts(_ value: Any?) -> Double? {
        guard let value = numericValue(value),
              value.isFinite,
              value >= 0 else { return nil }
        let watts = value / 1000.0
        guard watts <= maxPowerWatts else { return nil }
        return value
    }

    private static func sanitizedPowerWatts(_ value: Any?) -> Double? {
        guard let value = numericValue(value),
              value.isFinite,
              value >= 0,
              value <= maxPowerWatts else { return nil }
        return value
    }

    private static func sanitizedFrequencyHz(_ value: Any?, maximumHz: Double) -> Double? {
        guard let value = numericValue(value),
              value.isFinite,
              value >= 0,
              value <= maximumHz else { return nil }
        return value
    }

    private static func diagnosticSuffix(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let suffix = data.count > 4096 ? data.suffix(4096) : data
        return String(decoding: suffix, as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension PropertyListEncoder {
    static var powerMetricsHealthEncoder: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}

private extension Data {
    func trimmingTrailingNULBytes() -> Data {
        var endIndex = count
        while endIndex > 0, self[endIndex - 1] == 0 {
            endIndex -= 1
        }
        guard endIndex < count else { return self }
        return Data(prefix(endIndex))
    }
}
