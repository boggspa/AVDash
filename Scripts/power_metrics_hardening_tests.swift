import Foundation
import Darwin
@testable import PodcastPreviewCore

private enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure.failed(message)
    }
}

private func requireApprox(_ actual: Double?, _ expected: Double, accuracy: Double = 0.0001, _ message: String) throws {
    guard let actual, abs(actual - expected) <= accuracy else {
        throw TestFailure.failed("\(message) expected \(expected), got \(String(describing: actual))")
    }
}

private func plistData(_ root: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
}

private func runPowerMetricsHardeningTests() throws {
    let appleSilicon = try plistData([
        "processor": [
            "cpu_power": 12_600.0,
            "gpu_power": 2_300.0,
            "ane_power": 400.0,
            "combined_power": 15_300.0,
            "clusters": [
                ["cpus": [["cpu": 0, "freq_hz": 2_064_000_000.0], ["cpu": 1, "freq_hz": 2_150_000_000.0]]],
                ["cpus": [["cpu": 2, "freq_hz": 3_220_000_000.0]]]
            ]
        ],
        "gpu": ["freq_hz": 1_200_000_000.0]
    ])
    let appleReadings = PowerStatsSampler._testReadingsSnapshot(fromPowerMetricsPayload: appleSilicon, source: "apple-fixture")
    try requireApprox(appleReadings?.cpuPowerWatts, 12.6, "Apple Silicon CPU power should decode from milliwatts")
    try requireApprox(appleReadings?.gpuPowerWatts, 2.3, "Apple Silicon GPU power should decode from milliwatts")
    try requireApprox(appleReadings?.anePowerWatts, 0.4, "Apple Silicon ANE power should decode from milliwatts")
    try requireApprox(appleReadings?.combinedPowerWatts, 15.3, "Apple Silicon combined power should decode from milliwatts")
    try requireApprox(appleReadings?.gpuFrequencyMHz, 1_200, "GPU freq_hz should be converted to MHz")
    try require(appleReadings?.perCoreFrequenciesHz == [2_064_000_000.0, 2_150_000_000.0, 3_220_000_000.0], "Cluster per-core frequencies should preserve CPU indexes")
    try require(appleReadings?.sampleStatus == .live, "Parsed usable payloads should be live")
    try require(appleReadings?.source == "apple-fixture", "Parsed payload should preserve source")

    let intelPackage = try plistData([
        "processor": [
            "package_watts": 42.5,
            "packages": [
                ["cores": [
                    ["cpus": [["cpu": 0, "freq_hz": 3_200_000_000.0]]],
                    ["cpus": [["cpu": 1, "freq_hz": 3_180_000_000.0]]]
                ]]
            ]
        ],
        "gpu": [:]
    ])
    let intelReadings = PowerStatsSampler._testReadingsSnapshot(fromPowerMetricsPayload: intelPackage, source: "intel-fixture")
    try requireApprox(intelReadings?.cpuPowerWatts, 42.5, "Intel package watts should backfill CPU watts")
    try requireApprox(intelReadings?.combinedPowerWatts, 42.5, "Intel package watts should backfill combined watts")
    try require(intelReadings?.perCoreFrequenciesHz == [3_200_000_000.0, 3_180_000_000.0], "Intel package frequencies should decode")

    let allZero = try plistData([
        "processor": [
            "cpu_power": 0.0,
            "gpu_power": 0.0,
            "ane_power": 0.0,
            "combined_power": 0.0,
            "per_core_frequencies_hz": [0.0, 0.0]
        ],
        "gpu": ["freq_hz": 0.0]
    ])
    try require(PowerStatsSampler._testReadingsSnapshot(fromPowerMetricsPayload: allZero) == nil, "All-zero diagnostic payloads should be unusable")
    try require(!PowerStatsSampler.hasUsableReadings(inPowerMetricsPayload: allZero), "All-zero diagnostic payloads should not be usable")

    let sparseFrequencies = try plistData([
        "processor": [
            "per_core_frequencies_hz": [0.0, 2_000_000_000.0, -1.0, 11_000_000_000.0]
        ],
        "gpu": [:]
    ])
    let sparseReadings = PowerStatsSampler._testReadingsSnapshot(fromPowerMetricsPayload: sparseFrequencies)
    try require(sparseReadings?.perCoreFrequenciesHz == [0.0, 2_000_000_000.0, 0.0, 0.0], "Sparse per-core frequencies should keep usable values and zero invalid slots")

    var nulTerminated = appleSilicon
    nulTerminated.append(contentsOf: [0, 0, 0])
    try require(PowerStatsSampler._testReadingsSnapshot(fromPowerMetricsPayload: nulTerminated) != nil, "Trailing NUL bytes should be ignored")

    let outliers = try plistData([
        "processor": [
            "cpu_power": -1.0,
            "combined_power": 1_500_000.0,
            "per_core_frequencies_hz": [Double.infinity, Double.nan, 11_000_000_000.0]
        ],
        "gpu": ["freq_hz": 11_000_000_000.0]
    ])
    try require(PowerStatsSampler._testReadingsSnapshot(fromPowerMetricsPayload: outliers) == nil, "NaN, inf, negative, impossible GHz, and watt outliers should be rejected")

    let legacySnapshot = try plistData([
        "cpuPowerWatts": 3.4,
        "combinedPowerWatts": 5.6,
        "peakCombinedPowerWatts": 7.8,
        "cumulativeCombinedEnergyWh": 0.12,
        "perCoreFrequenciesHz": [2_000_000_000.0]
    ])
    let decodedLegacySnapshot = try PropertyListDecoder().decode(PowerStatsSampler.ReadingsSnapshot.self, from: legacySnapshot)
    try require(decodedLegacySnapshot.sampleStatus == .live, "Older readings snapshots should decode as live by default")
    try requireApprox(decodedLegacySnapshot.combinedPowerWatts, 5.6, "Older readings snapshots should preserve power values")
}

do {
    try runPowerMetricsHardeningTests()
    print("Power Metrics hardening tests passed")
} catch {
    fputs("Power Metrics hardening tests failed: \(error)\n", stderr)
    exit(1)
}
