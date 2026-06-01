import Foundation
import Combine
#if os(macOS)
import Darwin
#if canImport(IOKit)
import IOKit
#endif
#if canImport(libproc)
import libproc
#endif
#endif
#if canImport(Metal)
import Metal
#endif
import VideoToolbox

/// Tracks hardware media engine capability and recent encode/decode activity.
public final class MediaEngineStatsSampler: ObservableObject {
    public enum CapabilityKind: String, Codable, Equatable, Sendable {
        case appleMediaEngines
        case intelQuickSyncCPU
        case afterburnerPCIe
        case gpuHardwareVideo

        public var displayTitle: String {
            switch self {
            case .appleMediaEngines:
                return "Media Engines"
            case .intelQuickSyncCPU:
                return "Intel Quick Sync (CPU)"
            case .afterburnerPCIe:
                return "Afterburner Card (PCIe x16)"
            case .gpuHardwareVideo:
                return "GPU Hardware Encode/Decode"
            }
        }
    }

    public enum SessionRole: String, Codable, Sendable {
        case encode
        case decode

        public var displayText: String {
            switch self {
            case .encode:
                return "Encode"
            case .decode:
                return "Decode"
            }
        }
    }

    public struct RecentSession: Codable, Equatable, Identifiable, Sendable {
        public var sessionID: Int
        public var role: SessionRole
        public var codec: String
        public var width: Int?
        public var height: Int?
        public var lastEventDate: Date
        public var lastMeaningfulDate: Date?
        public var framesInput: Int?
        public var framesProcessed: Int?
        public var framesDropped: Int?
        public var lastClientName: String?
        public var isCompleted: Bool

        public init(
            sessionID: Int,
            role: SessionRole,
            codec: String,
            width: Int?,
            height: Int?,
            lastEventDate: Date,
            lastMeaningfulDate: Date?,
            framesInput: Int?,
            framesProcessed: Int?,
            framesDropped: Int?,
            lastClientName: String?,
            isCompleted: Bool
        ) {
            self.sessionID = sessionID
            self.role = role
            self.codec = codec
            self.width = width
            self.height = height
            self.lastEventDate = lastEventDate
            self.lastMeaningfulDate = lastMeaningfulDate
            self.framesInput = framesInput
            self.framesProcessed = framesProcessed
            self.framesDropped = framesDropped
            self.lastClientName = lastClientName
            self.isCompleted = isCompleted
        }

        public var id: String {
            "\(role.rawValue)-\(sessionID)"
        }

        // Computed text properties for consuming code
        public var codecText: String {
            codec.isEmpty ? "—" : codec
        }

        public var roleText: String {
            role.displayText
        }

        public var resolutionText: String? {
            guard let width, let height else { return nil }
            return "\(width)x\(height)"
        }

        public var lastActivityDate: Date {
            lastMeaningfulDate ?? lastEventDate
        }
    }

    public struct CapabilityState: Codable, Equatable, Sendable {
        public var capabilityKind: CapabilityKind
        public var isSupported: Bool
        public var hasEverDetectedSupport: Bool
        public var shouldShowCard: Bool
        public var supportsEncode: Bool
        public var supportsDecode: Bool
        public var supportedEncodeCodecs: [String]
        public var supportedDecodeCodecs: [String]
        public var displayTitle: String
        public var pathDescription: String
        public var pathDeviceName: String?

        public init(
            capabilityKind: CapabilityKind,
            isSupported: Bool,
            hasEverDetectedSupport: Bool,
            shouldShowCard: Bool,
            supportsEncode: Bool,
            supportsDecode: Bool,
            supportedEncodeCodecs: [String],
            supportedDecodeCodecs: [String],
            displayTitle: String? = nil,
            pathDescription: String,
            pathDeviceName: String? = nil
        ) {
            self.capabilityKind = capabilityKind
            self.isSupported = isSupported
            self.hasEverDetectedSupport = hasEverDetectedSupport
            self.shouldShowCard = shouldShowCard
            self.supportsEncode = supportsEncode
            self.supportsDecode = supportsDecode
            self.supportedEncodeCodecs = supportedEncodeCodecs
            self.supportedDecodeCodecs = supportedDecodeCodecs
            self.displayTitle = displayTitle ?? capabilityKind.displayTitle
            self.pathDescription = pathDescription
            self.pathDeviceName = pathDeviceName
        }

