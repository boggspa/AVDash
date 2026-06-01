//
//  MultiOutputStreamManager.swift
//  AVCMeter
//
//  Created by Chris Izatt on 06/07/2025.
//

import Foundation
import CoreAudio
import AVFoundation
import SwiftUI
import Combine
import AudioToolbox
import CoreAudioKit



/// Manages output streams across multiple audio devices, allowing control over
/// starting, stopping, and updating channel masks per output-capable device.
///
/// Mirrors `MultiDeviceStreamManager` for symmetry and UI support of output metering.
class MultiOutputStreamManager: ObservableObject {
    /// Shared singleton instance of the `MultiOutputStreamManager`.
    static let shared = MultiOutputStreamManager()

    var outputResamplers: [AudioDeviceID: UnsafeMutableRawPointer?] = [:]

    // Removed: activePollers

    /// Active pollers associated with each output audio device.
    @Published var activeOutputPollers: [AudioDeviceID: OutputPoller] = [:]

    /// Cached channel masks for each output device, stored by device ID.
    @Published var channelMaskCache: [AudioDeviceID: [Bool]] = [:]

    /// Shared ring buffers for each output device and its channels
    @Published var sharedOutputRingBuffers: [AudioDeviceID: [Int: UnsafeMutableRawPointer?]] = [:]

    /// Returns the post-fader output level for a particular device/channel, applying the fader value and mute state.
    func postFaderOutputLevel(deviceID: AudioDeviceID, channel: Int, rawLevel: Float) -> Float {
        let isMuted = ChannelStateManager.shared.isOutputMuted(deviceID: deviceID, channel: channel)
        let gain = isMuted ? 0.0 : ChannelStateManager.shared.outputFader(for: deviceID, channel: channel)
        return rawLevel * gain
    }

    /// Starts an output stream for the given device if not already active.
    @MainActor
    func startStream(for deviceID: AudioDeviceID) {
        print("[MultiOutputStreamManager] startStream called for deviceID: \(deviceID)")

        var foundIDs = [AudioDeviceID](repeating: 0, count: 32)
        let found = getAllOutputAudioDeviceIDs(&foundIDs, 32)
        let validIDs = foundIDs.prefix(Int(found))
        guard validIDs.contains(deviceID) else {
            print("[MultiOutputStreamManager] Warning: Tried to start stream for deviceID \(deviceID), but it was not found in system output devices.")
            return
        }

        guard activeOutputPollers[deviceID] == nil else { return }

        guard let context = OutputDeviceManager.shared.outputContexts[deviceID] else {
            print("[MultiOutputStreamManager][Error] No OutputMeteringContext for deviceID: \(deviceID) in outputContexts. OutputPoller will NOT be started.")
            return
        }

        if !OutputDeviceManager.shared.activeOutputDevices.contains(deviceID) {
            OutputDeviceManager.shared.activeOutputDevices.insert(deviceID)
        }

        let poller = OutputPoller(deviceID: deviceID, context: context)
        if let mask = channelMaskCache[deviceID] {
            poller.updateChannelMask(mask)
        }

        activeOutputPollers[deviceID] = poller
        poller.start()
    }

    /// Stops the output stream for the given device if it is currently active.
    @MainActor
    func stopStream(for deviceID: AudioDeviceID) {
        guard let poller = activeOutputPollers.removeValue(forKey: deviceID) else { return }
        Task {
            await poller.stop()
        }
    }

    /// Updates the channel mask for a specific output device and applies it if active.
    @MainActor
    func updateChannelMask(for deviceID: AudioDeviceID, mask: [Bool]) {
        activeOutputPollers[deviceID]?.updateChannelMask(mask)
        channelMaskCache[deviceID] = mask
    }

    /// Asynchronously retrieves the current channel mask for an output device.
    func getChannelMask(for deviceID: AudioDeviceID) async -> [Bool]? {
        return channelMaskCache[deviceID]
    }

    /// Returns the `OutputPoller` instance for an output device, if it exists.
    func getStream(for deviceID: AudioDeviceID) -> OutputPoller? {
        return activeOutputPollers[deviceID]
    }

    /// Checks if a device is currently being polled/output metered.
    func isDeviceActive(_ deviceID: AudioDeviceID) -> Bool {
        return activeOutputPollers[deviceID] != nil
    }
    func getAllStreams() -> [OutputPoller] {
        return Array(activeOutputPollers.values)
    }

    /// Returns a dictionary mapping device IDs to lists of active output channel indices.
    /// Only channels marked as 'true' in the channel mask are included.
    func getActiveOutputChannels() -> [AudioDeviceID: [Int]] {
        var result: [AudioDeviceID: [Int]] = [:]
        for deviceID in activeOutputPollers.keys {
            let channelCount = Int(OutputDeviceManager.shared.outputContexts[deviceID]?.device.outputChannels ?? 0)
            let mask = channelMaskCache[deviceID] ?? Array(repeating: true, count: channelCount)
            let activeChannels = mask.enumerated().compactMap { index, enabled in
                enabled ? index : nil
            }
            if !activeChannels.isEmpty {
                result[deviceID] = activeChannels
            }
        }
        return result
    }
}
