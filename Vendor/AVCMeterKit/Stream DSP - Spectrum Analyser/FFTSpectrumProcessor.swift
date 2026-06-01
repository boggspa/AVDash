//
//  FFTSpectrumProcessor.swift
//  AVCMeter
//
//  Created by Chris Izatt on 28/06/2025.
//

import Foundation
import Combine
import Accelerate   // for vDSP FFTs

/// A “pure Swift” processor that
/// 1. reads raw audio samples from the ring buffer
/// 2. windows & overlaps
/// 3. runs an FFT
/// 4. min/max or decimates bands
/// 5. smooths / log-scales / thresholds
/// 6. publishes display-ready data
final class FFTSpectrumProcessor: ObservableObject {
    // Expose configuration to renderer
    let sampleRate: Float
    let fftSize: Int
    private let channelCount: Int
    // MARK: Inputs
    private let streamManager: FFTStreamManager   // your thin I/O wrapper
    private let deviceName: String = ""
    private let channelIndex: Int
    private let hopSize: Int
    private let window: [Float]

    // MARK: FFT Setup
    private let fftSetup: FFTSetup
    private var realp: [Float]
    private var imagp: [Float]

    // MARK: Published output
    @Published var magnitudes: [Float] = []
    @Published var normalizedMagnitudes: [Float] = []


    private var splitLogBinIndices: [[Int]] = []

    var previousMagnitudes: [Float]? = nil

    private var peakHoldValues: [Float] = []
    private var peakHoldTimers: [Int] = []

    init(streamManager: FFTStreamManager,
         channelIndex: Int,
         channelCount: Int,
         sampleRate: Float = 48000.0,
         fftSize: Int = 512,
         overlapFactor: Int = 64,             // 50% overlap => hop = fftSize/2
         smoothingFrames: Int = 64)
    {
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.streamManager = streamManager
        self.channelIndex = channelIndex
        self.hopSize = fftSize

        // Pre-compute your window (e.g. Blackman-Harris)
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_blkman_window(&window, vDSP_Length(fftSize), 0)
        self.window = window

        // Debug: inspect first few window coefficients
        print("FFTSpectrumProcessor validation: window[0..7] =", window.prefix(8).map { String(format: "%.3f", $0) })

        // FFT buffers
        let paddedSize = fftSize * 2
        self.fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(paddedSize))), FFTRadix(FFT_RADIX2))!
        self.realp = [Float](repeating: 0, count: paddedSize/2)
        self.imagp = [Float](repeating: 0, count: paddedSize/2)

        // Split log-frequency bins into low, mid, and high bands
        let totalDisplayBins = 512
        let binsLow = totalDisplayBins / 2
        let binsMid = totalDisplayBins / 4
        let binsHigh = totalDisplayBins / 4
        let binFreq = sampleRate / Float(fftSize)

        func logFrequencies(from: Float, to: Float, count: Int) -> [Float] {
            (0..<count).map { i in
                let t = Float(i) / Float(max(count - 1, 1))
                return from * pow(to / from, t)
            }
        }

        let freqsSub = (0..<512).map { i in
            return Float(i) * (20.0 / 513.0)
        }
        let freqsLow = logFrequencies(from: 21, to: 200, count: binsLow)
        let freqsMid = logFrequencies(from: 201, to: 2000, count: binsMid)
        let freqsHigh = logFrequencies(from: 2001, to: 20000, count: binsHigh)

        self.splitLogBinIndices = (freqsSub + freqsLow + freqsMid + freqsHigh).map { f in
            let center = Int(round(f / binFreq))
            let spread = max(1, Int(f / 48.0))
            let lower = max(0, center - spread / 2)
            let upper = min(fftSize/2 - 1, center + spread / 2)
            return Array(lower...upper)
        }
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Call this on a timer or audio-callback thread
    func tick() {
        // 1) Read hopSize samples from the ring buffer
        var buffer = [Float](repeating: 0, count: hopSize)
        let readCount = streamManager.read(
            channel: channelIndex,
            into: &buffer,
        )
        guard readCount == hopSize else { return }

        // 2) Build the overlapping windowed frame
        //    You could maintain a rolling `pendingSamples` array and shift/hop
        //    For simplicity here we assume `buffer` is already fftSize long
        let paddedSize = fftSize * 2
        var bufferVar = [Float](repeating: 0, count: fftSize)
        bufferVar[0..<buffer.count] = buffer[0..<buffer.count]

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP.multiply(bufferVar, window, result: &windowed)

        var paddedWindowed = [Float](repeating: 0, count: paddedSize)
        paddedWindowed[0..<fftSize] = windowed[0..<fftSize]

        // 3) Perform the FFT
        var splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)
        paddedWindowed.withUnsafeMutableBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize/2) { complexPtr in
                vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize/2))
            }
        }
        vDSP_fft_zrip(fftSetup,
                      &splitComplex,
                      1,
                      vDSP_Length(log2(Float(fftSize))),
                      FFTDirection(FFT_FORWARD))

        // 4) Compute magnitudes for the positive-frequency half
        var mags = [Float](repeating: 0, count: fftSize/2)
        vDSP.absolute(splitComplex,
                      result: &mags)

        // Compute peak amplitude and convert to dB
        if let peakAmplitude = mags.max() {
            let peakDB = 20 * log10(max(peakAmplitude, 1e-10)) - 46
            print("Peak dB:", peakDB)
        }

        // Apply A-weighting filter to magnitude spectrum
        let aWeighting = (0..<mags.count).map { i -> Float in
            let freq = Float(i) * sampleRate / Float(fftSize)
            let f2 = freq * freq
            let ra = (f2 * f2) / ((f2 + 20.6 * 20.6) * sqrt((f2 + 107.7 * 107.7) * (f2 + 737.9 * 737.9)) * (f2 + 12200 * 12200))
            return ra.isFinite ? sqrt(ra) : 0
        }
        vDSP.multiply(mags, aWeighting, result: &mags)

        // 5) Convert magnitude to decibels with fixed offset
        let dbFloor: Float = -150, dbCeil: Float = 1
        var dbValues = [Float](repeating: dbFloor, count: fftSize/2)
        for i in 0..<mags.count {
            let amplitude = mags[i]
            let db = 20 * log10(max(amplitude, 1e-12))
            dbValues[i] = min(max(db, dbFloor), dbCeil)
        }

        let kernel: [Float] = [0.25, 0.5, 0.25]
        var blurred = [Float](repeating: 0, count: dbValues.count)
        vDSP_conv(dbValues, 1, kernel, 1, &blurred, 1, vDSP_Length(blurred.count), vDSP_Length(kernel.count))
        dbValues = blurred

        // Apply a 12 dB/oct roll-off from 20 Hz to 50 Hz
        let rollOffStartHz: Float = 20
        let rollOffEndHz: Float = 50
        let rollOffSlope: Float = -48.0  // in dB per octave
        for i in 0..<dbValues.count {
            let freq = Float(i) * sampleRate / Float(fftSize)
            if freq >= rollOffStartHz && freq <= rollOffEndHz {
                let octaveRatio = log2(freq / rollOffStartHz)
                let attenuation = octaveRatio * abs(rollOffSlope)
                dbValues[i] -= attenuation
            }
        }

        if peakHoldValues.count != dbValues.count {
            peakHoldValues = dbValues
            peakHoldTimers = [Int](repeating: 0, count: dbValues.count)
        }

        for i in 0..<dbValues.count {
            if dbValues[i] >= peakHoldValues[i] {
                peakHoldValues[i] = dbValues[i]
                peakHoldTimers[i] = 2  // assuming 0.1s hold @ 60 FPS (or 0.05s timer → 2 ticks = 0.1s)
            } else if peakHoldTimers[i] > 0 {
                peakHoldTimers[i] -= 6
            } else {
                // Apply decay falloff
                let decayRate: Float = 10.0  // dB per tick
                peakHoldValues[i] = max(peakHoldValues[i] - decayRate, dbValues[i])
            }
        }

        DispatchQueue.main.async {
            self.magnitudes = self.peakHoldValues
        }
    }

    /// Starts the audio stream and registers for periodic FFT processing.
    func start(pollRate: TimeInterval = 0.05) {
        do {
            try streamManager.start()
        } catch {
            print("FFTSpectrumProcessor: Failed to start stream:", error)
        }
        FFTSpectrumProcessorRegistry.shared.register(self)
    }
}


