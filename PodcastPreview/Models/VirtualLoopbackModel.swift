//
//  VirtualLoopbackModel.swift
//  PodcastPreview
//
//  Input + AudioServerPlugIn -> app mixer -> output routing model for the audio tab.
//

import Foundation
import SwiftUI
import CoreAudio
import Combine

struct AudioRouteDeviceDescriptor: Identifiable, Hashable {
    let deviceID: UInt32
    let uid: String
    let name: String
    let sampleRate: Double
    let manufacturer: String
    let transportType: DeviceTransportType
    let inputChannels: UInt32
    let outputChannels: UInt32

    var id: UInt32 { deviceID }
}

@MainActor
final class VirtualLoopbackModel: ObservableObject {
    private enum RoutingBackend {
        case local
        case remote
    }

    @Published var availableInputs: [AudioRouteDeviceDescriptor] = []
    @Published var availableOutputs: [AudioRouteDeviceDescriptor] = []
    @Published var selectedInputDeviceID: UInt32 = kAudioObjectUnknown
    @Published var selectedOutputDeviceID: UInt32 = kAudioObjectUnknown
    @Published var detectedPluginDevice: AudioRouteDeviceDescriptor?
    @Published var isRouterRunning = false
    @Published var busFed = false
    @Published var includeSelectedInput = true
    @Published var includeSystemAudio = true
    @Published var selectedInputGain: Double = 1.0
    @Published var systemAudioGain: Double = 1.0
    @Published var selectedInputLevel: Double = 0.0
    @Published var systemAudioLevel: Double = 0.0
    @Published var framesAvailable: UInt64 = 0
    @Published var framesCaptured: UInt64 = 0
    @Published var overruns: UInt64 = 0
    @Published var underruns: UInt64 = 0
    @Published var bufferFrames: UInt32 = 512
    @Published var routeSampleRate: Double = AudioRoutingServiceConstants.defaultLoopbackSampleRate
    @Published var isTapAnalysisEnabled = true
    @Published var statusText: String = "Idle"
    @Published var errorMessage: String?

    let tapMonitoring = MonitoringState(autoRefreshDevices: false)
    let tapThemeColor = Color(hue: 0.93, saturation: 0.70, brightness: 0.92)

    private let audioRoutingClient = AudioRoutingServiceClient()
    private var statusTimer: Timer?
    private var remoteTapTimer: Timer?
    private var remoteTapRingBuffer: OpaquePointer?
    private var remoteTapChannels: UInt32 = 0
    private var remoteStatus = AudioRoutingStatusSnapshot.empty
    private var hasAdoptedRemoteConfiguration = false
    private var routingBackend: RoutingBackend = .local
    private var framesCapturedBaseline: UInt64 = 0
    private var overrunsBaseline: UInt64 = 0
    private var underrunsBaseline: UInt64 = 0
    private let remoteStartRetryInterval: TimeInterval = 0.25
    private let remoteStartRetryCount = 8

    init() {
        refreshDevices()
        syncSourceControls()
        refreshStatus()
        pollRemoteStatusIfNeeded()
    }

    deinit {
        statusTimer?.invalidate()
        remoteTapTimer?.invalidate()
        if let remoteTapRingBuffer {
            RingBuffer_Destroy(remoteTapRingBuffer)
        }
        let client = audioRoutingClient
        Task { @MainActor in
            client.invalidate()
        }
    }

    var selectedInput: AudioRouteDeviceDescriptor? {
        availableInputs.first(where: { $0.deviceID == selectedInputDeviceID })
    }

    var selectedOutput: AudioRouteDeviceDescriptor? {
        availableOutputs.first(where: { $0.deviceID == selectedOutputDeviceID })
    }

    var pluginDisplayName: String {
        detectedPluginDevice?.name ?? "Podcast Preview ASP not detected"
    }

    var isTapActive: Bool {
        busFed
    }

    var isTapSpectrumAvailable: Bool {
        isTapAnalysisEnabled && tapMonitoring.currentRingBuffer() != nil
    }

    var inputSummary: String {
        selectedInput?.name ?? "Select input device"
    }