        public var supportedCodecsText: String {
            let codecs = supportedEncodeCodecs + supportedDecodeCodecs
            return codecs.isEmpty ? "—" : Set(codecs).sorted().joined(separator: " / ")
        }

        // Computed text properties for consuming code
        public var supportedEncodeCodecsText: String {
            supportedEncodeCodecs.isEmpty ? "—" : supportedEncodeCodecs.joined(separator: " / ")
        }

        public var supportedDecodeCodecsText: String {
            supportedDecodeCodecs.isEmpty ? "—" : supportedDecodeCodecs.joined(separator: " / ")
        }
    }

    public struct ActivitySummary: Codable, Equatable, Sendable {
        public var activityState: ActivityState
        public var activityValue: Double
        public var codec: String?
        public var recentProcessedFrames: Int
        public var retainedSessionCount: Int
        public var recentEncoderPathCount: Int
        public var activeSessionCount: Int
        public var lastMeaningfulActivityDate: Date?

        public init(
            activityState: ActivityState,
            activityValue: Double,
            codec: String? = nil,
            recentProcessedFrames: Int,
            retainedSessionCount: Int,
            recentEncoderPathCount: Int,
            activeSessionCount: Int,
            lastMeaningfulActivityDate: Date?
        ) {
            self.activityState = activityState
            self.activityValue = activityValue
            self.codec = codec
            self.recentProcessedFrames = recentProcessedFrames
            self.retainedSessionCount = retainedSessionCount
            self.recentEncoderPathCount = recentEncoderPathCount
            self.activeSessionCount = activeSessionCount
            self.lastMeaningfulActivityDate = lastMeaningfulActivityDate
        }

        public var statusText: String {
            switch activityState {
            case .idle: return "Idle"
            case .active: return "Active"
            case .busy: return "Busy"
            }
        }

        public var subtitleText: String {
            if let codec, !codec.isEmpty {
                return "Hardware encode available: \(codec)"
            }
            return "Hardware encode available"
        }

        public func subtitleText(supportsEncode: Bool) -> String {
            subtitleText
        }

        public var codecText: String {
            guard let codec, !codec.isEmpty else { return "—" }
            return codec
        }

        public var framesProcessedText: String {
            retainedSessionCount > 0 ? "\(recentProcessedFrames)" : "—"
        }

        public var sessionsText: String {
            if retainedSessionCount > 0 {
                return "\(retainedSessionCount) recent \(retainedSessionCount == 1 ? "session" : "sessions")"
            }
            return "—"
        }

        public var lastActiveText: String {
            guard lastMeaningfulActivityDate != nil else { return "—" }
            return "Active recently"
        }
    }

    public enum ActivityState: String, Codable, Sendable {
        case idle
        case active
        case busy
    }

    @Published public var isSupported: Bool = false
    @Published public var hasEverDetectedSupport: Bool = false
    @Published public var shouldShowCard: Bool = false
    @Published public var isActive: Bool = false
    @Published public var supportsEncode: Bool = false
    @Published public var supportsDecode: Bool = false
    @Published public var supportedCodecsText: String = "—"

    @Published public var subtitleText: String = "Hardware encode available"
    @Published public var statusText: String = "Idle"
    @Published public var codecText: String = "—"
    @Published public var framesProcessedText: String = "—"
    @Published public var sessionsText: String = "—"
    @Published public var lastActiveText: String = "—"

    @Published public var activityState: ActivityState = .idle
    @Published public var activityValue: Float = 0.0
    @Published public var activityHistory: [Float] = []
    @Published public private(set) var activitySeries = MediaEngineStatsSampler.makeSeries()
    @Published public private(set) var latestSnapshot: HardwareSnapshot? = nil
    @Published public private(set) var recentSessions: [RecentSession] = []
    @Published public private(set) var latestCapabilityState: CapabilityState? = nil
    @Published public private(set) var latestActivitySummary: ActivitySummary? = nil

    private var timer: DispatchSourceTimer?
    private var isExternallyClocked = false
    private var lastVTProcessSample: [Int32: VTProcessSample] = [:]
    private var lastSampleDate: Date?
    private var lastComputedActivityValue: Float = 0
    private var activitySeriesBuffer = MediaEngineStatsSampler.makeSeries()
    private let samplingQueue = DispatchQueue(label: "MediaEngineStatsSampler.sample", qos: .utility)

