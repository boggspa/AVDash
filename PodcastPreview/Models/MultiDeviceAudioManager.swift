//
//  MultiDeviceAudioManager.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 17/03/2026.
//
//  Manages simultaneous multi-device peak metering and exclusive spectrum mode
//

import Foundation
import SwiftUI
import Combine
import CoreAudio

/// Manages multiple audio devices for peak metering and exclusive spectrum analysis
@MainActor
final class MultiDeviceAudioManager: ObservableObject {
    @Published var availableDevices: [AudioDeviceModel] = []
    @Published var activeDevices: Set<UUID> = [] // Devices with active peak monitoring
    @Published var spectrumDevice: AudioDeviceModel? // Current device in spectrum mode (exclusive)
    @Published var errorMessage: String?

    // Metering state for each active device
    @Published var deviceMeteringStates: [UUID: DeviceMeteringState] = [:]

    // Spectrum state (uses existing MonitoringState for compatibility)
    @Published var spectrumMonitoringState: MonitoringState?

    // Settings
    @Published var bufferSizeFrames: UInt32 = 512

    private var meteringTimers: [UUID: Timer] = [:]
    private let meteringFrames: UInt32 = 256

    var isSpectrumMode: Bool {
        spectrumDevice != nil
    }

    init() {
        refreshDevices()
    }

    // MARK: - Device Discovery

    func refreshDevices() {
        var deviceIDs: [AudioDeviceID] = Array(repeating: 0, count: 64)
        let count = AudioDevices_GetAllInputDevices(&deviceIDs, 64)

        var discovered: [AudioDeviceModel] = []

        for i in 0..<Int(count) {
            let deviceID = deviceIDs[i]
            var nameBuffer: [CChar] = Array(repeating: 0, count: 256)

            guard AudioDevices_GetDeviceName(deviceID, &nameBuffer, 256) == noErr else {
                continue
            }

            let name = String(cString: nameBuffer)
            let sampleRate = AudioDevices_GetDeviceSampleRate(deviceID)
            let transportRaw = AudioDevices_GetDeviceTransportType(deviceID)
            let transportType = DeviceTransportType(rawTransportValue: transportRaw)

            var manufacturerBuffer: [CChar] = Array(repeating: 0, count: 256)
            let manufacturer: String
            if AudioDevices_GetDeviceManufacturer(deviceID, &manufacturerBuffer, 256) == noErr {
                manufacturer = String(cString: manufacturerBuffer)
            } else {
                manufacturer = ""
            }

            // Assign theme colors based on transport type
            let themeColor = colorForTransportType(transportType)

            let device = AudioDeviceModel(
                deviceID: deviceID,
                name: name,
                isSelected: false,
                sampleRate: sampleRate,
                manufacturer: manufacturer,
                transportType: transportType,
                themeColor: themeColor
            )

            // Preserve existing device state if re-discovering
            if let existing = availableDevices.first(where: { $0.deviceID == deviceID }) {
                device.themeColor = existing.themeColor
            }

            discovered.append(device)
        }

        availableDevices = discovered
    }

    private func colorForTransportType(_ type: DeviceTransportType) -> Color {
        switch type {
        case .builtIn:
            return Color(hue: 0.55, saturation: 0.7, brightness: 0.85) // Blue
        case .usb:
            return Color(hue: 0.3, saturation: 0.8, brightness: 0.85)  // Green
        case .fireWire:
            return Color(hue: 0.08, saturation: 0.85, brightness: 0.9) // Orange
        case .network:
            return Color(hue: 0.75, saturation: 0.75, brightness: 0.85) // Purple
        case .aggregate:
            return Color(hue: 0.15, saturation: 0.7, brightness: 0.9)  // Yellow
        case .virtual:
            return Color(hue: 0.95, saturation: 0.65, brightness: 0.85) // Pink
        case .unknown:
            return Color(hue: 0.0, saturation: 0.0, brightness: 0.7)   // Gray
        }
    }

    // MARK: - Multi-Device Peak Monitoring

    func togglePeakMonitoring(for device: AudioDeviceModel) {
        // Allow peak monitoring alongside spectrum mode
        // Spectrum mode uses its own device exclusively, but other devices can have peak meters

        if activeDevices.contains(device.id) {
            stopPeakMonitoring(for: device)
        } else {
            // Don't allow peak monitoring on the device that's in spectrum mode
            if spectrumDevice?.id == device.id {
                errorMessage = "This device is in spectrum mode"
                return
            }
            startPeakMonitoring(for: device)
        }
    }