    var outputSummary: String {
        selectedOutput?.name ?? "Select output device"
    }

    var sourceSummary: String {
        let hasSystemSource = includeSystemAudio && isPluginSelectedAsSystemOutput()
        let hasInputSource = includeSelectedInput && selectedInput != nil

        if hasSystemSource && hasInputSource {
            return "\(pluginDisplayName) + \(inputSummary)"
        }
        if hasSystemSource {
            return pluginDisplayName
        }
        return inputSummary
    }

    func refreshDevices() {
        let discovered = enumerateAllDevices()

        availableInputs = discovered.filter { $0.inputChannels > 0 }

        detectedPluginDevice = detectPluginDevice(in: discovered.filter { $0.outputChannels > 0 })
        availableOutputs = discovered.filter { device in
            device.outputChannels > 0 && device.deviceID != detectedPluginDevice?.deviceID
        }

        if let currentInput = selectedInput,
           availableInputs.contains(where: { $0.deviceID == currentInput.deviceID }) == false {
            selectedInputDeviceID = kAudioObjectUnknown
        }

        if let currentOutput = selectedOutput,
           availableOutputs.contains(where: { $0.deviceID == currentOutput.deviceID }) == false {
            selectedOutputDeviceID = kAudioObjectUnknown
        }

        if selectedInput == nil {
            let defaultInput = AudioDevices_GetDefaultInputDevice()
            if let match = availableInputs.first(where: { $0.deviceID == defaultInput }) {
                selectedInputDeviceID = match.deviceID
            } else {
                selectedInputDeviceID = availableInputs.first?.deviceID ?? kAudioObjectUnknown
            }
        }

        if selectedOutput == nil {
            let defaultOutput = AudioDevices_GetDefaultOutputDevice()
            if let match = availableOutputs.first(where: { $0.deviceID == defaultOutput }) {
                selectedOutputDeviceID = match.deviceID
            } else {
                selectedOutputDeviceID = availableOutputs.first?.deviceID ?? kAudioObjectUnknown
            }
        }

        syncRequestedOutputDevice()
    }

    func updateInputSelection(to deviceID: UInt32) {
        guard selectedInputDeviceID != deviceID else { return }
        selectedInputDeviceID = deviceID
        pushRemoteConfigurationIfNeeded()
        restartRoutingIfNeeded()
    }

    func updateIncludeSelectedInput(to isEnabled: Bool) {
        guard includeSelectedInput != isEnabled else { return }
        includeSelectedInput = isEnabled
        syncSourceControls()
        pushRemoteConfigurationIfNeeded()
        restartRoutingIfNeeded()
    }

    func updateIncludeSystemAudio(to isEnabled: Bool) {
        guard includeSystemAudio != isEnabled else { return }
        includeSystemAudio = isEnabled
        syncSourceControls()
        pushRemoteConfigurationIfNeeded()
        refreshStatus()
    }

    func updateSelectedInputGain(to gain: Double) {
        let clampedGain = min(max(gain, 0.0), 2.0)
        guard abs(selectedInputGain - clampedGain) > 0.001 else { return }
        selectedInputGain = clampedGain
        syncSourceControls()
        pushRemoteConfigurationIfNeeded()
        refreshStatus()
    }

    func updateSystemAudioGain(to gain: Double) {
        let clampedGain = min(max(gain, 0.0), 2.0)
        guard abs(systemAudioGain - clampedGain) > 0.001 else { return }
        systemAudioGain = clampedGain
        syncSourceControls()
        pushRemoteConfigurationIfNeeded()
        refreshStatus()
    }

    func updateOutputSelection(to deviceID: UInt32) {
        guard selectedOutputDeviceID != deviceID else { return }
        selectedOutputDeviceID = deviceID
        syncRequestedOutputDevice()
        pushRemoteConfigurationIfNeeded()
        restartRoutingIfNeeded()
    }

    func updateBufferFrames(to frames: UInt32) {
        guard bufferFrames != frames else { return }
        bufferFrames = frames
        pushRemoteConfigurationIfNeeded()
        restartRoutingIfNeeded()
    }

