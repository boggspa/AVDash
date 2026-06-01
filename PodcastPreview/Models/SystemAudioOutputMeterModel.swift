import Foundation
import Combine
import CoreAudio
import AudioToolbox
import CoreMedia
import CoreGraphics
import AppKit
import os.lock

#if canImport(ScreenCaptureKit)
@preconcurrency import ScreenCaptureKit
#endif

private nonisolated struct PendingSessionUpdate: Sendable {
    var frameCountDelta = 0
    var hotFrameDelta = 0
    var latestPayloadBytes = 0
    var latestSampleCount = 0
    var latestBufferSource = "—"
    var latestFrameDate: Date?
    var latestSignalDate: Date?
    var latestSampleRate: Double?
    var latestErrorText: String?
    var latestLeftLinear: Double = 0
    var latestRightLinear: Double = 0
    var hasFrameData = false
    var hadSignal = false
    var captureActive: Bool?
    var stateSampleRate: Double?

    mutating func record(frame: SystemOutputCapturedFrame) {
        frameCountDelta += 1
        latestPayloadBytes = frame.payloadBytes
        latestSampleCount = frame.sampleCount
        latestBufferSource = frame.bufferSource
        latestFrameDate = frame.timestamp
        latestSampleRate = frame.sampleRate
        latestLeftLinear = max(latestLeftLinear, frame.leftLinear)
        latestRightLinear = max(latestRightLinear, frame.rightLinear)
        hasFrameData = true
        captureActive = true

        if frame.containsSignal {
            hotFrameDelta += 1
            latestSignalDate = frame.timestamp
            hadSignal = true
        }
    }

    mutating func recordState(isActive: Bool, sampleRate: Double) {
        captureActive = isActive
        if sampleRate > 0 {
            stateSampleRate = sampleRate
        }
    }

    mutating func recordError(_ message: String) {
        latestErrorText = message
        captureActive = false
    }
}

private nonisolated final class SystemOutputMeterSharedState: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var sessionToken = UUID()
    private var pending = PendingSessionUpdate()

    func reset(for token: UUID) {
        os_unfair_lock_lock(&lock)
        sessionToken = token
        pending = PendingSessionUpdate()
        os_unfair_lock_unlock(&lock)
    }

    func record(frame: SystemOutputCapturedFrame, for token: UUID) {
        os_unfair_lock_lock(&lock)
        guard sessionToken == token else {
            os_unfair_lock_unlock(&lock)
            return
        }
        pending.record(frame: frame)
        os_unfair_lock_unlock(&lock)
    }

    func recordState(isActive: Bool, sampleRate: Double, for token: UUID) {
        os_unfair_lock_lock(&lock)
        guard sessionToken == token else {
            os_unfair_lock_unlock(&lock)
            return
        }
        pending.recordState(isActive: isActive, sampleRate: sampleRate)
        os_unfair_lock_unlock(&lock)
    }

    func recordError(_ message: String, for token: UUID) {
        os_unfair_lock_lock(&lock)
        guard sessionToken == token else {
            os_unfair_lock_unlock(&lock)
            return
        }
        pending.recordError(message)
        os_unfair_lock_unlock(&lock)
    }

    func takePending() -> PendingSessionUpdate {
        os_unfair_lock_lock(&lock)
        let current = pending
        pending = PendingSessionUpdate()
        os_unfair_lock_unlock(&lock)
        return current
    }
}

@MainActor
final class SystemAudioOutputMeterModel: NSObject, ObservableObject {
    static let shared = SystemAudioOutputMeterModel()

    enum StatusStyle {
        case unsupported
        case disabled
        case permissionNeeded
        case idle
        case warmup
        case live
    }

    enum CaptureBackendPreference: String {
        case automatic
        case coreAudioTap
        case screenCapture
        case virtualInput
    }

    enum CaptureBackend: String {
        case unsupported
        case coreAudioTap
        case screenCapture
        case virtualInput

        var displayName: String {
            switch self {
            case .unsupported:
                return "Unavailable"
            case .coreAudioTap:
                return "Core Audio Tap"
            case .screenCapture:
                return "Screen Capture"
            case .virtualInput:
                return "Virtual Input"
            }
        }
    }

    struct VirtualInputDeviceTarget: Identifiable, Hashable {
        enum Family: String {
            case loopback
            case blackHole
        }

        let id: String
        let deviceID: AudioDeviceID
        let uid: String
        let displayName: String
        let manufacturer: String
        let sampleRate: Double
        let inputChannels: UInt32
        let transportType: DeviceTransportType
        let family: Family

        var subtitle: String {
            let vendor = manufacturer.isEmpty ? transportType.rawValue : manufacturer
            return "\(vendor) · \(inputChannels) ch"
        }
    }

    struct CaptureSourceTarget: Identifiable, Hashable {
        let id: String
        let displayName: String
        let bundleIdentifier: String?
        let processID: pid_t
        let subtitle: String

        init(application: NSRunningApplication) {
            let resolvedName = application.localizedName ?? application.bundleIdentifier ?? "PID \(application.processIdentifier)"
            let resolvedBundleID = application.bundleIdentifier
            self.id = resolvedBundleID.map { "bundle:\($0)" } ?? "pid:\(application.processIdentifier)"
            self.displayName = resolvedName
            self.bundleIdentifier = resolvedBundleID
            self.processID = application.processIdentifier
            self.subtitle = resolvedBundleID ?? "PID \(application.processIdentifier)"
        }

#if canImport(ScreenCaptureKit)
        @available(macOS 13.0, *)
        func matches(screenCaptureApplication application: SCRunningApplication) -> Bool {
            if let bundleIdentifier, application.bundleIdentifier == bundleIdentifier {
                return true
            }
            return application.processID == processID
        }
#endif
    }

    enum CaptureSource: Equatable {
        case systemMix
        case application(CaptureSourceTarget)

        var id: String {
            switch self {
            case .systemMix:
                return "system-mix"
            case .application(let target):
                return target.id
            }
        }

        var sourceText: String {
            switch self {
            case .systemMix:
                return "System Mix"
            case .application(let target):
                return target.displayName
            }
        }

        var detailLabel: String {
            switch self {
            case .systemMix:
                return "the current system mix"
            case .application(let target):
                return target.displayName
            }
        }
    }

    struct Diagnostics {
        let totalFrames: Int
        let hotFrames: Int
        let lastBufferSource: String
        let lastPayloadBytes: Int
        let lastSampleCount: Int
        let outputDeviceUID: String
        let lastErrorText: String?
        let lastFrameDate: Date?
    }

    struct Snapshot {
        let leftLevel: Double
        let rightLevel: Double
        let leftPeakHold: Double
        let rightPeakHold: Double
        let leftValueText: String
        let rightValueText: String
        let statusText: String
        let statusStyle: StatusStyle
        let detailText: String
        let outputDeviceText: String
        let sourceText: String
        let capturePathText: String
        let sampleRateText: String
        let captureActive: Bool
        let isCaptureEnabled: Bool
        let hasSignal: Bool
        let lastSignalDate: Date?
        let selectedBackend: CaptureBackend
        let backendPreference: CaptureBackendPreference
        let supportsCoreAudioTap: Bool
        let supportsScreenCapture: Bool
        let supportsVirtualInputFallback: Bool
        let virtualInputDeviceText: String
        let screenCapturePermissionGranted: Bool
        let screenCapturePermissionNeeded: Bool
        let selectedSourceID: String
        let selectedVirtualInputID: String?
        let availableSourceTargets: [CaptureSourceTarget]
        let availableVirtualInputDevices: [VirtualInputDeviceTarget]
        let diagnostics: Diagnostics

        static let initial = Snapshot(
            leftLevel: 0,
            rightLevel: 0,
            leftPeakHold: 0,
            rightPeakHold: 0,
            leftValueText: "-inf dB",
            rightValueText: "-inf dB",
            statusText: "Idle",
            statusStyle: .idle,
            detailText: "Preparing stereo output metering.",
            outputDeviceText: "—",
            sourceText: "System Mix",
            capturePathText: "Unavailable",
            sampleRateText: "—",
            captureActive: false,
            isCaptureEnabled: true,
            hasSignal: false,
            lastSignalDate: nil,
            selectedBackend: .unsupported,
            backendPreference: .automatic,
            supportsCoreAudioTap: false,
            supportsScreenCapture: false,
            supportsVirtualInputFallback: false,
            virtualInputDeviceText: "Loopback / BlackHole",
            screenCapturePermissionGranted: false,
            screenCapturePermissionNeeded: false,
            selectedSourceID: "system-mix",
            selectedVirtualInputID: nil,
            availableSourceTargets: [],
            availableVirtualInputDevices: [],
            diagnostics: Diagnostics(
                totalFrames: 0,
                hotFrames: 0,
                lastBufferSource: "—",
                lastPayloadBytes: 0,
                lastSampleCount: 0,
                outputDeviceUID: "",
                lastErrorText: nil,
                lastFrameDate: nil
            )
        )
    }

    enum FocusAction {
        static let enableCapture = "system-output.capture.enable"
        static let disableCapture = "system-output.capture.disable"
        static let useCoreAudioTap = "system-output.backend.core-audio"
        static let useScreenCapture = "system-output.backend.screen-capture"
        static let useVirtualInput = "system-output.backend.virtual-input"
        static let useAutomatic = "system-output.backend.automatic"
        static let useSystemMix = "system-output.source.system-mix"
        static let selectAppPrefix = "system-output.source.app."
        static let selectVirtualInputPrefix = "system-output.virtual-input."
        static let requestScreenCaptureAccess = "system-output.permission.request-screen-recording"
        static let openScreenCaptureSettings = "system-output.permission.open-screen-recording-settings"
        static let restartCapture = "system-output.restart"
    }

