//
//  FFTStreamManager.swift
//  AVCMeter
//
//  Created by Chris Izatt on 28/06/2025.
//

import Foundation
import CoreAudio
import AudioToolbox

// MARK: - C API Bridging

/// Opaque handle to the C `FFTInputStream` type.
/// Creates a new FFTInputStream for the specified audio device, channel count, sample rate, and buffer size.
@_silgen_name("FFTInputStream_Create")
func FFTInputStream_Create(_ deviceID: AudioDeviceID, _ channelCount: UInt32, _ sampleRate: UInt32, _ bufferSize: UInt32) -> FFTInputStream?

/// Destroys the FFTInputStream and frees its resources.
@_silgen_name("FFTInputStream_Destroy")
func FFTInputStream_Destroy(_ stream: FFTInputStream)

/// Starts capturing audio. Returns `noErr` on success.
@_silgen_name("FFTInputStream_Start")
func FFTInputStream_Start(_ stream: FFTInputStream) -> OSStatus

/// Stops capturing audio. Returns `noErr` on success.
@_silgen_name("FFTInputStream_Stop")
func FFTInputStream_Stop(_ stream: FFTInputStream) -> OSStatus

/// Reads up to `count` samples for a channel into the provided buffer. Returns the number of frames read.
@_silgen_name("FFTInputStream_Read")
func FFTInputStream_Read(_ stream: FFTInputStream, _ channel: Int32, _ buffer: UnsafeMutablePointer<Float>, _ count: Int32) -> Int32

/// Returns the number of frames currently available in the stream's internal buffer for a given channel.
@_silgen_name("FFTInputStream_Filled")
func FFTInputStream_Filled(_ stream: FFTInputStream, _ channel: Int32) -> Int32

// MARK: - Swift Wrapper

/// A convenient Swift interface over the underlying C `FFTInputStream` API.
/// Handles creation, start/stop, and data I/O in a more idiomatic manner.
class FFTStreamManager {
  let deviceID: AudioDeviceID
  private let stream: FFTInputStream
  /// Initializes the FFTStreamManager by creating the C FFTInputStream.
  /// - Parameters:
  ///   - deviceID: Core Audio device identifier.
  ///   - channelCount: Number of input channels to capture.
  ///   - sampleRate: Audio sample rate in Hz.
  ///   - bufferSize: Capacity of the internal buffer (in frames).
  init?(deviceID: AudioDeviceID, channelCount: UInt32, sampleRate: UInt32, bufferSize: UInt32) {
      guard let s = FFTInputStream_Create(deviceID, channelCount, sampleRate, bufferSize) else {
          return nil
      }
      self.deviceID = deviceID
      self.stream = s
  }
  /// Starts audio capture on the stream.
  /// - Throws: An `NSError` if the underlying C call returns an error status.
  func start() throws { try check(FFTInputStream_Start(stream)) }
  /// Stops audio capture on the stream.
  /// - Throws: An `NSError` if the underlying C call returns an error status.
  func stop()  throws { try check(FFTInputStream_Stop(stream)) }
  /// Reads raw audio samples from the specified channel into `outBuffer`.
  /// - Parameters:
  ///   - channel: Zero-based channel index.
  ///   - outBuffer: Array to fill with samples.
  /// - Returns: Number of samples actually read.
  func read(channel: Int, into outBuffer: inout [Float]) -> Int {
      return outBuffer.withUnsafeMutableBufferPointer { ptr in
          guard let base = ptr.baseAddress else { return 0 }
          let read = FFTInputStream_Read(stream, Int32(channel), base, Int32(ptr.count))
          return Int(read)
      }
  }
  /// Queries how many frames are currently buffered for the given channel.
  /// - Parameter channel: Zero-based channel index.
  /// - Returns: Number of available frames.
  func available(channel: Int) -> Int {
      Int(FFTInputStream_Filled(stream, Int32(channel)))
  }
  /// Helper that throws an error if an OSStatus is not `noErr`.
  private func check(_ status: OSStatus) throws {
      guard status == noErr else {
          throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: nil)
      }
  }
  /// Cleans up by destroying the underlying C FFTInputStream.
  deinit {
    FFTInputStream_Destroy(stream)
  }
}

