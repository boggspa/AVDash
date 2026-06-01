//
//  MonitoringState.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 07/12/2025.
//

import Foundation
import SwiftUI
import Combine
import CoreAudio

/// Per-device monitoring session
struct DeviceMonitoringSession: Identifiable {
    let id: UUID
    let device: AudioDeviceModel
    var channelMetering: [MeteringResult]
    var timer: Timer?
    var uiTimer: Timer?
    var channelCount: UInt32
    var latestFirstResult: MeteringResult

    init(device: AudioDeviceModel, channelCount: UInt32) {
        self.id = UUID()
        self.device = device
        self.channelCount = channelCount
        self.channelMetering = Array(repeating: MeteringResult(peak: 0, rms: 0), count: Int(channelCount))
        self.latestFirstResult = MeteringResult(peak: 0.0, rms: 0.0)
    }
}

// MonitoringState manages current monitoring and metering for the selected device(s)
@MainActor
final class MonitoringState: ObservableObject {
    @Published var devices: [AudioDeviceModel] = []

    // Legacy single-device support (for FFT/spectrum, which only works on one device)
    @Published var selectedDevice: AudioDeviceModel?
    @Published var selectedSourceName: String?
    @Published var selectedSourceSampleRate: Double = 0.0
    @Published var selectedSourceManufacturer: String = ""
    @Published var selectedSourceConnection: String = ""
    @Published var selectedSourceThemeColor: Color = .green
    @Published var selectedSourceSpectrumThemeColor: Color = .purple
    @Published var selectedSourceWaveformThemeColor: Color = .blue
    @Published var channelMetering: [MeteringResult] = []
    @Published var meteringResult: MeteringResult = MeteringResult(peak: 0.0, rms: 0.0)
    /// Throttled snapshot for UI text (Peak/RMS labels). Keeps metering fast while reducing SwiftUI Text churn.
    @Published var uiMeteringResult: MeteringResult = MeteringResult(peak: 0.0, rms: 0.0)

    // Multi-device monitoring
    @Published var activeSessions: [UUID: DeviceMonitoringSession] = [:]

    @Published var errorMessage: String?

    /// Per-device metering calibration in dB (compensates fixed path attenuation)
    /// Range: -20 dB to +20 dB. Default: 0 dB (unity gain)
    /// Use positive values if your signal path is consistently quiet.
    @Published var meterCalibrationDB: Float = 0.0 {
        didSet {
            applyCalibration()
        }
    }

    /// Selected channel for spectrum analyzer display (0-indexed)
    @Published var selectedSpectrumChannel: UInt32 = 0 {
        didSet {
            // Clamp to available channels
            if selectedSpectrumChannel >= channelCount {
                selectedSpectrumChannel = max(0, channelCount - 1)
            }
            // Apply to FFT analyzer (thread-safe atomic write)
            FFTAnalyser_SetSelectedChannel(selectedSpectrumChannel)
        }
    }

    /// Minimum frequency for spectrum display (in Hz)
    /// Default: 20 Hz. Lower values show more sub-bass content.
    @Published var spectrumMinFreqHz: Double = 20.0 {
        didSet {
            FFTAnalyser_SetFrequencyRange(spectrumMinFreqHz, spectrumMaxFreqHz)
        }
    }

    /// Maximum frequency for spectrum display (in Hz)
    /// Default: 20,000 Hz (20 kHz). Higher values approach Nyquist limit.
    @Published var spectrumMaxFreqHz: Double = 20000.0 {
        didSet {
            FFTAnalyser_SetFrequencyRange(spectrumMinFreqHz, spectrumMaxFreqHz)
        }
    }

    /// Audio engine buffer size in frames.
    /// Larger = more stable on older Intel Macs, but higher latency.
    @Published var bufferSizeFrames: UInt32 = 512

    private var timer: Timer?
    private var uiTimer: Timer?
    private var externalRingBuffer: OpaquePointer?
    private var usingExternalSource = false

    private let meteringFrames: UInt32 = 256 // e.g., 256 frames per update
    private(set) var channelCount: UInt32 = 1

