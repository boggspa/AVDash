//
//  MultiDeviceStreamManager.swift
//  AVCMeter
//
//  Created by Chris Izatt on 18/06/2025.
//

import Foundation
import CoreAudio

@_silgen_name("Mixer_RegisterDevice")
func Mixer_RegisterDevice(_ deviceID: UInt32, _ type: UInt32, _ numChannels: UInt32) -> Int32

@_silgen_name("Mixer_AttachInputRingBuffer")
func Mixer_AttachInputRingBuffer(_ deviceID: UInt32, _ type: UInt32, _ deviceChannelIndex: UInt32, _ ringBuffer: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("Mixer_Init")
func Mixer_Init(_ sampleRate: UInt32, _ bufferFrames: UInt32) -> Int32

@_silgen_name("Mixer_Shutdown")
func Mixer_Shutdown()

@_silgen_name("Mixer_StartProcessingThread")
func Mixer_StartProcessingThread() -> Int32

@_silgen_name("Mixer_StopProcessingThread")
func Mixer_StopProcessingThread()

@_silgen_name("Mixer_IsProcessingThreadRunning")
func Mixer_IsProcessingThreadRunning() -> Int32


/// Manages audio streams across multiple audio devices, providing control over starting, stopping,
/// and updating streams and their channel masks.
///
/// This singleton class maintains active pollers for each audio device and caches channel masks
/// to optimize stream handling.
class MultiDeviceStreamManager: ObservableObject {



    /// MARK: - C Notification / Callback Integration

    /// This method is intended to be called from C code (via bridging or NotificationCenter)
    /// when the low-level PCM engine detects a new audio device.
    ///
    /// It updates the shared AudioDeviceManager's inputDevices list and immediately attempts
    /// to start a stream for the new device, ensuring the Swift device list stays in sync
    /// with the C engine's device state.
    ///
    /// - Parameter deviceID: The unique identifier of the newly detected audio device.
    ///
    /// Usage from C:
    /// - Post a Notification named "PCMEngineDidDetectNewDevice" with userInfo containing
    ///   the deviceID as `NSNumber` under key "deviceID".
    /// - Or call this method directly via bridging if exposed.
    ///
    /// Example NotificationCenter observer setup:
    /// ```swift
    /// NotificationCenter.default.addObserver(forName: Notification.Name("PCMEngineDidDetectNewDevice"), object: nil, queue: .main) { notification in
    ///     if let deviceIDNumber = notification.userInfo?["deviceID"] as? NSNumber {
    ///         let deviceID = AudioDeviceID(deviceIDNumber.uint32Value)
    ///         Task {
    ///             // Update AudioDeviceManager's inputDevices here as appropriate before starting stream
    ///             // For example, refresh devices list from the PCM engine or other source
    ///
    ///             // Start stream for the new device
    ///             await MultiDeviceStreamManager.shared.startStream(for: deviceID)
    ///         }
    ///     }
    /// }
    /// ```
    @MainActor
    func notifyNewDeviceDetected(deviceID: AudioDeviceID) async {
        // Update AudioDeviceManager's inputDevices list here as appropriate to reflect new device.
        // This could mean refreshing from the PCM engine or app logic.
        // For example:
        // AudioDeviceManager.shared.refreshDevicesFromPCMEngine()
        //
        // Since that code is context-dependent, it should be implemented where you manage device enumeration.

        // Start streaming for the newly detected device
        await startStream(for: deviceID)
        await autoSyncActivatedDevicesWithMixer()
    }

    /// The shared singleton instance of the `MultiDeviceStreamManager`.
    static let shared = MultiDeviceStreamManager()

    /// A dictionary mapping audio device IDs to their corresponding active `DevicePoller` instances.
    /// This property is published to allow observers to react to changes in active pollers.
    @Published var activePollers: [AudioDeviceID: DevicePoller] = [:]

    /// A cache of channel masks for each audio device, mapping device IDs to arrays of booleans
    /// representing active channels. This property is published for observation.
    @Published var channelMaskCache: [AudioDeviceID: [Bool]] = [:]

    /// Mapping from deviceID to array of device channel indices for each enabled mixer channel.
    /// This guarantees a one-to-one device-to-mixer channel mapping that mirrors the UI mask logic.
    @Published var mixerChannelMap: [AudioDeviceID: [Int]] = [:]

    private let mixerBufferFrames: UInt32 = 128

    private let maxStartStreamRetries = 10

    let MIXER_CHANNEL_INPUT: UInt32 = 0

    @MainActor
    func ensureMixerReadyForStream(sampleRate: Float64) -> Bool {
        let sanitizedSampleRate = UInt32(max(1.0, sampleRate.rounded()))
        let initResult = Mixer_Init(sanitizedSampleRate, mixerBufferFrames)
        guard initResult == 0 else {
            print("Failed to initialize mixer: error code \(initResult)")
            return false
        }

        if Mixer_IsProcessingThreadRunning() != 0 {
            return true
        }

        let startResult = Mixer_StartProcessingThread()
        guard startResult == 0 else {
            print("Failed to start mixer processing thread: error code \(startResult)")
            Mixer_Shutdown()
            return false
        }

        return true
    }

    @MainActor
    func shutdownMixerIfIdle(hasActiveOutputs: Bool) {
        guard activePollers.isEmpty,
              AudioDeviceManager.shared.activeDevices.isEmpty,
              !hasActiveOutputs else {
            return
        }

        Mixer_StopProcessingThread()
        Mixer_Shutdown()
    }

    @MainActor
    func syncMeteredInputDevicesWithMixer() async {
        let meteredDevices = AudioDeviceManager.shared.activeDevices.values.map(\.device)

        for device in meteredDevices {
            if activePollers[device.deviceID] == nil {
                await startStream(for: device.deviceID)
            } else {
                let mask = channelMaskCache[device.deviceID]
                    ?? AudioDeviceManager.shared.selectedChannelMasks[device.deviceID]
                    ?? Array(repeating: true, count: Int(device.inputChannels))
                await updateChannelMask(for: device.deviceID, mask: mask)
            }
        }
    }

    /// Starts an audio stream for the specified device if it is not already active.
    ///
    /// This method creates a new `DevicePoller` for the device, updates its channel mask if available,
    /// and begins polling the device's audio stream.
    ///
    /// If the device is not found in the input devices list, this method will retry starting the stream
    /// with a short delay up to a maximum retry count before aborting.
    ///
    /// - Parameters:
    ///   - deviceID: The unique identifier of the audio device for which to start the stream.
    ///   - retryCount: The current retry attempt count, default is 0.
    @MainActor
    func startStream(for deviceID: AudioDeviceID, retryCount: Int = 0) async {
        guard activePollers[deviceID] == nil else { return }

        // Reminder: Ensure device enumeration is complete before calling this method
        // to avoid missing devices or incorrect channel counts.

        // Check if device is present in inputDevices; if not, schedule a retry with delay
        guard let device = AudioDeviceManager.shared.inputDevices.first(where: { $0.deviceID == deviceID }) else {
            if retryCount < maxStartStreamRetries {
                // Delay before retrying to allow device enumeration to complete
                Task.detached {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    await self.startStream(for: deviceID, retryCount: retryCount + 1)
                }
            } else {
            }
            return
        }
        let poller = DevicePoller(deviceID: deviceID)

        // Await channel mask and update poller BEFORE registration/context
        let mask: [Bool]
        if let existingMask = await getChannelMask(for: deviceID), !existingMask.isEmpty {
            mask = existingMask
        } else {
            // If no existing mask, assign default and cache it if inputChannels > 0
            if device.inputChannels > 0 {
                let defaultMask = Array(repeating: true, count: Int(device.inputChannels))
                channelMaskCache[deviceID] = defaultMask
                mask = defaultMask
            } else {
                mask = []
            }
        }
        poller.updateChannelMask(mask)

        // Build the active channel indices array from mask (like allVisibleStrips in UI)
        let activeChannelIndices = mask.enumerated().compactMap { $0.element ? $0.offset : nil }
        self.mixerChannelMap[deviceID] = activeChannelIndices

        // Register the context for routing matrix visibility BEFORE registration
        let context = AudioDeviceContext(device: device, stream: nil, poller: poller)
        AudioDeviceManager.shared.activeContexts[deviceID] = context

        activePollers[deviceID] = poller
        poller.start()

        // Register device with mixer. Input PCM is fed from the HAL callback,
        // so the legacy shared-ring-buffer attachment is optional now.
        guard let poller = activePollers[deviceID] else { return }
        guard ensureMixerReadyForStream(sampleRate: device.sampleRate) else { return }

        let numChannels = UInt32(device.inputChannels)
        let registrationResult = Mixer_RegisterDevice(deviceID, MIXER_CHANNEL_INPUT, numChannels)
        if registrationResult != 0 {
            print("Failed to register device \(deviceID) with mixer: error code \(registrationResult)")
            return
        }
        print("Registered device \(deviceID) with mixer (\(numChannels) channels)")

        if let ringBufferPointer = poller.ringBuffer {
            for deviceChannelIndex in activeChannelIndices {
                let attachResult = Mixer_AttachInputRingBuffer(deviceID, MIXER_CHANNEL_INPUT, UInt32(deviceChannelIndex), ringBufferPointer)
                if attachResult != 0 {
                    print("Failed to attach ring buffer for device \(deviceID) channel \(deviceChannelIndex): error code \(attachResult)")
                } else {
                    print("Attached ring buffer for device \(deviceID) channel \(deviceChannelIndex)")
                }
            }
        } else {
            print("No shared input ring buffer available for device \(deviceID); mixer feed will come directly from HAL input callbacks.")
        }
    }

    /// Stops the audio stream for the specified device if it is currently active.
    ///
    /// This method stops the associated `DevicePoller` and removes it from the active pollers dictionary.
    /// If there are no more active pollers after removal, the dedicated mixer processing thread is stopped.
    ///
    /// - Parameter deviceID: The unique identifier of the audio device for which to stop the stream.
    @MainActor
    func stopStream(for deviceID: AudioDeviceID) {
        guard let poller = activePollers[deviceID] else { return }
        poller.stop()
        activePollers.removeValue(forKey: deviceID)
        mixerChannelMap.removeValue(forKey: deviceID)
        shutdownMixerIfIdle(hasActiveOutputs: !OutputDeviceManager.shared.activeOutputDevices.isEmpty)
    }

    /// Updates the channel mask for the specified audio device.
    ///
    /// This method updates the channel mask on the active `DevicePoller` and caches the mask.
    ///
    /// - Parameters:
    ///   - deviceID: The unique identifier of the audio device whose channel mask is being updated.
    ///   - mask: An array of booleans representing the active channels for the device.
    @MainActor
    func updateChannelMask(for deviceID: AudioDeviceID, mask: [Bool]) {
        activePollers[deviceID]?.updateChannelMask(mask)
        channelMaskCache[deviceID] = mask

        // Also update mixerChannelMap accordingly for consistency
        let activeChannelIndices = mask.enumerated().compactMap { $0.element ? $0.offset : nil }
        mixerChannelMap[deviceID] = activeChannelIndices

        // Device mixer registration now handled in DeviceStreamController
    }

    /// Retrieves the channel mask for the specified audio device asynchronously.
    ///
    /// This method is intended to be overridden or implemented to provide the actual channel mask
    /// retrieval logic for a given device.
    ///
    /// - Parameter deviceID: The unique identifier of the audio device for which to retrieve the channel mask.
    /// - Returns: An optional array of booleans representing the active channels, or `nil` if unavailable.
    func getChannelMask(for deviceID: AudioDeviceID) async -> [Bool]? {
        return channelMaskCache[deviceID]
    }

    /// Retrieves the `DevicePoller` instance for a given device ID, if available.
    /// - Parameter deviceID: The unique identifier of the audio device.
    /// - Returns: The `DevicePoller` for the specified device, or `nil` if not found.
    func getStream(for deviceID: AudioDeviceID) -> DevicePoller? {
        return activePollers[deviceID]
    }

    @MainActor
    func getActiveInputChannels() -> [AudioDeviceID: [Int]] {
        var result: [AudioDeviceID: [Int]] = [:]
        for (deviceID, poller) in activePollers {
            let channelCount = poller.channelMask.count
            let active = poller.channelMask.enumerated().compactMap { index, enabled in
                enabled ? index : nil
            }
            if !active.isEmpty {
                result[deviceID] = active
            }
        }
        return result
    }


    /// Synchronizes all available, activated, and metered input devices with the mixer engine.
    /// Ensures that for every device present in the current device list:
    /// - Streams are started and metering is enabled
    /// - The mixer is registered for all active channels
    /// - Channel masks are up-to-date
    /// Prunes any pollers for removed devices.
    @MainActor
    func autoSyncActivatedDevicesWithMixer() async {
        // 1. Refresh input devices
        AudioDeviceManager.shared.refreshDeviceList()
        try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms for update
        let inputDevices = AudioDeviceManager.shared.inputDevices
        // 2. Ensure every device is started and registered
        for device in inputDevices {
            if activePollers[device.deviceID] == nil {
                await startStream(for: device.deviceID)
            }
            // Ensure mask is set and matches inputChannels
            let mask = channelMaskCache[device.deviceID] ?? Array(repeating: true, count: Int(device.inputChannels))
            if mask.count != Int(device.inputChannels) {
                let fixedMask = Array(repeating: true, count: Int(device.inputChannels))
                channelMaskCache[device.deviceID] = fixedMask
                await updateChannelMask(for: device.deviceID, mask: fixedMask)
            } else {
                await updateChannelMask(for: device.deviceID, mask: mask)
            }
        }
        // 3. Prune pollers for devices no longer present
        let validIDs = Set(inputDevices.map { $0.deviceID })
        for pollerID in activePollers.keys where !validIDs.contains(pollerID) {
            stopStream(for: pollerID)
        }
    }

    /// Returns the post-fader input level for a particular device/channel, applying the fader value and mute state.
    ///
    /// This method queries the shared `ChannelStateManager` for the mute state and fader level
    /// for the specified device and channel, then applies these to the raw input level to produce
    /// the post-fader value suitable for mixing or display.
    ///
    /// - Parameters:
    ///   - deviceID: The audio device identifier.
    ///   - channel: The channel index within the device.
    ///   - rawLevel: The raw input level before fader and mute are applied.
    /// - Returns: The adjusted input level after applying mute and fader gain.
    func postFaderInputLevel(deviceID: AudioDeviceID, channel: Int, rawLevel: Float) -> Float {
        let isMuted = ChannelStateManager.shared.isMuted(deviceID: deviceID, channel: channel)
        let gain = isMuted ? 0.0 : ChannelStateManager.shared.fader(for: deviceID, channel: channel)
        return rawLevel * gain
    }
}