    private static let samplingIntervalSeconds = 5
    private static let vtProcessCPUTriggerPercent = 0.15
    private static let vtProcessSignalNormalizationPercent = 3.0

    private var historyLength: Int {
        HardwareCollectionSettings.liveSeriesCapacity(
            sampleIntervalSeconds: Self.samplingIntervalSeconds
        )
    }

    private struct CapabilitySnapshot {
        var capabilityKind: CapabilityKind
        var isSupported: Bool
        var supportsEncode: Bool
        var supportsDecode: Bool
        var supportedEncodeCodecs: [String]
        var supportedDecodeCodecs: [String]
        var displayTitle: String
        var pathDescription: String
        var pathDeviceName: String?
    }

    private struct VideoEncoderDescriptor {
        var codec: String
        var encoderName: String
        var displayName: String
        var encoderID: String
        var gpuRegistryID: UInt64?
    }

    private struct VTProcessSample {
        var cpuNS: UInt64
        var t: TimeInterval
        var role: SessionRole
    }

    private struct VTProcessActivity {
        var encoderCount: Int = 0
        var decoderCount: Int = 0
        var activeEncoderCount: Int = 0
        var activeDecoderCount: Int = 0
        var encoderCPUPercent: Double = 0
        var decoderCPUPercent: Double = 0

        var activeProcessCount: Int {
            activeEncoderCount + activeDecoderCount
        }

        var totalCPUPercent: Double {
            encoderCPUPercent + decoderCPUPercent
        }

        var hasAnyVTProcess: Bool {
            (encoderCount + decoderCount) > 0
        }

        var signalValue: Float {
            guard totalCPUPercent > 0 else { return 0 }
            return min(
                max(Float(totalCPUPercent / MediaEngineStatsSampler.vtProcessSignalNormalizationPercent), 0.08),
                0.45
            )
        }
    }

    private struct TaskInfo {
        var userNS: UInt64
        var systemNS: UInt64
    }

    public init() {}

