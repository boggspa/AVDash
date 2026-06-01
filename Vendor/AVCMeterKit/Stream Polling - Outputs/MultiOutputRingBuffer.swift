//
//  MultiOutputRingBuffer.swift
//  AVCMeter
//
//  Created by Chris Izatt on 07/07/2025.
//
import Foundation


// MARK: - OutputChannelRingBufferWrapper (C Interop Layer)

// Note: This class now manages its own locking internally to ensure thread safety on all methods.
// Locking is managed exclusively inside this wrapper to avoid nested locks and potential deadlocks.

final class OutputChannelRingBufferWrapper {
    private var storage: [[Float]]
    private var writeIndices: [Int]
    private var validCounts: [Int]
    private let bufferSize: Int
    private let lock = NSLock()

    let channelCount: Int

    init(channelCount: Int, bufferSize: Int) {
        self.channelCount = channelCount
        self.bufferSize = bufferSize
        self.storage = Array(repeating: Array(repeating: 0.0, count: bufferSize), count: channelCount)
        self.writeIndices = Array(repeating: 0, count: channelCount)
        self.validCounts = Array(repeating: 0, count: channelCount)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func writeLocked(_ value: Float, to channel: Int) {
        guard bufferSize > 0 else { return }
        storage[channel][writeIndices[channel]] = value
        writeIndices[channel] = (writeIndices[channel] + 1) % bufferSize
        validCounts[channel] = min(validCounts[channel] + 1, bufferSize)
    }

    func write(_ value: Float, to channel: Int) {
        guard channel < channelCount && channel >= 0 else { return }
        withLock {
            writeLocked(value, to: channel)
        }
    }

    func write(_ values: [Float], to channel: Int) {
        guard channel < channelCount && channel >= 0 else { return }
        guard !values.isEmpty else { return }
        withLock {
            for value in values.suffix(bufferSize) {
                writeLocked(value, to: channel)
            }
        }
    }

    func read(from channel: Int, frameCount: Int = 1) -> [Float] {
        guard channel >= 0 && channel < channelCount else {
            if frameCount < 1 {
                return []
            }
            return Array(repeating: 0.0, count: frameCount)
        }
        if frameCount < 1 {
            return []
        }

        return withLock {
            let availableCount = validCounts[channel]
            let countToFetch = min(frameCount, availableCount)
            var result: [Float] = []
            result.reserveCapacity(frameCount)

            if countToFetch < frameCount {
                result.append(contentsOf: Array(repeating: 0.0, count: frameCount - countToFetch))
            }

            guard countToFetch > 0 else {
                return result
            }

            let startIndex = (writeIndices[channel] - countToFetch + bufferSize) % bufferSize
            for offset in 0..<countToFetch {
                let index = (startIndex + offset) % bufferSize
                result.append(storage[channel][index])
            }

            return result
        }
    }

    func mostRecent(from channel: Int) -> Float {
        guard channel >= 0 && channel < channelCount else { return 0.0 }
        return withLock {
            guard validCounts[channel] > 0, bufferSize > 0 else { return 0.0 }
            let index = (writeIndices[channel] - 1 + bufferSize) % bufferSize
            return storage[channel][index]
        }
    }

    func count(for channel: Int) -> Int {
        guard channel >= 0 && channel < channelCount else { return 0 }
        return withLock {
            validCounts[channel]
        }
    }

    func clear() {
        withLock {
            for ch in 0..<channelCount {
                storage[ch] = Array(repeating: 0.0, count: bufferSize)
                writeIndices[ch] = 0
                validCounts[ch] = 0
            }
        }
    }

    func free() {
        // No-op for Swift arrays, kept for API compatibility
    }

    func withUnsafeBufferPointer<T>(for channel: Int, _ body: (UnsafeBufferPointer<Float>) -> T) -> T? {
        guard channel >= 0 && channel < channelCount else { return nil }
        let snapshot = read(from: channel, frameCount: count(for: channel))
        return snapshot.withUnsafeBufferPointer(body)
    }
}

// MARK: - MultiChannelOutputRingBuffer (Swift Manager Class)

// Note: This class now exclusively manages thread safety for all operations on the wrapper.
// All public functions accessing the wrapper are locked with 'lock'.

// WARNING:
// Without explicit synchronization, concurrent array access on the wrapper is NOT thread safe.
// Further changes required for true lock-free concurrency on ring buffer arrays.

// Atomics is used only for summary properties, not the ring buffer arrays.

final class MultiChannelOutputRingBuffer {
    private let wrapper: OutputChannelRingBufferWrapper
    private let channelCount: Int
    private let capacity: Int

    private var lastAverages: [Float] = []
    private var lastMaxima: [Float] = []
    private let cacheLock = NSLock()

    init(channels: Int, capacity: Int) {
        self.channelCount = channels
        self.capacity = capacity
        self.wrapper = OutputChannelRingBufferWrapper(channelCount: channels, bufferSize: capacity)
    }

    func clear() {
        wrapper.clear()
    }

    func free() {
        wrapper.free()
    }

    var channels: Int {
        return channelCount
    }

    func write(_ value: Float, toChannel channel: Int) {
        wrapper.write(value, to: channel)
    }

    func write(_ values: [Float], toChannel channel: Int) {
        wrapper.write(values, to: channel)
    }

    func mostRecent(for channel: Int) -> Float {
        guard channel < channelCount else { return 0.0 }
        return wrapper.mostRecent(from: channel)
    }

    func readMostRecent(fromChannel channel: Int) -> Float {
        wrapper.mostRecent(from: channel)
    }

    func allMostRecent() -> [Float] {
        let maxChannels = min(channelCount, wrapper.channelCount)
        return (0..<maxChannels).map { readMostRecent(fromChannel: $0) }
    }

    func average(for channel: Int) -> Float {
        guard channel < channelCount else { return 0.0 }
        let count = wrapper.count(for: channel)
        guard count > 0 else { return 0.0 }
        return wrapper.read(from: channel, frameCount: count).average()
    }

    func max(for channel: Int) -> Float {
        guard channel < channelCount else { return -100.0 }
        let count = wrapper.count(for: channel)
        guard count > 0 else { return -100.0 }
        return wrapper.read(from: channel, frameCount: count).max() ?? -100.0
    }

    func readAll(fromChannel channel: Int) -> [Float] {
        guard channel < channelCount else { return [] }
        let count = wrapper.count(for: channel)
        guard count > 0 else { return [] }
        return wrapper.read(from: channel, frameCount: count)
    }

    func updateCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        lastAverages = (0..<channelCount).map { average(for: $0) }
        lastMaxima = (0..<channelCount).map { max(for: $0) }
    }

    var isEmpty: Bool {
        return (0..<channelCount).allSatisfy { wrapper.count(for: $0) == 0 }
    }

    func count(for channel: Int) -> Int {
        guard channel < channelCount else { return 0 }
        return wrapper.count(for: channel)
    }

    func allAverages() -> [Float] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return lastAverages
    }

    func withUnsafeBufferPointer<T>(forChannel channel: Int, _ body: (UnsafeBufferPointer<Float>) -> T) -> T? {
        return wrapper.withUnsafeBufferPointer(for: channel, body)
    }
}

extension MultiChannelOutputRingBuffer: CustomStringConvertible {
    var description: String {
        "OutputRingBuffer – Channels: \(channelCount), Capacity: \(capacity)"
    }
}
