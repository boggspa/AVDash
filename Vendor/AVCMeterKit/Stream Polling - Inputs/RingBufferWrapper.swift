///
///  RingBufferWrapper.swift
///  AVCMeter
///
///  Created by Chris Izatt on 11/06/2025.
///
///  This file provides Swift wrappers around a C-based ring buffer implementation.
///
///  It defines two main classes:
///  - `RingBufferWrapper`: Manages a single ring buffer for audio data.
///  - `MultiChannelRingBuffer`: Manages multiple `RingBufferWrapper` instances for multichannel audio.

import Foundation
import CoreAudio

@_silgen_name("maxRingBuffer")
func maxRingBuffer(_ buffer: UnsafeMutablePointer<RingBuffer>) -> Float

@_silgen_name("getRingBufferFillCount")
func getRingBufferFillCount(_ buffer: UnsafeMutablePointer<RingBuffer>) -> Int32

@_silgen_name("mostRecentRingBuffer")
func mostRecentRingBuffer(_ buffer: UnsafeMutablePointer<RingBuffer>) -> Float

/// MARK: - RingBufferWrapper

final class RingBufferWrapper {
    var buffer: UnsafeMutablePointer<RingBuffer>?
    /// The device identifier for ownership tagging.
    let ownerDeviceID: AudioDeviceID
    /// Temporary buffer used for reading all values from the ring buffer.
    private var tempReadBuffer = [Float](repeating: 0, count: 128)

    /// Reads all available values from the ring buffer into a temporary buffer.
    ///
    /// - Returns: A `[Float]` array containing the most recent values from the buffer.
    func readAll() -> [Float] {
        guard let buffer = buffer else { return [] }
        ringbuffer_read_all(buffer, &tempReadBuffer, 128)
        return tempReadBuffer
    }

    /// Returns all values currently in the ring buffer.
    ///
    /// - Returns: A `[Float]` array containing the current values in the buffer.
    var allValues: [Float] {
        return readAll()
    }

    /// Initializes the ring buffer with a specified capacity and owner device ID.
    ///
    /// - Parameters:
    ///   - capacity: The number of samples the buffer should store. Default is 128.
    ///   - ownerDeviceID: The device identifier for ownership tagging.
    init(capacity: Int = 128, ownerDeviceID: AudioDeviceID) {
        self.ownerDeviceID = ownerDeviceID
        self.buffer = createRingBuffer(Int32(capacity))
        if buffer == nil {
            assertionFailure("Failed to create RingBuffer")
        }
    }

    /// Cleans up and destroys the ring buffer when the wrapper is deallocated.
    ///
    /// Deinitializes the underlying C ring buffer to free resources.
    deinit {
        if let buffer = buffer {
            destroyRingBuffer(buffer)
        }
    }

    /// Writes a single float value into the ring buffer.
    ///
    /// - Parameter value: The `Float` value to write into the buffer.
    func write(_ value: Float) {
        guard let buffer = buffer else { return }
        writeRingBuffer(buffer, value)
    }

    /// Calculates and returns the average of the values currently in the ring buffer.
    ///
    /// - Returns: The average (`Float`) of all values currently stored in the buffer.
    @inline(__always)
    func average() -> Float {
        guard let buffer = buffer else { return 0.0 }
        return averageRingBuffer(buffer)
    }

    /// Clears all contents of the ring buffer.
    ///
    /// Removes all values from the buffer, resetting its state.
    func clear() {
        guard let buffer = buffer else { return }
        clearRingBuffer(buffer)
    }

    /// Returns the number of values currently stored in the ring buffer.
    ///
    /// - Returns: The number of values currently held in the buffer.
    @inline(__always)
    func count() -> Int {
        guard let buffer = buffer else { return 0 }
        return Int(getRingBufferFillCount(buffer))
    }

    /// Returns the most recently written value in the ring buffer.
    ///
    /// - Returns: The most recent `Float` value written to the buffer, or `0.0` if empty.
    @inline(__always)
    func mostRecent() -> Float {
        guard let buffer = buffer else { return 0.0 }
        return mostRecentRingBuffer(buffer)
    }
}

extension RingBufferWrapper: CustomStringConvertible {
    /// Provides a textual description of the ring buffer wrapper showing the average value.
    ///
    /// - Returns: A `String` describing the average value of the buffer.
    var description: String {
        "Average: \(average())"
    }
}

extension RingBufferWrapper {
    /// Returns the maximum value currently stored in the ring buffer.
    ///
    /// - Returns: The maximum `Float` value currently stored in the buffer, or `-100.0` if empty.
    @inline(__always)
    func max() -> Float {
        guard let buffer = buffer else { return -100.0 }
        return maxRingBuffer(buffer)
    }
}