    private func startPeakMonitoring(for device: AudioDeviceModel) {
        let channelCount = AudioDevices_GetInputChannelCount(device.deviceID)
        guard channelCount > 0 else {
            errorMessage = "Device has no input channels"
            return
        }

        // Start the device's peak monitoring engine
        let success = device.startPeakMonitoring(bufferSize: bufferSizeFrames, channels: channelCount)
        guard success else {
            errorMessage = "Failed to start monitoring on \(device.name)"
            return
        }

        // Create metering state
        let meteringState = DeviceMeteringState(
            device: device,
            channelCount: channelCount
        )
        deviceMeteringStates[device.id] = meteringState
        activeDevices.insert(device.id)

        // Start metering timer for this device
        startMeteringTimer(for: device.id)

        errorMessage = nil
    }

    func stopPeakMonitoring(for device: AudioDeviceModel) {
        device.stopPeakMonitoring()

        // Stop timer
        meteringTimers[device.id]?.invalidate()
        meteringTimers.removeValue(forKey: device.id)

        // Remove state
        deviceMeteringStates.removeValue(forKey: device.id)
        activeDevices.remove(device.id)
    }

    private func startMeteringTimer(for deviceID: UUID) {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.updateMetering(for: deviceID)
            }
        }
        meteringTimers[deviceID] = timer
    }

    private func updateMetering(for deviceID: UUID) {
        guard let state = deviceMeteringStates[deviceID],
              let ringBuffer = state.device.getRingBuffer() else {
            return
        }

        // Update each channel
        for channel in 0..<state.channelCount {
            var result = MeteringResult(peak: 0, rms: 0)
            let status = MeteringDSP_Compute(ringBuffer, UInt32(channel), Int(meteringFrames), &result)

            if status == 0 {
                state.channelMetering[Int(channel)] = result
            }
        }

        // Update first channel summary
        if let first = state.channelMetering.first {
            state.meteringResult = first
        }
    }

    // MARK: - Exclusive Spectrum Mode

    func startSpectrumMode(for device: AudioDeviceModel) {
        #if DEBUG
        print("Starting spectrum mode for device: \(device.name)")
        #endif

        // Stop peak monitoring on THIS device if it's active
        if activeDevices.contains(device.id) {
            stopPeakMonitoring(for: device)
        }

        // Stop any previous spectrum device
        if let previousSpectrum = spectrumDevice {
            #if DEBUG
            print("   Stopping previous spectrum device: \(previousSpectrum.name)")
            #endif
            stopSpectrumMode()
        }

        // Create a MonitoringState for this device
        let monitoringState = MonitoringState()
        monitoringState.startMonitoring(device: device)

        spectrumMonitoringState = monitoringState
        spectrumDevice = device
        device.isSelected = true

        #if DEBUG
        print("Success: Spectrum mode activated")
        print("   Spectrum state: \(spectrumMonitoringState != nil ? "created" : "nil")")
        print("   Spectrum device: \(spectrumDevice?.name ?? "nil")")
        #endif

        errorMessage = nil
    }

    func stopSpectrumMode() {
        spectrumMonitoringState?.stopMonitoring()
        spectrumMonitoringState = nil

        if let device = spectrumDevice {
            device.isSelected = false
        }
        spectrumDevice = nil
    }

    private func stopAllPeakMonitoring() {
        for deviceID in activeDevices {
            if let state = deviceMeteringStates[deviceID] {
                stopPeakMonitoring(for: state.device)
            }
        }
    }

    func stopAll() {
        stopAllPeakMonitoring()
        stopSpectrumMode()
    }

    // MARK: - Query Methods

    func isDeviceActive(_ device: AudioDeviceModel) -> Bool {
        if spectrumDevice?.id == device.id {
            return true
        }
        return activeDevices.contains(device.id)
    }

    func monitoringMode(for device: AudioDeviceModel) -> String {
        if spectrumDevice?.id == device.id {
            return "Spectrum"
        } else if activeDevices.contains(device.id) {
            return "Peak"
        } else {
            return "Inactive"
        }
    }
}

// MARK: - Device Metering State

@MainActor
final class DeviceMeteringState: ObservableObject {
    @Published var channelMetering: [MeteringResult]
    @Published var meteringResult: MeteringResult

    let device: AudioDeviceModel
    let channelCount: UInt32

    init(device: AudioDeviceModel, channelCount: UInt32) {
        self.device = device
        self.channelCount = channelCount
        self.channelMetering = Array(repeating: MeteringResult(peak: 0, rms: 0), count: Int(channelCount))
        self.meteringResult = MeteringResult(peak: 0, rms: 0)
    }
}