    // Latest first-channel result (not @Published). UI pulls from this at a lower rate.
    private var latestFirstResult: MeteringResult = MeteringResult(peak: 0.0, rms: 0.0)

    init(autoRefreshDevices: Bool = true) {
        // Default to a larger buffer on older systems where UI + audio callbacks can stutter.
        if #unavailable(macOS 12.0) {
            bufferSizeFrames = 1024
        }

        // Set default frequency range
        FFTAnalyser_SetFrequencyRange(spectrumMinFreqHz, spectrumMaxFreqHz)

        if autoRefreshDevices {
            refreshDevices()
        }
    }

    func startMonitoring(device: AudioDeviceModel) {
        // If the same device is reselected, do nothing
        if let current = selectedDevice, current.deviceID == device.deviceID {
            return
        }

        // Always stop any existing monitoring first
        stopMonitoring()

        // Clean up old peak hold data when switching devices
        MetalMeterView.clearPeakHoldData()

        selectedDevice = device
        usingExternalSource = false
        externalRingBuffer = nil
        errorMessage = nil

        // Ask CoreAudio how many input channels this device has
        let count = AudioDevices_GetInputChannelCount(device.deviceID)
        channelCount = max(count, 1)

        // Reset spectrum channel selection to first channel
        selectedSpectrumChannel = 0
        FFTAnalyser_SetSelectedChannel(0)

        // Prepare per-channel metering array
        channelMetering = Array(
            repeating: MeteringResult(peak: 0, rms: 0),
            count: Int(channelCount)
        )

        // Apply metering calibration (in dB) at the DSP layer
        // Default 0 dB = unity gain; adjust if input levels are consistently low
        meterCalibrationDB = 0.0
        MeteringDSP_SetCalibrationDB(meterCalibrationDB)
        FFTAnalyser_SetCalibrationDB(meterCalibrationDB)

        if !device.startMonitoring(bufferSize: bufferSizeFrames, channels: channelCount) {
            errorMessage = "Failed to start audio monitoring."
            selectedDevice = nil
            return
        }

        // Metering cadence: ~15Hz reduces SwiftUI churn while keeping meters responsive.
        // The Metal views pull data at 30Hz independently, so we can publish slower here.
        timer = Timer.scheduledTimer(withTimeInterval: 0.067, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.updateAllChannels()
            }
        }

        // UI text cadence: much slower than metering to avoid frequent Text re-layout.
        // This does NOT affect the underlying metering calculations.
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.uiMeteringResult = self.latestFirstResult
            }
        }
    }

    func startExternalMonitoring(sourceName: String,
                                 ringBuffer: OpaquePointer,
                                 channelCount: UInt32,
                                 sampleRate: Double,
                                 themeColor: Color = .green,
                                 spectrumThemeColor: Color = .green,
                                 waveformThemeColor: Color = .blue,
                                 manufacturer: String = "",
                                 connection: String = "Virtual Audio Tap") {
        stopMonitoring()

        selectedDevice = nil
        selectedSourceName = sourceName
        selectedSourceSampleRate = sampleRate
        selectedSourceManufacturer = manufacturer
        selectedSourceConnection = connection
        selectedSourceThemeColor = themeColor
        externalRingBuffer = ringBuffer
        usingExternalSource = true
        errorMessage = nil

        self.channelCount = max(channelCount, 1)
        selectedSpectrumChannel = 0
        FFTAnalyser_SetSelectedChannel(0)

        channelMetering = Array(
            repeating: MeteringResult(peak: 0, rms: 0),
            count: Int(self.channelCount)
        )

        meterCalibrationDB = 0.0
        MeteringDSP_SetCalibrationDB(meterCalibrationDB)
        FFTAnalyser_SetCalibrationDB(meterCalibrationDB)

        timer = Timer.scheduledTimer(withTimeInterval: 0.067, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.updateAllChannels()
            }
        }

        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.uiMeteringResult = self.latestFirstResult
            }
        }
    }

    // MARK: - Multi-Device Peak Monitoring

    /// Start peak metering for a device (adds to active sessions)
    func startPeakMonitoring(device: AudioDeviceModel) {
        // Check if already monitoring this device
        if activeSessions.values.contains(where: { $0.device.deviceID == device.deviceID }) {
            return
        }

        // Get channel count for this device
        let count = AudioDevices_GetInputChannelCount(device.deviceID)
        let channelCount = max(count, 1)

        // Create session
        var session = DeviceMonitoringSession(device: device, channelCount: channelCount)

        // Start audio engine for this device using multi-instance mode
        if !device.startPeakMonitoring(bufferSize: bufferSizeFrames, channels: channelCount) {
            errorMessage = "Failed to start peak monitoring for \(device.name)."
            return
        }

        // Setup metering timer for this session
        let sessionID = session.id
        session.timer = Timer.scheduledTimer(withTimeInterval: 0.067, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.updatePeakSession(sessionID: sessionID)
            }
        }

        // Add to active sessions
        activeSessions[session.id] = session
    }

    /// Stop peak metering for a device
    func stopPeakMonitoring(deviceID: UInt32) {
        guard let sessionEntry = activeSessions.first(where: { $0.value.device.deviceID == deviceID }) else {
            return
        }

        let session = sessionEntry.value
        session.timer?.invalidate()
        session.uiTimer?.invalidate()
        session.device.stopPeakMonitoring()

        activeSessions.removeValue(forKey: sessionEntry.key)
    }

    /// Update peak levels for a specific session
    private func updatePeakSession(sessionID: UUID) {
        guard var session = activeSessions[sessionID] else { return }

        // Get the ring buffer for this specific device instance
        guard let rbPtr = session.device.getRingBuffer() else { return }

        var newResults = session.channelMetering

        for ch in 0..<Int(session.channelCount) {
            var result = MeteringResult(peak: 0, rms: 0)
            let status = MeteringDSP_Compute(rbPtr, UInt32(ch), Int(meteringFrames), &result)
            if status == 0 {
                newResults[ch] = result
            }
        }

        // Update session
        session.channelMetering = newResults
        if let first = newResults.first {
            session.latestFirstResult = first
        }

        // Write back to dictionary
        activeSessions[sessionID] = session
    }

    /// Toggle peak monitoring for a device
    func togglePeakMonitoring(device: AudioDeviceModel) {
        if activeSessions.values.contains(where: { $0.device.deviceID == device.deviceID }) {
            stopPeakMonitoring(deviceID: device.deviceID)
        } else {
            startPeakMonitoring(device: device)
        }
    }

    /// Check if a device is currently being peak-monitored
    func isPeakMonitoring(deviceID: UInt32) -> Bool {
        activeSessions.values.contains(where: { $0.device.deviceID == deviceID })
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil

        uiTimer?.invalidate()
        uiTimer = nil

        if !usingExternalSource {
            selectedDevice?.stopMonitoring()
        }

        // Reset calibration to 0 dB when stopping
        MeteringDSP_SetCalibrationDB(0.0)
        FFTAnalyser_SetCalibrationDB(0.0)

        selectedDevice = nil
        selectedSourceName = nil
        selectedSourceSampleRate = 0.0
        selectedSourceManufacturer = ""
        selectedSourceConnection = ""
        selectedSourceThemeColor = .green
        externalRingBuffer = nil
        usingExternalSource = false
        channelMetering.removeAll()

        // Reset published + cached results so UI labels go quiet
        meteringResult = MeteringResult(peak: 0.0, rms: 0.0)
        uiMeteringResult = MeteringResult(peak: 0.0, rms: 0.0)
        latestFirstResult = MeteringResult(peak: 0.0, rms: 0.0)

        // Clean up peak hold tracking data to prevent memory accumulation
        MetalMeterView.clearPeakHoldData()
    }

    func updateAllChannels() {
        guard let rbPtr = currentRingBuffer() else { return }

        var newResults = channelMetering
        if newResults.count < Int(channelCount) {
            newResults = Array(
                repeating: MeteringResult(peak: 0, rms: 0),
                count: Int(channelCount)
            )
        }

        for ch in 0..<Int(channelCount) {
            var result = MeteringResult(peak: 0, rms: 0)
            let status = MeteringDSP_Compute(rbPtr, UInt32(ch), Int(meteringFrames), &result)
            if status == 0 {
                newResults[ch] = result
            }
        }

        // Only publish if there is a meaningful change to reduce SwiftUI invalidations.
        // IMPORTANT: Always publish quickly on rising peaks so the meters feel snappy.
        // Use a more lenient epsilon to ensure smooth updates while still reducing churn.
        let epsilon: Float = 0.0001  // Reduced from 0.0005 for smoother updates

        var changed = false
        if newResults.count != channelMetering.count {
            changed = true
        } else {
            for i in 0..<newResults.count {
                let a = newResults[i]
                let b = channelMetering[i]

                // Rising peaks should update immediately (captures transients without needing high UI FPS).
                if a.peak > b.peak + epsilon {
                    changed = true
                    break
                }

                // For falling values, use the epsilon threshold
                if abs(a.peak - b.peak) > epsilon || abs(a.rms - b.rms) > epsilon {
                    changed = true
                    break
                }
            }
        }

        if changed {
            channelMetering = newResults
            if let first = newResults.first {
                // Keep a fast-updating result available for meters/graphs,
                // and also cache it for the slower UI text snapshot timer.
                meteringResult = first
                latestFirstResult = first
            }
        }
    }

    func refreshDevices() {
        let maxDevices: UInt32 = 32
        var ids = [UInt32](repeating: 0, count: Int(maxDevices))

        let count = AudioDevices_GetAllInputDevices(&ids, maxDevices)

        var newDevices: [AudioDeviceModel] = []

        for i in 0..<Int(count) {
            var nameBuffer = [CChar](repeating: 0, count: 256)
            if AudioDevices_GetDeviceName(ids[i], &nameBuffer, 256) == noErr {
                let name = String(cString: nameBuffer)
                newDevices.append(AudioDeviceModel(deviceID: ids[i],
                                                   name: name,
                                                   themeColor: .green))
            }
        }

        devices = newDevices
    }

    func applyBufferSizeChange() {
        guard let device = selectedDevice else { return }
        stopMonitoring()
        startMonitoring(device: device)
    }

    func applyCalibration() {
        // Apply calibration to both metering and FFT for consistency
        MeteringDSP_SetCalibrationDB(meterCalibrationDB)
        FFTAnalyser_SetCalibrationDB(meterCalibrationDB)
    }

    func applySpectrumSettings() {
        FFTAnalyser_SetSelectedChannel(selectedSpectrumChannel)
        FFTAnalyser_SetFrequencyRange(spectrumMinFreqHz, spectrumMaxFreqHz)
        FFTAnalyser_SetCalibrationDB(meterCalibrationDB)
    }

    func currentRingBuffer() -> OpaquePointer? {
        if usingExternalSource {
            return externalRingBuffer
        }
        if selectedDevice != nil {
            return AudioEngine_GetRingBuffer()
        }
        return nil
    }

    var displaySampleRate: Double {
        if let device = selectedDevice {
            return device.sampleRate
        }
        return selectedSourceSampleRate
    }

    var displayName: String {
        if let device = selectedDevice {
            return device.name
        }
        if let selectedSourceName, !selectedSourceName.isEmpty {
            return selectedSourceName
        }
        return "Unknown Source"
    }

    var displayManufacturer: String {
        if let device = selectedDevice {
            return device.manufacturer
        }
        return selectedSourceManufacturer
    }

    var displayConnection: String {
        if let device = selectedDevice {
            return device.transportType.rawValue
        }
        return selectedSourceConnection
    }

    var displayThemeColor: Color {
        if let device = selectedDevice {
            return device.themeColor
        }
        return selectedSourceThemeColor
    }

    var displaySpectrumThemeColor: Color {
        if let device = selectedDevice {
            return device.themeColor
        }
        return selectedSourceSpectrumThemeColor
    }

    var displayWaveformThemeColor: Color {
        if let device = selectedDevice {
            return device.themeColor
        }
        return selectedSourceWaveformThemeColor
    }
}
