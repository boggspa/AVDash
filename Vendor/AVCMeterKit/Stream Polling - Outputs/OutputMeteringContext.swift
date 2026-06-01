//
//  OutputMeteringContext.swift
//  AVCMeter
//
//  Created by Chris Izatt on 07/07/2025.
//

import Foundation
import CoreAudio

final class OutputLevelHandler {
    let peakBuffer: MultiChannelOutputRingBuffer

    init(peakBuffer: MultiChannelOutputRingBuffer) {
        self.peakBuffer = peakBuffer
    }

    func callAsFunction(_ channelIndex: Int) -> Float {
        return peakBuffer.readMostRecent(fromChannel: channelIndex)
    }
    /// Returns the most recent peak level for a given channel.
    ///
    /// - Parameter channel: The index of the output channel.
    /// - Returns: The most recent peak level as a Float.
    func mostRecentPeak(for channel: Int) -> Float {
        return peakBuffer.readMostRecent(fromChannel: channel)
    }
}

/// Represents the metering context for a specific output audio device,
/// managing peak buffers and optional RMS buffers for visualization or analysis.
final class OutputMeteringContext {
    /// The output audio device associated with this metering context.
    let device: AudioDevice

    let handler: OutputLevelHandler
    var levelHandlerContext: UnsafeMutableRawPointer?

    /// Ring buffer storing RMS (root mean square) audio level values for output channels.
    let rmsBuffer: MultiChannelOutputRingBuffer

    /// Ring buffer storing peak audio level values for output channels.
    let peakBuffer: MultiChannelOutputRingBuffer

    /// Indicates whether the output metering context is currently active.
    var isActive: Bool = false

    /// Pointer to a shared buffer used for interprocess communication or shared memory.
    var sharedBufferPointer: UnsafeMutableRawPointer?

    /// Initializes a new `OutputMeteringContext` for a given output device.
    ///
    /// - Parameters:
    ///   - device: The `AudioDevice` instance to associate with this context.
    ///   - handler: The `OutputLevelHandler` instance to handle peak levels.
    ///   - peakBuffer: An optional pre-existing peak buffer to use instead of creating a new one.
    ///   - rmsBuffer: An optional pre-existing RMS buffer to use instead of creating a new one.
    init(device: AudioDevice, handler: OutputLevelHandler, peakBuffer: MultiChannelOutputRingBuffer? = nil, rmsBuffer: MultiChannelOutputRingBuffer? = nil) {
        self.device = device
        self.peakBuffer = peakBuffer ?? MultiChannelOutputRingBuffer(
            channels: Int(device.outputChannels),
            capacity: 128
        )
        self.rmsBuffer = rmsBuffer ?? MultiChannelOutputRingBuffer(
            channels: Int(device.outputChannels),
            capacity: 128
        )
        self.handler = handler
    }
}

extension OutputMeteringContext {
    /// Returns the global channel index for this device and channel.
    func globalChannelIndex(for channelIndex: Int) -> Int {
        (Int(device.deviceID) << 8) | channelIndex
    }
}
