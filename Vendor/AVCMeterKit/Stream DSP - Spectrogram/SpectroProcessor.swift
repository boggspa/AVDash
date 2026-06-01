//
// SpectroProcessor.swift
// Real-time FFT-based spectral analysis for audio input streams
//
//  SpectroProcessor.swift
//  AVCMeter
//
//  Created by Chris Izatt on 29/06/2025.
//

import Foundation

import Accelerate
import QuartzCore

/// Converts an array of FFT magnitudes to decibel (dB) values.
///
/// - Parameters:
///   - magnitudes: Array of squared magnitudes (output from `vDSP_zvmags`)
///   - fftSize: FFT size used for normalization
/// - Returns: Array of decibel values, normalized relative to FFT size
func convertMagnitudesToDecibels(_ magnitudes: [Float], fftSize: Int32, peakLevel: Float = 1.0) -> [Float] {
    let scale = 2.0 / Float(fftSize)  // Apply FFT normalization + energy correction for one-sided spectrum
    var scaledMagnitudes = magnitudes

    // Normalize by peak level to prevent clipping from hot input signals
    let normalizedScale = scale / max(peakLevel, 0.001)
    vDSP_vsmul(magnitudes, 1, [normalizedScale], &scaledMagnitudes, 1, vDSP_Length(magnitudes.count))

    var dbMagnitudes = [Float](repeating: -200.0, count: magnitudes.count)
    var zero: Float = 1e-10

    vDSP_vdbcon(scaledMagnitudes, 1, &zero, &dbMagnitudes, 1, vDSP_Length(magnitudes.count), 0)
    return dbMagnitudes
}

// SpectroProcessor: Handles per-channel FFT analysis and normalization

/// Performs FFT-based spectral analysis on audio input buffers for a specific device.
///
/// This struct encapsulates the configuration and processing logic required to convert
/// time-domain audio samples into normalized spectral magnitudes suitable for visualization or further analysis.
///
/// - Note: Designed to be instantiated per audio device with a configurable FFT size.
class SpectroProcessor {
    /// Unique identifier for the audio device.
    let deviceID: Int32
    /// Number of samples used for FFT processing.
    let fftSize: Int

    /// FFT configuration and windowing cache.
    private var fftSetup: FFTSetup?
    /// Precomputed Hann window for tapering input samples.
    private var window: [Float]

    /// Pre-allocated working buffers to avoid allocation churn
    private var centeredBuffer: [Float]
    private var realBuffer: [Float]
    private var imagBuffer: [Float]
    private var windowedBuffer: [Float]
    private var magnitudesBuffer: [Float]

    /// Sample accumulation buffer — collects HAL callback frames until a full FFT window is ready
    private var accumulationBuffer: [Float]
    private var accumulatedCount: Int = 0

    /// Track peak magnitude for automatic gain control
    private var peakMagnitude: Float = 0.001
    private var peakSmoothingFactor: Float = 0.95  // Exponential moving average

    /// Input gain reduction (attenuation) to prevent hot FFT magnitudes
    private let inputGain: Float = 0.0000000008  // Reduce signal amplitude before FFT

