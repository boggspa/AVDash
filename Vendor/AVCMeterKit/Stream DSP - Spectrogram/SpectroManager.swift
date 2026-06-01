///
///  SpectroManager.swift
///  AVCMeter
///
///  Created by Chris Izatt on 29/06/2025.
///

import Foundation
import CoreAudio
import AudioToolbox

/// MARK: - C FFT Processor Bindings
///
/// These declarations expose C functions from the underlying AV/C FFT processor
/// into Swift using @_silgen_name. Each corresponds to a C function implemented
/// in the linked native module. Use with caution, as type safety is not enforced.

@_silgen_name("SpectroInputStream_Create")
func SpectroInputStream_Create(_ deviceID: UInt32, _ channelCount: UInt32) -> UnsafeMutableRawPointer?

@_silgen_name("SpectroInputStream_Destroy")
func SpectroInputStream_Destroy(_ stream: UnsafeMutableRawPointer)

@_silgen_name("SpectroInputStream_Start")
func SpectroInputStream_Start(_ stream: UnsafeMutableRawPointer) -> OSStatus

@_silgen_name("SpectroInputStream_Stop")
func SpectroInputStream_Stop(_ stream: UnsafeMutableRawPointer) -> OSStatus

@_silgen_name("SpectroInputStream_Clear")
func SpectroInputStream_Clear(_ stream: UnsafeMutableRawPointer)

@_silgen_name("SpectroInputStream_Read")
func SpectroInputStream_Read(_ stream: UnsafeMutableRawPointer, _ channel: Int32, _ buffer: UnsafeMutablePointer<Float>, _ frames: Int32) -> Int32

@_silgen_name("SpectroInputStream_Filled")
func SpectroInputStream_Filled(_ stream: UnsafeMutableRawPointer, _ channel: Int32) -> Int32

@_silgen_name("SpectroRingBuffer_Init")
func SpectroRingBuffer_Init(_ numDevices: Int32, _ channelsPerDevice: UnsafePointer<Int32>, _ numFrames: Int32, _ fftSize: Int32)

@_silgen_name("SpectroRingBuffer_Write")
func SpectroRingBuffer_Write(_ deviceID: Int32, _ channel: Int32, _ fftMagnitudes: UnsafePointer<Float>)

@_silgen_name("SpectroRingBuffer_ReadFrame")
func SpectroRingBuffer_ReadFrame(_ deviceID: Int32, _ channel: Int32, _ frameOffset: Int32) -> UnsafePointer<Float>?

@_silgen_name("SpectroRingBuffer_WriteInterleaved")
func SpectroRingBuffer_WriteInterleaved(_ deviceID: Int32, _ interleaved: UnsafePointer<Float>, _ numChannels: Int32, _ fftSize: Int32)

@_silgen_name("Spectro2DRingBuffer_Create")
func Spectro2DRingBuffer_Create(_ width: Int32, _ height: Int32) -> UnsafeMutableRawPointer?

@_silgen_name("Spectro2DRingBuffer_Destroy")
func Spectro2DRingBuffer_Destroy(_ buffer: UnsafeMutableRawPointer)

@_silgen_name("Spectro2DRingBuffer_WriteColumn")
func Spectro2DRingBuffer_WriteColumn(_ buffer: UnsafeMutableRawPointer, _ columnData: UnsafePointer<Float>)

@_silgen_name("Spectro2DRingBuffer_GetSnapshot")
func Spectro2DRingBuffer_GetSnapshot(_ buffer: UnsafeMutableRawPointer, _ delay: Int32, _ outWidth: UnsafeMutablePointer<Int32>, _ outHeight: UnsafeMutablePointer<Int32>) -> UnsafePointer<Float>

@_silgen_name("SpectroHistoryRingBuffer_Create")
func SpectroHistoryRingBuffer_Create(_ numBins: Int, _ numFrames: Int) -> UnsafeMutableRawPointer?

@_silgen_name("SpectroHistoryRingBuffer_Destroy")
func SpectroHistoryRingBuffer_Destroy(_ buffer: UnsafeMutableRawPointer)

