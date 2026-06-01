///
///  SystemAudioCaptureManager.swift
///  AVCMeter
///
///  Manages system audio capture via ScreenCaptureKit (macOS 13+).
///  Captures system audio output using SCStream and feeds into
///  lock-free ring buffers for metering, FFT, spectrogram, and waveform analysis.
///

import Foundation
import ScreenCaptureKit
import CoreAudio
import Combine

/// Unique device ID for system audio capture (distinct from real audio devices)
let systemAudioDeviceID: AudioDeviceID = 888_888

/// Manages system audio capture session and metering pipeline
@MainActor
final class SystemAudioCaptureManager: NSObject, ObservableObject {
    static let shared = SystemAudioCaptureManager()

    enum CaptureStatus: String {
        case idle = "Idle"
        case starting = "Starting..."
        case capturing = "Capturing"
        case permissionNeeded = "Permission Needed"
        case error = "Error"
        case unsupported = "Unsupported (macOS 13+ required)"
    }

    @Published private(set) var status: CaptureStatus = .idle
    @Published private(set) var isCapturing: Bool = false
    @Published private(set) var channelCount: Int = 2
    @Published private(set) var sampleRate: Double = 48_000
    @Published private(set) var errorMessage: String?

    /// DeviceMeteringContext for integration with the metering pipeline
    private var meteringContext: DeviceMeteringContext?

    /// Ring buffer for FFT/Spectrogram/Waveform analysis (interleaved stereo)
    // nonisolated(unsafe) because the underlying C ring buffer has mutex protection
    nonisolated(unsafe) private var analysisRingBuffer: OpaquePointer?

    /// SCStream capture session (stored as Any to avoid @available on stored property)
    private var stream: Any?
    private var streamQueue = DispatchQueue(label: "com.avcmeter.systemaudio", qos: .userInitiated)

    /// Scratch buffer for interleaved PCM conversion
    private var analysisScratch = SystemAudioAnalysisScratch()

    /// System audio device info
    private var systemOutputDeviceID: AudioDeviceID = kAudioObjectUnknown

    private var cancellables = Set<AnyCancellable>()