    func updateSampleRate(to sampleRate: Double) {
        let normalizedSampleRate = AudioRoutingServiceConstants.normalizeLoopbackSampleRate(sampleRate)
        guard abs(routeSampleRate - normalizedSampleRate) > 0.5 else { return }

        routeSampleRate = normalizedSampleRate
        if routingBackend == .local || !audioRoutingClient.isSupportedAndAvailable {
            applyConfiguredLoopbackSampleRateLocally()
        }
        pushRemoteConfigurationIfNeeded()
        refreshDevices()
        refreshStatus()
    }

    func updateTapAnalysisEnabled(to isEnabled: Bool) {
        guard isTapAnalysisEnabled != isEnabled else { return }
        isTapAnalysisEnabled = isEnabled

        PPVirtualLoopbackRouter_SetTapAnalysisEnabled(isEnabled)
        pushRemoteConfigurationIfNeeded()
        refreshTapMonitoringState()
    }

    func resetRouteCounters() {
        framesCapturedBaseline += framesCaptured
        overrunsBaseline += overruns
        underrunsBaseline += underruns

        framesCaptured = 0
        overruns = 0
        underruns = 0
    }

    func startRouting() {
        guard let output = selectedOutput else {
            errorMessage = "Select an output device before starting the route."
            return
        }

        syncSourceControls()

        let systemFeedsBus = includeSystemAudio && isPluginSelectedAsSystemOutput()
        let inputRequested = includeSelectedInput
        var inputStarted = false

        if inputRequested, let input = selectedInput {
            let inputChannels = max(input.inputChannels, 1)
            let inputResult = PPRouteInputEngine_Start(input.deviceID, bufferFrames, inputChannels)
            if inputResult == 0 {
                inputStarted = true
            } else if !systemFeedsBus {
                errorMessage = "Failed to start the input side of the route."
                refreshStatus()
                return
            }
        } else if inputRequested && !systemFeedsBus {
            errorMessage = "Select an input device or set macOS output to Podcast Preview Virtual Output."
            return
        } else if !inputRequested && !systemFeedsBus {
            errorMessage = "Enable Selected Input or set macOS output to Podcast Preview Virtual Output."
            return
        }

        startStatusTimer()

        guard audioRoutingClient.isSupportedPlatform else {
            startLocalRouting(output: output, inputStarted: inputStarted)
            return
        }

        startRemoteRouting(output: output,
                           inputStarted: inputStarted,
                           remainingAttempts: remoteStartRetryCount)
    }

    func stopRouting() {
        statusTimer?.invalidate()
        statusTimer = nil
        remoteTapTimer?.invalidate()
        remoteTapTimer = nil
        tapMonitoring.stopMonitoring()

        if routingBackend == .local {
            PPVirtualLoopbackRouter_Stop()
        } else {
            pushRemoteConfigurationIfNeeded(routeEnabledOverride: false)
        }

        PPRouteInputEngine_Stop()
        syncSourceControls()
        refreshStatus()
        errorMessage = nil
    }

    func restartRoutingIfNeeded() {
        guard isRouterRunning else { return }
        stopRouting()
        startRouting()
    }