    @Published private(set) var snapshot: Snapshot = .initial

    /// Same live stream as Stereo Output meters; use with ``MonitoringState/startExternalMonitoring`` for spectrum/waveform.
    var stereoMixVisualizationRingBufferHandle: OpaquePointer? { stereoMixVisualizationRingBuffer }

    var stereoMixVisualizationSampleRate: Double {
        sessionSampleRate > 0 ? sessionSampleRate : 48_000
    }

    var isSupportedPlatform: Bool {
        supportsCoreAudioTap || supportsScreenCapture || isLegacyThirdPartyFallbackOS
    }

    private let preferenceDefaultsKey = "SystemAudioOutputMeterModel.captureBackendPreference"
    private let enabledDefaultsKey = "SystemAudioOutputMeterModel.captureEnabled"
    private let selectedVirtualInputUIDDefaultsKey = "SystemAudioOutputMeterModel.virtualInputUID"
    private let uiRefreshInterval: TimeInterval = 1.0 / 12.0
    private let runtimeSanityRefreshInterval: TimeInterval = 5.0
    private var backendPreference: CaptureBackendPreference = .automatic
    private var captureSource: CaptureSource = .systemMix
    private var availableSourceTargets: [CaptureSourceTarget] = []
    private var availableVirtualInputDevices: [VirtualInputDeviceTarget] = []
    private var selectedVirtualInputUID: String?
    private var captureEnabled = true
    private var currentBackend: CaptureBackend = .unsupported
    private var session: (any SystemOutputMeterSession)?
    /// Stereo interleaved PCM for FFT/waveform on the Hardware tab (Screen Capture or Core Audio tap only).
    private var stereoMixVisualizationRingBuffer: OpaquePointer?
    private var refreshTimer: Timer?
    private var isRunning = false
    private var activeConsumerCount = 0
    private var isRestarting = false
    private var lastRuntimeContextRefreshAt: Date = .distantPast

    private let runtimeListenerQueue = DispatchQueue(label: "SystemAudioOutputMeterModel.runtime", qos: .utility)
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var outputSampleRateListener: AudioObjectPropertyListenerBlock?
    private var observedOutputSampleRateDeviceID: AudioDeviceID = kAudioObjectUnknown

    private var outputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var outputDeviceName = "—"
    private var outputDeviceUID = ""
    private var outputSampleRate: Double = 48_000

    private var sessionSampleRate: Double = 48_000
    private var captureActive = false
    private var totalFrames = 0
    private var hotFrames = 0
    private var lastPayloadBytes = 0
    private var lastSampleCount = 0
    private var lastBufferSource = "—"
    private var lastFrameDate: Date?
    private var lastSignalDate: Date?
    private var lastErrorText: String?
    private var warmupStartedAt: Date?

    private var leftLinear: Double = 0
    private var rightLinear: Double = 0
    private var leftPeakLinear: Double = 0
    private var rightPeakLinear: Double = 0

    private nonisolated let sharedState = SystemOutputMeterSharedState()

