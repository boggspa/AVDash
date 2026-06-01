/**
 OutputPoller.swift
 AVCMeter

Created by Chris Izatt on 07/07/2025.
**/

import Foundation
import CoreAudio

enum MixerChannelType: UInt32 {
    case input = 0
    case output = 1
}


@_silgen_name("Mixer_GetOutputChannelPeak")
func Mixer_GetOutputChannelPeak(_ deviceID: UInt32, _ deviceChannelIndex: UInt32) -> Float

@_silgen_name("Mixer_GetOutputChannelRMS")
func Mixer_GetOutputChannelRMS(_ deviceID: UInt32, _ deviceChannelIndex: UInt32) -> Float


/**
 Manages the polling and mixer output handling for a specific output audio device.

 The `OutputPoller` class is responsible for registering an output device with the mixer engine,
 setting up shared ring buffers for inter-process communication, and periodically polling audio
 levels and mixer output data. It writes metered audio levels to shared memory, enabling UI components
 to visualize real-time audio metering data.

 This class maintains an internal polling loop running asynchronously, which:
 - Ensures all output channels have associated shared ring buffers.
 - Starts the mixer engine for the device.
 - Routes mixer output channels to global output channels with gain routing.
 - Periodically reads peak meter levels from shared buffers.
 - Writes mixer output audio data to shared ring buffers.

 The polling loop runs until explicitly stopped, and channel masking allows selective polling
 and output of enabled channels only.

 Note: Clients of OutputPoller should also wait for readiness before assuming polling is active,
 as there is a readiness check performed internally before starting the polling loop.
 */
final class OutputPoller {
    /// The unique identifier for the output audio device being polled.
    private let deviceID: AudioDeviceID

    /// The metering context containing device info and peak buffer used for UI metering.
    let context: OutputMeteringContext

    /// A boolean mask array representing which output channels are active for polling and output.
    private var channelMask: [Bool]
    private let channelMaskLock = NSLock()

    /// Holds the polling task so it can be cancelled on stop/deinit
    private var pollingTask: Task<Void, Never>? = nil

    /**
     Initializes a new `OutputPoller` for a specified output device and metering context.

     - Parameters:
       - deviceID: The audio device identifier to monitor.
       - context: The metering context containing device details and peak buffer.

     All output channels are initially set to active (`true`) in the channel mask.
     */
    init(deviceID: AudioDeviceID, context: OutputMeteringContext) {
        self.deviceID = deviceID
        self.context = context
        self.channelMask = Array(repeating: true, count: Int(context.device.outputChannels))
    }


    /**
     Starts the asynchronous polling loop for the output device.

     This method performs the following:
     - Ensures the device is registered and set up.
     - Launches a detached asynchronous task that:
       - Periodically reads peak meter levels from shared buffers.
       - Writes mixer output audio data to shared ring buffers.
       - Honors the channel mask to selectively poll and write enabled channels.

     The polling loop continues until `stop()` is called.

     If registration has previously failed, this method logs a warning and returns immediately.
     */
    func start() {
        guard pollingTask == nil else {
            return
        }

        pollingTask = Task.detached { [weak self] in
            guard let self = self else { return }

            while !Task.isCancelled {
                let activeChannels = self.activeChannels

                for channel in activeChannels {
                    let peak = Mixer_GetOutputChannelPeak(self.deviceID, UInt32(channel))
                    let rms = Mixer_GetOutputChannelRMS(self.deviceID, UInt32(channel))

                    self.context.peakBuffer.write(peak, toChannel: channel)
                    self.context.rmsBuffer.write(rms, toChannel: channel)
                }

                try? await Task.sleep(nanoseconds: 16_000_000) // ~60Hz meter updates
            }

        }
    }

    /**
     Stops the polling loop, causing the asynchronous polling task to terminate gracefully.

     Also unregisters the device from the global mixer output channels.
     */
    func stop() async {
        pollingTask?.cancel()

        if let task = pollingTask {
            _ = await task.value
        }

        pollingTask = nil
    }

    /**
     Updates the output channel mask to selectively enable or disable polling and output per channel.

     - Parameter mask: An array of booleans indicating active (`true`) or inactive (`false`) channels.
     */
    func updateChannelMask(_ mask: [Bool]) {
        channelMaskLock.lock()
        channelMask = mask
        channelMaskLock.unlock()
    }

}

/**
 A thread-safe atomic boolean flag used to control the running state of background tasks.

 The `AtomicFlag` class provides synchronized methods to set, clear, and read a boolean flag,
 ensuring safe concurrent access from multiple threads.
 */
final class AtomicFlag {
    private let lock = NSLock()
    private var _flag: Bool = false

    /**
     Atomically sets the flag to `true`.
     */
    func setTrue() {
        lock.lock()
        _flag = true
        lock.unlock()
    }

    /**
     Atomically sets the flag to `false`.
     */
    func setFalse() {
        lock.lock()
        _flag = false
        lock.unlock()
    }

    /**
     Atomically retrieves the current value of the flag.

     - Returns: The current boolean value of the flag.
     */
    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _flag
    }
}

extension OutputPoller {
    /**
     Returns the list of currently enabled output channel indices based on the channel mask.

     - Returns: An array of integers representing active channel indices.
     */
    var activeChannels: [Int] {
        channelMaskLock.lock()
        let mask = channelMask
        channelMaskLock.unlock()
        return mask.enumerated().compactMap { $0.element ? $0.offset : nil }
    }
}