    /// Initializes a new SpectroProcessor with the given device ID and FFT size.
    ///
    /// - Parameters:
    ///   - deviceID: Unique identifier for the audio device.
    ///   - fftSize: Number of samples for FFT; must be a power of two. Defaults to 1024.
    ///
    /// - Discussion:
    ///   Sets up the FFT configuration and precomputes the Hann window to optimize repeated processing.
    ///   Also pre-allocates all working buffers to eliminate allocation overhead on every frame.
    init(deviceID: Int32, fftSize: Int = 1024) {
        self.deviceID = deviceID
        self.fftSize = fftSize
        self.fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(fftSize))), FFTRadix(kFFTRadix2))
        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // Pre-allocate working buffers once
        self.centeredBuffer = [Float](repeating: 0, count: fftSize)
        self.realBuffer = [Float](repeating: 0, count: fftSize / 2)
        self.imagBuffer = [Float](repeating: 0, count: fftSize / 2)
        self.windowedBuffer = [Float](repeating: 0, count: fftSize)
        self.magnitudesBuffer = [Float](repeating: 0, count: fftSize / 2)
        self.accumulationBuffer = [Float](repeating: 0, count: fftSize)
    }

    /// Timestamp of the last spectrogram buffer write, initialized to current time
    private var lastSpectrogramWrite: CFTimeInterval = CACurrentMediaTime()
    /// Minimum interval between spectrogram writes (in seconds), target ~30 FPS
    private let spectrogramWriteInterval: CFTimeInterval = 1.0 / 30.0

    /// Processes a single channel of audio samples to produce normalized spectral magnitudes.
    ///
    /// - Parameters:
    ///   - channel: The channel index of the audio input.
    ///   - inputPtr: Pointer to Float samples representing the audio buffer. Must have `fftSize` samples.
    ///   - count: Number of samples in the input buffer.
    ///
    /// - Discussion:
    ///   This method performs several processing steps:
    ///   1. Validates input length.
    ///   2. Removes DC offset from the input samples.
    ///   3. Applies a Hann window to reduce spectral leakage.
    ///   4. Computes the FFT of the windowed samples.
    ///   5. Calculates magnitudes and normalizes them.
    ///   6. Clips and compresses the magnitudes into a [0,1] range.
    ///   7. Writes the processed spectral data to a shared manager for visualization or further use.
    func process(channel: Int32, inputPtr: UnsafePointer<Float>, count: Int) {
        // Accumulate samples across HAL callbacks until we have a full FFT window.
        // This decouples the FFT size from the hardware buffer size.
        let toCopy = min(count, fftSize - accumulatedCount)
        accumulationBuffer.withUnsafeMutableBufferPointer { buf in
            (buf.baseAddress! + accumulatedCount).initialize(from: inputPtr, count: toCopy)
        }
        accumulatedCount += toCopy
        guard accumulatedCount >= fftSize else { return }
        accumulatedCount = 0

        // Remove DC offset
        var mean: Float = 0
        accumulationBuffer.withUnsafeBufferPointer { src in
            vDSP_meanv(src.baseAddress!, 1, &mean, vDSP_Length(fftSize))
            vDSP_vsadd(src.baseAddress!, 1, [-mean], &centeredBuffer, 1, vDSP_Length(fftSize))
        }

        // Apply input gain reduction to prevent hot FFT magnitudes
        vDSP_vsmul(centeredBuffer, 1, [inputGain], &centeredBuffer, 1, vDSP_Length(fftSize))

        var real = realBuffer
        var imag = imagBuffer
        var splitComplex = DSPSplitComplex(realp: &real, imagp: &imag)

        // Apply Hann window
        vDSP_vmul(centeredBuffer, 1, window, 1, &windowedBuffer, 1, vDSP_Length(fftSize))

        windowedBuffer.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                vDSP_ctoz(complexPtr, 1, &splitComplex, 1, vDSP_Length(fftSize / 2))
            }
        }

        // Perform FFT
        vDSP_fft_zrip(fftSetup!, &splitComplex, 1, vDSP_Length(log2(Float(fftSize))), FFTDirection(FFT_FORWARD))

        // Compute magnitudes
        vDSP_zvmags(&splitComplex, 1, &magnitudesBuffer, 1, vDSP_Length(fftSize / 2))

        // Track peak magnitude for automatic gain control
        var currentPeak: Float = 0
        vDSP_maxv(magnitudesBuffer, 1, &currentPeak, vDSP_Length(magnitudesBuffer.count))
        peakMagnitude = peakSmoothingFactor * peakMagnitude + (1.0 - peakSmoothingFactor) * currentPeak

        // Use unified FFT scaling from local function for safe conversion
        let vis = VisualisationSettings.shared
        let activeThresholdDB = vis.spectrogramThresholdDB
        let activeGate = vis.spectrogramGate
        let activePowerCurve = vis.spectrogramPowerCurve
        let activeGainTrim = vis.spectrogramGainTrimDB

        var dbMagnitudes = convertMagnitudesToDecibels(magnitudesBuffer, fftSize: Int32(fftSize), peakLevel: peakMagnitude)
        if activeGainTrim != 0 {
            for i in 0..<dbMagnitudes.count {
                dbMagnitudes[i] += activeGainTrim
            }
        }
        let clamped = dbMagnitudes.map { min(max($0, activeThresholdDB), 0.0) }
        let normalized = clamped.map { ($0 - activeThresholdDB) / abs(activeThresholdDB) }
        let compressed = normalized.map { value -> Float in
            let gated = max(0.0, (value - activeGate) / max(1.0 - activeGate, 0.001))
            return pow(gated, activePowerCurve)
        }

        // Write FFT frame
        SpectroManager.shared.writeFFTFrame(
            deviceID: deviceID,
            channel: channel,
            magnitudes: compressed
        )

        // Throttle spectrogram writes to ~30 FPS
        let now = CACurrentMediaTime()
        guard now - lastSpectrogramWrite >= spectrogramWriteInterval else { return }
        lastSpectrogramWrite = now

        // Ensure history ring buffer exists
        if SpectroManager.shared.historyRingBuffer(for: deviceID, channel: channel) == nil {
            let numBins = compressed.count
            let numFrames = SpectroManager.spectrogramHistoryFrames
            if let bufHist = SpectroManager.shared.createHistoryRingBuffer(numBins: numBins, numFrames: numFrames) {
                SpectroManager.shared.registerHistoryBuffer(bufHist, for: deviceID, channel: channel)
            }
        }

        guard let historyBufPointer = SpectroManager.shared.historyRingBuffer(for: deviceID, channel: channel) else {
            return
        }

        // Write to history buffer
        SpectroManager.shared.writeHistoryFrame(
            historyBufPointer,
            magnitudes: compressed
        )
    }
}