    private var screenCapturePermissionGranted: Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return false
    }

    private var supportsCoreAudioTap: Bool {
        if #available(macOS 14.2, *) {
            return true
        }
        return false
    }

    private var supportsScreenCapture: Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }

    private var isLegacyThirdPartyFallbackOS: Bool {
        !supportsCoreAudioTap && !supportsScreenCapture
    }

    private var selectedVirtualInputDevice: VirtualInputDeviceTarget? {
        if let selectedVirtualInputUID,
           let selectedDevice = availableVirtualInputDevices.first(where: { $0.uid == selectedVirtualInputUID }) {
            return selectedDevice
        }
        return availableVirtualInputDevices.first
    }

    private var supportsVirtualInputFallback: Bool {
        selectedVirtualInputDevice != nil
    }

    override init() {
        super.init()
        if UserDefaults.standard.object(forKey: enabledDefaultsKey) != nil {
            captureEnabled = UserDefaults.standard.bool(forKey: enabledDefaultsKey)
        }
        if let stored = UserDefaults.standard.string(forKey: preferenceDefaultsKey),
           let preference = CaptureBackendPreference(rawValue: stored) {
            backendPreference = preference
        }
        selectedVirtualInputUID = UserDefaults.standard.string(forKey: selectedVirtualInputUIDDefaultsKey)
        refreshAvailableSourceTargets()
        refreshAvailableVirtualInputDevices()
        refreshRuntimeContext()
        rebuildSnapshot()
    }

    deinit {
        defaultOutputListener = nil
        outputSampleRateListener = nil
    }

    func activate() {
        activeConsumerCount += 1
        guard activeConsumerCount == 1 else { return }
        start()
    }

    func deactivate() {
        guard activeConsumerCount > 0 else { return }
        activeConsumerCount -= 1
        guard activeConsumerCount == 0 else { return }
        stop()
    }

    func start() {
        guard isRunning == false else { return }
        isRunning = true
        refreshAvailableSourceTargets()
        refreshAvailableVirtualInputDevices()
        refreshRuntimeContext()
        installRuntimeContextListenersIfNeeded()
        lastRuntimeContextRefreshAt = Date()
        guard captureEnabled else {
            rebuildSnapshot()
            return
        }
        restartSession(reason: "start")
        installRefreshTimer()
    }

    func setCaptureEnabled(_ enabled: Bool) {
        guard captureEnabled != enabled else { return }
        captureEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: enabledDefaultsKey)

        if enabled {
            refreshAvailableSourceTargets()
            refreshAvailableVirtualInputDevices()
            refreshRuntimeContext()
            guard isRunning else {
                rebuildSnapshot()
                return
            }
            installRefreshTimer()
            restartSession(reason: "capture-enabled")
        } else {
            invalidateRefreshTimer()
            stopCurrentSession()
            totalFrames = 0
            hotFrames = 0
            lastPayloadBytes = 0
            lastSampleCount = 0
            lastBufferSource = "—"
            lastFrameDate = nil
            lastSignalDate = nil
            leftLinear = 0
            rightLinear = 0
            leftPeakLinear = 0
            rightPeakLinear = 0
            lastErrorText = nil
            rebuildSnapshot()
        }
    }

    private func installRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: uiRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        refreshTimer?.tolerance = uiRefreshInterval * 0.25
    }

    private func invalidateRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        invalidateRefreshTimer()
        stopCurrentSession()
        removeRuntimeContextListeners()
        rebuildSnapshot()
    }

    func performFocusAction(_ actionID: String) {
        switch actionID {
        case FocusAction.enableCapture:
            setCaptureEnabled(true)
        case FocusAction.disableCapture:
            setCaptureEnabled(false)
        case FocusAction.useCoreAudioTap:
            setBackendPreference(.coreAudioTap)
        case FocusAction.useScreenCapture:
            setBackendPreference(.screenCapture)
        case FocusAction.useVirtualInput:
            setBackendPreference(.virtualInput)
        case FocusAction.useAutomatic:
            setBackendPreference(.automatic)
        case FocusAction.useSystemMix:
            setCaptureSource(.systemMix)
        case FocusAction.requestScreenCaptureAccess:
            requestScreenCaptureAccess()
        case FocusAction.openScreenCaptureSettings:
            openScreenCaptureSettings()
        case FocusAction.restartCapture:
            restartSession(reason: "manual-restart")
        default:
            if actionID.hasPrefix(FocusAction.selectAppPrefix) {
                let sourceID = String(actionID.dropFirst(FocusAction.selectAppPrefix.count))
                guard let target = availableSourceTargets.first(where: { $0.id == sourceID }) else { return }
                setCaptureSource(.application(target))
            } else if actionID.hasPrefix(FocusAction.selectVirtualInputPrefix) {
                let deviceID = String(actionID.dropFirst(FocusAction.selectVirtualInputPrefix.count))
                setSelectedVirtualInput(uid: deviceID)
            }
        }
    }

    private func setBackendPreference(_ preference: CaptureBackendPreference) {
        guard backendPreference != preference else { return }
        if preference == .virtualInput {
            captureSource = .systemMix
        }
        backendPreference = preference
        UserDefaults.standard.set(preference.rawValue, forKey: preferenceDefaultsKey)
        restartSession(reason: "backend-preference-changed")
    }

    private func setCaptureSource(_ source: CaptureSource) {
        guard captureSource != source else { return }
        if case .application = source, backendPreference == .virtualInput {
            backendPreference = .automatic
            UserDefaults.standard.set(backendPreference.rawValue, forKey: preferenceDefaultsKey)
        }
        captureSource = source
        restartSession(reason: "capture-source-changed")
    }

    private func setSelectedVirtualInput(uid: String) {
        guard let target = availableVirtualInputDevices.first(where: { $0.uid == uid }) else { return }
        guard selectedVirtualInputUID != target.uid else { return }
        selectedVirtualInputUID = target.uid
        UserDefaults.standard.set(target.uid, forKey: selectedVirtualInputUIDDefaultsKey)

        let resolvedBackend = resolveBackend(for: backendPreference)
        if isRunning && captureEnabled && resolvedBackend == .virtualInput {
            restartSession(reason: "virtual-input-device-changed")
        } else {
            rebuildSnapshot()
        }
    }

    private func tick() {
        guard captureEnabled else {
            rebuildSnapshot()
            return
        }
        decayDisplayLevels()
        applyPendingUpdate(sharedState.takePending())

        if shouldPerformRuntimeContextSanityRefresh(at: Date()) {
            let didRestart = refreshRuntimeContextAndRestartIfNeeded(reason: "runtime-context-sanity-refresh")
            refreshAvailableSourceTargets()
            refreshAvailableVirtualInputDevices()
            if didRestart {
                return
            }
        }

        let resolvedBackend = resolveBackend(for: backendPreference)
        let shouldRestartForDeviceChange = resolvedBackend == .coreAudioTap && currentBackend == .coreAudioTap && session == nil && isRunning
        if resolvedBackend != currentBackend || shouldRestartForDeviceChange {
            restartSession(reason: "runtime-context-changed")
            return
        }

        rebuildSnapshot()
    }

    private func refreshRuntimeContext() {
        let deviceID = AudioDevices_GetDefaultOutputDevice()
        outputDeviceID = deviceID

        var nameBuffer = [CChar](repeating: 0, count: 256)
        if deviceID != kAudioObjectUnknown && AudioDevices_GetDeviceName(deviceID, &nameBuffer, 256) == noErr {
            outputDeviceName = String(cString: nameBuffer)
        } else {
            outputDeviceName = "Unavailable"
        }

        var uidBuffer = [CChar](repeating: 0, count: 256)
        if deviceID != kAudioObjectUnknown && AudioDevices_GetDeviceUID(deviceID, &uidBuffer, 256) == noErr {
            outputDeviceUID = String(cString: uidBuffer)
        } else {
            outputDeviceUID = ""
        }

        if deviceID != kAudioObjectUnknown {
            let sampleRate = AudioDevices_GetDeviceSampleRate(deviceID)
            outputSampleRate = sampleRate > 0 ? sampleRate : 48_000
        } else {
            outputSampleRate = 48_000
        }
    }

    private func refreshAvailableSourceTargets() {
        let runningApps = NSWorkspace.shared.runningApplications
        var seen = Set<String>()
        let refreshedTargets = runningApps
            .filter { application in
                application.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
                application.isTerminated == false &&
                (application.localizedName != nil || application.bundleIdentifier != nil)
            }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive {
                    return lhs.isActive && !rhs.isActive
                }
                let lhsName = lhs.localizedName ?? lhs.bundleIdentifier ?? ""
                let rhsName = rhs.localizedName ?? rhs.bundleIdentifier ?? ""
                return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
            }
            .compactMap { application -> CaptureSourceTarget? in
                let target = CaptureSourceTarget(application: application)
                guard seen.insert(target.id).inserted else { return nil }
                return target
            }
            .prefix(8)

        availableSourceTargets = Array(refreshedTargets)

        if case .application(let selectedTarget) = captureSource,
           let reboundTarget = availableSourceTargets.first(where: { $0.id == selectedTarget.id }) {
            captureSource = .application(reboundTarget)
        } else if case .application = captureSource,
                  availableSourceTargets.contains(where: { $0.id == captureSource.id }) == false {
            captureSource = .systemMix
        }
    }

    private func refreshAvailableVirtualInputDevices() {
        let maxDevices: UInt32 = 64
        var deviceIDs: [AudioDeviceID] = Array(repeating: 0, count: Int(maxDevices))
        let count = AudioDevices_GetAllInputDevices(&deviceIDs, maxDevices)

        let refreshedDevices = deviceIDs
            .prefix(Int(count))
            .compactMap { buildVirtualInputDeviceTarget(for: $0) }
            .sorted(by: preferredVirtualInputOrder)

        availableVirtualInputDevices = refreshedDevices

        if let selectedVirtualInputUID,
           refreshedDevices.contains(where: { $0.uid == selectedVirtualInputUID }) {
            return
        }

        selectedVirtualInputUID = refreshedDevices.first?.uid
        if let selectedVirtualInputUID {
            UserDefaults.standard.set(selectedVirtualInputUID, forKey: selectedVirtualInputUIDDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedVirtualInputUIDDefaultsKey)
        }
    }

    private func buildVirtualInputDeviceTarget(for deviceID: AudioDeviceID) -> VirtualInputDeviceTarget? {
        let inputChannels = AudioDevices_GetInputChannelCount(deviceID)
        guard inputChannels >= 2 else { return nil }

        var nameBuffer = [CChar](repeating: 0, count: 256)
        guard AudioDevices_GetDeviceName(deviceID, &nameBuffer, 256) == noErr else { return nil }
        let name = String(cString: nameBuffer)

        var uidBuffer = [CChar](repeating: 0, count: 256)
        guard AudioDevices_GetDeviceUID(deviceID, &uidBuffer, 256) == noErr else { return nil }
        let uid = String(cString: uidBuffer)

        var manufacturerBuffer = [CChar](repeating: 0, count: 256)
        let manufacturer: String
        if AudioDevices_GetDeviceManufacturer(deviceID, &manufacturerBuffer, 256) == noErr {
            manufacturer = String(cString: manufacturerBuffer)
        } else {
            manufacturer = ""
        }

        let normalizedName = name.lowercased()
        let normalizedManufacturer = manufacturer.lowercased()

        let family: VirtualInputDeviceTarget.Family?
        if normalizedName.contains("loopback") || normalizedManufacturer.contains("rogue amoeba") {
            family = .loopback
        } else if normalizedName.contains("blackhole") ||
                    normalizedName.contains("black hole") ||
                    normalizedManufacturer.contains("existential") {
            family = .blackHole
        } else {
            family = nil
        }

        guard let family else { return nil }

        return VirtualInputDeviceTarget(
            id: uid,
            deviceID: deviceID,
            uid: uid,
            displayName: name,
            manufacturer: manufacturer,
            sampleRate: AudioDevices_GetDeviceSampleRate(deviceID),
            inputChannels: inputChannels,
            transportType: DeviceTransportType(rawTransportValue: AudioDevices_GetDeviceTransportType(deviceID)),
            family: family
        )
    }

    private func preferredVirtualInputOrder(lhs: VirtualInputDeviceTarget, rhs: VirtualInputDeviceTarget) -> Bool {
        func familyRank(_ family: VirtualInputDeviceTarget.Family) -> Int {
            switch family {
            case .loopback:
                return 0
            case .blackHole:
                return 1
            }
        }

        let leftRank = familyRank(lhs.family)
        let rightRank = familyRank(rhs.family)
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        if lhs.inputChannels != rhs.inputChannels {
            return lhs.inputChannels < rhs.inputChannels
        }
        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private func installRuntimeContextListenersIfNeeded() {
        if defaultOutputListener == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.handleDefaultOutputDeviceChanged()
                }
            }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, runtimeListenerQueue, block) == noErr {
                defaultOutputListener = block
            }
        }

        installObservedOutputSampleRateListener(for: outputDeviceID)
    }

    private func installObservedOutputSampleRateListener(for deviceID: AudioDeviceID) {
        guard observedOutputSampleRateDeviceID != deviceID else { return }
        removeObservedOutputSampleRateListener()
        guard deviceID != kAudioObjectUnknown else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleObservedOutputSampleRateChanged()
            }
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectAddPropertyListenerBlock(deviceID, &address, runtimeListenerQueue, block) == noErr {
            outputSampleRateListener = block
            observedOutputSampleRateDeviceID = deviceID
        }
    }

    private func removeObservedOutputSampleRateListener() {
        guard let outputSampleRateListener, observedOutputSampleRateDeviceID != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(observedOutputSampleRateDeviceID, &address, runtimeListenerQueue, outputSampleRateListener)
        self.outputSampleRateListener = nil
        observedOutputSampleRateDeviceID = kAudioObjectUnknown
    }

    private func removeRuntimeContextListeners() {
        removeObservedOutputSampleRateListener()
        guard let defaultOutputListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, runtimeListenerQueue, defaultOutputListener)
        self.defaultOutputListener = nil
    }

    private func handleDefaultOutputDeviceChanged() {
        _ = refreshRuntimeContextAndRestartIfNeeded(reason: "default-output-device-changed")
    }

    private func handleObservedOutputSampleRateChanged() {
        _ = refreshRuntimeContextAndRestartIfNeeded(reason: "output-sample-rate-changed")
    }

    @discardableResult
    private func refreshRuntimeContextAndRestartIfNeeded(reason: String) -> Bool {
        let previousDeviceUID = outputDeviceUID
        let previousSampleRate = outputSampleRate
        refreshRuntimeContext()
        installObservedOutputSampleRateListener(for: outputDeviceID)
        lastRuntimeContextRefreshAt = Date()

        let deviceChanged = previousDeviceUID != outputDeviceUID
        let sampleRateChanged = abs(previousSampleRate - outputSampleRate) > 0.5
        guard deviceChanged || sampleRateChanged else {
            rebuildSnapshot()
            return false
        }

        guard isRunning, captureEnabled else {
            rebuildSnapshot()
            return false
        }

        restartSession(reason: reason)
        return true
    }

    private func shouldPerformRuntimeContextSanityRefresh(at now: Date) -> Bool {
        now.timeIntervalSince(lastRuntimeContextRefreshAt) >= runtimeSanityRefreshInterval
    }

    private func restartSession(reason: String) {
        guard captureEnabled else {
            stopCurrentSession()
            rebuildSnapshot()
            return
        }
        let backend = resolveBackend(for: backendPreference)
        stopCurrentSession()
        currentBackend = backend
        totalFrames = 0
        hotFrames = 0
        lastPayloadBytes = 0
        lastSampleCount = 0
        lastBufferSource = "—"
        lastFrameDate = nil
        lastSignalDate = nil
        leftLinear = 0
        rightLinear = 0
        leftPeakLinear = 0
        rightPeakLinear = 0
        captureActive = false
        warmupStartedAt = Date()
        lastErrorText = nil
        sessionSampleRate = outputSampleRate
        isRestarting = false

        guard isRunning else {
            rebuildSnapshot()
            return
        }

        switch backend {
        case .unsupported:
            lastErrorText = reason == "start" ? nil : "Stereo output metering is unavailable on this macOS version."
            rebuildSnapshot()
            return
        case .screenCapture:
            guard screenCapturePermissionGranted else {
                rebuildSnapshot()
                return
            }
        case .coreAudioTap:
            break
        case .virtualInput:
            guard selectedVirtualInputDevice != nil else {
                rebuildSnapshot()
                return
            }
        }

        isRestarting = true
        let token = UUID()
        sharedState.reset(for: token)
        let frameHandler = makeFrameHandler(for: token)
        let stateHandler = makeStateHandler(for: token)
        let errorHandler = makeErrorHandler(for: token)

        let newSession: any SystemOutputMeterSession
        switch backend {
        case .coreAudioTap:
            if #available(macOS 14.2, *) {
                prepareStereoMixVisualizationRingBufferIfNeeded(for: backend)
                newSession = CoreAudioTapOutputSession(
                    outputDeviceUID: outputDeviceUID,
                    captureSource: captureSource,
                    frameHandler: frameHandler,
                    stateHandler: stateHandler,
                    errorHandler: errorHandler,
                    analysisRingBuffer: stereoMixVisualizationRingBuffer
                )
            } else {
                rebuildSnapshot()
                return
            }
        case .screenCapture:
            if #available(macOS 13.0, *) {
                prepareStereoMixVisualizationRingBufferIfNeeded(for: backend)
                newSession = ScreenCaptureOutputSession(
                    captureSource: captureSource,
                    frameHandler: frameHandler,
                    stateHandler: stateHandler,
                    errorHandler: errorHandler,
                    analysisRingBuffer: stereoMixVisualizationRingBuffer
                )
            } else {
                rebuildSnapshot()
                return
            }
        case .virtualInput:
            guard let selectedVirtualInputDevice else {
                rebuildSnapshot()
                return
            }
            newSession = VirtualInputOutputSession(
                deviceTarget: selectedVirtualInputDevice,
                frameHandler: frameHandler,
                stateHandler: stateHandler,
                errorHandler: errorHandler
            )
        case .unsupported:
            rebuildSnapshot()
            return
        }

        session = newSession
        newSession.start()
        rebuildSnapshot()
    }

    private func stopCurrentSession() {
        sharedState.reset(for: UUID())
        session?.stop()
        session = nil
        captureActive = false
        isRestarting = false
        destroyStereoMixVisualizationRingBuffer()
    }

    private func destroyStereoMixVisualizationRingBuffer() {
        if let stereoMixVisualizationRingBuffer {
            RingBuffer_Destroy(stereoMixVisualizationRingBuffer)
        }
        stereoMixVisualizationRingBuffer = nil
    }

    private func prepareStereoMixVisualizationRingBufferIfNeeded(for backend: CaptureBackend) {
        destroyStereoMixVisualizationRingBuffer()
        guard backend == .screenCapture || backend == .coreAudioTap else { return }
        if let ringBuffer = RingBuffer_Create(65_536, 2) {
            stereoMixVisualizationRingBuffer = ringBuffer
        } else {
            stereoMixVisualizationRingBuffer = nil
        }
    }

    private func makeFrameHandler(for token: UUID) -> (SystemOutputCapturedFrame) -> Void {
        return { [weak self] frame in
            self?.sharedState.record(frame: frame, for: token)
        }
    }

    private func makeStateHandler(for token: UUID) -> (Bool, Double) -> Void {
        return { [weak self] isActive, sampleRate in
            self?.sharedState.recordState(isActive: isActive, sampleRate: sampleRate, for: token)
        }
    }

    private func makeErrorHandler(for token: UUID) -> (String) -> Void {
        return { [weak self] message in
            self?.sharedState.recordError(message, for: token)
        }
    }

    private func applyPendingUpdate(_ pending: PendingSessionUpdate) {
        guard pending.frameCountDelta > 0 ||
                pending.hotFrameDelta > 0 ||
                pending.hasFrameData ||
                pending.captureActive != nil ||
                pending.stateSampleRate != nil ||
                pending.latestErrorText != nil else {
            return
        }

        isRestarting = false
        totalFrames += pending.frameCountDelta
        hotFrames += pending.hotFrameDelta

        if pending.hasFrameData {
            captureActive = pending.captureActive ?? true
            lastPayloadBytes = pending.latestPayloadBytes
            lastSampleCount = pending.latestSampleCount
            lastBufferSource = pending.latestBufferSource
            lastFrameDate = pending.latestFrameDate
            if let latestSampleRate = pending.latestSampleRate, latestSampleRate > 0 {
                sessionSampleRate = latestSampleRate
            }
            if let latestSignalDate = pending.latestSignalDate {
                lastSignalDate = latestSignalDate
            }

            let smoothing = pending.hadSignal ? 0.62 : 0.22
            leftLinear = max(pending.latestLeftLinear, leftLinear * (1 - smoothing))
            rightLinear = max(pending.latestRightLinear, rightLinear * (1 - smoothing))
            leftPeakLinear = max(pending.latestLeftLinear, leftPeakLinear * 0.94)
            rightPeakLinear = max(pending.latestRightLinear, rightPeakLinear * 0.94)
        } else if let captureActive = pending.captureActive {
            self.captureActive = captureActive
        }

        if let stateSampleRate = pending.stateSampleRate, stateSampleRate > 0 {
            sessionSampleRate = stateSampleRate
        }

        if let latestErrorText = pending.latestErrorText {
            lastErrorText = latestErrorText
            captureActive = false
        }
    }

    private func decayDisplayLevels() {
        leftLinear *= 0.84
        rightLinear *= 0.84
        leftPeakLinear *= 0.96
        rightPeakLinear *= 0.96

        if leftLinear < 0.000_01 { leftLinear = 0 }
        if rightLinear < 0.000_01 { rightLinear = 0 }
        if leftPeakLinear < 0.000_01 { leftPeakLinear = 0 }
        if rightPeakLinear < 0.000_01 { rightPeakLinear = 0 }
    }

    private func resolveBackend(for preference: CaptureBackendPreference) -> CaptureBackend {
        switch preference {
        case .automatic:
            switch captureSource {
            case .systemMix:
                if supportsCoreAudioTap {
                    return .coreAudioTap
                }
                if supportsScreenCapture {
                    return .screenCapture
                }
                if supportsVirtualInputFallback {
                    return .virtualInput
                }
            case .application:
                if supportsScreenCapture {
                    return .screenCapture
                }
                if supportsCoreAudioTap {
                    return .coreAudioTap
                }
            }
            return .unsupported
        case .coreAudioTap:
            return supportsCoreAudioTap ? .coreAudioTap : .unsupported
        case .screenCapture:
            return supportsScreenCapture ? .screenCapture : .unsupported
        case .virtualInput:
            return supportsVirtualInputFallback ? .virtualInput : .unsupported
        }
    }

    private func rebuildSnapshot() {
        let selectedBackend = resolveBackend(for: backendPreference)
        let recentSignal = lastSignalDate.map { Date().timeIntervalSince($0) < 2.0 } ?? false
        let recentFrames = lastFrameDate.map { Date().timeIntervalSince($0) < 2.0 } ?? false
        let permissionNeeded = selectedBackend == .screenCapture && !screenCapturePermissionGranted
        let sourceText = captureSource.sourceText
        let sourceDetailLabel = captureSource.detailLabel

        let statusStyle: StatusStyle
        if !captureEnabled {
            statusStyle = .disabled
        } else if selectedBackend == .unsupported {
            statusStyle = .unsupported
        } else if permissionNeeded {
            statusStyle = .permissionNeeded
        } else if captureActive && recentFrames {
            statusStyle = .live
        } else if isRestarting || (warmupStartedAt.map { Date().timeIntervalSince($0) < 3.0 } ?? false) {
            statusStyle = .warmup
        } else {
            statusStyle = .idle
        }

        let statusText: String
        switch statusStyle {
        case .unsupported:
            statusText = "N/A"
        case .disabled:
            statusText = "Off"
        case .permissionNeeded:
            statusText = "Access"
        case .idle:
            statusText = "Idle"
        case .warmup:
            statusText = "Warm-up"
        case .live:
            statusText = "Live"
        }

        let detailText: String
        let virtualInputDeviceText = selectedVirtualInputDevice?.displayName ?? "Loopback / BlackHole"
        if !captureEnabled {
            detailText = "Stereo output metering is turned off to reduce background work. Turn it back on whenever you want live output metering again."
        } else if selectedBackend == .unsupported {
            switch captureSource {
            case .application(let target):
                detailText = supportsScreenCapture || supportsCoreAudioTap
                    ? "The selected source \(target.displayName) currently has no usable capture backend."
                    : "App-only metering for \(target.displayName) needs Screen Capture or Core Audio Tap. On this macOS version, switch back to System Mix or route the mix into Loopback / BlackHole instead."
            case .systemMix:
                if isLegacyThirdPartyFallbackOS && !supportsVirtualInputFallback {
                    detailText = "On this macOS version, install Loopback or BlackHole and route the system mix into its stereo input to enable this card."
                } else if isLegacyThirdPartyFallbackOS {
                    detailText = "A compatible third-party stereo input is available. Use Automatic or Virtual Input to meter the mix through \(virtualInputDeviceText)."
                } else if supportsVirtualInputFallback {
                    detailText = "Native capture backends are available on this Mac, but you can also switch to Virtual Input if you prefer to meter a routed Loopback or BlackHole device instead."
                } else {
                    detailText = "Stereo output metering is unavailable on this macOS version."
                }
            }
        } else if permissionNeeded {
            detailText = "Screen Capture needs Screen Recording approval before it can meter \(sourceDetailLabel)."
        } else if captureActive && totalFrames == 0 {
            detailText = "Capture started for \(sourceDetailLabel) on \(outputDeviceName), but no callbacks have arrived yet."
        } else if captureActive && totalFrames > 0 && hotFrames == 0 {
            detailText = "Capture is active for \(sourceDetailLabel) on \(outputDeviceName), but the latest frames are silent. Try the alternate backend in the focused view."
        } else {
            switch selectedBackend {
            case .virtualInput:
                detailText = "Following the stereo input from \(virtualInputDeviceText). Route the system mix into that Loopback or BlackHole device whenever you want manual routed-output metering."
            case .coreAudioTap, .screenCapture:
                switch captureSource {
                case .systemMix:
                    detailText = "Following the current macOS stereo output on \(outputDeviceName), independent of Podcast Preview's own route."
                case .application(let target):
                    detailText = "Following only \(target.displayName) on \(outputDeviceName), so the meters latch onto that app rather than the whole system mix."
                }
            case .unsupported:
                detailText = "Stereo output metering is unavailable on this macOS version."
            }
        }

        let capturePathText: String
        if !captureEnabled {
            capturePathText = "Disabled"
        } else if selectedBackend == .virtualInput {
            capturePathText = selectedVirtualInputDevice.map { "Virtual Input · \($0.displayName)" } ?? "Virtual Input"
        } else {
            capturePathText = selectedBackend.displayName
        }
        let sampleRate = sessionSampleRate > 0 ? sessionSampleRate : outputSampleRate

        let nextSnapshot = Snapshot(
            leftLevel: normalizedLevel(fromLinear: leftLinear),
            rightLevel: normalizedLevel(fromLinear: rightLinear),
            leftPeakHold: normalizedLevel(fromLinear: leftPeakLinear),
            rightPeakHold: normalizedLevel(fromLinear: rightPeakLinear),
            leftValueText: dbText(fromLinear: leftLinear),
            rightValueText: dbText(fromLinear: rightLinear),
            statusText: statusText,
            statusStyle: statusStyle,
            detailText: detailText,
            outputDeviceText: outputDeviceName,
            sourceText: sourceText,
            capturePathText: capturePathText,
            sampleRateText: sampleRateText(sampleRate),
            captureActive: captureActive,
            isCaptureEnabled: captureEnabled,
            hasSignal: recentSignal,
            lastSignalDate: lastSignalDate,
            selectedBackend: selectedBackend,
            backendPreference: backendPreference,
            supportsCoreAudioTap: supportsCoreAudioTap,
            supportsScreenCapture: supportsScreenCapture,
            supportsVirtualInputFallback: supportsVirtualInputFallback,
            virtualInputDeviceText: virtualInputDeviceText,
            screenCapturePermissionGranted: screenCapturePermissionGranted,
            screenCapturePermissionNeeded: permissionNeeded && captureEnabled,
            selectedSourceID: captureSource.id,
            selectedVirtualInputID: selectedVirtualInputUID,
            availableSourceTargets: availableSourceTargets,
            availableVirtualInputDevices: availableVirtualInputDevices,
            diagnostics: Diagnostics(
                totalFrames: totalFrames,
                hotFrames: hotFrames,
                lastBufferSource: lastBufferSource,
                lastPayloadBytes: lastPayloadBytes,
                lastSampleCount: lastSampleCount,
                outputDeviceUID: outputDeviceUID,
                lastErrorText: lastErrorText,
                lastFrameDate: lastFrameDate
            )
        )

        guard snapshotPublishToken(for: nextSnapshot) != snapshotPublishToken(for: snapshot) else { return }
        snapshot = nextSnapshot
    }

    private func snapshotPublishToken(for snapshot: Snapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(Int((snapshot.leftLevel * 1000).rounded()))
        hasher.combine(Int((snapshot.rightLevel * 1000).rounded()))
        hasher.combine(Int((snapshot.leftPeakHold * 1000).rounded()))
        hasher.combine(Int((snapshot.rightPeakHold * 1000).rounded()))
        hasher.combine(snapshot.leftValueText)
        hasher.combine(snapshot.rightValueText)
        hasher.combine(snapshot.statusText)
        hasher.combine(snapshot.detailText)
        hasher.combine(snapshot.outputDeviceText)
        hasher.combine(snapshot.sourceText)
        hasher.combine(snapshot.capturePathText)
        hasher.combine(snapshot.sampleRateText)
        hasher.combine(snapshot.captureActive)
        hasher.combine(snapshot.isCaptureEnabled)
        hasher.combine(snapshot.hasSignal)
        hasher.combine(snapshot.selectedSourceID)
        hasher.combine(snapshot.selectedBackend.rawValue)
        hasher.combine(snapshot.backendPreference.rawValue)
        hasher.combine(snapshot.screenCapturePermissionGranted)
        hasher.combine(snapshot.screenCapturePermissionNeeded)
        hasher.combine(snapshot.supportsVirtualInputFallback)
        hasher.combine(snapshot.virtualInputDeviceText)
        hasher.combine(snapshot.selectedVirtualInputID ?? "")
        for target in snapshot.availableSourceTargets {
            hasher.combine(target.id)
            hasher.combine(target.displayName)
        }
        for target in snapshot.availableVirtualInputDevices {
            hasher.combine(target.id)
            hasher.combine(target.displayName)
            hasher.combine(target.subtitle)
        }
        hasher.combine(snapshot.diagnostics.totalFrames)
        hasher.combine(snapshot.diagnostics.hotFrames)
        hasher.combine(snapshot.diagnostics.lastBufferSource)
        hasher.combine(snapshot.diagnostics.lastPayloadBytes)
        hasher.combine(snapshot.diagnostics.lastSampleCount)
        hasher.combine(snapshot.diagnostics.outputDeviceUID)
        hasher.combine(snapshot.diagnostics.lastErrorText ?? "")
        return hasher.finalize()
    }

    private func requestScreenCaptureAccess() {
        guard supportsScreenCapture else { return }
        guard #available(macOS 10.15, *) else { return }
        let granted = CGRequestScreenCaptureAccess()
        if granted {
            restartSession(reason: "screen-capture-access-granted")
        } else {
            rebuildSnapshot()
        }
    }

    private func openScreenCaptureSettings() {
        let primaryURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        let fallbackURL = URL(string: "x-apple.systempreferences:com.apple.preference.security")
        if let primaryURL, NSWorkspace.shared.open(primaryURL) {
            return
        }
        if let fallbackURL {
            NSWorkspace.shared.open(fallbackURL)
        }
    }
}