    public func start() {
        stop()
        isExternallyClocked = false
        resetSamplingState()
        publishBaselineState()

        let presentationInterval = max(1, HardwareCollectionSettings.collectorIntervalSeconds())
        let timer = DispatchSource.makeTimerSource(queue: samplingQueue)
        timer.schedule(deadline: .now() + .seconds(presentationInterval), repeating: .seconds(presentationInterval))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer

        samplingQueue.async { [weak self] in
            self?.sample()
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        isExternallyClocked = false
        resetSamplingState()
        DispatchQueue.main.async {
            self.latestSnapshot = nil
        }
    }

    public func initializeForExternalClock() {
        timer?.cancel()
        timer = nil
        isExternallyClocked = true
        resetSamplingState()
        publishBaselineState()
    }

    public func triggerTick() {
        guard isExternallyClocked else { return }
        samplingQueue.async { [weak self] in
            self?.tick()
        }
    }

    public static func makeSeries() -> MetricSeries {
        MetricSeries(key: .mediaEngineActivityRatio, unit: .ratio)
    }

    private func resetSamplingState() {
        lastVTProcessSample.removeAll()
        lastSampleDate = nil
        lastComputedActivityValue = 0
        activitySeriesBuffer = Self.makeSeries()
    }

    private func publishBaselineState() {
        let capability = Self.detectCapability()
        let detectedSupport = capability.isSupported
        let capabilityState = CapabilityState(
            capabilityKind: capability.capabilityKind,
            isSupported: detectedSupport,
            hasEverDetectedSupport: hasEverDetectedSupport || detectedSupport,
            shouldShowCard: detectedSupport || hasEverDetectedSupport,
            supportsEncode: capability.supportsEncode,
            supportsDecode: capability.supportsDecode,
            supportedEncodeCodecs: capability.supportedEncodeCodecs,
            supportedDecodeCodecs: capability.supportedDecodeCodecs,
            displayTitle: capability.displayTitle,
            pathDescription: capability.pathDescription,
            pathDeviceName: capability.pathDeviceName
        )
        let activitySummary = ActivitySummary(
            activityState: .idle,
            activityValue: 0,
            recentProcessedFrames: 0,
            retainedSessionCount: 0,
            recentEncoderPathCount: 0,
            activeSessionCount: 0,
            lastMeaningfulActivityDate: nil
        )
        let latestSnapshot = Self.makeLatestSnapshot(activityValue: 0, timestamp: Date())

        DispatchQueue.main.async {
            self.latestCapabilityState = capabilityState
            self.latestActivitySummary = activitySummary
            self.hasEverDetectedSupport = capabilityState.hasEverDetectedSupport
            self.isSupported = capabilityState.isSupported
            self.shouldShowCard = capabilityState.shouldShowCard
            self.isActive = false
            self.supportsEncode = capabilityState.supportsEncode
            self.supportsDecode = capabilityState.supportsDecode
            self.supportedCodecsText = capabilityState.supportedCodecsText
            self.subtitleText = capabilityState.pathDescription
            self.statusText = activitySummary.statusText
            self.codecText = activitySummary.codecText
            self.framesProcessedText = activitySummary.framesProcessedText
            self.sessionsText = activitySummary.sessionsText
            self.lastActiveText = activitySummary.lastActiveText
            self.activityState = activitySummary.activityState
            self.activityValue = Float(activitySummary.activityValue)
            self.activityHistory = []
            self.activitySeries = Self.makeSeries()
            self.latestSnapshot = latestSnapshot
            self.recentSessions = []
        }
    }

    private func tick() {
        let now = Date()
        guard let lastSampleDate else {
            sample()
            return
        }

        guard now.timeIntervalSince(lastSampleDate) >= TimeInterval(Self.samplingIntervalSeconds) else {
            appendHeldHistorySample()
            return
        }
        sample()
    }

    private func sample() {
        let now = Date()
        lastSampleDate = now

        let capability = Self.detectCapability()
        let vtProcessActivity = sampleVTProcessActivity(at: now)
        let activeSessionCount = vtProcessActivity.activeProcessCount
        let observedSessionCount = vtProcessActivity.encoderCount + vtProcessActivity.decoderCount
        let activityState: ActivityState = {
            guard vtProcessActivity.hasAnyVTProcess else { return .idle }
            if activeSessionCount >= 2 || vtProcessActivity.totalCPUPercent >= 1.0 {
                return .busy
            }
            return .active
        }()
        let activityValue: Float = {
            switch activityState {
            case .idle:
                return 0
            case .active:
                let encodePathSignal: Float = vtProcessActivity.encoderCount > 0 ? 0.28 : 0
                let decodePathSignal: Float = vtProcessActivity.decoderCount > 0 ? 0.18 : 0
                return max(max(encodePathSignal, decodePathSignal), vtProcessActivity.signalValue)
            case .busy:
                let multiSessionSignal: Float = activeSessionCount >= 2 ? 0.82 : 0
                return max(max(vtProcessActivity.signalValue, 0.72), multiSessionSignal)
            }
        }()

        let supportsEncode = capability.supportsEncode || vtProcessActivity.encoderCount > 0
        let supportsDecode = capability.supportsDecode || vtProcessActivity.decoderCount > 0
        let capabilityState = CapabilityState(
            capabilityKind: capability.capabilityKind,
            isSupported: capability.isSupported,
            hasEverDetectedSupport: hasEverDetectedSupport || capability.isSupported,
            shouldShowCard: capability.isSupported || hasEverDetectedSupport,
            supportsEncode: supportsEncode,
            supportsDecode: supportsDecode,
            supportedEncodeCodecs: capability.supportedEncodeCodecs,
            supportedDecodeCodecs: capability.supportedDecodeCodecs,
            displayTitle: capability.displayTitle,
            pathDescription: capability.pathDescription,
            pathDeviceName: capability.pathDeviceName
        )
        let activitySummary = ActivitySummary(
            activityState: activityState,
            activityValue: Double(activityValue),
            codec: capabilityState.supportedEncodeCodecs.first,
            recentProcessedFrames: 0,
            retainedSessionCount: observedSessionCount,
            recentEncoderPathCount: observedSessionCount,
            activeSessionCount: activeSessionCount,
            lastMeaningfulActivityDate: activityState == .idle ? nil : now
        )

        publish(
            capabilityState: capabilityState,
            activitySummary: activitySummary,
            recentSessions: Self.makeRecentSessions(
                encoderCount: vtProcessActivity.encoderCount,
                decoderCount: vtProcessActivity.decoderCount,
                timestamp: now,
                codec: capabilityState.supportedEncodeCodecs.first ?? capabilityState.supportedDecodeCodecs.first ?? "Generic Media"
            ),
            activityValue: activityValue,
            timestamp: now
        )
    }

    private func appendHeldHistorySample() {
        let now = Date()
        let heldValue = lastComputedActivityValue
        activitySeriesBuffer.append(Double(heldValue), at: now, capacity: historyLength)
        let activitySeries = activitySeriesBuffer
        DispatchQueue.main.async {
            self.activityHistory.append(heldValue)
            if self.activityHistory.count > self.historyLength {
                self.activityHistory.removeFirst(self.activityHistory.count - self.historyLength)
            }
            self.activitySeries = activitySeries
        }
    }

    private func publish(
        capabilityState: CapabilityState,
        activitySummary: ActivitySummary,
        recentSessions: [RecentSession],
        activityValue: Float,
        timestamp: Date
    ) {
        lastComputedActivityValue = activityValue
        activitySeriesBuffer.append(Double(activityValue), at: timestamp, capacity: historyLength)
        let activitySeries = activitySeriesBuffer
        let latestSnapshot = Self.makeLatestSnapshot(activityValue: Double(activityValue), timestamp: timestamp)
        DispatchQueue.main.async {
            self.latestCapabilityState = capabilityState
            self.latestActivitySummary = activitySummary
            self.hasEverDetectedSupport = capabilityState.hasEverDetectedSupport
            self.isSupported = capabilityState.isSupported
            self.shouldShowCard = capabilityState.shouldShowCard
            self.isActive = activitySummary.activityState != .idle
            self.supportsEncode = capabilityState.supportsEncode
            self.supportsDecode = capabilityState.supportsDecode
            self.supportedCodecsText = capabilityState.supportedCodecsText
            self.subtitleText = activitySummary.subtitleText(supportsEncode: capabilityState.supportsEncode)
            self.statusText = activitySummary.statusText
            self.codecText = activitySummary.codecText
            self.framesProcessedText = activitySummary.framesProcessedText
            self.sessionsText = activitySummary.sessionsText
            self.lastActiveText = activitySummary.lastActiveText
            self.activityState = activitySummary.activityState
            self.activityValue = Float(activitySummary.activityValue)
            self.activityHistory.append(activityValue)
            if self.activityHistory.count > self.historyLength {
                self.activityHistory.removeFirst(self.activityHistory.count - self.historyLength)
            }
            self.activitySeries = activitySeries
            self.latestSnapshot = latestSnapshot
            self.recentSessions = recentSessions
        }
    }

    private static func makeLatestSnapshot(activityValue: Double, timestamp: Date) -> HardwareSnapshot {
        var snapshot = HardwareSnapshot(timestamp: timestamp)
        snapshot.setMetric(.mediaEngineActivityRatio, value: min(max(activityValue, 0), 1))
        return snapshot
    }

    private static func makeRecentSessions(
        encoderCount: Int,
        decoderCount: Int,
        timestamp: Date,
        codec: String
    ) -> [RecentSession] {
        var sessions: [RecentSession] = []
        for index in 0..<encoderCount {
            sessions.append(
                RecentSession(
                    sessionID: 10_000 + index,
                    role: .encode,
                    codec: codec,
                    width: nil,
                    height: nil,
                    lastEventDate: timestamp,
                    lastMeaningfulDate: timestamp,
                    framesInput: nil,
                    framesProcessed: nil,
                    framesDropped: nil,
                    lastClientName: "VTEncoderXPCService",
                    isCompleted: false
                )
            )
        }
        for index in 0..<decoderCount {
            sessions.append(
                RecentSession(
                    sessionID: 20_000 + index,
                    role: .decode,
                    codec: codec,
                    width: nil,
                    height: nil,
                    lastEventDate: timestamp,
                    lastMeaningfulDate: timestamp,
                    framesInput: nil,
                    framesProcessed: nil,
                    framesDropped: nil,
                    lastClientName: "VTDecoderXPCService",
                    isCompleted: false
                )
            )
        }
        return sessions
    }

    private static func detectCapability() -> CapabilitySnapshot {
        #if os(macOS)
        #if arch(arm64)
        let isNativeAppleSiliconProcess = true
        #else
        let isNativeAppleSiliconProcess = false
        #endif
        let isAppleSilicon = isNativeAppleSiliconProcess || sysctlInt("hw.optional.arm64") == 1
        let hardwareEncoders = detectedHardwareEncoders()
        let hardwareEncodeCodecs = mergedCodecLabels(hardwareEncoders.map(\.codec))
        let gpuRegistryIDs = Set(hardwareEncoders.compactMap(\.gpuRegistryID))
        let gpuDeviceNames = resolveGPUDeviceNames(for: gpuRegistryIDs)
        let gpuPathDeviceName = gpuDeviceNames.sorted().first

        if isAppleSilicon {
            let fallbackCodecs = ["H.264", "HEVC", "ProRes"]
            let encodeCodecs = hardwareEncodeCodecs.isEmpty ? fallbackCodecs : hardwareEncodeCodecs
            return CapabilitySnapshot(
                capabilityKind: .appleMediaEngines,
                isSupported: true,
                supportsEncode: !encodeCodecs.isEmpty,
                supportsDecode: true,
                supportedEncodeCodecs: encodeCodecs,
                supportedDecodeCodecs: fallbackCodecs,
                displayTitle: CapabilityKind.appleMediaEngines.displayTitle,
                pathDescription: "Apple media engines detected through VideoToolbox hardware encode support.",
                pathDeviceName: nil
            )
        }

        if !hardwareEncodeCodecs.isEmpty {
            let hasGPUPath = gpuPathDeviceName != nil
            return CapabilitySnapshot(
                capabilityKind: hasGPUPath ? .gpuHardwareVideo : .intelQuickSyncCPU,
                isSupported: true,
                supportsEncode: true,
                supportsDecode: true,
                supportedEncodeCodecs: hardwareEncodeCodecs,
                supportedDecodeCodecs: hardwareEncodeCodecs,
                displayTitle: hasGPUPath ? CapabilityKind.gpuHardwareVideo.displayTitle : CapabilityKind.intelQuickSyncCPU.displayTitle,
                pathDescription: gpuPathDeviceName.map {
                    "Hardware video path is attached to \($0)."
                } ?? "Hardware video path detected through VideoToolbox.",
                pathDeviceName: gpuPathDeviceName
            )
        }
        #endif

        return CapabilitySnapshot(
            capabilityKind: .appleMediaEngines,
            isSupported: false,
            supportsEncode: false,
            supportsDecode: false,
            supportedEncodeCodecs: [],
            supportedDecodeCodecs: [],
            displayTitle: CapabilityKind.appleMediaEngines.displayTitle,
            pathDescription: "No explicit hardware media path was detected.",
            pathDeviceName: nil
        )
    }

    private func sampleVTProcessActivity(at now: Date) -> VTProcessActivity {
        #if os(macOS)
        let logical = Self.sysctlInt("hw.logicalcpu") ?? Self.sysctlInt("hw.logicalcpu_max") ?? 1
        let nowInterval = now.timeIntervalSince1970
        let pids = Self.listAllPIDs()
        guard !pids.isEmpty else {
            lastVTProcessSample = [:]
            return VTProcessActivity()
        }

        var activity = VTProcessActivity()
        var sampledPIDs = Set<Int32>()

        for pid in pids {
            guard let role = Self.vtServiceRole(pid: pid),
                  let taskInfo = Self.readTaskInfo(pid: pid) else {
                continue
            }

            sampledPIDs.insert(pid)
            let cpuNS = taskInfo.userNS &+ taskInfo.systemNS
            let previousSample = lastVTProcessSample[pid]
            var cpuPercent: Double = 0
            if let previousSample, previousSample.role == role {
                let dt = max(0.001, nowInterval - previousSample.t)
                let deltaCPUSeconds = Double(cpuNS >= previousSample.cpuNS ? (cpuNS - previousSample.cpuNS) : 0) / 1_000_000_000.0
                cpuPercent = (deltaCPUSeconds / dt) * (100.0 / Double(max(logical, 1)))
            }
            lastVTProcessSample[pid] = VTProcessSample(cpuNS: cpuNS, t: nowInterval, role: role)

            switch role {
            case .encode:
                activity.encoderCount += 1
                let clampedCPU = max(0, cpuPercent)
                activity.encoderCPUPercent += clampedCPU
                if clampedCPU >= Self.vtProcessCPUTriggerPercent {
                    activity.activeEncoderCount += 1
                }
            case .decode:
                activity.decoderCount += 1
                let clampedCPU = max(0, cpuPercent)
                activity.decoderCPUPercent += clampedCPU
                if clampedCPU >= Self.vtProcessCPUTriggerPercent {
                    activity.activeDecoderCount += 1
                }
            }
        }

        lastVTProcessSample = lastVTProcessSample.filter { sampledPIDs.contains($0.key) }
        return activity
        #else
        return VTProcessActivity()
        #endif
    }

    private static func normalizedCodecLabel(_ codec: String) -> String {
        let trimmed = codec.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("av1") { return "AV1" }
        if lower.contains("hevc") { return "HEVC" }
        if lower.contains("h.264") || lower.contains("h264") || lower.contains("avc") { return "H.264" }
        if lower.contains("prores") { return "ProRes" }
        if lower.contains("vp9") { return "VP9" }
        return trimmed.isEmpty ? "Generic Media" : trimmed
    }

    private static func mergedCodecLabels(_ codecs: [String]) -> [String] {
        let deduplicated = Set(
            codecs
                .map(normalizedCodecLabel(_:))
                .filter { !$0.isEmpty && $0 != "Generic Media" }
        )
        return deduplicated.sorted {
            let lhsRank = codecDisplayOrder($0)
            let rhsRank = codecDisplayOrder($1)
            if lhsRank == rhsRank {
                return $0 < $1
            }
            return lhsRank < rhsRank
        }
    }

    private static func codecDisplayOrder(_ codec: String) -> Int {
        switch normalizedCodecLabel(codec) {
        case "H.264": return 0
        case "HEVC": return 1
        case "ProRes": return 2
        case "AV1": return 3
        case "VP9": return 4
        default: return 100
        }
    }

    private static func detectedHardwareEncoders() -> [VideoEncoderDescriptor] {
        #if os(macOS)
        var encoderList: CFArray?
        let status = VTCopyVideoEncoderList(nil, &encoderList)
        guard status == noErr,
              let entries = encoderList as? [[CFString: Any]] else {
            return []
        }

        return entries.compactMap { entry -> VideoEncoderDescriptor? in
            if #available(macOS 10.14, *) {
                let isHardwareAccelerated = (entry[kVTVideoEncoderList_IsHardwareAccelerated] as? Bool) ?? false
                guard isHardwareAccelerated else { return nil }
            }

            let codecName = (entry[kVTVideoEncoderList_CodecName] as? String).map(normalizedCodecLabel) ?? "Generic Media"
            guard codecName != "Generic Media" else { return nil }

            let encoderName = (entry[kVTVideoEncoderList_EncoderName] as? String) ?? codecName
            let displayName = (entry[kVTVideoEncoderList_DisplayName] as? String) ?? encoderName
            let encoderID = (entry[kVTVideoEncoderList_EncoderID] as? String) ?? encoderName
            let gpuRegistryID = (entry[kVTVideoEncoderList_GPURegistryID] as? NSNumber)?.uint64Value

            return VideoEncoderDescriptor(
                codec: codecName,
                encoderName: encoderName,
                displayName: displayName,
                encoderID: encoderID,
                gpuRegistryID: gpuRegistryID
            )
        }
        #else
        return []
        #endif
    }