    var isSupported: Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }

    var canCapture: Bool {
        guard isSupported else { return false }
        return CGPreflightScreenCaptureAccess()
    }

    var statusText: String {
        switch status {
        case .idle:
            return "System audio capture idle"
        case .starting:
            return "Starting system audio capture..."
        case .capturing:
            return "Capturing \(channelCount) channels @ \(Int(sampleRate)) Hz"
        case .permissionNeeded:
            return "Screen recording permission required"
        case .error:
            return errorMessage ?? "Capture error"
        case .unsupported:
            return "Requires macOS 13 or later"
        }
    }

    private override init() {
        super.init()
        setupDefaultChannelCountAndSampleRate()
    }

    /// Query current system default output device for channel count and sample rate
    private func setupDefaultChannelCountAndSampleRate() {
        var deviceID = kAudioObjectUnknown
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceID
        )

        guard result == noErr && deviceID != kAudioObjectUnknown else {
            // Fallback to stereo 48kHz
            channelCount = 2
            sampleRate = 48_000
            return
        }

        systemOutputDeviceID = deviceID

        // Get channel count
        var streamConfigAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        propertySize = 0
        _ = AudioObjectGetPropertyDataSize(deviceID, &streamConfigAddress, 0, nil, &propertySize)

        if propertySize > 0 {
            let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferList.deallocate() }
            if AudioObjectGetPropertyData(deviceID, &streamConfigAddress, 0, nil, &propertySize, bufferList) == noErr {
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                var totalChannels: UInt32 = 0
                for buffer in buffers {
                    totalChannels += buffer.mNumberChannels
                }
                // Screen Capture Kit typically provides stereo, but we'll respect the device
                channelCount = max(2, Int(totalChannels))
            }
        }

        // Get sample rate
        var sampleRateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sr: Double = 48_000
        propertySize = UInt32(MemoryLayout<Double>.size)
        if AudioObjectGetPropertyData(deviceID, &sampleRateAddress, 0, nil, &propertySize, &sr) == noErr {
            sampleRate = sr
        }
    }

    /// Start system audio capture
    func startCapture() {
        guard isSupported else {
            status = .unsupported
            return
        }

        guard CGPreflightScreenCaptureAccess() else {
            status = .permissionNeeded
            return
        }

        guard !isCapturing else { return }

        status = .starting
        errorMessage = nil

        // Refresh device info before starting
        setupDefaultChannelCountAndSampleRate()

        // Create DeviceMeteringContext for integration with metering pipeline
        meteringContext = ensureSystemAudioMeteringContext()

        // Create ring buffers
        setupRingBuffers()

        // Update SystemAudioSource cached values
        SystemAudioSource.shared.updateCachedValues()

        // Start SCStream capture (macOS 13.0+)
        if #available(macOS 13.0, *) {
            startSCStream()
        }
    }

    /// Request screen capture permission (triggers system prompt)
    func requestPermission() {
        // This triggers the system permission prompt
        CGRequestScreenCaptureAccess()
    }

    /// Open System Preferences to Screen Recording settings
    func openSystemPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Create or retrieve the DeviceMeteringContext for system audio
    private func ensureSystemAudioMeteringContext() -> DeviceMeteringContext {
        let manager = AudioDeviceManager.shared

        if let existing = manager.activeDevices[systemAudioDeviceID],
           Int(existing.device.inputChannels) == channelCount {
            manager.selectedChannelMasks[systemAudioDeviceID] = Array(repeating: true, count: channelCount)
            MultiDeviceStreamManager.shared.channelMaskCache[systemAudioDeviceID] = Array(repeating: true, count: channelCount)
            return existing
        }

        let systemAudioDevice = AudioDevice(
            deviceID: systemAudioDeviceID,
            name: "System Audio",
            inputChannels: UInt32(channelCount),
            outputChannels: 0,
            sampleRate: sampleRate,
            transportType: "virtual"
        )
        let handler = LevelHandler()
        handler.manager = manager
        let context = DeviceMeteringContext(device: systemAudioDevice, handler: handler)

        manager.activeDevices[systemAudioDeviceID] = context
        manager.selectedChannelMasks[systemAudioDeviceID] = Array(repeating: true, count: channelCount)
        MultiDeviceStreamManager.shared.channelMaskCache[systemAudioDeviceID] = Array(repeating: true, count: channelCount)
        return context
    }

    /// Stop system audio capture
    func stopCapture() {
        if #available(macOS 13.0, *) {
            (stream as? SCStream)?.stopCapture { _ in }
        }
        stream = nil
        isCapturing = false
        status = .idle

        // Remove DeviceMeteringContext from AudioDeviceManager
        let manager = AudioDeviceManager.shared
        manager.activeDevices.removeValue(forKey: systemAudioDeviceID)
        manager.selectedChannelMasks.removeValue(forKey: systemAudioDeviceID)
        MultiDeviceStreamManager.shared.channelMaskCache.removeValue(forKey: systemAudioDeviceID)
        meteringContext = nil

        destroyRingBuffers()
        SystemAudioSource.shared.updateCachedValues()
    }

    private func setupRingBuffers() {
        destroyRingBuffers()

        // Analysis buffer - interleaved for FFT/waveform (limit to stereo for analysis)
        let analysisChannels = min(channelCount, 2)
        analysisRingBuffer = RingBuffer_Create(65536, Int32(analysisChannels))
    }

    private func destroyRingBuffers() {
        if let analysisRingBuffer {
            RingBuffer_Destroy(analysisRingBuffer)
        }
        analysisRingBuffer = nil
    }

    @available(macOS 13.0, *)
    private func startSCStream() {
        SCShareableContent.getWithCompletionHandler { [weak self] shareableContent, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    // Check if error is permission-related
                    let errorDesc = error.localizedDescription.lowercased()
                    if errorDesc.contains("permission") || errorDesc.contains("denied") || errorDesc.contains("unauthorized") {
                        self.status = .permissionNeeded
                        self.errorMessage = "Screen recording permission required"
                    } else {
                        self.status = .error
                        self.errorMessage = "Failed to get shareable content: \(error.localizedDescription)"
                    }
                }
                return
            }

            guard let display = shareableContent?.displays.first else {
                DispatchQueue.main.async {
                    self.status = .error
                    self.errorMessage = "No display available for capture"
                }
                return
            }

            // Capture system mix (all audio)
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 2
            configuration.showsCursor = false
            configuration.capturesAudio = true
            configuration.sampleRate = Int(sampleRate)
            configuration.channelCount = channelCount
            configuration.excludesCurrentProcessAudio = false

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            self.stream = stream as Any

            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.streamQueue)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.streamQueue)
            } catch {
                DispatchQueue.main.async {
                    self.status = .error
                    self.errorMessage = "Failed to add stream output: \(error.localizedDescription)"
                }
                return
            }

            stream.startCapture { [weak self] error in
                DispatchQueue.main.async {
                    if let error = error {
                        let errorDesc = error.localizedDescription.lowercased()
                        if errorDesc.contains("permission") || errorDesc.contains("denied") || errorDesc.contains("unauthorized") {
                            self?.status = .permissionNeeded
                            self?.errorMessage = "Screen recording permission required. Please enable in System Preferences > Security & Privacy > Screen Recording."
                        } else {
                            self?.status = .error
                            self?.errorMessage = "Capture start failed: \(error.localizedDescription)"
                        }
                        self?.isCapturing = false
                    } else {
                        self?.status = .capturing
                        self?.isCapturing = true
                    }
                }
            }
        }
    }

    /// Get the most recent peak value for a channel
    func peak(for channel: Int) -> Float {
        guard let context = meteringContext,
              channel < channelCount else { return 0.0 }
        return context.peakBuffer.max(for: channel)
    }

    /// Get the most recent RMS value for a channel
    func rms(for channel: Int) -> Float {
        guard let context = meteringContext,
              channel < channelCount else { return 0.0 }
        return context.rmsBuffer.average(for: channel)
    }

    /// Get the analysis ring buffer handle for FFT/spectrogram/waveform
    var analysisBufferHandle: OpaquePointer? {
        analysisRingBuffer
    }

    /// Read interleaved samples from the analysis ring buffer (nonisolated for thread-safe access from visualization threads)
    nonisolated func readAnalysisInterleaved(_ data: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        guard let analysisRingBuffer = self.analysisRingBuffer else { return 0 }
        return Int(RingBuffer_ReadAllInterleaved(analysisRingBuffer, data, frameCount))
    }
}