private protocol SystemOutputMeterSession: AnyObject {
    func start()
    func stop()
}

// MARK: - Stereo mix → analysis ring (Hardware tab FFT / waveform)

/// One instance per capture session / queue; reuses storage instead of allocating `[Float]` per buffer.
private nonisolated final class SystemOutputAnalysisInterleavedScratch: @unchecked Sendable {
    var interleaved = ContiguousArray<Float>()
}

/// Full-rate interleaved stereo floats into the shared ``RingBuffer`` (single producer per capture queue).
private nonisolated func writeInterleavedAnalysisPCM(
    bufferList: UnsafePointer<AudioBufferList>,
    format: AudioStreamBasicDescription,
    ring: OpaquePointer,
    scratch: SystemOutputAnalysisInterleavedScratch
) {
    let audioBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
    guard !audioBuffers.isEmpty else { return }

    let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let isSignedInteger = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
    let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    let bitsPerChannel = Int(format.mBitsPerChannel)
    let channels = max(1, Int(format.mChannelsPerFrame))

    scratch.interleaved.removeAll(keepingCapacity: true)

    if isNonInterleaved {
        let leftBuffer = audioBuffers[0]
        let rightBuffer = audioBuffers.count > 1 ? audioBuffers[1] : audioBuffers[0]
        if isFloat && bitsPerChannel == 32,
           let leftData = leftBuffer.mData?.assumingMemoryBound(to: Float.self),
           let rightData = rightBuffer.mData?.assumingMemoryBound(to: Float.self) {
            let frames = min(
                Int(leftBuffer.mDataByteSize) / MemoryLayout<Float>.size,
                Int(rightBuffer.mDataByteSize) / MemoryLayout<Float>.size
            )
            guard frames > 0 else { return }
            let needed = frames * 2
            if scratch.interleaved.capacity < needed {
                scratch.interleaved.reserveCapacity(needed)
            }
            for i in 0..<frames {
                scratch.interleaved.append(leftData[i])
                scratch.interleaved.append(rightData[i])
            }
        } else if isSignedInteger && bitsPerChannel == 16,
                  let leftData = leftBuffer.mData?.assumingMemoryBound(to: Int16.self),
                  let rightData = rightBuffer.mData?.assumingMemoryBound(to: Int16.self) {
            let frames = min(
                Int(leftBuffer.mDataByteSize) / MemoryLayout<Int16>.size,
                Int(rightBuffer.mDataByteSize) / MemoryLayout<Int16>.size
            )
            guard frames > 0 else { return }
            let needed = frames * 2
            if scratch.interleaved.capacity < needed {
                scratch.interleaved.reserveCapacity(needed)
            }
            let scale = 1.0 / Float(Int16.max)
            for i in 0..<frames {
                scratch.interleaved.append(Float(leftData[i]) * scale)
                scratch.interleaved.append(Float(rightData[i]) * scale)
            }
        } else {
            return
        }
    } else {
        let buffer = audioBuffers[0]
        if isFloat && bitsPerChannel == 32,
           let sampleData = buffer.mData?.assumingMemoryBound(to: Float.self) {
            let frames = Int(buffer.mDataByteSize) / max(MemoryLayout<Float>.size * channels, 1)
            guard frames > 0 else { return }
            let needed = frames * 2
            if scratch.interleaved.capacity < needed {
                scratch.interleaved.reserveCapacity(needed)
            }
            if channels == 1 {
                for i in 0..<frames {
                    let s = sampleData[i]
                    scratch.interleaved.append(s)
                    scratch.interleaved.append(s)
                }
            } else {
                for i in 0..<frames {
                    let base = i * channels
                    scratch.interleaved.append(sampleData[base])
                    scratch.interleaved.append(sampleData[base + 1])
                }
            }
        } else if isSignedInteger && bitsPerChannel == 16,
                  let sampleData = buffer.mData?.assumingMemoryBound(to: Int16.self) {
            let frames = Int(buffer.mDataByteSize) / max(MemoryLayout<Int16>.size * channels, 1)
            guard frames > 0 else { return }
            let needed = frames * 2
            if scratch.interleaved.capacity < needed {
                scratch.interleaved.reserveCapacity(needed)
            }
            let scale = 1.0 / Float(Int16.max)
            if channels == 1 {
                for i in 0..<frames {
                    let s = Float(sampleData[i]) * scale
                    scratch.interleaved.append(s)
                    scratch.interleaved.append(s)
                }
            } else {
                for i in 0..<frames {
                    let base = i * channels
                    scratch.interleaved.append(Float(sampleData[base]) * scale)
                    scratch.interleaved.append(Float(sampleData[base + 1]) * scale)
                }
            }
        } else {
            return
        }
    }

    let frameCount = scratch.interleaved.count / 2
    guard frameCount > 0 else { return }
    scratch.interleaved.withUnsafeBufferPointer { buf in
        guard let base = buf.baseAddress else { return }
        RingBuffer_WriteInterleaved(ring, base, frameCount, 2)
    }
}

