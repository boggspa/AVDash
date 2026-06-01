import Foundation
import Combine
import Accelerate
import CoreAudio

/// Protocol for audio stream sources that can provide samples for FFT analysis.
protocol FFTAudioSource: AnyObject {
    var deviceID: AudioDeviceID { get }
    var name: String { get }
    func read(channel: Int, into outBuffer: inout [Float]) -> Int
    func stop() throws
}

extension FFTStreamManager: FFTAudioSource {
    var name: String {
        return String(cString: getDeviceName(deviceID))
    }
}

final class SafeFFTSpectrumProcessor: ObservableObject {
    let sampleRate: Float
    let fftSize: Int
    let deviceName: String
    let channelIndex: Int
    private let hopSize: Int
    private let paddedSize: Int

    private let streamManager: FFTAudioSource
    private let window: [Float]
    private let fftSetup: FFTSetup

    // Preallocated buffers for reuse (avoid allocations on every tick)
    private var realp: [Float]
    private var imagp: [Float]
    private var inputBuffer: [Float]
    private var windowedBuffer: [Float]
    private var paddedWindowed: [Float]
    private var peakHoldValues: [Float]
    private var peakHoldTimers: [Int]

    // Additional buffers for tick() processing (pre-allocated to avoid churn at 60Hz)
    private var magsBuffer: [Float]
    private var dbValuesBuffer: [Float]
    private var blurredBuffer: [Float]
    private var aWeightingBuffer: [Float]
    private var splitLogBinIndices: [[Int]] = []

    @Published fileprivate(set) var magnitudes: [Float] = []
    @Published fileprivate(set) var normalizedMagnitudes: [Float] = []

    var previousMagnitudes: [Float]? = nil
    var isActive: Bool = true
    private var isRegistered = false

    init(streamManager: FFTAudioSource,
         channelIndex: Int,
         channelCount: Int,
         sampleRate: Float = 48000.0,
         fftSize: Int = 512,
         scale: CGFloat = 1.0) {

        self.streamManager = streamManager
        self.channelIndex = channelIndex
        self.deviceName = streamManager.name
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.hopSize = fftSize
        let scaleInt = Int(scale)
        self.paddedSize = fftSize * 2 * scaleInt

        self.window = {
            var w = [Float](repeating: 0, count: fftSize)
            vDSP_blkman_window(&w, vDSP_Length(fftSize), 0)
            return w
        }()

        self.fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(fftSize))), FFTRadix(FFT_RADIX2))!
        self.realp = [Float](repeating: 0, count: fftSize / 2)
        self.imagp = [Float](repeating: 0, count: fftSize / 2)
        self.inputBuffer = [Float](repeating: 0, count: fftSize)
        self.windowedBuffer = [Float](repeating: 0, count: fftSize)
        self.paddedWindowed = [Float](repeating: 0, count: paddedSize)
        self.peakHoldValues = [Float](repeating: -150, count: fftSize / 2)
        self.peakHoldTimers = [Int](repeating: 0, count: fftSize / 2)

        // Pre-allocate buffers for tick() processing (runs at 60Hz, no allocation churn)
        self.magsBuffer = [Float](repeating: 0, count: fftSize / 2)
        self.dbValuesBuffer = [Float](repeating: -150, count: fftSize / 2)
        self.blurredBuffer = [Float](repeating: 0, count: fftSize / 2)
        self.aWeightingBuffer = [Float](repeating: 0, count: fftSize / 2)
        // New log bin mapping: 512 bins from 20 Hz to 20,000 Hz, continuous mapping
        let totalDisplayBins = 256
        let binFreq = sampleRate / Float(fftSize)

        func logSpace(from: Float, to: Float, count: Int) -> [Float] {
            let logMin = log10(from)
            let logMax = log10(to)
            return (0..<count).map { i in
                let t = Float(i) / Float(max(count - 1, 1))
                return pow(10, logMin + t * (logMax - logMin))
            }
        }

        let logFrequencies = logSpace(from: 20, to: 20000, count: totalDisplayBins)

        self.splitLogBinIndices = logFrequencies.map { f in
            let center = Int(round(f / binFreq))
            let spread = max(1, Int((f / 200.0).squareRoot())) // narrower in lows
            let lower = max(0, center - spread / 2)
            let upper = min(fftSize / 2 - 1, center + spread / 2)
            return Array(lower...upper)
        }

        print("SafeFFTSpectrumProcessor initialized for channel \(channelIndex) with fftSize \(fftSize)")
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func start(pollRate: TimeInterval = 0.06) {
        guard !isRegistered else {
            isActive = true
            return
        }
        isActive = true
        isRegistered = true
        SafeFFTSpectrumProcessorRegistry.shared.register(self)
    }

    func tick() {
        guard isActive else { return }

        // Read samples into preallocated inputBuffer
        let read = streamManager.read(channel: channelIndex, into: &inputBuffer)
        guard read == hopSize else { return }

        // Window
        vDSP.multiply(inputBuffer, window, result: &windowedBuffer)
        // Zero-pad
        paddedWindowed.replaceSubrange(0..<fftSize, with: windowedBuffer)
        paddedWindowed.replaceSubrange(fftSize..<paddedSize, with: repeatElement(0, count: fftSize))

        // Prepare split complex for FFT using explicit buffer-pointer scopes.
        realp.withUnsafeMutableBufferPointer { realBuffer in
            imagp.withUnsafeMutableBufferPointer { imagBuffer in
                guard let realBaseAddress = realBuffer.baseAddress,
                      let imagBaseAddress = imagBuffer.baseAddress else {
                    return
                }

                var split = DSPSplitComplex(realp: realBaseAddress, imagp: imagBaseAddress)
                paddedWindowed.withUnsafeMutableBufferPointer { paddedBuffer in
                    guard let paddedBaseAddress = paddedBuffer.baseAddress else { return }
                    paddedBaseAddress.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexBuffer in
                        vDSP_ctoz(complexBuffer, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, vDSP_Length(log2(Float(fftSize))), FFTDirection(FFT_FORWARD))

                // Magnitude calculation (use pre-allocated buffer)
                vDSP.absolute(split, result: &magsBuffer)
            }
        }

        // Apply A-weighting filter (use pre-allocated buffer)
        for i in 0..<magsBuffer.count {
            let freq = Float(i) * sampleRate / Float(fftSize)
            let f2 = freq * freq
            let ra = (f2 * f2) / ((f2 + 20.6 * 20.6) * sqrt((f2 + 107.7 * 107.7) * (f2 + 737.9 * 737.9)) * (f2 + 12200 * 12200))
            aWeightingBuffer[i] = ra.isFinite ? sqrt(ra) : 0
        }
        vDSP.multiply(magsBuffer, aWeightingBuffer, result: &magsBuffer)

        // Convert to dB (use pre-allocated buffer), applying gain trim from settings
        let dbFloor: Float = -150, dbCeil: Float = 1
        let gainTrim = VisualisationSettings.shared.spectrumGainTrimDB
        for i in 0..<magsBuffer.count {
            let db = 20 * log10(max(magsBuffer[i], 1e-12)) - 6.0 + gainTrim
            dbValuesBuffer[i] = min(max(db, dbFloor), dbCeil)
        }

        // Blur/smooth (use pre-allocated buffer)
        let kernel: [Float] = [0.25, 0.5, 0.25]
        vDSP_conv(dbValuesBuffer, 1, kernel, 1, &blurredBuffer, 1, vDSP_Length(blurredBuffer.count), vDSP_Length(kernel.count))
        // Copy blurred result back to dbValuesBuffer
        dbValuesBuffer = blurredBuffer

        // Roll-off
        let rollOffStartHz: Float = 00
        let rollOffEndHz: Float = 21
        let rollOffSlope: Float = -48.0
        for i in 0..<dbValuesBuffer.count {
            let freq = Float(i) * sampleRate / Float(fftSize)
            if freq >= rollOffStartHz && freq <= rollOffEndHz {
                let octaveRatio = log2(freq / rollOffStartHz)
                let attenuation = octaveRatio * abs(rollOffSlope)
                dbValuesBuffer[i] -= attenuation
            }
        }

        // Peak hold logic
        for i in 0..<dbValuesBuffer.count {
            if dbValuesBuffer[i] >= peakHoldValues[i] {
                peakHoldValues[i] = dbValuesBuffer[i]
                peakHoldTimers[i] = 4 // Increased hold duration
            } else if peakHoldTimers[i] > 0 {
                peakHoldTimers[i] -= 1
            } else {
                peakHoldValues[i] = max(peakHoldValues[i] - 2.2, dbValuesBuffer[i]) // Slower decay
            }
        }

        let peakHoldSnapshot = peakHoldValues
        let minDB: Float = -60
        let maxDB: Float = 15
        let range = maxDB - minDB
        let normalizedSnapshot = peakHoldSnapshot.map { value in
            max(0.0, min(1.0, (value - minDB) / range))
        }

        magnitudes = peakHoldSnapshot
        normalizedMagnitudes = normalizedSnapshot
    }

    func stop() {
        self.isActive = false
        try? streamManager.stop()
    }
}