    private func attachTapMonitoring() {
        guard isTapAnalysisEnabled else {
            stopTapMonitoring()
            return
        }

        if routingBackend == .remote {
            if let remoteTapRingBuffer {
                tapMonitoring.startExternalMonitoring(
                    sourceName: sourceSummary,
                    ringBuffer: remoteTapRingBuffer,
                    channelCount: max(remoteTapChannels, 1),
                    sampleRate: max(remoteStatus.sampleRate, 1),
                    themeColor: tapThemeColor,
                    manufacturer: detectedPluginDevice?.manufacturer ?? "Podcast Preview",
                    connection: "Audio routing agent -> downstream output"
                )
            }
            return
        }

        guard PPVirtualLoopbackRouter_IsRunning(),
              let ringBuffer = PPVirtualLoopbackRouter_GetTapRingBuffer() else {
            errorMessage = "Route started without a tap ring buffer."
            return
        }

        let tapChannels = max(PPVirtualLoopbackRouter_GetTapChannelCount(), 1)
        let tapSampleRate = PPVirtualLoopbackRouter_GetTapSampleRate()

        let inputActive = includeSelectedInput && PPRouteInputEngine_IsRunning()
        let systemActive = includeSystemAudio && isPluginSelectedAsSystemOutput()
        let connection: String
        if inputActive && systemActive {
            connection = "Local input + AudioServerPlugIn -> app mixer"
        } else if systemActive {
            connection = "AudioServerPlugIn -> app bus"
        } else {
            connection = "Local input -> app bus"
        }

        tapMonitoring.startExternalMonitoring(
            sourceName: inputActive && systemActive ? "Program Mixer" : sourceSummary,
            ringBuffer: ringBuffer,
            channelCount: tapChannels,
            sampleRate: tapSampleRate,
            themeColor: tapThemeColor,
            manufacturer: detectedPluginDevice?.manufacturer ?? selectedInput?.manufacturer ?? "Podcast Preview",
            connection: connection
        )
    }

    private func stopTapMonitoring() {
        remoteTapTimer?.invalidate()
        remoteTapTimer = nil
        tapMonitoring.stopMonitoring()
    }

    private func refreshTapMonitoringState() {
        if !isTapAnalysisEnabled {
            stopTapMonitoring()
            return
        }

        if routingBackend == .remote {
            startRemoteTapMirroring()
        }
        attachTapMonitoring()
    }