private nonisolated func writeCMSampleBufferToAnalysisRing(
    _ sampleBuffer: CMSampleBuffer,
    ring: OpaquePointer,
    scratch: SystemOutputAnalysisInterleavedScratch
) {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
        return
    }
    let asbd = asbdPointer.pointee
    let channelCount = max(1, Int(asbd.mChannelsPerFrame))
    let listSize = MemoryLayout<AudioBufferList>.size + max(0, channelCount - 1) * MemoryLayout<AudioBuffer>.size
    let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { rawPointer.deallocate() }

    let audioBufferListPointer = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
    var blockBuffer: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: nil,
        bufferListOut: audioBufferListPointer,
        bufferListSize: listSize,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        blockBufferOut: &blockBuffer
    )
    guard status == noErr else { return }
    writeInterleavedAnalysisPCM(
        bufferList: UnsafePointer(audioBufferListPointer),
        format: asbd,
        ring: ring,
        scratch: scratch
    )
}

private nonisolated struct SystemOutputCapturedFrame: Sendable {
    let timestamp: Date
    let leftLinear: Double
    let rightLinear: Double
    let payloadBytes: Int
    let sampleCount: Int
    let sampleRate: Double
    let bufferSource: String
    let containsSignal: Bool
}

@available(macOS 14.2, *)
private final class CoreAudioTapOutputSession: SystemOutputMeterSession {
    private let outputDeviceUID: String
    private let captureSource: SystemAudioOutputMeterModel.CaptureSource
    private let queue = DispatchQueue(label: "SystemAudioOutputMeterModel.coreaudio", qos: .userInitiated)
    private let frameHandler: (SystemOutputCapturedFrame) -> Void
    private let stateHandler: (Bool, Double) -> Void
    private let errorHandler: (String) -> Void
    private let analysisRingBuffer: OpaquePointer?
    private let analysisInterleavedScratch = SystemOutputAnalysisInterleavedScratch()

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapUUIDString = UUID().uuidString
    private var aggregateUID = "com.podcastpreview.stereo-output.aggregate.\(UUID().uuidString)"
    private var streamFormat = AudioStreamBasicDescription()
    private var didStop = false
    private var lastForwardUptime: TimeInterval = 0