@_silgen_name("SpectroHistoryRingBuffer_WriteFrame")
func SpectroHistoryRingBuffer_WriteFrame(_ buffer: UnsafeMutableRawPointer, _ magnitudes: UnsafePointer<Float>)

@_silgen_name("SpectroHistoryRingBuffer_GetSnapshot")
func SpectroHistoryRingBuffer_GetSnapshot(_ buffer: UnsafeMutableRawPointer, _ delayFrames: Int32, _ outWidth: UnsafeMutablePointer<Int>, _ outHeight: UnsafeMutablePointer<Int>) -> UnsafePointer<Float>

@_silgen_name("SpectroHistoryRingBuffer_GetLinearSnapshot")
func SpectroHistoryRingBuffer_GetLinearSnapshot(_ buffer: OpaquePointer, _ maxFrames: Int, _ outFrames: UnsafeMutablePointer<Int>, _ outHeight: UnsafeMutablePointer<Int>) -> UnsafePointer<Float>?

@_silgen_name("SpectroHistoryRingBuffer_GetWriteIndex")
func SpectroHistoryRingBuffer_GetWriteIndex(_ buffer: OpaquePointer) -> Int32




/// MARK: - Swift Wrapper Interface

final class SpectroManager: ObservableObject {
    static let shared = SpectroManager()
    static var fftBinCount: Int { VisualisationSettings.shared.spectrumFFTSize }
    static var spectrogramDisplayFrames: Int { VisualisationSettings.shared.spectrogramDisplaySeconds * 30 }
    static var spectrogramHistoryFrames: Int { spectrogramDisplayFrames }
    static var fftSize: Int { fftBinCount }

    /// Maps device and channel to corresponding history ring buffer instances.
    private var historyBuffers: [Int32: [Int32: UnsafeMutableRawPointer]] = [:]

    /// Maps device and channel to corresponding 2D ring buffer instances.
    private var twoDRingBuffers: [Int32: [Int32: UnsafeMutableRawPointer]] = [:]

    /// Keeps device-level input streams alive only while at least one spectrogram is visible.
    private var activeInputStreams: [UInt32: UnsafeMutableRawPointer] = [:]
    /// Reference-counts visible spectrogram channels per device.
    private var activeSpectrogramChannels: [UInt32: [Int32: Int]] = [:]
    private let sessionLock = NSLock()

    // MARK: - Input Stream Lifecycle
    /**
     Input Stream Lifecycle Methods

     These methods manage the creation, destruction, and operation of audio input streams.
     */

    /// Creates a new audio input stream for the specified device and channel count.
    /// - Parameters:
    ///   - deviceID: The Core Audio device identifier.
    ///   - channelCount: The number of input channels to handle.
    /// - Returns: A pointer to the native `SpectroInputStream` instance, or `nil` on failure.
    func createInputStream(deviceID: UInt32, channelCount: UInt32) -> UnsafeMutableRawPointer? {
        return SpectroInputStream_Create(deviceID, channelCount)
    }

    /// Destroys a previously created audio input stream.
    /// - Parameter stream: Pointer to the native `SpectroInputStream` instance.
    func destroyInputStream(_ stream: UnsafeMutableRawPointer) {
        SpectroInputStream_Destroy(stream)
    }

    /// Starts the specified audio input stream.
    /// - Parameter stream: Pointer to the native `SpectroInputStream` instance.
    /// - Returns: An `OSStatus` indicating success or failure.
    func startInputStream(_ stream: UnsafeMutableRawPointer) -> OSStatus {
        return SpectroInputStream_Start(stream)
    }

    /// Stops the specified audio input stream.
    /// - Parameter stream: Pointer to the native `SpectroInputStream` instance.
    /// - Returns: An `OSStatus` indicating success or failure.
    func stopInputStream(_ stream: UnsafeMutableRawPointer) -> OSStatus {
        return SpectroInputStream_Stop(stream)
    }