/// C callback entry point for handling incoming audio buffers.
/// - Parameters:
///   - deviceID: Unique device identifier.
///   - channel: Channel index.
///   - windowedBuffer: Pointer to input samples (already windowed).
///   - frameCount: Number of frames in the buffer.
@_cdecl("SpectroProcessor_HandleInput")
public func SpectroProcessor_HandleInput(_ deviceID: Int32, _ channel: Int32, _ inputPtr: UnsafePointer<Float>, _ frameCount: Int32) {
    guard SpectroManager.shared.isSpectrogramChannelActive(deviceID: UInt32(deviceID), channel: channel) else {
        return
    }
    // Pass pointer directly - no array allocation
    let processor = SpectroProcessorManager.shared.processor(for: deviceID, frameCount: frameCount)
    processor.process(channel: channel, inputPtr: inputPtr, count: Int(frameCount))
}

@_cdecl("SpectroProcessor_ShouldProcessChannel")
public func SpectroProcessor_ShouldProcessChannel(_ deviceID: Int32, _ channel: Int32) -> Int32 {
    SpectroManager.shared.isSpectrogramChannelActive(deviceID: UInt32(deviceID), channel: channel) ? 1 : 0
}

// SpectroProcessorManager: Manages FFT processors per deviceID

/// Singleton manager responsible for caching and providing SpectroProcessor instances.
///
/// Maintains a cache of processors keyed by device ID to avoid redundant initialization.
/// Provides thread-safe access to processors, lazily creating them as needed.
final class SpectroProcessorManager {
    /// Shared singleton instance.
    static let shared = SpectroProcessorManager()
    /// Cache mapping device IDs to their corresponding SpectroProcessor instances.
    private var processors: [Int32: SpectroProcessor] = [:]

    /// Retrieves the SpectroProcessor for a given device ID and frame count.
    /// - Parameters:
    ///   - deviceID: Unique identifier for the audio device.
    ///   - frameCount: Number of frames to configure the FFT size.
    /// - Returns: An initialized SpectroProcessor configured for the specified device and frame count.
    ///
    /// - Discussion:
    ///   If a processor for the given device ID exists, it is returned. Otherwise, a new processor
    ///   is created with the specified frame count as the FFT size, cached, and returned.
    func processor(for deviceID: Int32, frameCount: Int32) -> SpectroProcessor {
        if let existing = processors[deviceID] {
            return existing
        } else {
            // Use the same FFT size as the spectrum analyser for consistent bin density.
            // The accumulation buffer in SpectroProcessor handles any HAL frame size.
            let fftSize = VisualisationSettings.shared.spectrumFFTSize
            let newProcessor = SpectroProcessor(deviceID: deviceID, fftSize: fftSize)
            processors[deviceID] = newProcessor
            return newProcessor
        }
    }
}