    init(
        outputDeviceUID: String,
        captureSource: SystemAudioOutputMeterModel.CaptureSource,
        frameHandler: @escaping (SystemOutputCapturedFrame) -> Void,
        stateHandler: @escaping (Bool, Double) -> Void,
        errorHandler: @escaping (String) -> Void,
        analysisRingBuffer: OpaquePointer?
    ) {
        self.outputDeviceUID = outputDeviceUID
        self.captureSource = captureSource
        self.frameHandler = frameHandler
        self.stateHandler = stateHandler
        self.errorHandler = errorHandler
        self.analysisRingBuffer = analysisRingBuffer
    }

    func start() {
        queue.async { [weak self] in
            self?.configureAndStart()
        }
    }

    func stop() {
        queue.sync {
            guard didStop == false else { return }
            didStop = true
            if let ioProcID {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                self.ioProcID = nil
            }
            if aggregateDeviceID != kAudioObjectUnknown {
                AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
                aggregateDeviceID = kAudioObjectUnknown
            }
            if tapID != kAudioObjectUnknown {
                AudioHardwareDestroyProcessTap(tapID)
                tapID = kAudioObjectUnknown
            }
        }
    }

    private func configureAndStart() {
        let tapDescription = CATapDescription()
        tapDescription.name = "Podcast Preview Stereo Output"
        tapDescription.isMixdown = true
        tapDescription.isMono = false
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        switch captureSource {
        case .systemMix:
            tapDescription.processes = []
            tapDescription.isExclusive = true
        case .application(let target):
            let matchedProcessObjectIDs = resolveCoreAudioProcessObjectIDs(for: target)
            guard matchedProcessObjectIDs.isEmpty == false else {
                errorHandler("Core Audio could not find an active output process for \(target.displayName). Try playback in that app or switch this source to Screen Capture.")
                return
            }
            tapDescription.processes = matchedProcessObjectIDs
            tapDescription.isExclusive = false
        }

        if outputDeviceUID.isEmpty == false {
            tapDescription.deviceUID = outputDeviceUID
        }

        if let tapUUID = tapDescription.value(forKey: "UUID") as? UUID {
            tapUUIDString = tapUUID.uuidString
        } else if let tapUUID = tapDescription.value(forKey: "uuid") as? UUID {
            tapUUIDString = tapUUID.uuidString
        } else {
            tapDescription.setValue(UUID(), forKey: "UUID")
            if let tapUUID = tapDescription.value(forKey: "UUID") as? UUID {
                tapUUIDString = tapUUID.uuidString
            }
        }

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &createdTapID)
        guard status == noErr else {
            errorHandler("Core Audio tap creation failed (\(status)).")
            return
        }
        tapID = createdTapID

        let tapList: [[String: Any]] = [[
            coreAudioKey(kAudioSubTapUIDKey): tapUUIDString,
            coreAudioKey(kAudioSubTapDriftCompensationKey): NSNumber(value: 0)
        ]]

        let aggregateDescription: [String: Any] = [
            coreAudioKey(kAudioAggregateDeviceNameKey): "Podcast Preview Stereo Output",
            coreAudioKey(kAudioAggregateDeviceUIDKey): aggregateUID,
            coreAudioKey(kAudioAggregateDeviceTapListKey): tapList,
            coreAudioKey(kAudioAggregateDeviceIsPrivateKey): NSNumber(value: 1),
            coreAudioKey(kAudioAggregateDeviceTapAutoStartKey): NSNumber(value: 0)
        ]