    func acquireSpectrogramSession(
        deviceID: UInt32,
        channelCount: UInt32,
        channel: Int32,
        historyFrames: Int32 = 30,
        fftSize: Int32 = Int32(SpectroManager.fftBinCount)
    ) -> Bool {
        // Filter out synthetic device IDs that are not real Core Audio devices
        guard deviceID != 888_888 && deviceID != 999_999 else {
            sessionLock.lock()
            var activeChannels = activeSpectrogramChannels[deviceID] ?? [:]
            activeChannels[channel, default: 0] += 1
            activeSpectrogramChannels[deviceID] = activeChannels
            sessionLock.unlock()
            return true // Allow session but skip Core Audio stream creation
        }

        sessionLock.lock()

        var activeChannels = activeSpectrogramChannels[deviceID] ?? [:]
        activeChannels[channel, default: 0] += 1
        activeSpectrogramChannels[deviceID] = activeChannels

        guard activeInputStreams[deviceID] == nil else {
            sessionLock.unlock()
            return true
        }

        initializeRingBuffer(
            numDevices: 1,
            channelsPerDevice: [Int32(channelCount)],
            numFrames: historyFrames,
            fftSize: fftSize
        )

        guard let stream = createInputStream(deviceID: deviceID, channelCount: channelCount) else {
            if let count = activeChannels[channel] {
                if count > 1 {
                    activeChannels[channel] = count - 1
                } else {
                    activeChannels.removeValue(forKey: channel)
                }
            }

            if activeChannels.isEmpty {
                activeSpectrogramChannels.removeValue(forKey: deviceID)
            } else {
                activeSpectrogramChannels[deviceID] = activeChannels
            }

            sessionLock.unlock()
            return false
        }

        let status = startInputStream(stream)
        guard status == noErr else {
            destroyInputStream(stream)

            if let count = activeChannels[channel] {
                if count > 1 {
                    activeChannels[channel] = count - 1
                } else {
                    activeChannels.removeValue(forKey: channel)
                }
            }

            if activeChannels.isEmpty {
                activeSpectrogramChannels.removeValue(forKey: deviceID)
            } else {
                activeSpectrogramChannels[deviceID] = activeChannels
            }

            sessionLock.unlock()
            return false
        }

        activeInputStreams[deviceID] = stream
        sessionLock.unlock()
        return true
    }

    func acquireExternalSpectrogramSession(
        deviceID: UInt32,
        channelCount: UInt32,
        channel: Int32,
        historyFrames: Int32 = 30,
        fftSize: Int32 = Int32(SpectroManager.fftBinCount)
    ) -> Bool {
        sessionLock.lock()
        let hadChannels = !(activeSpectrogramChannels[deviceID]?.isEmpty ?? true)
        var activeChannels = activeSpectrogramChannels[deviceID] ?? [:]
        activeChannels[channel, default: 0] += 1
        activeSpectrogramChannels[deviceID] = activeChannels

        if !hadChannels {
            initializeRingBuffer(
                numDevices: 1,
                channelsPerDevice: [Int32(channelCount)],
                numFrames: historyFrames,
                fftSize: fftSize
            )
        }

        sessionLock.unlock()
        return true
    }

    func releaseSpectrogramSession(deviceID: UInt32, channel: Int32) {
        var streamToDestroy: UnsafeMutableRawPointer?
        var shouldDestroyChannelResources = false

        sessionLock.lock()
        if var activeChannels = activeSpectrogramChannels[deviceID] {
            if let count = activeChannels[channel] {
                shouldDestroyChannelResources = true
                if count > 1 {
                    activeChannels[channel] = count - 1
                } else {
                    activeChannels.removeValue(forKey: channel)
                }
            }

            if activeChannels.isEmpty {
                activeSpectrogramChannels.removeValue(forKey: deviceID)
                streamToDestroy = activeInputStreams.removeValue(forKey: deviceID)
            } else {
                activeSpectrogramChannels[deviceID] = activeChannels
            }
        } else {
            shouldDestroyChannelResources = true
        }
        sessionLock.unlock()

        if let stream = streamToDestroy {
            _ = stopInputStream(stream)
            destroyInputStream(stream)
        }

        if shouldDestroyChannelResources {
            destroySpectrogramResources(for: Int32(deviceID), channel: channel)
        }
    }

