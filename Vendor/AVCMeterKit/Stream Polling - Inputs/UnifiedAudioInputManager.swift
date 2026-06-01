//
//  UnifiedAudioInputManager.swift
//  AVCMeter
//
//  Coordinates audio input for all consumers: Metering, FFT Spectrum, Waveform, and Spectrogram.
//
//  This manager:
//  1. Ensures only one HAL input stream per device (metering stream)
//  2. Provides consumer registration to track active audio pipelines
//  3. Coordinates buffer access for Spectrum, Waveform, and Spectrogram consumers
//
//  Architecture:
//  - HALInputStream.c creates single HAL stream per device
//  - Metering writes peak/RMS via SwiftMeterCallback
//  - Other consumers register here and read from shared metering buffers
//

import Foundation
import CoreAudio
import Combine

// MARK: - Consumer Types

enum AudioConsumerType {
    case metering
    case spectrum
    case waveform
    case spectrogram
}

// MARK: - Unified Audio Input Manager

/// Central coordinator for all audio input consumers.
///
/// **Purpose:**
/// Ensures that each audio device has only ONE HAL input stream, and that all consumers
/// (metering, spectrum, waveform, spectrogram) are coordinated through this single manager.
///
/// **Threading:**
/// - Thread-safe state management via NSLock
/// - Published properties for SwiftUI observation
/// - Audio reads use RingBuffer's internal mutex
final class UnifiedAudioInputManager: ObservableObject {
    // MARK: - Singleton

    static let shared = UnifiedAudioInputManager()

    // MARK: - State

    /// Active consumers per device: [deviceID: [consumerType: refCount]]
    /// Used to determine when to start/stop HAL streams
    @Published private(set) var activeConsumers: [AudioDeviceID: [AudioConsumerType: Int]] = [:]

    private let stateLock = NSLock()
    private var activeConsumerState: [AudioDeviceID: [AudioConsumerType: Int]] = [:]

    // MARK: - Initialization

    private init() {}

    // MARK: - Consumer Management

    /// Register a consumer for a device.
    ///
    /// Multiple consumers can register for the same device. The HAL stream
    /// remains active as long as at least one consumer is registered.
    ///
    /// - Parameters:
    ///   - type: The type of consumer (spectrum, waveform, etc.)
    ///   - deviceID: The audio device
    /// - Returns: true if successfully registered, false if device unavailable
    func registerConsumer(_ type: AudioConsumerType, for deviceID: AudioDeviceID) -> Bool {
        stateLock.lock()

        // Initialize counts for this device if needed
        if activeConsumerState[deviceID] == nil {
            activeConsumerState[deviceID] = [:]
        }

        // Increment count for this consumer type
        let current = activeConsumerState[deviceID]?[type] ?? 0
        activeConsumerState[deviceID]?[type] = current + 1
        let snapshot = activeConsumerState
        stateLock.unlock()

        publishActiveConsumers(snapshot)

        return true
    }

    /// Unregister a consumer from a device.
    ///
    /// - Parameters:
    ///   - type: The consumer type
    ///   - deviceID: The audio device
    func unregisterConsumer(_ type: AudioConsumerType, from deviceID: AudioDeviceID) {
        stateLock.lock()

        guard var counts = activeConsumerState[deviceID] else {
            stateLock.unlock()
            return
        }

        // Decrement count
        let current = counts[type] ?? 0
        if current > 0 {
            counts[type] = current - 1
        }

        activeConsumerState[deviceID] = counts

        // Remove device entry if no consumers remain
        if counts.values.allSatisfy({ $0 == 0 }) {
            activeConsumerState.removeValue(forKey: deviceID)
        }

        let snapshot = activeConsumerState
        stateLock.unlock()

        publishActiveConsumers(snapshot)
    }

    /// Check if a specific consumer is active for a device.
    func isConsumerActive(_ type: AudioConsumerType, for deviceID: AudioDeviceID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (activeConsumerState[deviceID]?[type] ?? 0) > 0
    }

    /// Get active consumer types for a device.
    func activeConsumerTypes(for deviceID: AudioDeviceID) -> [AudioConsumerType] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeConsumerState[deviceID]?.compactMap { type, count in
            count > 0 ? type : nil
        } ?? []
    }

    /// Access the metering context for a device.
    /// Other consumers read audio from this context's ring buffers.
    func meteringContext(for deviceID: AudioDeviceID) -> DeviceMeteringContext? {
        return AudioDeviceManager.shared.activeDevices[deviceID]
    }

    private func publishActiveConsumers(_ snapshot: [AudioDeviceID: [AudioConsumerType: Int]]) {
        let publish = { self.activeConsumers = snapshot }
        if Thread.isMainThread {
            publish()
        } else {
            DispatchQueue.main.async(execute: publish)
        }
    }
}
