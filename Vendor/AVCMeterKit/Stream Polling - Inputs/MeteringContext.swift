//
//  MeteringContext.swift
//  AVCMeter
//
//  Created by Chris Izatt on 11/06/2025.
//

import Foundation
import CoreAudio

/// Represents the metering context for a specific audio device, managing RMS and peak buffers and level handling.
///
/// This class handles the buffering of audio level data for a given device and provides a handler callback for level updates.
internal class DeviceMeteringContext {
    /// The audio device associated with this metering context.
    let device: AudioDevice

    /// Ring buffer storing RMS (root mean square) audio level values for multiple channels.
    let rmsBuffer: MultiChannelRingBuffer

    /// Ring buffer storing peak audio level values for multiple channels.
    let peakBuffer: MultiChannelRingBuffer

    /// Handler responsible for processing level updates from the device.
    var handler: LevelHandler

    /// Indicates whether the metering context is currently active.
    var isActive: Bool = false

    /// Pointer to a shared buffer used for interprocess communication or shared memory.
    var sharedBufferPointer: UnsafeMutableRawPointer?

    /// Retained C callback context pointer for balanced release.
    var levelHandlerContext: UnsafeMutableRawPointer?

    /// Retained callback cache pointer for balanced release on cleanup.
    var callbackCacheContext: UnsafeMutableRawPointer?

    /// Initializes a new `DeviceMeteringContext` for a given audio device and level handler.
    ///
    /// - Parameters:
    ///   - device: The `AudioDevice` instance to associate with this context.
    ///   - handler: The `LevelHandler` responsible for processing level updates.
    internal init(device: AudioDevice, handler: LevelHandler) {
        self.rmsBuffer = MultiChannelRingBuffer(
            channels: Int(device.inputChannels),
            capacity: 128,
            ownerDeviceID: device.deviceID
        )
        self.peakBuffer = MultiChannelRingBuffer(
            channels: Int(device.inputChannels),
            capacity: 128,
            ownerDeviceID: device.deviceID
        )
        self.device = device
        self.handler = handler
    }
}

/// Handles audio level updates and communicates with the `AudioDeviceManager`.
///
/// This class acts as a delegate or callback handler for audio level changes.
internal class LevelHandler {
    /// Weak reference to the audio device manager to avoid retain cycles.
    weak var manager: AudioDeviceManager?
}

/// A shared instance of `LevelHandler` used internally.
private let sharedLevelHandler = LevelHandler()

/// Pre-cached raw C ring buffer pointers for the audio callback.
/// This allows SwiftMeterCallback to write directly to C ring buffers
/// without any Swift ARC operations, dictionary lookups, or weak-ref loads.
internal final class MeterCallbackCache {
    let peakBuffers: UnsafeMutablePointer<UnsafeMutablePointer<RingBuffer>?>
    let rmsBuffers: UnsafeMutablePointer<UnsafeMutablePointer<RingBuffer>?>
    let channelCount: Int

    init(channelCount: Int) {
        self.channelCount = channelCount
        peakBuffers = .allocate(capacity: channelCount)
        rmsBuffers = .allocate(capacity: channelCount)
        peakBuffers.initialize(repeating: nil, count: channelCount)
        rmsBuffers.initialize(repeating: nil, count: channelCount)
    }

    deinit {
        peakBuffers.deinitialize(count: channelCount)
        peakBuffers.deallocate()
        rmsBuffers.deinitialize(count: channelCount)
        rmsBuffers.deallocate()
    }
}

/// Converts a linear audio level value (range 0 to 1) to decibels (dB).
///
/// - Parameter value: A linear audio level value, typically between 0 and 1.
/// - Returns: The corresponding decibel value, with a minimum clamp to -120 dB for very low values.
internal func linearToDb(_ value: Float) -> Float {
    return 20 * log10f(max(value, 0.000_001))
}

/// Normalizes a decibel value to a 0 to 1 range based on a specified floor.
///
/// - Parameters:
///   - db: The decibel value to normalize.
///   - floor: The minimum decibel threshold to consider (default is -60 dB).
/// - Returns: A normalized value between 0 and 1, where values below the floor return 0.
internal func dbToNormalized(_ db: Float, floor: Float = -60.0) -> Float {
    guard db > floor else { return 0 }
    return min(1.0, (db - floor) / abs(floor))
}

/// Extension providing utility functions for arrays of `Float` values.
internal extension Array where Element == Float {
    /// Calculates the average of the float values in the array.
    ///
    /// - Returns: The average of the array elements, or -100.0 if the array is empty.
    func average() -> Float {
        guard !self.isEmpty else { return -100.0 }
        let sum = self.reduce(0, +)
        return sum / Float(self.count)
    }
}

/// C-compatible function to fetch recent input samples from Swift metering context.
///
/// - Parameters:
///   - channel: The channel index to read samples from.
///   - outputBuffer: A pointer to the C float buffer to write samples into.
///   - maxCount: The maximum number of samples to write.
///
/// This bridges Swift-managed metering buffers with C consumers, such as the audio routing matrix.


extension AudioDeviceManager {
    /// Returns the first DeviceMeteringContext that contains the given global input channel index.
    func contextForChannel(channel: Int) -> DeviceMeteringContext? {
        for context in activeDevices.values {
            if channel < context.device.inputChannels {
                return context
            }
        }
        return nil
    }
}

@_cdecl("SwiftMeteringContextBridge_getSharedBufferPointer")
public func SwiftMeteringContextBridge_getSharedBufferPointer(_ channel: Int32) -> UnsafeMutableRawPointer? {
    // WARNING: The returned pointer may only be valid for the lifetime of the DeviceMeteringContext.
    // Caller MUST NOT access more samples than SwiftMeteringContextBridge_getSharedBufferSampleCount(channel) returns.
    guard let context = AudioDeviceManager.shared.contextForChannel(channel: Int(channel)) else {
        return nil
    }
    return context.sharedBufferPointer
}

@_cdecl("SwiftMeteringContextBridge_getSharedBufferSampleCount")
public func SwiftMeteringContextBridge_getSharedBufferSampleCount(_ channel: Int32) -> Int32 {
    guard let context = AudioDeviceManager.shared.contextForChannel(channel: Int(channel)) else {
        return 0
    }
    // Return the actual count of available samples for this channel.
    // Here, I'm assuming you want channel 0 of the device, but change as needed!
    return Int32(context.rmsBuffer.buffers[0].count())
}