    func isSpectrogramChannelActive(deviceID: UInt32, channel: Int32) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return (activeSpectrogramChannels[deviceID]?[channel] ?? 0) > 0
    }

    /// Clears the buffer of the specified audio input stream.
    /// - Parameter stream: Pointer to the native `SpectroInputStream` instance.
    func clearInputStream(_ stream: UnsafeMutableRawPointer) {
        SpectroInputStream_Clear(stream)
    }

    /// Reads audio data from the input stream for a specific channel.
    /// - Parameters:
    ///   - stream: Pointer to the native `SpectroInputStream` instance.
    ///   - channel: The channel index to read from.
    ///   - buffer: Buffer to receive the audio data.
    ///   - frames: Number of frames to read.
    /// - Returns: The number of frames actually read.
    func readInputStream(_ stream: UnsafeMutableRawPointer, channel: Int32, buffer: UnsafeMutablePointer<Float>, frames: Int32) -> Int32 {
        return SpectroInputStream_Read(stream, channel, buffer, frames)
    }

    /// Returns the number of filled frames available for a given channel in the input stream.
    /// - Parameters:
    ///   - stream: Pointer to the native `SpectroInputStream` instance.
    ///   - channel: The channel index to query.
    /// - Returns: The number of filled frames available.
    func inputStreamFilled(_ stream: UnsafeMutableRawPointer, channel: Int32) -> Int32 {
        return SpectroInputStream_Filled(stream, channel)
    }

    // MARK: - Ring Buffer Operations
    /**
     Ring Buffer Operations

     Methods for initializing, writing to, and reading from FFT ring buffers.
     */

    /// Initializes the FFT ring buffer for the specified devices and parameters.
    /// - Parameters:
    ///   - numDevices: The number of devices.
    ///   - channelsPerDevice: An array containing the channel count for each device.
    ///   - numFrames: Number of frames to keep in history.
    ///   - fftSize: FFT size to use.
    func initializeRingBuffer(numDevices: Int32, channelsPerDevice: [Int32], numFrames: Int32, fftSize: Int32) {
        channelsPerDevice.withUnsafeBufferPointer { ptr in
            SpectroRingBuffer_Init(numDevices, ptr.baseAddress!, numFrames, fftSize)
        }
    }

    /// Writes an FFT magnitude frame to the ring buffer for a given device and channel.
    /// - Parameters:
    ///   - deviceID: The Core Audio device identifier.
    ///   - channel: The channel index to write to.
    ///   - magnitudes: The FFT magnitude data.
    func writeFFTFrame(deviceID: Int32, channel: Int32, magnitudes: [Float]) {
        magnitudes.withUnsafeBufferPointer {
            SpectroRingBuffer_Write(deviceID, channel, $0.baseAddress!)
        }
    }

    /// Reads an FFT frame from the ring buffer.
    /// - Parameters:
    ///   - deviceID: The Core Audio device identifier.
    ///   - channel: The channel index to read from.
    ///   - frameOffset: The frame offset from the most recent.
    /// - Returns: An array of FFT magnitudes, or `nil` if unavailable.
    func readFFTFrame(deviceID: Int32, channel: Int32, frameOffset: Int32) -> [Float]? {
        guard let ptr = SpectroRingBuffer_ReadFrame(deviceID, channel, frameOffset) else { return nil }
        let buffer = UnsafeBufferPointer(start: ptr, count: SpectroManager.fftBinCount)
        return Array(buffer)
    }

    /// Writes interleaved FFT magnitudes for all channels to the ring buffer.
    /// - Parameters:
    ///   - deviceID: The Core Audio device identifier.
    ///   - interleavedMagnitudes: Interleaved FFT magnitude data for all channels.
    ///   - numChannels: Number of channels.
    ///   - fftSize: FFT size used.
    func writeInterleavedFFT(deviceID: Int32, interleavedMagnitudes: [Float], numChannels: Int32, fftSize: Int32) {
        interleavedMagnitudes.withUnsafeBufferPointer {
            SpectroRingBuffer_WriteInterleaved(deviceID, $0.baseAddress!, numChannels, fftSize)
        }
    }

    // MARK: - 2D Ring Buffer
    /**
     2D Ring Buffer Methods

     For managing and retrieving 2D ring buffer snapshots.
     */

    /// Creates a new 2D ring buffer with the specified dimensions.
    /// - Parameters:
    ///   - width: The number of columns (bins) per frame.
    ///   - height: The number of frames to keep in history.
    /// - Returns: Pointer to the native 2D ring buffer, or `nil` on failure.
    func create2DRingBuffer(width: Int32, height: Int32) -> UnsafeMutableRawPointer? {
        return Spectro2DRingBuffer_Create(width, height)
    }

    /// Destroys a previously created 2D ring buffer.
    /// - Parameter buffer: Pointer to the native 2D ring buffer.
    func destroy2DRingBuffer(_ buffer: UnsafeMutableRawPointer) {
        Spectro2DRingBuffer_Destroy(buffer)
    }

    /// Writes a single frame of data to the 2D ring buffer.
    /// - Parameters:
    ///   - buffer: Pointer to the native 2D ring buffer.
    ///   - frame: The frame data to write.
    func write2DColumn(_ buffer: UnsafeMutableRawPointer, columnData: [Float]) {
        columnData.withUnsafeBufferPointer {
            Spectro2DRingBuffer_WriteColumn(buffer, $0.baseAddress!)
        }
    }

    /// Ensures a 2D ring buffer is registered for the specified device and channel.
    /// If not present, this method creates and registers one.
    /// - Parameters:
    ///   - deviceID: The Core Audio device identifier.
    ///   - channel: The channel index.
    ///   - width: Number of bins (FFT size).
    ///   - height: Number of frames to retain.
    func ensure2DRingBufferExists(deviceID: Int32, channel: Int32, width: Int32, height: Int32) {
        if twoDRingBuffers[deviceID]?[channel] == nil {
            if let buffer = create2DRingBuffer(width: width, height: height) {
                register2DRingBuffer(buffer, for: deviceID, channel: channel)
            } else {
                print("Failed to create 2D ring buffer for device \(deviceID), channel \(channel)")
            }
        }
    }

    /// Retrieves a snapshot from the 2D ring buffer.
    /// - Parameters:
    ///   - buffer: Pointer to the native 2D ring buffer.
    ///   - delay: Number of frames to delay the snapshot.
    ///   - outWidth: Output parameter for the snapshot width.
    ///   - outHeight: Output parameter for the snapshot height.
    /// - Returns: Pointer to the snapshot data.
    func get2DSnapshot(_ buffer: UnsafeMutableRawPointer, delay: Int32, outWidth: inout Int32, outHeight: inout Int32) -> UnsafePointer<Float> {
        return Spectro2DRingBuffer_GetSnapshot(buffer, delay, &outWidth, &outHeight)
    }

    /// Returns the native 2D ring buffer pointer for a given device and channel, if registered.
    /// - Parameters:
    ///   - deviceID: The Core Audio device identifier.
    ///   - channel: The channel index.
    /// - Returns: Pointer to the native 2D ring buffer, or `nil` if not found.
    func twoDRingBuffer(for deviceID: Int32, channel: Int32) -> UnsafeMutableRawPointer? {
        return twoDRingBuffers[deviceID]?[channel]
    }

    /// Registers a created 2D ring buffer under a device and channel key.
    /// - Parameters:
    ///   - buffer: Pointer to the native 2D ring buffer.
    ///   - deviceID: The Core Audio device identifier.
    ///   - channel: The channel index.
    func register2DRingBuffer(_ buffer: UnsafeMutableRawPointer, for deviceID: Int32, channel: Int32) {
        if twoDRingBuffers[deviceID] == nil {
            twoDRingBuffers[deviceID] = [:]
        }
        twoDRingBuffers[deviceID]?[channel] = buffer
    }

    // MARK: - History Ring Buffer
    /**
     History Ring Buffer Methods

     For managing and retrieving history ring buffer snapshots.
     */

    /// Creates a new history ring buffer with the specified number of bins and frames.
    /// - Parameters:
    ///   - numBins: Number of bins (FFT size).
    ///   - numFrames: Number of frames to keep in history.
    /// - Returns: Pointer to the native history ring buffer, or `nil` on failure.
    func createHistoryRingBuffer(numBins: Int, numFrames: Int) -> UnsafeMutableRawPointer? {
        return SpectroHistoryRingBuffer_Create(numBins, numFrames)
    }

    /// Destroys a previously created history ring buffer.
    /// - Parameter buffer: Pointer to the native history ring buffer.
    func destroyHistoryRingBuffer(_ buffer: UnsafeMutableRawPointer) {
        SpectroHistoryRingBuffer_Destroy(buffer)
    }

    /// Writes a frame of FFT magnitudes to the history ring buffer.
    /// - Parameters:
    ///   - buffer: Pointer to the native history ring buffer.
    ///   - magnitudes: The FFT magnitude data to write.
    func writeHistoryFrame(_ buffer: UnsafeMutableRawPointer, magnitudes: [Float]) {
        magnitudes.withUnsafeBufferPointer {
            SpectroHistoryRingBuffer_WriteFrame(buffer, $0.baseAddress!)
        }
    }

    /// Retrieves a snapshot from the history ring buffer.
    /// - Parameters:
    ///   - buffer: Pointer to the native history ring buffer.
    ///   - delayFrames: Number of frames to delay the snapshot.
    ///   - outWidth: Output parameter for the snapshot width.
    ///   - outHeight: Output parameter for the snapshot height.
    /// - Returns: Pointer to the snapshot data.
    func getHistorySnapshot(_ buffer: UnsafeMutableRawPointer, delayFrames: Int32, outWidth: inout Int, outHeight: inout Int) -> UnsafePointer<Float> {
        return SpectroHistoryRingBuffer_GetSnapshot(buffer, delayFrames, &outWidth, &outHeight)
    }

    func getWriteIndex(_ buffer: UnsafeMutableRawPointer) -> Int {
        return Int(SpectroHistoryRingBuffer_GetWriteIndex(OpaquePointer(buffer)))
    }

    /// Returns the last maxFrames frames in chronological order (oldest first, newest last).
    func getLinearSnapshot(_ buffer: UnsafeMutableRawPointer, maxFrames: Int, outFrames: inout Int, outHeight: inout Int) -> UnsafePointer<Float>? {
        return SpectroHistoryRingBuffer_GetLinearSnapshot(OpaquePointer(buffer), maxFrames, &outFrames, &outHeight)
    }

    /// Returns the native history ring buffer pointer for a given device and channel, if registered.
    /// - Parameters:
    ///   - deviceID: The Core Audio device identifier.
    ///   - channel: The channel index.
    /// - Returns: Pointer to the native history ring buffer, or `nil` if not found.
    func historyRingBuffer(for deviceID: Int32, channel: Int32) -> UnsafeMutableRawPointer? {
        return historyBuffers[deviceID]?[channel]
    }

    /// Registers a created history buffer under a device and channel key.
    /// - Parameters:
    ///   - buffer: Pointer to the native history ring buffer.
    ///   - deviceID: The Core Audio device identifier.
    ///   - channel: The channel index.
    func registerHistoryBuffer(_ buffer: UnsafeMutableRawPointer, for deviceID: Int32, channel: Int32) {
        if historyBuffers[deviceID] == nil {
            historyBuffers[deviceID] = [:]
        }
        historyBuffers[deviceID]?[channel] = buffer
    }
    /// Destroys Spectrogram on instance closure
    func destroySpectrogramResources(for deviceID: Int32, channel: Int32) {
        if let hist = self.historyBuffers[deviceID]?[channel] {
            self.destroyHistoryRingBuffer(hist)
            self.historyBuffers[deviceID]?.removeValue(forKey: channel)
            if self.historyBuffers[deviceID]?.isEmpty == true {
                self.historyBuffers.removeValue(forKey: deviceID)
            }
        }
        if let ring2D = self.twoDRingBuffers[deviceID]?[channel] {
            self.destroy2DRingBuffer(ring2D)
            self.twoDRingBuffers[deviceID]?.removeValue(forKey: channel)
            if self.twoDRingBuffers[deviceID]?.isEmpty == true {
                self.twoDRingBuffers.removeValue(forKey: deviceID)
            }
        }
    }
}