    private func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatus()
                self?.pollRemoteStatusIfNeeded()
            }
        }
    }

    private func refreshStatus() {
        var inputStatus = PPRouteInputEngineStatus()
        PPRouteInputEngine_GetStatus(&inputStatus)

        var localRouterStatus = PPVirtualLoopbackRouterStatus()
        PPVirtualLoopbackRouter_GetStatus(&localRouterStatus)

        var transportStatus = PPVirtualLoopbackStatus()
        PPVirtualLoopbackTransport_GetStatus(&transportStatus)

        let effectiveRouterRunning = routingBackend == .remote || remoteStatus.isRouteRunning
            ? remoteStatus.isRouteRunning
            : localRouterStatus.isRunning
        let effectiveFramesAvailable = routingBackend == .remote || remoteStatus.isRouteRunning
            ? remoteStatus.framesAvailable
            : localRouterStatus.framesAvailable
        let effectiveOverruns = routingBackend == .remote || remoteStatus.isRouteRunning
            ? remoteStatus.overruns
            : localRouterStatus.overruns
        let effectiveUnderruns = routingBackend == .remote || remoteStatus.isRouteRunning
            ? remoteStatus.underruns
            : localRouterStatus.underruns

        let inputFeedsBus = includeSelectedInput &&
            inputStatus.isRunning &&
            transportStatus.inputWriterConnected &&
            transportStatus.inputSourceEnabled
        let pluginFeedsBus = includeSystemAudio &&
            isPluginSelectedAsSystemOutput() &&
            transportStatus.systemWriterConnected &&
            transportStatus.systemSourceEnabled

        busFed = inputFeedsBus || pluginFeedsBus
        isRouterRunning = effectiveRouterRunning
        let rawFramesCaptured = (inputFeedsBus ? transportStatus.inputFramesWritten : 0) +
            (pluginFeedsBus ? transportStatus.systemFramesWritten : 0)
        let rawOverruns = effectiveOverruns
        let rawUnderruns = effectiveUnderruns

        if rawFramesCaptured < framesCapturedBaseline {
            framesCapturedBaseline = 0
        }
        if rawOverruns < overrunsBaseline {
            overrunsBaseline = 0
        }
        if rawUnderruns < underrunsBaseline {
            underrunsBaseline = 0
        }

        framesCaptured = rawFramesCaptured - framesCapturedBaseline
        framesAvailable = effectiveFramesAvailable
        overruns = rawOverruns - overrunsBaseline
        underruns = rawUnderruns - underrunsBaseline
        selectedInputLevel = Double(min(max(transportStatus.inputSourcePeak * transportStatus.inputSourceGain, 0.0), 1.0))
        systemAudioLevel = Double(min(max(transportStatus.systemSourcePeak * transportStatus.systemSourceGain, 0.0), 1.0))

        if inputFeedsBus && pluginFeedsBus && isRouterRunning {
            statusText = "\(inputSummary) + \(pluginDisplayName) -> App mixer -> \(outputSummary)"
        } else if inputFeedsBus && isRouterRunning {
            statusText = "\(inputSummary) -> App bus -> \(outputSummary)"
        } else if pluginFeedsBus && isRouterRunning {
            statusText = "\(pluginDisplayName) -> App -> \(outputSummary)"
        } else if inputFeedsBus && pluginFeedsBus {
            statusText = "Input + system output active on program bus"
        } else if inputFeedsBus {
            statusText = "Input active on program bus"
        } else if pluginFeedsBus {
            statusText = "System output active on program bus"
        } else {
            statusText = "Idle"
        }

        let remoteError = remoteStatus.lastError.nilIfEmpty
        let currentError = remoteError ?? currentTransportError().nilIfEmpty
        if let currentError, !isRouterRunning || !busFed {
            errorMessage = currentError
        } else {
            errorMessage = nil
        }
    }

    private func isPluginSelectedAsSystemOutput() -> Bool {
        guard let pluginDevice = detectedPluginDevice else {
            return false
        }
        return AudioDevices_GetDefaultOutputDevice() == pluginDevice.deviceID
    }

    private func syncRequestedOutputDevice() {
        guard let output = selectedOutput else { return }
        output.uid.withCString { uidCString in
            _ = PPVirtualLoopbackTransport_SetRequestedOutputDeviceUID(uidCString)
        }
    }

    private func syncSourceControls() {
        _ = PPVirtualLoopbackTransport_SetSourceEnabled(kPPVirtualLoopbackSourceInput, includeSelectedInput)
        _ = PPVirtualLoopbackTransport_SetSourceEnabled(kPPVirtualLoopbackSourceSystem, includeSystemAudio)
        _ = PPVirtualLoopbackTransport_SetSourceGain(kPPVirtualLoopbackSourceInput, Float(selectedInputGain))
        _ = PPVirtualLoopbackTransport_SetSourceGain(kPPVirtualLoopbackSourceSystem, Float(systemAudioGain))
    }

    private func currentTransportError() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard PPVirtualLoopbackTransport_CopyLastError(&buffer, 256) == 0 else {
            return ""
        }
        return String(cString: buffer)
    }

    private func startLocalRouting(output: AudioRouteDeviceDescriptor, inputStarted: Bool) {
        applyConfiguredLoopbackSampleRateLocally()
        let outputResult = output.uid.withCString { uidCString in
            PPVirtualLoopbackRouter_Start(uidCString, bufferFrames)
        }

        guard outputResult == 0 else {
            if inputStarted {
                PPRouteInputEngine_Stop()
            }
            refreshStatus()
            errorMessage = currentTransportError().nilIfEmpty ?? "Failed to start the output side of the route."
            return
        }

        routingBackend = .local
        attachTapMonitoring()
        refreshStatus()
        errorMessage = nil
    }

    private func startRemoteRouting(output: AudioRouteDeviceDescriptor,
                                    inputStarted: Bool,
                                    remainingAttempts: Int) {
        pushRemoteConfigurationIfNeeded(routeEnabledOverride: true) { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                if let status, status.isRouteRunning {
                    self.routingBackend = .remote
                    self.attachTapMonitoring()
                    self.startRemoteTapMirroring()
                    self.refreshStatus()
                    self.errorMessage = nil
                    return
                }

                guard remainingAttempts > 1 else {
                    if inputStarted {
                        PPRouteInputEngine_Stop()
                    }
                    self.routingBackend = .local
                    self.remoteTapTimer?.invalidate()
                    self.remoteTapTimer = nil
                    self.refreshStatus()
                    self.errorMessage = status?.lastError.nilIfEmpty ??
                        "Audio routing agent did not bring the downstream route online."
                    return
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + self.remoteStartRetryInterval) { [weak self] in
                    self?.startRemoteRouting(output: output,
                                             inputStarted: inputStarted,
                                             remainingAttempts: remainingAttempts - 1)
                }
            }
        }
    }

    private func currentRoutingConfiguration(routeEnabledOverride: Bool? = nil) -> AudioRoutingConfiguration {
        let currentRouteEnabled = routeEnabledOverride ?? (remoteStatus.configuration.routeEnabled || isRouterRunning)

        return AudioRoutingConfiguration(
            routeEnabled: currentRouteEnabled,
            outputDeviceUID: selectedOutput?.uid ?? "",
            bufferFrames: bufferFrames,
            includeSystemAudio: includeSystemAudio,
            includeSelectedInput: includeSelectedInput,
            tapAnalysisEnabled: isTapAnalysisEnabled,
            systemAudioGain: Float(systemAudioGain),
            selectedInputGain: Float(selectedInputGain),
            sampleRate: routeSampleRate
        )
    }

    private func pushRemoteConfigurationIfNeeded(routeEnabledOverride: Bool? = nil,
                                                 completion: ((AudioRoutingStatusSnapshot?) -> Void)? = nil) {
        guard audioRoutingClient.isSupportedAndAvailable else {
            completion?(nil)
            return
        }

        let configuration = currentRoutingConfiguration(routeEnabledOverride: routeEnabledOverride)
        audioRoutingClient.setConfiguration(configuration) { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard let status else {
                    completion?(nil)
                    return
                }
                self.remoteStatus = status
                if status.isRouteRunning {
                    self.routingBackend = .remote
                }
                self.adoptRemoteConfigurationIfNeeded(status)
                self.refreshStatus()
                completion?(status)
            }
        }
    }

    private func pollRemoteStatusIfNeeded() {
        guard audioRoutingClient.isSupportedAndAvailable else { return }
        audioRoutingClient.fetchStatus { [weak self] status in
            Task { @MainActor in
                guard let self, let status else { return }
                self.remoteStatus = status
                if status.isRouteRunning {
                    self.routingBackend = .remote
                    self.startRemoteTapMirroring()
                }
                self.adoptRemoteConfigurationIfNeeded(status)
                self.refreshStatus()
            }
        }
    }

    private func adoptRemoteConfigurationIfNeeded(_ status: AudioRoutingStatusSnapshot) {
        guard !hasAdoptedRemoteConfiguration else { return }
        hasAdoptedRemoteConfiguration = true

        includeSystemAudio = status.configuration.includeSystemAudio
        includeSelectedInput = status.configuration.includeSelectedInput
        isTapAnalysisEnabled = status.configuration.tapAnalysisEnabled
        systemAudioGain = Double(status.configuration.systemAudioGain)
        selectedInputGain = Double(status.configuration.selectedInputGain)
        bufferFrames = status.configuration.bufferFrames
        routeSampleRate = AudioRoutingServiceConstants.normalizeLoopbackSampleRate(status.configuration.sampleRate)

        if !status.configuration.outputDeviceUID.isEmpty,
           let match = availableOutputs.first(where: { $0.uid == status.configuration.outputDeviceUID }) {
            selectedOutputDeviceID = match.deviceID
        }
    }

    private func applyConfiguredLoopbackSampleRateLocally() {
        let normalizedSampleRate = AudioRoutingServiceConstants.normalizeLoopbackSampleRate(routeSampleRate)
        if abs(routeSampleRate - normalizedSampleRate) > 0.5 {
            routeSampleRate = normalizedSampleRate
        }

        let status = AudioDevices_SetDeviceSampleRateByUID(AudioRoutingServiceConstants.loopbackDeviceUID,
                                                           normalizedSampleRate)
        if status != noErr {
            errorMessage = "Unable to set the FireWire Net Bridge sample rate."
        }
    }

    private func startRemoteTapMirroring() {
        guard audioRoutingClient.isSupportedAndAvailable else { return }
        guard isTapAnalysisEnabled else { return }
        guard remoteTapTimer == nil else { return }

        remoteTapTimer = Timer.scheduledTimer(withTimeInterval: 0.067, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.audioRoutingClient.fetchTapSnapshot(maxFrames: 2048) { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self, let snapshot else { return }
                    self.consumeRemoteTapSnapshot(snapshot)
                }
            }
        }
    }

    private func consumeRemoteTapSnapshot(_ snapshot: AudioRoutingTapSnapshot) {
        guard isTapAnalysisEnabled else { return }
        guard snapshot.channels > 0,
              snapshot.frames > 0,
              !snapshot.interleavedPCM.isEmpty else {
            return
        }

        let channelCount = snapshot.channels
        if remoteTapRingBuffer == nil || remoteTapChannels != channelCount {
            if let remoteTapRingBuffer {
                RingBuffer_Destroy(remoteTapRingBuffer)
            }

            remoteTapChannels = channelCount
            if let ringBuffer = RingBuffer_Create(32768, channelCount) {
                remoteTapRingBuffer = ringBuffer
            } else {
                remoteTapRingBuffer = nil
            }
            if let remoteTapRingBuffer {
                tapMonitoring.startExternalMonitoring(
                    sourceName: sourceSummary,
                    ringBuffer: remoteTapRingBuffer,
                    channelCount: channelCount,
                    sampleRate: snapshot.sampleRate,
                    themeColor: tapThemeColor,
                    manufacturer: detectedPluginDevice?.manufacturer ?? "Podcast Preview",
                    connection: "Audio routing agent -> downstream output"
                )
            }
        }

        guard let remoteTapRingBuffer else { return }
        snapshot.interleavedPCM.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: Float.self).baseAddress else { return }
            RingBuffer_WriteInterleaved(remoteTapRingBuffer,
                                        baseAddress,
                                        Int(snapshot.frames),
                                        channelCount)
        }
    }

    private func enumerateAllDevices() -> [AudioRouteDeviceDescriptor] {
        var systemDeviceIDs: [AudioDeviceID] = Array(repeating: 0, count: 128)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = UInt32(systemDeviceIDs.count * MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &systemDeviceIDs)
        guard status == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        return systemDeviceIDs.prefix(count).compactMap { buildDescriptor(for: $0) }
    }

    private func buildDescriptor(for deviceID: AudioDeviceID) -> AudioRouteDeviceDescriptor? {
        var nameBuffer = [CChar](repeating: 0, count: 256)
        guard AudioDevices_GetDeviceName(deviceID, &nameBuffer, 256) == noErr else {
            return nil
        }

        var uidBuffer = [CChar](repeating: 0, count: 256)
        guard AudioDevices_GetDeviceUID(deviceID, &uidBuffer, 256) == noErr else {
            return nil
        }

        var manufacturerBuffer = [CChar](repeating: 0, count: 256)
        let manufacturer: String
        if AudioDevices_GetDeviceManufacturer(deviceID, &manufacturerBuffer, 256) == noErr {
            manufacturer = String(cString: manufacturerBuffer)
        } else {
            manufacturer = ""
        }

        return AudioRouteDeviceDescriptor(
            deviceID: deviceID,
            uid: String(cString: uidBuffer),
            name: String(cString: nameBuffer),
            sampleRate: AudioDevices_GetDeviceSampleRate(deviceID),
            manufacturer: manufacturer,
            transportType: DeviceTransportType(rawTransportValue: AudioDevices_GetDeviceTransportType(deviceID)),
            inputChannels: AudioDevices_GetInputChannelCount(deviceID),
            outputChannels: AudioDevices_GetOutputChannelCount(deviceID)
        )
    }

    private func detectPluginDevice(in outputs: [AudioRouteDeviceDescriptor]) -> AudioRouteDeviceDescriptor? {
        let prioritized = outputs.filter {
            $0.transportType == .virtual &&
            (
                $0.name.localizedCaseInsensitiveContains("podcast") ||
                $0.name.localizedCaseInsensitiveContains("preview") ||
                $0.manufacturer.localizedCaseInsensitiveContains("podcast")
            )
        }

        if let match = prioritized.first {
            return match
        }

        return outputs.first(where: { $0.transportType == .virtual })
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
