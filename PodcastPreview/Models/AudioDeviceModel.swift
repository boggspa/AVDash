//
//  AudioDeviceModel.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 07/12/2025.
//

import Foundation
import Combine
import CoreAudio
import SwiftUI

/// Represents an audio device and provides methods to interact with C AudioEngine
final class AudioDeviceModel: ObservableObject, Identifiable {
    @Published var deviceID: UInt32
    @Published var name: String
    @Published var isSelected: Bool
    @Published var sampleRate: Double
    @Published var manufacturer: String
    @Published var transportType: DeviceTransportType
    @Published var themeColor: Color
    let id = UUID()
    
    // Channel counts
    var channelCount: UInt32 = 0
    var outputChannels: UInt32 = 0
    
    // Multi-instance engine support
    private var engineHandle: OpaquePointer? = nil
    private var usesMultiInstance: Bool = false

    // Add more properties (inputChannels, etc.) as needed

    init(deviceID: UInt32,
         name: String,
         isSelected: Bool = false,
         sampleRate: Double = 0.0,
         manufacturer: String = "",
         transportType: DeviceTransportType = .unknown,
         themeColor: Color = .green) {
        self.deviceID = deviceID
        self.name = name
        self.isSelected = isSelected
        self.sampleRate = sampleRate
        self.manufacturer = manufacturer
        self.transportType = transportType
        self.themeColor = themeColor
        
        // Query channel counts
        self.channelCount = AudioDevices_GetInputChannelCount(deviceID)
        self.outputChannels = AudioDevices_GetOutputChannelCount(deviceID)
    }

    // MARK: - Legacy Single-Instance Mode (for FFT/Spectrum)
    
    /// Start monitoring using the legacy global engine (for FFT/spectrum analysis)
    func startMonitoring(bufferSize: UInt32, channels: UInt32) -> Bool {
        // If we already have a multi-instance handle, stop it first
        if let handle = engineHandle {
            AudioEngine_Destroy(handle)
            engineHandle = nil
        }
        
        usesMultiInstance = false
        let result = AudioEngine_Start(deviceID, bufferSize, channels, channels)
        return result == 0
    }
    
    /// Stop monitoring (legacy mode)
    func stopMonitoring() {
        if usesMultiInstance, let handle = engineHandle {
            AudioEngine_StopInstance(handle)
            AudioEngine_Destroy(handle)
            engineHandle = nil
        } else {
            AudioEngine_Stop()
        }
    }
    
    /// Check running state (legacy mode)
    var isMonitoring: Bool {
        if usesMultiInstance, let handle = engineHandle {
            return AudioEngine_IsInstanceRunning(handle)
        } else {
            return AudioEngine_IsRunning()
        }
    }
    
    // MARK: - Multi-Instance Mode (for peak metering only)
    
    /// Start peak monitoring using a dedicated engine instance
    func startPeakMonitoring(bufferSize: UInt32, channels: UInt32) -> Bool {
        // Stop any existing monitoring
        if let handle = engineHandle {
            AudioEngine_Destroy(handle)
        }
        
        // Create new instance
        guard let handle = AudioEngine_Create(deviceID, bufferSize, channels, 0) else {
            return false
        }
        
        let result = AudioEngine_StartInstance(handle)
        if result == 0 {
            engineHandle = handle
            usesMultiInstance = true
            return true
        } else {
            AudioEngine_Destroy(handle)
            return false
        }
    }
    
    /// Stop peak monitoring
    func stopPeakMonitoring() {
        guard let handle = engineHandle else { return }
        AudioEngine_StopInstance(handle)
        AudioEngine_Destroy(handle)
        engineHandle = nil
        usesMultiInstance = false
    }
    
    /// Get ring buffer for this instance
    func getRingBuffer() -> OpaquePointer? {
        if usesMultiInstance, let handle = engineHandle {
            return AudioEngine_GetInstanceRingBuffer(handle)
        } else {
            return AudioEngine_GetRingBuffer()
        }
    }

    // You can add device discovery, selection, and more as needed
}

enum DeviceTransportType: String {
    case builtIn = "Built-in"
    case usb = "USB"
    case fireWire = "FireWire"
    case network = "Network"
    case aggregate = "Aggregate"
    case virtual = "Audio Server Plugin"
    case unknown = "Unknown"

    init(rawTransportValue: UInt32) {
        switch rawTransportValue {
        case 1: self = .builtIn
        case 2: self = .usb
        case 3: self = .fireWire
        case 4: self = .network
        case 5: self = .aggregate
        case 6: self = .virtual
        default: self = .unknown
        }
    }
}