        var createdAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &createdAggregateDeviceID)
        guard status == noErr else {
            errorHandler("Aggregate device creation failed (\(status)).")
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
            return
        }
        aggregateDeviceID = createdAggregateDeviceID

        guard let discoveredFormat = readDeviceFormat(deviceID: aggregateDeviceID) else {
            errorHandler("Unable to read aggregate stream format.")
            return
        }
        streamFormat = discoveredFormat

        var createdIOProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&createdIOProcID, aggregateDeviceID, queue) { [weak self] inNow, inInputData, _, outOutputData, _ in
            guard let self else { return }
            if let ring = self.analysisRingBuffer {
                if bufferHasMeaningfulPayload(inInputData) {
                    writeInterleavedAnalysisPCM(
                        bufferList: inInputData,
                        format: self.streamFormat,
                        ring: ring,
                        scratch: self.analysisInterleavedScratch
                    )
                } else if bufferHasMeaningfulPayload(UnsafePointer(outOutputData)) {
                    writeInterleavedAnalysisPCM(
                        bufferList: UnsafePointer(outOutputData),
                        format: self.streamFormat,
                        ring: ring,
                        scratch: self.analysisInterleavedScratch
                    )
                }
            }

            let now = ProcessInfo.processInfo.systemUptime
            let throttleWindow = 1.0 / 12.0

            guard now - self.lastForwardUptime >= throttleWindow else {
                return
            }

            if let frame = makeCapturedFrame(
                bufferList: inInputData,
                format: self.streamFormat,
                sampleRate: self.streamFormat.mSampleRate,
                timestamp: Date(),
                sourceLabel: "Core Audio input"
            ) {
                self.lastForwardUptime = now
                self.frameHandler(frame)
                return
            }

            if let frame = makeCapturedFrame(
                bufferList: UnsafePointer(outOutputData),
                format: self.streamFormat,
                sampleRate: self.streamFormat.mSampleRate,
                timestamp: Date(),
                sourceLabel: "Core Audio output"
            ) {
                self.lastForwardUptime = now
                self.frameHandler(frame)
            }
        }

        guard status == noErr, let createdIOProcID else {
            errorHandler("AudioDeviceCreateIOProcIDWithBlock failed (\(status)).")
            return
        }
        ioProcID = createdIOProcID

        status = AudioDeviceStart(aggregateDeviceID, createdIOProcID)
        guard status == noErr else {
            errorHandler("AudioDeviceStart failed (\(status)).")
            return
        }

        stateHandler(true, streamFormat.mSampleRate)
    }
}

private final class VirtualInputOutputSession: SystemOutputMeterSession {
    private let deviceTarget: SystemAudioOutputMeterModel.VirtualInputDeviceTarget
    private let queue = DispatchQueue(label: "SystemAudioOutputMeterModel.virtual-input", qos: .userInitiated)
    private let frameHandler: (SystemOutputCapturedFrame) -> Void
    private let stateHandler: (Bool, Double) -> Void
    private let errorHandler: (String) -> Void

    private var audioDevice: AudioDeviceModel?
    private var timer: DispatchSourceTimer?
    private var didStop = false
    private let bufferSizeFrames: UInt32 = 512
    private let meteringFrames: UInt32 = 256

    init(
        deviceTarget: SystemAudioOutputMeterModel.VirtualInputDeviceTarget,
        frameHandler: @escaping (SystemOutputCapturedFrame) -> Void,
        stateHandler: @escaping (Bool, Double) -> Void,
        errorHandler: @escaping (String) -> Void
    ) {
        self.deviceTarget = deviceTarget
        self.frameHandler = frameHandler
        self.stateHandler = stateHandler
        self.errorHandler = errorHandler
    }

    func start() {
        queue.async { [weak self] in
            self?.configureAndStart()
        }
    }

    func stop() {
        queue.sync {
            guard didStop == false else { return }
            didStop = true
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            audioDevice?.stopPeakMonitoring()
            audioDevice = nil
        }
    }

    private func configureAndStart() {
        let monitoredChannels = max(deviceTarget.inputChannels, 2)
        let device = AudioDeviceModel(
            deviceID: deviceTarget.deviceID,
            name: deviceTarget.displayName,
            sampleRate: deviceTarget.sampleRate,
            manufacturer: deviceTarget.manufacturer,
            transportType: deviceTarget.transportType
        )

        guard device.startPeakMonitoring(bufferSize: bufferSizeFrames, channels: monitoredChannels) else {
            errorHandler("Virtual input monitoring failed to start on \(deviceTarget.displayName).")
            return
        }

        audioDevice = device

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(120), repeating: .milliseconds(84), leeway: .milliseconds(12))
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        self.timer = timer
        timer.resume()

        stateHandler(true, deviceTarget.sampleRate > 0 ? deviceTarget.sampleRate : 48_000)
    }

    private func poll() {
        guard didStop == false,
              let ringBuffer = audioDevice?.getRingBuffer() else {
            return
        }

        var leftResult = MeteringResult(peak: 0, rms: 0)
        let leftStatus = MeteringDSP_Compute(ringBuffer, 0, Int(meteringFrames), &leftResult)
        guard leftStatus == 0 else {
            errorHandler("Virtual input metering could not read channel 1 from \(deviceTarget.displayName).")
            return
        }

        var rightResult = leftResult
        if deviceTarget.inputChannels > 1 {
            var computedRightResult = MeteringResult(peak: 0, rms: 0)
            let rightStatus = MeteringDSP_Compute(ringBuffer, 1, Int(meteringFrames), &computedRightResult)
            if rightStatus == 0 {
                rightResult = computedRightResult
            }
        }

        let leftLinear = max(Double(leftResult.peak), Double(leftResult.rms))
        let rightLinear = max(Double(rightResult.peak), Double(rightResult.rms))
        let payloadBytes = Int(meteringFrames) * Int(max(deviceTarget.inputChannels, 2)) * MemoryLayout<Float>.size

        frameHandler(
            SystemOutputCapturedFrame(
                timestamp: Date(),
                leftLinear: leftLinear,
                rightLinear: rightLinear,
                payloadBytes: payloadBytes,
                sampleCount: Int(meteringFrames),
                sampleRate: deviceTarget.sampleRate > 0 ? deviceTarget.sampleRate : 48_000,
                bufferSource: "Virtual input · \(deviceTarget.displayName)",
                containsSignal: max(leftLinear, rightLinear) > 0.0008
            )
        )
    }
}

#if canImport(ScreenCaptureKit)
@available(macOS 13.0, *)
private nonisolated final class ScreenCaptureOutputSession: NSObject, SystemOutputMeterSession, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SystemAudioOutputMeterModel.screencapture", qos: .userInitiated)
    private let captureSource: SystemAudioOutputMeterModel.CaptureSource
    private let frameHandler: (SystemOutputCapturedFrame) -> Void
    private let stateHandler: (Bool, Double) -> Void
    private let errorHandler: (String) -> Void
    private let analysisRingBuffer: OpaquePointer?
    private let analysisInterleavedScratch = SystemOutputAnalysisInterleavedScratch()

    private var stream: SCStream?
    private var sampleRate: Double = 48_000
    private var lastForwardUptime: TimeInterval = 0

    init(
        captureSource: SystemAudioOutputMeterModel.CaptureSource,
        frameHandler: @escaping (SystemOutputCapturedFrame) -> Void,
        stateHandler: @escaping (Bool, Double) -> Void,
        errorHandler: @escaping (String) -> Void,
        analysisRingBuffer: OpaquePointer?
    ) {
        self.captureSource = captureSource
        self.frameHandler = frameHandler
        self.stateHandler = stateHandler
        self.errorHandler = errorHandler
        self.analysisRingBuffer = analysisRingBuffer
    }

    func start() {
        SCShareableContent.getWithCompletionHandler { [weak self] shareableContent, error in
            guard let self else { return }
            if let error {
                self.errorHandler("Screen Capture content query failed (\(error.localizedDescription)).")
                return
            }
            guard let display = shareableContent?.displays.first else {
                self.errorHandler("No shareable display was available for Screen Capture audio.")
                return
            }

            let filter: SCContentFilter
            switch self.captureSource {
            case .systemMix:
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            case .application(let target):
                guard let matchedApplication = shareableContent?.applications.first(where: { target.matches(screenCaptureApplication: $0) }) else {
                    self.errorHandler("Screen Capture could not find \(target.displayName) in the current shareable application list.")
                    return
                }
                filter = SCContentFilter(display: display, including: [matchedApplication], exceptingWindows: [])
            }
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 2
            configuration.showsCursor = false
            configuration.capturesAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.excludesCurrentProcessAudio = false

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            self.stream = stream
            self.sampleRate = Double(configuration.sampleRate)

            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
            } catch {
                self.errorHandler("Screen Capture output registration failed (\(error.localizedDescription)).")
                return
            }

            stream.startCapture { error in
                if let error {
                    self.errorHandler("Screen Capture start failed (\(error.localizedDescription)).")
                    return
                }
                self.stateHandler(true, self.sampleRate)
            }
        }
    }

    func stop() {
        guard let stream else { return }
        stream.stopCapture(completionHandler: { _ in })
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            return
        case .audio:
            if let analysisRingBuffer {
                writeCMSampleBufferToAnalysisRing(
                    sampleBuffer,
                    ring: analysisRingBuffer,
                    scratch: analysisInterleavedScratch
                )
            }
            let now = ProcessInfo.processInfo.systemUptime
            let throttleWindow = 1.0 / 12.0
            guard now - lastForwardUptime >= throttleWindow else { return }
            guard let frame = makeCapturedFrame(from: sampleBuffer, sampleRate: sampleRate) else { return }
            lastForwardUptime = now
            frameHandler(frame)
        default:
            return
        }
    }
}
#endif