    private static func resolveGPUDeviceNames(for registryIDs: Set<UInt64>) -> Set<String> {
        guard !registryIDs.isEmpty else { return [] }
        #if os(macOS)
        #if canImport(Metal)
        if #available(macOS 10.13, *) {
            let devices = MTLCopyAllDevices()
            let names = devices.compactMap { device -> String? in
                guard registryIDs.contains(device.registryID) else { return nil }
                let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            }
            return Set(names)
        }
        #endif
        #endif
        return []
    }

    private static func sysctlInt(_ name: String) -> Int? {
        #if os(macOS)
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
        #else
        return nil
        #endif
    }

    private static func readTaskInfo(pid: Int32) -> TaskInfo? {
        #if os(macOS)
        var taskInfo = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, size)
        guard result == size else { return nil }
        return TaskInfo(
            userNS: UInt64(taskInfo.pti_total_user),
            systemNS: UInt64(taskInfo.pti_total_system)
        )
        #else
        return nil
        #endif
    }

    private static func listAllPIDs() -> [Int32] {
        #if os(macOS)
        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        if bytesNeeded <= 0 { return [] }

        let count = bytesNeeded / Int32(MemoryLayout<pid_t>.stride)
        var buffer = Array<pid_t>(repeating: 0, count: Int(count))

        let bytesFilled = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, rawBuffer.baseAddress, bytesNeeded)
        }
        if bytesFilled <= 0 { return [] }

        let filledCount = Int(bytesFilled) / MemoryLayout<pid_t>.stride
        return buffer.prefix(filledCount).map { Int32($0) }
        #else
        return []
        #endif
    }

    private static func vtServiceRole(pid: Int32) -> SessionRole? {
        #if os(macOS)
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard result > 0 else { return nil }
        let path = String(cString: pathBuffer)

        if path.contains("VTEncoderXPCService") {
            return .encode
        }
        if path.contains("VTDecoderXPCService") {
            return .decode
        }
        return nil
        #else
        return nil
        #endif
    }
}