final class FFTSpectrumProcessorRegistry {
    static let shared = FFTSpectrumProcessorRegistry()
    private var processors: [WeakRef<FFTSpectrumProcessor>] = []
    private var timer: Timer?

    private init() {
        let newTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tickAll()
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func register(_ processor: FFTSpectrumProcessor) {
        processors.append(WeakRef(value: processor))
    }

    private static var frameCount = 0
    private func tickAll() {
        processors = processors.filter { $0.value != nil }
        for ref in processors {
            ref.value?.tick()
            if let processor = ref.value, let previous = processor.previousMagnitudes {
                guard processor.magnitudes.count == previous.count else {
                    processor.previousMagnitudes = processor.magnitudes
                    continue
                }
                let alpha: Float = 0.1   // much smoother averaging
                let decayRate: Float = 0.5  // slower decay
                var smoothed = previous

                for i in 0..<processor.magnitudes.count {
                    let freq = Float(i) * processor.sampleRate / Float(processor.fftSize)

                    let shouldUpdate: Bool
                    if freq < 200 {
                        shouldUpdate = true  // update every frame
                    } else if freq < 2000 {
                        shouldUpdate = FFTSpectrumProcessorRegistry.frameCount % 3 == 0
                    } else {
                        shouldUpdate = FFTSpectrumProcessorRegistry.frameCount % 6 == 0
                    }

                    if shouldUpdate {
                        let newValue = processor.magnitudes[i]
                        let oldValue = previous[i]
                        if newValue > oldValue {
                            smoothed[i] = newValue
                        } else {
                            smoothed[i] = max(oldValue - decayRate, newValue)
                        }
                        smoothed[i] = alpha * smoothed[i] + (1.0 - alpha) * oldValue
                    } else {
                        smoothed[i] = previous[i]
                    }
                }

                processor.magnitudes = smoothed
                processor.previousMagnitudes = smoothed

                let minDB: Float = -60
                let maxDB: Float = 15
                let range = maxDB - minDB
                processor.normalizedMagnitudes = processor.magnitudes.map { db in
                    return max(0.0, min(1.0, (db - minDB) / range))
                }
            } else {
                ref.value?.previousMagnitudes = ref.value?.magnitudes
            }
        }
        FFTSpectrumProcessorRegistry.frameCount += 1
    }

    private struct WeakRef<T: AnyObject> {
        weak var value: T?
    }
}