// MARK: - SCStreamOutput & SCStreamDelegate

@available(macOS 13.0, *)
extension SystemAudioCaptureManager: SCStreamOutput, SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            // Ignore video frames
            return
        case .audio:
            // Process on main actor
            Task { @MainActor in
                self.processAudioSampleBuffer(sampleBuffer)
            }
        default:
            return
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.status = .error
            self?.errorMessage = "Stream stopped: \(error.localizedDescription)"
            self?.isCapturing = false
            self?.stream = nil
        }
    }

    private func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }

        let asbd = asbdPointer.pointee
        let bufferChannelCount = Int(asbd.mChannelsPerFrame)

        // Get audio buffer list
        let listSize = MemoryLayout<AudioBufferList>.size + max(0, bufferChannelCount - 1) * MemoryLayout<AudioBuffer>.size
        let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPointer.deallocate() }

        let audioBufferListPointer = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPointer,
            bufferListSize: listSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return }

        // Process audio data
        let audioBuffers = UnsafeMutableAudioBufferListPointer(audioBufferListPointer)
        processAudioBuffers(audioBuffers, format: asbd)
    }

    private func processAudioBuffers(_ audioBuffers: UnsafeMutableAudioBufferListPointer, format: AudioStreamBasicDescription) {
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let bitsPerChannel = Int(format.mBitsPerChannel)
        let channels = Int(format.mChannelsPerFrame)

        guard channels > 0 else { return }

        // Calculate peak/RMS per channel
        var channelPeaks = [Float](repeating: 0.0, count: channels)
        var channelRMS = [Float](repeating: 0.0, count: channels)
        var channelSampleCounts = [Int](repeating: 0, count: channels)

        // Extract samples based on format
        if format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            // Non-interleaved: separate buffers per channel
            for ch in 0..<min(channels, audioBuffers.count) {
                let buffer = audioBuffers[ch]
                guard let data = buffer.mData else { continue }

                let frameCount = Int(buffer.mDataByteSize) / ((bitsPerChannel + 7) / 8)

                if isFloat && bitsPerChannel == 32 {
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for i in 0..<frameCount {
                        let sample = abs(samples[i])
                        channelPeaks[ch] = max(channelPeaks[ch], sample)
                        channelRMS[ch] += sample * sample
                        channelSampleCounts[ch] += 1
                    }
                } else if isSignedInteger && bitsPerChannel == 16 {
                    let samples = data.assumingMemoryBound(to: Int16.self)
                    let scale = 1.0 / Float(Int16.max)
                    for i in 0..<frameCount {
                        let sample = abs(Float(samples[i]) * scale)
                        channelPeaks[ch] = max(channelPeaks[ch], sample)
                        channelRMS[ch] += sample * sample
                        channelSampleCounts[ch] += 1
                    }
                }
            }
        } else {
            // Interleaved: single buffer with alternating channel samples
            guard let buffer = audioBuffers.first,
                  let data = buffer.mData else { return }

            let bytesPerSample = (bitsPerChannel + 7) / 8
            let frameCount = Int(buffer.mDataByteSize) / (bytesPerSample * channels)

            if isFloat && bitsPerChannel == 32 {
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frameCount {
                    for ch in 0..<channels {
                        let idx = frame * channels + ch
                        let sample = abs(samples[idx])
                        channelPeaks[ch] = max(channelPeaks[ch], sample)
                        channelRMS[ch] += sample * sample
                        channelSampleCounts[ch] += 1
                    }
                }
            } else if isSignedInteger && bitsPerChannel == 16 {
                let samples = data.assumingMemoryBound(to: Int16.self)
                let scale = 1.0 / Float(Int16.max)
                for frame in 0..<frameCount {
                    for ch in 0..<channels {
                        let idx = frame * channels + ch
                        let sample = abs(Float(samples[idx]) * scale)
                        channelPeaks[ch] = max(channelPeaks[ch], sample)
                        channelRMS[ch] += sample * sample
                        channelSampleCounts[ch] += 1
                    }
                }
            }
        }

        // Calculate final RMS and write to ring buffers
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            for ch in 0..<min(channels, self.channelCount) {
                let count = channelSampleCounts[ch]
                if count > 0 {
                    let rms = sqrt(channelRMS[ch] / Float(count))
                    // Write to DeviceMeteringContext ring buffers
                    if let context = self.meteringContext {
                        context.peakBuffer.write(toGlobalChannelID: ch, value: channelPeaks[ch])
                        context.rmsBuffer.write(toGlobalChannelID: ch, value: rms)
                    }
                }
            }
        }

        // Write interleaved data to analysis ring buffer for FFT/waveform
        writeToAnalysisRingBuffer(audioBuffers, format: format)
    }

    private func writeToAnalysisRingBuffer(_ audioBuffers: UnsafeMutableAudioBufferListPointer, format: AudioStreamBasicDescription) {
        guard let analysisRingBuffer = self.analysisRingBuffer else { return }

        let channels = Int(format.mChannelsPerFrame)
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let bitsPerChannel = Int(format.mBitsPerChannel)

        // Limit to stereo for analysis
        let analysisChannels = min(channels, 2)

        analysisScratch.interleaved.removeAll(keepingCapacity: true)

        if format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            // Non-interleaved - interleave for analysis
            guard audioBuffers.count >= analysisChannels else { return }

            let leftBuffer = audioBuffers[0]
            let rightBuffer = analysisChannels > 1 ? audioBuffers[1] : audioBuffers[0]

            guard let leftData = leftBuffer.mData,
                  let rightData = rightBuffer.mData else { return }

            if isFloat && bitsPerChannel == 32 {
                let leftSamples = leftData.assumingMemoryBound(to: Float.self)
                let rightSamples = rightData.assumingMemoryBound(to: Float.self)
                let frames = min(
                    Int(leftBuffer.mDataByteSize) / MemoryLayout<Float>.size,
                    Int(rightBuffer.mDataByteSize) / MemoryLayout<Float>.size
                )
                guard frames > 0 else { return }

                if analysisScratch.interleaved.capacity < frames * 2 {
                    analysisScratch.interleaved.reserveCapacity(frames * 2)
                }
                for i in 0..<frames {
                    analysisScratch.interleaved.append(leftSamples[i])
                    analysisScratch.interleaved.append(rightSamples[i])
                }
            } else if isSignedInteger && bitsPerChannel == 16 {
                let leftSamples = leftData.assumingMemoryBound(to: Int16.self)
                let rightSamples = rightData.assumingMemoryBound(to: Int16.self)
                let frames = min(
                    Int(leftBuffer.mDataByteSize) / MemoryLayout<Int16>.size,
                    Int(rightBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                )
                guard frames > 0 else { return }

                let scale = 1.0 / Float(Int16.max)
                if analysisScratch.interleaved.capacity < frames * 2 {
                    analysisScratch.interleaved.reserveCapacity(frames * 2)
                }
                for i in 0..<frames {
                    analysisScratch.interleaved.append(Float(leftSamples[i]) * scale)
                    analysisScratch.interleaved.append(Float(rightSamples[i]) * scale)
                }
            } else {
                return
            }
        } else {
            // Already interleaved - extract first two channels
            guard let buffer = audioBuffers.first,
                  let data = buffer.mData else { return }

            if isFloat && bitsPerChannel == 32 {
                let samples = data.assumingMemoryBound(to: Float.self)
                let frames = Int(buffer.mDataByteSize) / max(MemoryLayout<Float>.size * channels, 1)
                guard frames > 0 else { return }

                if analysisScratch.interleaved.capacity < frames * 2 {
                    analysisScratch.interleaved.reserveCapacity(frames * 2)
                }

                if channels == 1 {
                    // Mono - duplicate to stereo
                    for i in 0..<frames {
                        let s = samples[i]
                        analysisScratch.interleaved.append(s)
                        analysisScratch.interleaved.append(s)
                    }
                } else {
                    // Stereo or more - extract first two channels
                    for i in 0..<frames {
                        analysisScratch.interleaved.append(samples[i * channels])
                        analysisScratch.interleaved.append(samples[i * channels + 1])
                    }
                }
            } else if isSignedInteger && bitsPerChannel == 16 {
                let samples = data.assumingMemoryBound(to: Int16.self)
                let frames = Int(buffer.mDataByteSize) / max(MemoryLayout<Int16>.size * channels, 1)
                guard frames > 0 else { return }

                let scale = 1.0 / Float(Int16.max)
                if analysisScratch.interleaved.capacity < frames * 2 {
                    analysisScratch.interleaved.reserveCapacity(frames * 2)
                }

                if channels == 1 {
                    for i in 0..<frames {
                        let s = Float(samples[i]) * scale
                        analysisScratch.interleaved.append(s)
                        analysisScratch.interleaved.append(s)
                    }
                } else {
                    for i in 0..<frames {
                        analysisScratch.interleaved.append(Float(samples[i * channels]) * scale)
                        analysisScratch.interleaved.append(Float(samples[i * channels + 1]) * scale)
                    }
                }
            } else {
                return
            }
        }

        // Write to ring buffer
        let frameCount = analysisScratch.interleaved.count / 2
        guard frameCount > 0 else { return }

        analysisScratch.interleaved.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            RingBuffer_WriteInterleaved(analysisRingBuffer, base, frameCount, 2)
        }
    }
}

/// Scratch buffer for interleaved PCM analysis data
private final class SystemAudioAnalysisScratch {
    var interleaved = ContiguousArray<Float>()
}

// MARK: - RingBuffer C Interface

@_silgen_name("RingBuffer_Create")
func RingBuffer_Create(_ capacity: Int32, _ channels: Int32) -> OpaquePointer?

@_silgen_name("RingBuffer_Destroy")
func RingBuffer_Destroy(_ buffer: OpaquePointer?)

@_silgen_name("RingBuffer_WriteInterleaved")
func RingBuffer_WriteInterleaved(_ buffer: OpaquePointer?, _ data: UnsafePointer<Float>, _ frameCount: Int, _ channels: Int32)

@_silgen_name("RingBuffer_ReadAllInterleaved")
func RingBuffer_ReadAllInterleaved(_ buffer: OpaquePointer?, _ data: UnsafeMutablePointer<Float>, _ frameCount: Int) -> Int32