// MARK: - Post-EQ Stream Reader

/// C bridge declarations for post-EQ ring buffer access
@_silgen_name("Mixer_ReadPostEQBuffer")
func Mixer_ReadPostEQBuffer(_ globalChannelIndex: UInt32, _ outputArray: UnsafeMutablePointer<Float>, _ maxCount: Int32) -> Int32

@_silgen_name("Mixer_PostEQBufferFilled")
func Mixer_PostEQBufferFilled(_ globalChannelIndex: UInt32) -> Int32

@_silgen_name("Mixer_ReadPostDynamicsBuffer")
func Mixer_ReadPostDynamicsBuffer(_ globalChannelIndex: UInt32, _ outputArray: UnsafeMutablePointer<Float>, _ maxCount: Int32) -> Int32

@_silgen_name("Mixer_PostDynamicsBufferFilled")
func Mixer_PostDynamicsBufferFilled(_ globalChannelIndex: UInt32) -> Int32

/// Reads post-EQ audio from the mixer's per-channel ring buffer.
/// Conforms to `FFTAudioSource` so it can be used with `SafeFFTSpectrumProcessor`.
class PostEQStreamReader: FFTAudioSource, WaveformAudioSource {
    let deviceID: AudioDeviceID
    let name: String
    private let globalChannelIndex: Int32

    init?(deviceID: AudioDeviceID, channelIndex: Int, channelType: UInt32 = 0) {
        self.deviceID = deviceID
        let globalIdx = Mixer_GetGlobalChannelIndex(UInt32(deviceID), channelType, UInt32(channelIndex))
        guard globalIdx >= 0 else { return nil }
        self.globalChannelIndex = globalIdx

        // Resolve name
        if deviceID == 1_000_000 { self.name = "Synthesizer" }
        else if deviceID == 1_000_001 { self.name = "Drum Machine" }
        else if deviceID == 1_000_002 { self.name = "Tone Generator" }
        else if deviceID == 1_000_003 { self.name = "Physical Model" }
        else if deviceID == 1_000_004 { self.name = "Sampler" }
        else { self.name = String(cString: getDeviceName(deviceID)) }
    }

    func read(channel: Int, into outBuffer: inout [Float]) -> Int {
        return outBuffer.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return 0 }
            let read = Mixer_ReadPostEQBuffer(UInt32(globalChannelIndex), base, Int32(ptr.count))
            return Int(read)
        }
    }

    func readSamples(frameCount: Int) -> [Float] {
        let requested = max(1, frameCount)
        var buffer = [Float](repeating: 0.0, count: requested)
        let count = read(channel: 0, into: &buffer)
        guard count > 0 else { return [] }
        if count < buffer.count {
            buffer.removeLast(buffer.count - count)
        }
        return buffer
    }

    func availableFrames() -> Int {
        return Int(Mixer_PostEQBufferFilled(UInt32(globalChannelIndex)))
    }

    func stop() throws {
        // No-op — the mixer manages the post-EQ buffer lifecycle
    }
}

class PostDynamicsStreamReader: FFTAudioSource {
    let deviceID: AudioDeviceID
    let name: String
    private let globalChannelIndex: Int32

    init?(deviceID: AudioDeviceID, channelIndex: Int, channelType: UInt32 = 0) {
        self.deviceID = deviceID
        let globalIdx = Mixer_GetGlobalChannelIndex(UInt32(deviceID), channelType, UInt32(channelIndex))
        guard globalIdx >= 0 else { return nil }
        self.globalChannelIndex = globalIdx
        self.name = String(cString: getDeviceName(deviceID))
    }

    func read(channel: Int, into outBuffer: inout [Float]) -> Int {
        return outBuffer.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return 0 }
            let read = Mixer_ReadPostDynamicsBuffer(UInt32(globalChannelIndex), base, Int32(ptr.count))
            return Int(read)
        }
    }

    func stop() throws {
    }
}
