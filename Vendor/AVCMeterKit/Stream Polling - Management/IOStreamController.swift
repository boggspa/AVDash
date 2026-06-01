///
/// IOStreamController.swift
///
/// Controller for toggling device audio streams in a safe, stateless way.
///
/// This should be imported wherever device metering needs to be managed (e.g. ContentView).
///

// IMPORTANT CONTRACT:
// The method `registerDeviceWithMixer(deviceID:channelMask:)` *must* be called before any calls to
// `startStream` or any mixer/ring buffer API operations for that device. This ensures the mixer engine
// is aware of the device and its active channels before streaming begins.

import Foundation
import CoreAudio
import SwiftUI



final class DeviceStreamController {
    /// Toggles the audio stream state for a given input device.
    /// Starts or stops metering and updates the selected device ID.
    /// Also ensures the device is registered with the global mixer engine.
    /// - Parameters:
    ///   - device: The `AudioDevice` to start/stop metering for.
    ///   - manager: The `AudioDeviceManager` controlling device states.
    ///   - streamManager: The stream manager handling audio polling.
    ///   - selectedDeviceID: A binding to the currently selected device.
    static func toggleDeviceStream(device: AudioDevice,
                                   manager: AudioDeviceManager,
                                   streamManager: MultiDeviceStreamManager,
                                   selectedDeviceID: Binding<AudioDeviceID>) {
        if streamManager.activePollers[device.deviceID] != nil {
            manager.endMetering(for: device)

            // Intentional crash point for debugging: poller failed to stop
            if streamManager.activePollers[device.deviceID] != nil {
                fatalError("[DeviceStreamController] Poller for deviceID=\(device.deviceID) failed to stop after endMetering")
            }

            Task { @MainActor in
                streamManager.stopStream(for: device.deviceID)
                // If routing window is open, refresh it
                if FloatingWindowController.shared.routingWindow != nil {
                    AudioRoutingMatrixManager.shared.refreshFromActiveDevices()
                }
            }
            selectedDeviceID.wrappedValue = 0
        } else {
            Task { @MainActor in
                await streamManager.startStream(for: device.deviceID)
                manager.beginMetering(device: device)

                // Intentional crash point for debugging: poller failed to start
                if streamManager.activePollers[device.deviceID] == nil {
                    fatalError("[DeviceStreamController] Poller for deviceID=\(device.deviceID) failed to start")
                }

                selectedDeviceID.wrappedValue = device.deviceID

                if let channelCount = manager.activeDevices[device.deviceID]?.device.inputChannels {
                    let globalInputs = (0..<device.inputChannels).map { channelIndex in
                        "Input \(channelIndex + 1) = Global Channel **\((Int(device.deviceID) << 8) | Int(channelIndex))**"
                    }
                    let message = "\(device.name) assigned with Global Channels:\n" + globalInputs.joined(separator: "\n")
                    GlobalChannelLogStore.shared.add(message)
                }

                if FloatingWindowController.shared.routingWindow != nil {
                    AudioRoutingMatrixManager.shared.refreshFromActiveDevices()
                }
            }
        }
    }

    /// Registers the device and its active channels with the global mixer engine.
    /// This *must* be called before any calls to `startStream` or any channelMask/ring-buffer operations for the device.
    /// - Parameters:
    ///   - deviceID: The AudioDeviceID to register.
    ///   - channelMask: The array of Bool representing which channels are active (true).
    static func registerDeviceWithMixer(deviceID: AudioDeviceID, channelMask: [Bool]) {
        let activeChannelIndices = channelMask.enumerated().compactMap { $0.element ? $0.offset : nil }
        if !activeChannelIndices.isEmpty {
            let activeChannelCount = UInt32(activeChannelIndices.count)
            print("[DeviceStreamController] Registering deviceID=\(deviceID) with activeChannelCount=\(activeChannelCount)")
           // let regResult = Mixer_RegisterDevice(UInt32(deviceID), MIXER_CHANNEL_INPUT, activeChannelCount)
           // print("[DeviceStreamController] Mixer_RegisterDevice returned \(regResult) for deviceID=\(deviceID)")

            // Intentional crash point for debugging: registration failure
          //  if regResult < 0 {
            //    fatalError("[DeviceStreamController] Mixer_RegisterDevice failed with result \(regResult) for deviceID=\(deviceID)")
          //  }
  //      } else {
    ///        print("[DeviceStreamController] Skipping registration for deviceID=\(deviceID) as mask is empty or fully masked out")
        }
    }
}

/// Controls starting and stopping of output device streams.
final class OutputStreamController {
    static func toggleOutputStream(for device: AudioDevice,
                                   manager: OutputDeviceManager,
                                   streamManager: MultiOutputStreamManager) {
        let isActive = manager.activeOutputDevices.contains(device.deviceID)

        if isActive {
            Task { @MainActor in
                manager.endOutput(for: device)
            }
        } else {
            Task {
                await manager.startOutputStream(for: device)

                // Handle output stream start failure gracefully
                if !manager.activeOutputDevices.contains(device.deviceID) {
                    print("[OutputStreamController] Output stream failed to start for deviceID=\(device.deviceID)")
                    return
                }

                // Removed call to streamManager.startStream because manager.startOutputStream handles context creation and poller start.

                let channelCount = Int(device.outputChannels)
                let newMask = Array(repeating: true, count: channelCount)
                await streamManager.updateChannelMask(for: device.deviceID, mask: newMask)

                // Add global output ID notification when stream starts
                let globalInputs = (0..<device.inputChannels).map { channelIndex in
                    "Input \(channelIndex + 1) = Global Channel **\((Int(device.deviceID) << 8) | Int(channelIndex))**"
                }
                let message = globalInputs.joined(separator: "\n")
                GlobalChannelLogStore.shared.add(message)
            }
        }
    }
}