final class SafeFFTSpectrumProcessorRegistry {
    static let shared = SafeFFTSpectrumProcessorRegistry()
    private var processors: [WeakRef<SafeFFTSpectrumProcessor>] = []
    private var timer: Timer?

    private init() {
        // Update at 60Hz (16.67ms) for responsive spectrum display (was 0.06s / 16.67Hz)
        // Each processor gets updated every frame, not every 3rd frame
        let newTimer = Timer.scheduledTimer(withTimeInterval: 0.0167, repeats: true) { [weak self] _ in
            self?.tickAll()
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func register(_ processor: SafeFFTSpectrumProcessor) {
        processors.append(WeakRef(value: processor))
    }

    private static var frameCount = 0
    private func tickAll() {
        processors = processors.filter { $0.value != nil }
        guard !processors.isEmpty else { return }

        // Process ALL processors every tick (not every 3rd) for responsive spectrum
        for processor in processors.compactMap({ $0.value }) {
            processor.tick()

            if let previous = processor.previousMagnitudes {
                guard processor.magnitudes.count == previous.count else {
                    processor.previousMagnitudes = processor.magnitudes
                    continue
                }
                var smoothed = previous
                let alpha = VisualisationSettings.shared.spectrumAlpha
                for i in 0..<processor.magnitudes.count {
                    let newValue = processor.magnitudes[i]
                    let oldValue = previous[i]
                    smoothed[i] = alpha * newValue + (1.0 - alpha) * oldValue
                }
                processor.magnitudes = smoothed
                processor.previousMagnitudes = smoothed

                let minDB = VisualisationSettings.shared.spectrumMinDB
                let maxDB: Float = 15
                let range = maxDB - minDB
                processor.normalizedMagnitudes = processor.magnitudes.map { db in
                    return max(0.0, min(1.0, (db - minDB) / range))
                }
            } else {
                processor.previousMagnitudes = processor.magnitudes
            }
        }
        SafeFFTSpectrumProcessorRegistry.frameCount += 1
    }

    private struct WeakRef<T: AnyObject> {
        weak var value: T?
    }
}
