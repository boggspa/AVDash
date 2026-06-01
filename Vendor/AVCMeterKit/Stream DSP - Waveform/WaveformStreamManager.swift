//
//  WaveformStreamManager.swift
//  AVCMeter
//
//  Created by Chris Izatt on 24/06/2025.
//
// NOTE: Make sure you set per-device channel counts with WaveformBridge_SetDeviceChannelCount before starting streams!


import Foundation
import CoreAudio
import AVFoundation

fileprivate final class WaveformChannelState {
    let key: String
    let buffer: UnsafeMutablePointer<PCMRingBuffer>

    private let lock = NSLock()
    private var stream: UnsafeMutablePointer<PCMInputStream>?
    private var context: UnsafeMutableRawPointer?
    private var isStarting = false

    init(key: String, buffer: UnsafeMutablePointer<PCMRingBuffer>) {
        self.key = key
        self.buffer = buffer
    }

    func beginStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil, !isStarting else { return false }
        isStarting = true
        return true
    }

    func install(stream: UnsafeMutablePointer<PCMInputStream>, context: UnsafeMutableRawPointer) {
        lock.lock()
        self.stream = stream
        self.context = context
        self.isStarting = false
        lock.unlock()
    }

    func cancelStart() {
        lock.lock()
        isStarting = false
        lock.unlock()
    }

    func currentStream() -> UnsafeMutablePointer<PCMInputStream>? {
        lock.lock()
        defer { lock.unlock() }
        return stream
    }

    func stopStream() {
        let streamToDestroy: UnsafeMutablePointer<PCMInputStream>?
        lock.lock()
        streamToDestroy = stream
        stream = nil
        isStarting = false
        lock.unlock()

        if let streamToDestroy {
            PCMInputStream_Destroy(streamToDestroy)
        }
    }

    deinit {
        stopStream()
        if let context {
            Unmanaged<PCMContext>.fromOpaque(context).release()
        }
        destroyPCMRingBuffer(buffer)
    }
}