private nonisolated func makeCapturedFrame(
    from sampleBuffer: CMSampleBuffer,
    sampleRate: Double
) -> SystemOutputCapturedFrame? {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
        return nil
    }

    let asbd = asbdPointer.pointee
    let channelCount = max(1, Int(asbd.mChannelsPerFrame))
    let listSize = MemoryLayout<AudioBufferList>.size + max(0, channelCount - 1) * MemoryLayout<AudioBuffer>.size
    let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { rawPointer.deallocate() }

    let audioBufferListPointer = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
    var blockBuffer: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: nil,
        bufferListOut: audioBufferListPointer,
        bufferListSize: listSize,
        blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault,
        flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
        blockBufferOut: &blockBuffer
    )

    guard status == noErr else { return nil }
    let frameCount = max(1, CMSampleBufferGetNumSamples(sampleBuffer))
    return makeCapturedFrame(
        bufferList: UnsafePointer(audioBufferListPointer),
        format: asbd,
        sampleRate: sampleRate,
        timestamp: Date(),
        sourceLabel: "Screen Capture audio",
        frameCountOverride: frameCount
    )
}

private nonisolated func makeCapturedFrame(
    bufferList: UnsafePointer<AudioBufferList>,
    format: AudioStreamBasicDescription,
    sampleRate: Double,
    timestamp: Date,
    sourceLabel: String,
    frameCountOverride: Int? = nil
) -> SystemOutputCapturedFrame? {
    let audioBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
    guard audioBuffers.isEmpty == false else { return nil }

    let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let isSignedInteger = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
    let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    let bitsPerChannel = Int(format.mBitsPerChannel)
    let channels = max(1, Int(format.mChannelsPerFrame))

    let payloadBytes = audioBuffers.reduce(0) { partialResult, buffer in
        partialResult + Int(buffer.mDataByteSize)
    }

    guard payloadBytes > 0 else {
        return SystemOutputCapturedFrame(
            timestamp: timestamp,
            leftLinear: 0,
            rightLinear: 0,
            payloadBytes: 0,
            sampleCount: frameCountOverride ?? 0,
            sampleRate: sampleRate,
            bufferSource: sourceLabel,
            containsSignal: false
        )
    }

    var leftPeak = 0.0
    var rightPeak = 0.0
    var sampleCount = 0

    func updatePeaks(left: Double, right: Double) {
        leftPeak = max(leftPeak, abs(left))
        rightPeak = max(rightPeak, abs(right))
        sampleCount += 1
    }

    if isNonInterleaved {
        let leftBuffer = audioBuffers[0]
        let rightBuffer = audioBuffers.count > 1 ? audioBuffers[1] : audioBuffers[0]

        if isFloat && bitsPerChannel == 32,
           let leftData = leftBuffer.mData?.assumingMemoryBound(to: Float.self),
           let rightData = rightBuffer.mData?.assumingMemoryBound(to: Float.self) {
            let frames = frameCountOverride ?? min(
                Int(leftBuffer.mDataByteSize) / MemoryLayout<Float>.size,
                Int(rightBuffer.mDataByteSize) / MemoryLayout<Float>.size
            )
            let stride = sampleAnalysisStride(for: frames)
            var index = 0
            while index < frames {
                updatePeaks(left: Double(leftData[index]), right: Double(rightData[index]))
                index += stride
            }
        } else if isSignedInteger && bitsPerChannel == 16,
                  let leftData = leftBuffer.mData?.assumingMemoryBound(to: Int16.self),
                  let rightData = rightBuffer.mData?.assumingMemoryBound(to: Int16.self) {
            let frames = frameCountOverride ?? min(
                Int(leftBuffer.mDataByteSize) / MemoryLayout<Int16>.size,
                Int(rightBuffer.mDataByteSize) / MemoryLayout<Int16>.size
            )
            let stride = sampleAnalysisStride(for: frames)
            var index = 0
            while index < frames {
                updatePeaks(
                    left: Double(leftData[index]) / Double(Int16.max),
                    right: Double(rightData[index]) / Double(Int16.max)
                )
                index += stride
            }
        } else {
            return nil
        }
    } else {
        let buffer = audioBuffers[0]
        if isFloat && bitsPerChannel == 32,
           let sampleData = buffer.mData?.assumingMemoryBound(to: Float.self) {
            let frames = frameCountOverride ?? (Int(buffer.mDataByteSize) / max(MemoryLayout<Float>.size * channels, 1))
            let stride = sampleAnalysisStride(for: frames)
            var frameIndex = 0
            while frameIndex < frames {
                let baseIndex = frameIndex * channels
                let left = Double(sampleData[baseIndex])
                let right = channels > 1 ? Double(sampleData[baseIndex + 1]) : left
                updatePeaks(left: left, right: right)
                frameIndex += stride
            }
        } else if isSignedInteger && bitsPerChannel == 16,
                  let sampleData = buffer.mData?.assumingMemoryBound(to: Int16.self) {
            let frames = frameCountOverride ?? (Int(buffer.mDataByteSize) / max(MemoryLayout<Int16>.size * channels, 1))
            let stride = sampleAnalysisStride(for: frames)
            var frameIndex = 0
            while frameIndex < frames {
                let baseIndex = frameIndex * channels
                let left = Double(sampleData[baseIndex]) / Double(Int16.max)
                let right = channels > 1
                    ? Double(sampleData[baseIndex + 1]) / Double(Int16.max)
                    : left
                updatePeaks(left: left, right: right)
                frameIndex += stride
            }
        } else {
            return nil
        }
    }

    return SystemOutputCapturedFrame(
        timestamp: timestamp,
        leftLinear: leftPeak,
        rightLinear: rightPeak,
        payloadBytes: payloadBytes,
        sampleCount: frameCountOverride ?? sampleCount,
        sampleRate: sampleRate,
        bufferSource: sourceLabel,
        containsSignal: max(leftPeak, rightPeak) > 0.0008
    )
}

private func bufferHasMeaningfulPayload(_ bufferList: UnsafePointer<AudioBufferList>) -> Bool {
    let audioBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
    return audioBuffers.contains(where: { $0.mDataByteSize > 0 && $0.mData != nil })
}

private func resolveCoreAudioProcessObjectIDs(
    for target: SystemAudioOutputMeterModel.CaptureSourceTarget
) -> [AudioObjectID] {
    copyCoreAudioProcessObjectIDs().filter { processObjectID in
        guard coreAudioProcessIsRunningOutput(processObjectID) else { return false }
        if let bundleIdentifier = target.bundleIdentifier,
           let processBundleIdentifier = coreAudioProcessBundleIdentifier(processObjectID),
           processBundleIdentifier == bundleIdentifier {
            return true
        }
        return coreAudioProcessPID(processObjectID) == target.processID
    }
}

private func copyCoreAudioProcessObjectIDs() -> [AudioObjectID] {
    let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &dataSize) == noErr,
          dataSize >= UInt32(MemoryLayout<AudioObjectID>.size) else {
        return []
    }

    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    var processObjectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
    guard AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, &processObjectIDs) == noErr else {
        return []
    }
    return processObjectIDs.filter { $0 != kAudioObjectUnknown }
}

private func coreAudioProcessPID(_ processObjectID: AudioObjectID) -> pid_t? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var processID: pid_t = 0
    var dataSize = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &dataSize, &processID) == noErr else {
        return nil
    }
    return processID
}

private func coreAudioProcessBundleIdentifier(_ processObjectID: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyBundleID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(processObjectID, &address, 0, nil, &dataSize) == noErr,
          dataSize >= UInt32(MemoryLayout<CFString?>.size) else {
        return nil
    }

    let rawBuffer = UnsafeMutableRawPointer.allocate(
        byteCount: Int(dataSize),
        alignment: MemoryLayout<CFString?>.alignment
    )
    defer { rawBuffer.deallocate() }

    guard AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &dataSize, rawBuffer) == noErr,
          let bundleIdentifier = rawBuffer.assumingMemoryBound(to: CFString?.self).pointee else {
        return nil
    }
    return bundleIdentifier as String
}

private func coreAudioProcessIsRunningOutput(_ processObjectID: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningOutput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var isRunningOutput: UInt32 = 0
    var dataSize = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &dataSize, &isRunningOutput) == noErr else {
        return false
    }
    return isRunningOutput != 0
}

private func readDeviceFormat(deviceID: AudioObjectID) -> AudioStreamBasicDescription? {
    var format = AudioStreamBasicDescription()
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

    var inputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamFormat,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &formatSize, &format) == noErr {
        return format
    }

    var outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreamFormat,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectGetPropertyData(deviceID, &outputAddress, 0, nil, &formatSize, &format) == noErr {
        return format
    }

    return nil
}

private func normalizedLevel(fromLinear linear: Double) -> Double {
    guard linear > 0 else { return 0 }
    let db = 20 * log10(max(linear, 0.000_001))
    return min(max((db + 60) / 60, 0), 1)
}

private func dbText(fromLinear linear: Double) -> String {
    guard linear > 0.000_001 else { return "-inf dB" }
    let db = 20 * log10(linear)
    return String(format: "%.0f dB", db)
}

private func sampleRateText(_ sampleRate: Double) -> String {
    guard sampleRate > 0 else { return "—" }
    return String(format: "%.1f kHz", sampleRate / 1000.0)
}

private func coreAudioKey(_ key: UnsafePointer<CChar>) -> String {
    String(utf8String: key) ?? ""
}

private nonisolated func sampleAnalysisStride(for frames: Int) -> Int {
    guard frames > 0 else { return 1 }
    return max(1, frames / 160)
}