extension MediaEngineStatsSampler {
    public var liveSnapshot: MediaEngineStatsSamplerLiveSnapshot {
        MediaEngineStatsSamplerLiveSnapshot(
            isSupported: isSupported,
            hasEverDetectedSupport: hasEverDetectedSupport,
            shouldShowCard: shouldShowCard,
            isActive: isActive,
            supportsEncode: supportsEncode,
            supportsDecode: supportsDecode,
            supportedCodecsText: supportedCodecsText,
            latestCapabilityState: latestCapabilityState,
            subtitleText: subtitleText,
            statusText: statusText,
            codecText: codecText,
            framesProcessedText: framesProcessedText,
            sessionsText: sessionsText,
            lastActiveText: lastActiveText,
            latestActivitySummary: latestActivitySummary,
            recentSessions: recentSessions,
            activityState: activityState,
            activityValue: activityValue,
            activityHistory: activityHistory,
            activitySeries: activitySeries
        )
    }

    public func applyRemoteSnapshot(_ snapshot: MediaEngineStatsSamplerLiveSnapshot) {
        if snapshot.isEmptyUnsupportedMediaEngineSnapshot, shouldShowCard {
            // Older helpers can publish an all-empty media payload; keep the local
            // capability baseline so the card chrome does not disappear.
            return
        }

        isSupported = snapshot.isSupported
        hasEverDetectedSupport = snapshot.hasEverDetectedSupport
        shouldShowCard = snapshot.shouldShowCard
        isActive = snapshot.isActive
        supportsEncode = snapshot.supportsEncode
        supportsDecode = snapshot.supportsDecode
        supportedCodecsText = snapshot.supportedCodecsText
        latestCapabilityState = snapshot.latestCapabilityState
        subtitleText = snapshot.subtitleText
        statusText = snapshot.statusText
        codecText = snapshot.codecText
        framesProcessedText = snapshot.framesProcessedText
        sessionsText = snapshot.sessionsText
        lastActiveText = snapshot.lastActiveText
        latestActivitySummary = snapshot.latestActivitySummary
        recentSessions = snapshot.recentSessions
        activityState = snapshot.activityState
        activityValue = snapshot.activityValue
        activityHistory = snapshot.activityHistory
        activitySeries = snapshot.activitySeries
    }
}

private extension MediaEngineStatsSamplerLiveSnapshot {
    var isEmptyUnsupportedMediaEngineSnapshot: Bool {
        !isSupported
            && !hasEverDetectedSupport
            && !shouldShowCard
            && !isActive
            && !supportsEncode
            && !supportsDecode
            && latestCapabilityState == nil
            && latestActivitySummary == nil
            && recentSessions.isEmpty
            && activityValue == 0
            && activityHistory.isEmpty
            && activitySeries.samples.isEmpty
    }
}