fileprivate final class PCMContext {
    let deviceID: AudioDeviceID
    let channelIndex: Int
    weak var state: WaveformChannelState?

    init(deviceID: AudioDeviceID, channelIndex: Int, state: WaveformChannelState) {
        self.deviceID = deviceID
        self.channelIndex = channelIndex
        self.state = state
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count , by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

private let downsampleFactor = 4

@_silgen_name("createPCMInputStream")
func PCMInputStream_Create(
    _ deviceID: AudioDeviceID,
    _ callback: @convention(c) (UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?, UInt32, UInt32, UnsafeMutableRawPointer?) -> Void,
    _ context: UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<PCMInputStream>?

@_silgen_name("destroyPCMInputStream")
func PCMInputStream_Destroy(_ stream: UnsafeMutablePointer<PCMInputStream>)

@_silgen_name("PCMInputStream_Read")
func PCMInputStream_Read(_ stream: UnsafeMutablePointer<PCMInputStream>, _ buffer: UnsafeMutablePointer<Float>, _ frameCount: Int32) -> Int32

@_silgen_name("PCMInputStream_Clear")
func PCMInputStream_Clear(_ stream: UnsafeMutablePointer<PCMInputStream>)

@_silgen_name("PCMInputStream_Filled")
func PCMInputStream_Filled(_ stream: UnsafeMutablePointer<PCMInputStream>) -> Int32


@_silgen_name("PCMInputStream_ReadChannel")
func PCMInputStream_ReadChannel(_ stream: UnsafeMutablePointer<PCMInputStream>, _ buffer: UnsafeMutablePointer<Float>, _ frameCount: Int32, _ channelIndex: Int32) -> Int32

@_silgen_name("createPCMRingBuffer")
func createPCMRingBuffer(_ capacity: Int32, _ channelCount: Int32) -> UnsafeMutablePointer<PCMRingBuffer>?

@_silgen_name("destroyPCMRingBuffer")
func destroyPCMRingBuffer(_ buffer: UnsafeMutablePointer<PCMRingBuffer>?)

@_silgen_name("readSingleChannelFromRingBuffer")
func readSingleChannelFromRingBuffer(
    _ buffer: UnsafeMutablePointer<PCMRingBuffer>,
    _ channelIndex: Int32,
    _ output: UnsafeMutablePointer<Float>,
    _ count: Int32
) -> Int32

@_silgen_name("writeMinMaxToRingBuffer")
func writeMinMaxToRingBuffer(_ buffer: UnsafeMutablePointer<PCMRingBuffer>, _ minVal: Float, _ maxVal: Float)

@_silgen_name("writeSingleChannelToRingBuffer")
func writeSingleChannelToRingBuffer(
    _ buffer: UnsafeMutablePointer<PCMRingBuffer>,
    _ channelIndex: Int32,
    _ data: UnsafePointer<Float>?,
    _ frameCount: Int32,
    _ stride: Int32
)

@_silgen_name("getSingleChannelFillLevel")
func getSingleChannelFillLevel(_ buffer: UnsafeMutablePointer<PCMRingBuffer>, _ channelIndex: Int32) -> Int32

class WaveformStreamManager: ObservableObject {
    private let sampleRate = 48000
    private let stateLock = NSLock()
    private var channelStates: [String: WaveformChannelState] = [:]

    // Singleton instance to manage waveform streams globally
    static let shared: WaveformStreamManager = {
        let instance = WaveformStreamManager()
        return instance
    }()

    // Stream windows are currently treated as visible for waveform updates.
    private func windowIsVisible(for deviceID: AudioDeviceID, channelIndex: Int) -> Bool {
        _ = (deviceID, channelIndex)
        return true
    }

    // MARK: - Logging Throttling
    private var lastLogTimes: [String: Date] = [:]
    private let logThrottleInterval: TimeInterval = 3.0
    private func throttledLog(_ tag: String, _ message: String) {
        let now = Date()
        let last = lastLogTimes[tag] ?? Date.distantPast
        if now.timeIntervalSince(last) >= logThrottleInterval {
            print("[\(tag)] \(message)")
            lastLogTimes[tag] = now
        }
    }

    // MARK: - PCM Input Handler Callback

    /// C-style callback invoked by PCMInputStream when new audio data is available.
    /// It writes incoming per-channel PCM data into the corresponding ring buffer.
    private let pcmInputHandler: @convention(c) (
        UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?,
        UInt32,
        UInt32,
        UnsafeMutableRawPointer?
    ) -> Void = { pcm, numFrames, numChannels, context in
        guard let context = context else { return }
        let contextObj = Unmanaged<PCMContext>.fromOpaque(context).takeUnretainedValue()
        guard let state = contextObj.state else { return }
        guard let pcm = pcm else { return }
        guard let channelPtr = pcm[Int(contextObj.channelIndex)] else { return }
        writeSingleChannelToRingBuffer(
            state.buffer,
            0,
            channelPtr,
            Int32(numFrames),
            1
        )
    }

    // MARK: - Device Channel Count Retrieval

    /// Retrieves the number of input channels available on the specified audio device.
    func getInputChannelCount(for deviceID: AudioDeviceID) -> Int {
        // Filter out synthetic device IDs that are not real Core Audio devices
        guard deviceID != 888_888 && deviceID != 999_999 else { return 1 }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMaster
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr else { return 1 }

        let bufferListPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: 1)
        defer { bufferListPtr.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPtr)
        guard status == noErr else { return 1 }

        let bufferList = bufferListPtr.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeBufferPointer(start: &bufferList.pointee, count: 1)

        var channelCount = 0
        let mBuffers = buffers[0].mNumberBuffers
        let bufferPtr = UnsafeBufferPointer<AudioBuffer>(
            start: withUnsafePointer(to: &bufferList.pointee.mBuffers) {
                UnsafeRawPointer($0).assumingMemoryBound(to: AudioBuffer.self)
            },
            count: Int(mBuffers)
        )
        for buffer in bufferPtr {
            channelCount += Int(buffer.mNumberChannels)
        }
        return max(channelCount, 1)
    }

    // MARK: - Stream Management

    /// Starts a PCM input stream for the specified device and channel.
    /// Creates and stores a ring buffer for the channel's waveform data.
    func startStream(for deviceID: AudioDeviceID, channelIndex: Int) {
        // Filter out synthetic device IDs that are not real Core Audio devices
        guard deviceID != 888_888 && deviceID != 999_999 else { return }

        guard channelIndex >= 0 else { return }
        guard channelIndex < getInputChannelCount(for: deviceID) else { return }

        guard let state = ensureStateExists(for: deviceID, channelIndex: channelIndex) else { return }
        guard state.beginStart() else { return }

        let contextObject = PCMContext(deviceID: deviceID, channelIndex: channelIndex, state: state)
        let context = Unmanaged.passRetained(contextObject).toOpaque()
        if let stream = PCMInputStream_Create(deviceID, pcmInputHandler, context) {
            state.install(stream: stream, context: context)
        } else {
            state.cancelStart()
            Unmanaged<PCMContext>.fromOpaque(context).release()
        }
    }

    /// Stops and cleans up all streams associated with the specified device,
    /// including their buffers once no readers/callbacks retain the state anymore.
    func stopStream(for deviceID: AudioDeviceID) {
        let states = removeStates(matching: "\(deviceID)-")
        for state in states {
            state.stopStream()
        }
    }

    func stopStream(for deviceID: AudioDeviceID, channelIndex: Int) {
        let key = "\(deviceID)-\(channelIndex)"
        if let state = removeState(forKey: key) {
            state.stopStream()
        }
    }

    /// Fetches the latest waveform samples for the specified device and channel.
    /// Starts the stream if not already active and reads from the ring buffer.
    func fetchSamples(for deviceID: AudioDeviceID, channelIndex: Int, frameCount: Int = 2048) -> [Float] {
        // Ensure ring buffers exist before starting or reading
        guard let state = ensureStateExists(for: deviceID, channelIndex: channelIndex) else { return [] }

        if state.currentStream() == nil {
            startStream(for: deviceID, channelIndex: channelIndex)
        }

        let requested = max(1, frameCount)
        var output = [Float](repeating: 0.0, count: requested)
        var readCount: Int32 = 0
        output.withUnsafeMutableBufferPointer { ptr in
            if let baseAddress = ptr.baseAddress {
                readCount = readSingleChannelFromRingBuffer(
                    state.buffer,
                    0,
                    baseAddress,
                    Int32(requested)
                )
            }
        }

        guard readCount > 0 else { return [] }
        if readCount < Int32(output.count) {
            output.removeLast(output.count - Int(readCount))
        }
        return output
    }

    /// Clears the PCM input stream buffer for a given device and channel.
    func clearStream(for deviceID: AudioDeviceID, channelIndex: Int) {
        if let stream = state(for: deviceID, channelIndex: channelIndex)?.currentStream() {
            PCMInputStream_Clear(stream)
        }
    }

    /// Returns the number of filled samples in the PCM input stream buffer.
    func bufferFillLevel(for deviceID: AudioDeviceID, channelIndex: Int) -> Int {
        guard let stream = state(for: deviceID, channelIndex: channelIndex)?.currentStream() else { return 0 }
        return Int(PCMInputStream_Filled(stream))
    }

    // MARK: - Stream Lookup Registration

    /// Registers a callback with the C-side PCMEngine to allow lookup of active streams by key.
    /// This enables C code to query the Swift-managed streams by "deviceID-channelIndex" keys.


    private func key(for deviceID: AudioDeviceID, channelIndex: Int) -> String {
        "\(deviceID)-\(channelIndex)"
    }

    private func state(for deviceID: AudioDeviceID, channelIndex: Int) -> WaveformChannelState? {
        let key = key(for: deviceID, channelIndex: channelIndex)
        stateLock.lock()
        defer { stateLock.unlock() }
        return channelStates[key]
    }

    private func ensureStateExists(for deviceID: AudioDeviceID, channelIndex: Int) -> WaveformChannelState? {
        let key = key(for: deviceID, channelIndex: channelIndex)

        stateLock.lock()
        if let existing = channelStates[key] {
            stateLock.unlock()
            return existing
        }

        let historyLength = sampleRate * VisualisationSettings.shared.waveformDurationSeconds
        guard let buffer = createPCMRingBuffer(Int32(historyLength), 1) else {
            stateLock.unlock()
            return nil
        }

        let state = WaveformChannelState(key: key, buffer: buffer)
        channelStates[key] = state
        stateLock.unlock()
        return state
    }

    private func removeState(forKey key: String) -> WaveformChannelState? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return channelStates.removeValue(forKey: key)
    }

    private func removeStates(matching prefix: String) -> [WaveformChannelState] {
        stateLock.lock()
        let keys = channelStates.keys.filter { $0.hasPrefix(prefix) }
        let removed = keys.compactMap { channelStates.removeValue(forKey: $0) }
        stateLock.unlock()
        return removed
    }
}