/// MARK: - MultiChannelRingBuffer

final class MultiChannelRingBuffer {
    /// Shared singleton instance for global access, configured with 32 channels and device ID 0.
    static let shared = MultiChannelRingBuffer(channels: 128, ownerDeviceID: 0)
    /// The array of per-channel ring buffer wrappers.
    var buffers: [RingBufferWrapper]
    /// The cached average values for each channel, updated via `updateCache()`.
    private(set) var lastAverages: [Float] = []
    /// The cached maximum values for each channel, updated via `updateCache()`.
    private(set) var lastMaxima: [Float] = []
    /// Lock to ensure thread-safe cache updates.
    private let cacheLock = NSLock()

    /// Initializes a multi-channel ring buffer instance.
    ///
    /// - Parameters:
    ///   - channels: The total number of audio channels to allocate buffers for.
    ///   - capacity: The number of samples each buffer should store. Default is 128.
    ///   - ownerDeviceID: The device identifier for ownership tagging.
    init(channels: Int, capacity: Int = 128, ownerDeviceID: AudioDeviceID) {
        buffers = (0..<channels).map { _ in RingBufferWrapper(capacity: capacity, ownerDeviceID: ownerDeviceID) }
    }

    /// Writes an array of float values, distributing each value to its corresponding channel buffer.
    ///
    /// - Parameter values: An array of `Float` values, one per channel.
    func write(_ values: [Float]) {
        for (i, val) in values.enumerated() where i < buffers.count {
            buffers[i].write(val)
        }
    }

    /// Writes a value to the ring buffer corresponding to a global channel ID.
    ///
    /// - Parameters:
    ///   - globalChannelID: The global channel ID, typically formed by (deviceID << 8) | channelIndex.
    ///   - value: The Float value to write.
    func write(toGlobalChannelID globalChannelID: Int, value: Float) {
        guard globalChannelID >= 0 && globalChannelID < buffers.count else { return }
        buffers[globalChannelID].write(value)
    }

    /// Returns the average value for a specified channel.
    ///
    /// - Parameter channel: The channel index to query.
    /// - Returns: The average value for the specified channel, or `0.0` if the channel is invalid.
    func average(for channel: Int) -> Float {
        guard channel < buffers.count else { return 0.0 }
        return buffers[channel].average()
    }

    /// Returns the maximum value for a specified channel.
    ///
    /// - Parameter channel: The channel index to query.
    /// - Returns: The maximum value for the specified channel, or `-100.0` if the channel is invalid.
    func max(for channel: Int) -> Float {
        guard channel < buffers.count else { return -100.0 }
        return buffers[channel].max()
    }

    /// Returns the number of values in the first channel buffer, or zero if none exist.
    ///
    /// - Returns: The count of values in the first channel's buffer, or `0` if not available.
    var count: Int {
        buffers.first?.count() ?? 0
    }

    /// Returns the number of channels in the multi-channel buffer.
    ///
    /// - Returns: The total number of channels.
    var channels: Int {
        return buffers.count
    }

    /// Returns the cached averages from the last cache update.
    ///
    /// - Returns: An array of average values, one per channel.
    func allAverages() -> [Float] {
        return lastAverages
    }

    /// Reads all values from the ring buffer of a specified channel.
    ///
    /// - Parameter channel: The channel index to read from.
    /// - Returns: An array of `Float` values currently in the buffer for the specified channel.
    func readAll(for channel: Int) -> [Float] {
        guard channel < buffers.count else { return [] }
        return buffers[channel].readAll()
    }

    /// Updates cached averages and maxima for all channel buffers in a thread-safe manner.
    ///
    /// This method locks the cache, updates the averages and maxima arrays, and then unlocks.
    func updateCache() {
        cacheLock.lock()
        lastAverages = buffers.map { $0.average() }
        lastMaxima = buffers.map { $0.max() }
        cacheLock.unlock()
    }

    /// Returns the most recent value for a specified channel.
    ///
    /// - Parameter channel: The channel index to query.
    /// - Returns: The most recently written value for the specified channel, or `0.0` if invalid.
    func mostRecent(for channel: Int) -> Float {
        guard channel < buffers.count else { return 0.0 }
        return buffers[channel].mostRecent()
    }

    /// Returns the cached most recent values for all channels.
    ///
    /// - Returns: An array of the most recent values for each channel.
    func allMostRecent() -> [Float] {
        return buffers.map { $0.mostRecent() }
    }

    /// Indicates whether all channel buffers are empty.
    ///
    /// - Returns: `true` if all buffers contain zero values; otherwise, `false`.
    var isEmpty: Bool {
        return buffers.allSatisfy { $0.count() == 0 }
    }
}
