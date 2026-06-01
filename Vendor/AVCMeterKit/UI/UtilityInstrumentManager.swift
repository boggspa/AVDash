import Foundation
import AVFoundation
import CoreAudio
import Combine

/// Manages the in-app utility instruments (Synthesizer and Drum Machine).
/// Handles sound generation, MIDI response, and mixer integration.
final class UtilityInstrumentManager: ObservableObject {
    static let shared = UtilityInstrumentManager()

    private let hostQueue = DispatchQueue(label: "com.avcmeter.utility-instrument-host")
    private let renderFrameCount: AVAudioFrameCount = 128

    // Virtual Device IDs
    let synthesizerDeviceID: AudioDeviceID = 1_000_000
    let drumMachineDeviceID: AudioDeviceID = 1_000_001
    let toneGeneratorDeviceID: AudioDeviceID = 1_000_002
    let physicalModelDeviceID: AudioDeviceID = 1_000_003
    let samplerDeviceID: AudioDeviceID = 1_000_004

    // Engines
    private var synthesizerEngine: UtilitySynthesizerEngine?
    private var drumMachineEngine: UtilityDrumMachineEngine?
    private var toneGeneratorEngine: UtilityToneGeneratorEngine?
    private var physicalModelEngine: UtilityPhysicalModelEngine?
    private var samplerEngine: UtilitySamplerEngine?

    // MIDI Selection (Source Endpoint Name)
    @Published var synthMIDISource: String?
    @Published var drumMIDISource: String?
    @Published var physicalMIDISource: String?
    @Published var samplerMIDISource: String?

    // Sampler Parameters
    struct SamplerBank {
        var sampleData: [Float]?
        var sampleRate: Double = 48000
        var trimStart: Double = 0.0 // 0.0 to 1.0
        var trimEnd: Double = 1.0   // 0.0 to 1.0
        var level: Double = 0.8
        var fileName: String?
    }
    @Published var samplerBanks: [SamplerBank] = Array(repeating: SamplerBank(), count: 11)
    @Published var selectedSamplerBankIndex: Int = 0
    @Published var samplerMasterVolume: Double = 0.8
    @Published var samplerCutoff: Double = 1.0
    @Published var samplerResonance: Double = 0.0
    @Published var samplerAttack: Double = 0.01
    @Published var samplerDecay: Double = 0.1
    @Published var samplerSustain: Double = 1.0
    @Published var samplerRelease: Double = 0.2

    // Synth Parameters
    @Published var synthOsc1Level: Double = 0.5
    @Published var synthOsc1Wave: Double = 0.0 // 0: Sine, 1: Saw, 2: Square
    @Published var synthOsc1Pitch: Double = 0.5 // -12 to +12 semitones
    @Published var synthOsc2Level: Double = 0.5
    @Published var synthOsc2Wave: Double = 2.0
    @Published var synthOsc2Pitch: Double = 0.51
    @Published var synthCutoff: Double = 0.7
    @Published var synthResonance: Double = 0.3
    @Published var synthAttack: Double = 0.1
    @Published var synthDecay: Double = 0.2
    @Published var synthSustain: Double = 0.6
    @Published var synthRelease: Double = 0.3
    @Published var synthReverbLevel: Double = 0.2
    @Published var synthMasterVolume: Double = 0.8
    @Published var synthGlide: Double = 0.1

    // Synth Arp/Mod/Mixer
    @Published var synthArpRate: Double = 0.5
    @Published var synthArpActive: Bool = false
    @Published var synthLFORate: Double = 0.3
    @Published var synthLFOPitchAmount: Double = 0.0
    @Published var synthLFOFilterAmount: Double = 0.0
    @Published var synthNoiseLevel: Double = 0.0

    // Tone Generator Parameters
    @Published var toneWaveform: Int = 0 // 0: Sine, 1: Triangle, 2: Saw, 3: Square, 4: Pink, 5: White
    @Published var toneFrequency: Double = 1000.0
    @Published var toneGain: Double = -12.0 // dB
    @Published var toneBypass: Bool = true

    // Physical Model Parameters
    @Published var pmDamping: Double = 0.5
    @Published var pmExcitation: Double = 0.8 // Noise burst amount
    @Published var pmDecay: Double = 0.7
    @Published var pmBrightness: Double = 0.5
    @Published var pmMasterVolume: Double = 0.8
    @Published var pmCutoff: Double = 1.0
    @Published var pmResonance: Double = 0.0
    @Published var pmAttack: Double = 0.01
    @Published var pmRelease: Double = 0.5
    @Published var pmDistortion: Double = 0.0
    @Published var pmX: Double = 0.5 // Character X (Wood <-> Metal)
    @Published var pmY: Double = 0.5 // Character Y (Glass <-> String)

    // Drum Parameters
    @Published var drumTempo: Double = 0.6
    @Published var drumAccent: Double = 0.5
    @Published var drumSwing: Double = 0.0
    @Published var drumGlobalCutoff: Double = 1.0
    @Published var drumGlobalResonance: Double = 0.0
    @Published var drumSelectedPatternIndex: Int = 0
    @Published var drumPatterns: [[String: [Bool]]] = Array(repeating: [
        "BD": Array(repeating: false, count: 16),
        "SD": Array(repeating: false, count: 16),
        "LT": Array(repeating: false, count: 16),
        "MT": Array(repeating: false, count: 16),
        "HT": Array(repeating: false, count: 16),
        "RS": Array(repeating: false, count: 16),
        "CP": Array(repeating: false, count: 16),
        "CB": Array(repeating: false, count: 16),
        "CY": Array(repeating: false, count: 16),
        "OH": Array(repeating: false, count: 16),
        "CH": Array(repeating: false, count: 16)
    ], count: 4)

    @Published var drumParams: [String: [String: Double]] = [
        "BD": ["Tune": 0.5, "Decay": 0.5, "Level": 0.5, "Filter": 1.0, "Res": 0.0, "Mod": 0.5],
        "SD": ["Tune": 0.5, "Decay": 0.5, "Level": 0.5, "Snappy": 0.5, "Filter": 1.0, "Res": 0.0, "Mod": 0.5],
        "LT": ["Tune": 0.5, "Decay": 0.5, "Level": 0.5, "Filter": 1.0, "Res": 0.0, "Mod": 0.5],
        "MT": ["Tune": 0.5, "Decay": 0.5, "Level": 0.5, "Filter": 1.0, "Res": 0.0, "Mod": 0.5],
        "HT": ["Tune": 0.5, "Decay": 0.5, "Level": 0.5, "Filter": 1.0, "Res": 0.0, "Mod": 0.5],
        "RS": ["Tune": 0.5, "Decay": 0.5, "Level": 0.5, "Filter": 1.0, "Res": 0.0, "Mod": 0.5],
        "CP": ["Tune": 0.5, "Decay": 0.5, "Level": 0.5, "Filter": 1.0, "Res": 0.0, "Mod": 0.5],
        "CB": ["Tune": 0.5, "Decay": 0.5, "Level": 0.5, "Filter": 1.0, "Res": 0.0, "Mod": 0.5],
        "CY": ["Tune": 0.5, "Decay": 0.5, "Level": 0.5, "Filter": 1.0, "Res": 0.0, "Mod": 0.5],
        "OH": ["Tune": 0.5, "Decay": 0.5, "Level": 0.5, "Filter": 1.0, "Res": 0.0, "Mod": 0.5],
        "CH": ["Tune": 0.5, "Decay": 0.5, "Level": 0.5, "Filter": 1.0, "Res": 0.0, "Mod": 0.5]
    ]

    // Obsolete global drum parameters (maintained for compatibility during refactor)
    @Published var drumLevel: Double = 0.5
    @Published var drumTune: Double = 0.5
    @Published var drumDecay: Double = 0.5
    @Published var drumSnappy: Double = 0.5

    // Device Contexts for Metering
    private var synthMeteringContext: DeviceMeteringContext?
    private var drumMeteringContext: DeviceMeteringContext?
    private var toneMeteringContext: DeviceMeteringContext?
    private var physicalMeteringContext: DeviceMeteringContext?
    private var samplerMeteringContext: DeviceMeteringContext?

    @Published var isSynthesizerActive = false
    @Published var isDrumMachineActive = false
    @Published var isToneGeneratorActive = false
    @Published var isPhysicalModelActive = false
    @Published var isSamplerActive = false

    private var cancellables = Set<AnyCancellable>()

    private init() {}

    func pushPhysicalModelMeters(peaks: [Float], rms: [Float]) {
        if let pmCtx = physicalMeteringContext {
            pmCtx.peakBuffer.write(peaks)
            pmCtx.rmsBuffer.write(rms)
        }
    }

    func pushSamplerMeters(peaks: [Float], rms: [Float]) {
        if let samplerCtx = samplerMeteringContext {
            samplerCtx.peakBuffer.write(peaks)
            samplerCtx.rmsBuffer.write(rms)
        }
    }

    func startSampler() {
        hostQueue.async { [weak self] in
            guard let self = self else { return }

            // Ensure mixer is active for visualization
            DispatchQueue.main.sync {
                _ = MultiDeviceStreamManager.shared.ensureMixerReadyForStream(sampleRate: 48000)
            }

            Mixer_RegisterDevice(UInt32(self.samplerDeviceID), 0, 2)
            let engine = UtilitySamplerEngine(sampleRate: 48000)
            engine.manager = self
            self.samplerEngine = engine
            InstrumentOutputManager.shared.register(instrument: engine)

            DispatchQueue.main.async {
                self.isSamplerActive = true
                self.ensureSamplerMeteringContext()
            }

            print("[UtilityManager] Started Sampler Engine")
        }
    }

    func stopSampler() {
        hostQueue.async { [weak self] in
            guard let self = self else { return }

            if let engine = self.samplerEngine {
                InstrumentOutputManager.shared.unregister(instrument: engine)
            }
            Mixer_UnregisterDevice(UInt32(self.samplerDeviceID), 0)
            self.samplerEngine = nil

            DispatchQueue.main.async {
                self.isSamplerActive = false
                AudioDeviceManager.shared.activeDevices.removeValue(forKey: self.samplerDeviceID)
                AudioDeviceManager.shared.selectedChannelMasks.removeValue(forKey: self.samplerDeviceID)
                self.samplerMeteringContext = nil
            }

            print("[UtilityManager] Stopped Sampler Engine")
        }
    }

    @MainActor
    private func ensureSamplerMeteringContext() {
        let manager = AudioDeviceManager.shared

        let samplerDevice = AudioDevice(
            deviceID: samplerDeviceID,
            name: "Sampler Engine",
            inputChannels: 2,
            outputChannels: 0,
            sampleRate: 48000,
            transportType: "virtual"
        )
        let samplerContext = DeviceMeteringContext(device: samplerDevice, handler: LevelHandler())
        manager.activeDevices[samplerDeviceID] = samplerContext
        manager.selectedChannelMasks[samplerDeviceID] = [true, true]
        self.samplerMeteringContext = samplerContext
    }

    func startToneGenerator() {
        hostQueue.async { [weak self] in
            guard let self = self else { return }

            // Ensure mixer is active for visualization
            DispatchQueue.main.sync {
                _ = MultiDeviceStreamManager.shared.ensureMixerReadyForStream(sampleRate: 48000)
            }

            Mixer_RegisterDevice(UInt32(self.toneGeneratorDeviceID), 0, 2)
            let engine = UtilityToneGeneratorEngine(sampleRate: 48000)
            engine.manager = self
            self.toneGeneratorEngine = engine
            InstrumentOutputManager.shared.register(instrument: engine)

            DispatchQueue.main.async {
                self.isToneGeneratorActive = true
                self.ensureToneMeteringContext()
            }

            print("[UtilityManager] Started Tone Generator")
        }
    }

    func stopToneGenerator() {
        hostQueue.async { [weak self] in
            guard let self = self else { return }

            if let engine = self.toneGeneratorEngine {
                InstrumentOutputManager.shared.unregister(instrument: engine)
            }
            Mixer_UnregisterDevice(UInt32(self.toneGeneratorDeviceID), 0)
            self.toneGeneratorEngine = nil

            DispatchQueue.main.async {
                self.isToneGeneratorActive = false
                AudioDeviceManager.shared.activeDevices.removeValue(forKey: self.toneGeneratorDeviceID)
                AudioDeviceManager.shared.selectedChannelMasks.removeValue(forKey: self.toneGeneratorDeviceID)
                self.toneMeteringContext = nil
            }

            print("[UtilityManager] Stopped Tone Generator")
        }
    }

    @MainActor
    private func ensureToneMeteringContext() {
        let manager = AudioDeviceManager.shared

        let toneDevice = AudioDevice(
            deviceID: toneGeneratorDeviceID,
            name: "Tone Generator",
            inputChannels: 2,
            outputChannels: 0,
            sampleRate: 48000,
            transportType: "virtual"
        )
        let toneContext = DeviceMeteringContext(device: toneDevice, handler: LevelHandler())
        manager.activeDevices[toneGeneratorDeviceID] = toneContext
        manager.selectedChannelMasks[toneGeneratorDeviceID] = [true, true]
        self.toneMeteringContext = toneContext
    }

    func pushToneMeters(peaks: [Float], rms: [Float]) {
        if let toneCtx = toneMeteringContext {
            toneCtx.peakBuffer.write(peaks)
            toneCtx.rmsBuffer.write(rms)
        }
    }

    func startPhysicalModel() {
        hostQueue.async { [weak self] in
            guard let self = self else { return }

            // Ensure mixer is active for visualization
            DispatchQueue.main.sync {
                _ = MultiDeviceStreamManager.shared.ensureMixerReadyForStream(sampleRate: 48000)
            }

            Mixer_RegisterDevice(UInt32(self.physicalModelDeviceID), 0, 2)
            let engine = UtilityPhysicalModelEngine(sampleRate: 48000)
            engine.manager = self
            self.physicalModelEngine = engine
            InstrumentOutputManager.shared.register(instrument: engine)

            DispatchQueue.main.async {
                self.isPhysicalModelActive = true
                self.ensurePhysicalModelMeteringContext()
            }

            print("[UtilityManager] Started Physical Model Synth")
        }
    }

    func stopPhysicalModel() {
        hostQueue.async { [weak self] in
            guard let self = self else { return }

            if let engine = self.physicalModelEngine {
                InstrumentOutputManager.shared.unregister(instrument: engine)
            }
            Mixer_UnregisterDevice(UInt32(self.physicalModelDeviceID), 0)
            self.physicalModelEngine = nil

            DispatchQueue.main.async {
                self.isPhysicalModelActive = false
                AudioDeviceManager.shared.activeDevices.removeValue(forKey: self.physicalModelDeviceID)
                AudioDeviceManager.shared.selectedChannelMasks.removeValue(forKey: self.physicalModelDeviceID)
                self.physicalMeteringContext = nil
            }

            print("[UtilityManager] Stopped Physical Model Synth")
        }
    }

    @MainActor
    private func ensurePhysicalModelMeteringContext() {
        let manager = AudioDeviceManager.shared

        let pmDevice = AudioDevice(
            deviceID: physicalModelDeviceID,
            name: "Physical Model Synth",
            inputChannels: 2,
            outputChannels: 0,
            sampleRate: 48000,
            transportType: "virtual"
        )
        let pmContext = DeviceMeteringContext(device: pmDevice, handler: LevelHandler())
        manager.activeDevices[physicalModelDeviceID] = pmContext
        manager.selectedChannelMasks[physicalModelDeviceID] = [true, true]
        self.physicalMeteringContext = pmContext
    }

    func startSynthesizer() {
        hostQueue.async { [weak self] in
            guard let self = self else { return }

            // Ensure mixer is active for visualization
            DispatchQueue.main.sync {
                _ = MultiDeviceStreamManager.shared.ensureMixerReadyForStream(sampleRate: 48000)
            }

            Mixer_RegisterDevice(UInt32(self.synthesizerDeviceID), 0, 2)
            let engine = UtilitySynthesizerEngine(sampleRate: 48000)
            engine.manager = self
            self.synthesizerEngine = engine
            InstrumentOutputManager.shared.register(instrument: engine)

            DispatchQueue.main.async {
                self.isSynthesizerActive = true
                self.ensureSynthMeteringContext()
            }

            print("[UtilityManager] Started Synthesizer")
        }
    }

    func stopSynthesizer() {
        hostQueue.async { [weak self] in
            guard let self = self else { return }

            if let engine = self.synthesizerEngine {
                InstrumentOutputManager.shared.unregister(instrument: engine)
            }
            Mixer_UnregisterDevice(UInt32(self.synthesizerDeviceID), 0)
            self.synthesizerEngine = nil

            DispatchQueue.main.async {
                self.isSynthesizerActive = false
                AudioDeviceManager.shared.activeDevices.removeValue(forKey: self.synthesizerDeviceID)
                AudioDeviceManager.shared.selectedChannelMasks.removeValue(forKey: self.synthesizerDeviceID)
                self.synthMeteringContext = nil
            }

            print("[UtilityManager] Stopped Synthesizer")
        }
    }

    func startDrumMachine() {
        hostQueue.async { [weak self] in
            guard let self = self else { return }

            // Ensure mixer is active for visualization
            DispatchQueue.main.sync {
                _ = MultiDeviceStreamManager.shared.ensureMixerReadyForStream(sampleRate: 48000)
            }

            Mixer_RegisterDevice(UInt32(self.drumMachineDeviceID), 0, 2)
            let engine = UtilityDrumMachineEngine(sampleRate: 48000)
            engine.manager = self
            self.drumMachineEngine = engine
            InstrumentOutputManager.shared.register(instrument: engine)

            DispatchQueue.main.async {
                self.isDrumMachineActive = true
                self.ensureDrumMeteringContext()
            }

            print("[UtilityManager] Started Drum Machine")
        }
    }

    func stopDrumMachine() {
        hostQueue.async { [weak self] in
            guard let self = self else { return }

            if let engine = self.drumMachineEngine {
                InstrumentOutputManager.shared.unregister(instrument: engine)
            }
            Mixer_UnregisterDevice(UInt32(self.drumMachineDeviceID), 0)
            self.drumMachineEngine = nil

            DispatchQueue.main.async {
                self.isDrumMachineActive = false
                AudioDeviceManager.shared.activeDevices.removeValue(forKey: self.drumMachineDeviceID)
                AudioDeviceManager.shared.selectedChannelMasks.removeValue(forKey: self.drumMachineDeviceID)
                self.drumMeteringContext = nil
            }

            print("[UtilityManager] Stopped Drum Machine")
        }
    }

    @MainActor
    private func ensureSynthMeteringContext() {
        let manager = AudioDeviceManager.shared

        let synthDevice = AudioDevice(
            deviceID: synthesizerDeviceID,
            name: "Synthesizer Engine",
            inputChannels: 2,
            outputChannels: 0,
            sampleRate: 48000,
            transportType: "virtual"
        )
        let synthContext = DeviceMeteringContext(device: synthDevice, handler: LevelHandler())
        manager.activeDevices[synthesizerDeviceID] = synthContext
        manager.selectedChannelMasks[synthesizerDeviceID] = [true, true]
        self.synthMeteringContext = synthContext
    }

    @MainActor
    private func ensureDrumMeteringContext() {
        let manager = AudioDeviceManager.shared

        let drumDevice = AudioDevice(
            deviceID: drumMachineDeviceID,
            name: "808 Drum Machine",
            inputChannels: 2,
            outputChannels: 0,
            sampleRate: 48000,
            transportType: "virtual"
        )
        let drumContext = DeviceMeteringContext(device: drumDevice, handler: LevelHandler())
        manager.activeDevices[drumMachineDeviceID] = drumContext
        manager.selectedChannelMasks[drumMachineDeviceID] = [true, true]
        self.drumMeteringContext = drumContext
    }

    func pushSynthMeters(peaks: [Float], rms: [Float]) {
        if let synthCtx = synthMeteringContext {
            synthCtx.peakBuffer.write(peaks)
            synthCtx.rmsBuffer.write(rms)
        }
    }

    func pushDrumMeters(peaks: [Float], rms: [Float]) {
        if let drumCtx = drumMeteringContext {
            drumCtx.peakBuffer.write(peaks)
            drumCtx.rmsBuffer.write(rms)
        }
    }

    func handleMIDIMessage(status: UInt8, data1: UInt8, data2: UInt8, sourceEndpoint: String) {
        let type = status & 0xF0

        // Handle CC Messages
        if type == 0xB0 {
            if let update = MIDIMappingManager.shared.processCC(cc: data1, value: data2) {
                print("[UtilityManager] Param update: \(update.parameter) = \(update.normalizedValue)")
                // Apply update to engine here if engine supports it
            }
        }

        let isInternalSource = sourceEndpoint == "Internal Sequencer" ||
                               sourceEndpoint == "Internal Keyboard" ||
                               sourceEndpoint == "Internal CC Controller"

        // Synthesizer
        if synthMIDISource == nil || sourceEndpoint == "unknown" || sourceEndpoint == synthMIDISource || isInternalSource {
            synthesizerEngine?.handleMIDI(status: status, data1: data1, data2: data2)
        }

        // Drum Machine
        if drumMIDISource == nil || sourceEndpoint == "unknown" || sourceEndpoint == drumMIDISource || isInternalSource {
            drumMachineEngine?.handleMIDI(status: status, data1: data1, data2: data2)
        }

        // Physical Model
        if physicalMIDISource == nil || sourceEndpoint == "unknown" || sourceEndpoint == physicalMIDISource || isInternalSource {
            physicalModelEngine?.handleMIDI(status: status, data1: data1, data2: data2)
        }

        // Sampler
        if samplerMIDISource == nil || sourceEndpoint == "unknown" || sourceEndpoint == samplerMIDISource || isInternalSource {
            samplerEngine?.handleMIDI(status: status, data1: data1, data2: data2)
        }

        // Tone Generator
        toneGeneratorEngine?.handleMIDI(status: status, data1: data1, data2: data2)
    }
}

// MARK: - Internal DSP Engines

protocol InstrumentAudioRenderDelegate: AnyObject {
    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int)
}

private class UtilityToneGeneratorEngine: InstrumentAudioRenderDelegate {
    private let sampleRate: Double
    private var phase: Double = 0
    weak var manager: UtilityInstrumentManager?

    // Pink Noise State
    private var pinkRows = [Double](repeating: 0, count: 12)
    private var pinkRunningSum: Double = 0
    private var pinkIndex: Int = 0

    // Realtime buffers
    private var leftBuffer: UnsafeMutablePointer<Float>?
    private var rightBuffer: UnsafeMutablePointer<Float>?
    private var maxFrames: Int = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    deinit {
        leftBuffer?.deallocate()
        rightBuffer?.deallocate()
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        if frameCount > maxFrames {
            leftBuffer?.deallocate()
            rightBuffer?.deallocate()
            leftBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            rightBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            maxFrames = frameCount
        }

        guard let lBuf = leftBuffer, let rBuf = rightBuffer else { return }

        let bypass = manager?.toneBypass ?? false
        if bypass {
            memset(buffer, 0, frameCount * 2 * MemoryLayout<Float>.size)
            memset(lBuf, 0, frameCount * MemoryLayout<Float>.size)
            memset(rBuf, 0, frameCount * MemoryLayout<Float>.size)
            if let deviceID = manager?.toneGeneratorDeviceID {
                Mixer_FeedSingleChannelToMixer(UInt32(deviceID), 0, 0, lBuf, Int32(frameCount))
                Mixer_FeedSingleChannelToMixer(UInt32(deviceID), 0, 1, rBuf, Int32(frameCount))
            }
            manager?.pushToneMeters(peaks: [0,0], rms: [0,0])
            return
        }

        let waveform = manager?.toneWaveform ?? 0
        let freq = manager?.toneFrequency ?? 1000.0
        let gainDb = manager?.toneGain ?? -12.0
        let linearGain = pow(10.0, gainDb / 20.0)

        let phaseStep = (2.0 * .pi * freq) / sampleRate

        var peaks: [Float] = [0, 0]
        var rmsSums: [Float] = [0, 0]

        for i in 0..<frameCount {
            var val: Double = 0

            switch waveform {
            case 0: // Sine
                val = sin(phase)
            case 1: // Triangle
                let p = phase / (2.0 * .pi)
                val = 2.0 * abs(2.0 * (p - floor(p + 0.5))) - 1.0
            case 2: // Saw
                val = (phase / .pi) - 1.0
            case 3: // Square
                val = phase < .pi ? 1.0 : -1.0
            case 4: // Pink Noise
                val = nextPink()
            case 5: // White Noise
                val = Double.random(in: -1...1)
            default:
                val = 0
            }

            let finalVal = Float(val * linearGain)

            buffer[i*2] = finalVal
            buffer[i*2 + 1] = finalVal
            lBuf[i] = finalVal
            rBuf[i] = finalVal

            peaks[0] = max(peaks[0], abs(finalVal))
            peaks[1] = max(peaks[1], abs(finalVal))
            rmsSums[0] += finalVal * finalVal
            rmsSums[1] += finalVal * finalVal

            phase += phaseStep
            if phase > 2.0 * .pi { phase -= 2.0 * .pi }
        }

        // Push directly to C mixer ring buffer
        if let deviceID = manager?.toneGeneratorDeviceID {
            _ = Mixer_FeedSingleChannelToMixer(UInt32(deviceID), 0, 0, lBuf, Int32(frameCount))
            _ = Mixer_FeedSingleChannelToMixer(UInt32(deviceID), 0, 1, rBuf, Int32(frameCount))
        }

        // Push metering
        let rms = [
            sqrt(rmsSums[0] / Float(max(1, frameCount))),
            sqrt(rmsSums[1] / Float(max(1, frameCount)))
        ]
        manager?.pushToneMeters(peaks: peaks, rms: rms)
    }

    private func nextPink() -> Double {
        // Voss-McCartney algorithm for Pink Noise
        var newRandom = Double.random(in: -1...1)
        pinkIndex += 1
        var numZeros = 0
        var tempIndex = pinkIndex
        while (tempIndex & 1) == 0 && numZeros < pinkRows.count - 1 {
            numZeros += 1
            tempIndex >>= 1
        }

        pinkRunningSum -= pinkRows[numZeros]
        pinkRows[numZeros] = newRandom / Double(pinkRows.count)
        pinkRunningSum += pinkRows[numZeros]

        return pinkRunningSum + (Double.random(in: -1...1) / Double(pinkRows.count))
    }

    func handleMIDI(status: UInt8, data1: UInt8, data2: UInt8) {
        // Tone generator typically doesn't respond to MIDI notes
    }
}

private class UtilitySynthesizerEngine: InstrumentAudioRenderDelegate {
    private let sampleRate: Float

    // Voice state
    private var phase: Float = 0
    private var activeNotes: [UInt8] = []
    private var currentFreq: Float = 440.0
    private var targetFreq: Float = 440.0
    weak var manager: UtilityInstrumentManager?

    // Arpeggiator state
    private var arpPhase: Double = 0
    private var arpNoteIndex: Int = 0

    // Modulation state
    private var lfoPhase: Float = 0

    // Envelope state
    private enum EnvState { case idle, attack, decay, sustain, release }
    private var envState: EnvState = .idle
    private var envLevel: Float = 0.0

    // Filter state (Moog 4-pole approximation)
    private var y1: Float = 0, y2: Float = 0, y3: Float = 0, y4: Float = 0
    private var oldx: Float = 0, oldy1: Float = 0, oldy2: Float = 0, oldy3: Float = 0, oldy4: Float = 0

    // Reverb state (Schroeder-style parallel comb filters)
    private var combBuffers: [[Float]] = [
        [Float](repeating: 0, count: 1116),
        [Float](repeating: 0, count: 1188),
        [Float](repeating: 0, count: 1277),
        [Float](repeating: 0, count: 1356)
    ]
    private var combIndices: [Int] = [0, 0, 0, 0]

    private var allpassBuffers: [[Float]] = [
        [Float](repeating: 0, count: 556),
        [Float](repeating: 0, count: 441)
    ]
    private var allpassIndices: [Int] = [0, 0]

    // Realtime buffers
    private var leftBuffer: UnsafeMutablePointer<Float>?
    private var rightBuffer: UnsafeMutablePointer<Float>?
    private var maxFrames: Int = 0

    init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
    }

    deinit {
        leftBuffer?.deallocate()
        rightBuffer?.deallocate()
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        if frameCount > maxFrames {
            leftBuffer?.deallocate()
            rightBuffer?.deallocate()
            leftBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            rightBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            maxFrames = frameCount
        }

        guard let lBuf = leftBuffer, let rBuf = rightBuffer else { return }

        let osc1Level = Float(manager?.synthOsc1Level ?? 0.5)
        let osc1Wave = Int(manager?.synthOsc1Wave ?? 0)
        let osc1Pitch = Float((manager?.synthOsc1Pitch ?? 0.5) * 24.0 - 12.0)

        let osc2Level = Float(manager?.synthOsc2Level ?? 0.5)
        let osc2Wave = Int(manager?.synthOsc2Wave ?? 2)
        let osc2Pitch = Float((manager?.synthOsc2Pitch ?? 0.5) * 24.0 - 12.0)

        let noiseLevel = Float(manager?.synthNoiseLevel ?? 0.0)

        // LFO
        let lfoRate = Float(manager?.synthLFORate ?? 0.3) * 20.0 // 0 to 20Hz
        let lfoPitchAmt = Float(manager?.synthLFOPitchAmount ?? 0.0)
        let lfoFilterAmt = Float(manager?.synthLFOFilterAmount ?? 0.0)
        let lfoStep = (2.0 * .pi * lfoRate) / sampleRate

        // Arpeggiator
        let arpActive = manager?.synthArpActive ?? false
        let arpRate = manager?.synthArpRate ?? 0.5
        let arpBpm = 60.0 + (arpRate * 240.0) // 60 to 300 BPM
        let arpStepSamples = (Double(sampleRate) * 60.0) / (arpBpm * 4.0) // 16th notes

        // Logarithmic Cutoff Mapping
        let rawCutoff = Float(manager?.synthCutoff ?? 0.7)
        let cutoffFreq = 20.0 * pow(1000.0, rawCutoff)
        let cutoffParam = min(0.99, max(0.01, cutoffFreq / (sampleRate * 0.5)))

        let resParam = Float(manager?.synthResonance ?? 0.3)
        let glideParam = Float(manager?.synthGlide ?? 0.1)

        let attackParam = Float(manager?.synthAttack ?? 0.1)
        let decayParam = Float(manager?.synthDecay ?? 0.2)
        let sustainParam = Float(manager?.synthSustain ?? 0.6)
        let releaseParam = Float(manager?.synthRelease ?? 0.3)
        let reverbLevel = Float(manager?.synthReverbLevel ?? 0.2)
        let masterVol = Float(manager?.synthMasterVolume ?? 0.8)

        let attackRate = 1.0 / (sampleRate * max(0.005, attackParam * 3.0))
        let decayRate = 1.0 / (sampleRate * max(0.005, decayParam * 3.0))
        let releaseRate = 1.0 / (sampleRate * max(0.005, releaseParam * 5.0))
        let glideSlew = glideParam < 0.001 ? 1.0 : 1.0 - exp(-1.0 / (sampleRate * glideParam * 2.0))

        var peaks: [Float] = [0, 0]
        var rmsSums: [Float] = [0, 0]

        if envState == .idle && reverbLevel < 0.01 && !arpActive {
            memset(buffer, 0, frameCount * 2 * MemoryLayout<Float>.size)
            memset(lBuf, 0, frameCount * MemoryLayout<Float>.size)
            memset(rBuf, 0, frameCount * MemoryLayout<Float>.size)
            if let deviceID = manager?.synthesizerDeviceID {
                Mixer_FeedSingleChannelToMixer(UInt32(deviceID), 0, 0, lBuf, Int32(frameCount))
                Mixer_FeedSingleChannelToMixer(UInt32(deviceID), 0, 1, rBuf, Int32(frameCount))
            }
            manager?.pushSynthMeters(peaks: [0,0], rms: [0,0])
            return
        }

        for i in 0..<frameCount {
            // Arpeggiator update
            if arpActive && !activeNotes.isEmpty {
                arpPhase += 1.0
                if arpPhase >= arpStepSamples {
                    arpPhase -= arpStepSamples
                    arpNoteIndex = (arpNoteIndex + 1) % activeNotes.count
                    let note = activeNotes[arpNoteIndex]
                    targetFreq = 440.0 * pow(2.0, (Float(note) - 69.0) / 12.0)
                    envState = .attack
                }
            }

            // Portamento update
            currentFreq += (targetFreq - currentFreq) * glideSlew

            // LFO update
            let lfoVal = sin(lfoPhase)
            lfoPhase += lfoStep
            if lfoPhase > 2.0 * .pi { lfoPhase -= 2.0 * .pi }

            // Pitch modulation
            let pitchMod = lfoVal * lfoPitchAmt * 2.0 // +/- 2 semitones
            let f1 = currentFreq * pow(2.0, (osc1Pitch + pitchMod) / 12.0)
            let f2 = currentFreq * pow(2.0, (osc2Pitch + pitchMod) / 12.0)
            let phaseStep1 = (2.0 * .pi * f1) / sampleRate

            // Envelope update
            switch envState {
            case .attack:
                envLevel += attackRate
                if envLevel >= 1.0 { envLevel = 1.0; envState = .decay }
            case .decay:
                envLevel -= decayRate
                if envLevel <= sustainParam { envLevel = sustainParam; envState = .sustain }
            case .sustain:
                envLevel = sustainParam
            case .release:
                envLevel -= releaseRate
                if envLevel <= 0.0 { envLevel = 0.0; envState = .idle }
            case .idle:
                envLevel = 0.0
            }

            // Oscillators
            var o1: Float = 0
            switch osc1Wave {
            case 1: o1 = (phase / .pi) - 1.0 // Saw
            case 2: o1 = phase < .pi ? 1.0 : -1.0 // Square
            default: o1 = sin(phase) // Sine
            }

            var o2: Float = 0
            let phase2 = (phase * (f2/f1)).truncatingRemainder(dividingBy: 2.0 * .pi)
            switch osc2Wave {
            case 1: o2 = (phase2 / .pi) - 1.0
            case 2: o2 = phase2 < .pi ? 1.0 : -1.0
            default: o2 = sin(phase2)
            }

            let noise = (Float.random(in: -1...1)) * noiseLevel
            let mixedOsc = (o1 * osc1Level) + (o2 * osc2Level) + noise

            // Filter Modulated by Envelope and LFO
            let filterMod = lfoVal * lfoFilterAmt * 0.5
            let modulatedCutoff = min(0.99, max(0.01, cutoffParam * (1.0 + envLevel * 3.0) + filterMod))
            let f = modulatedCutoff * 1.16
            let fb = resParam * 4.0 * (1.0 - 0.15 * f * f)

            let input = mixedOsc - y4 * fb
            let clipped = max(-1.0, min(1.0, input))

            y1 = y1 + f * (clipped - y1 + oldx - oldy1)
            y2 = y2 + f * (y1 - y2 + oldy1 - oldy2)
            y3 = y3 + f * (y2 - y3 + oldy2 - oldy3)
            y4 = y4 + f * (y3 - y4 + oldy3 - oldy4)

            oldx = clipped
            oldy1 = y1
            oldy2 = y2
            oldy3 = y3
            oldy4 = y4

            let filteredOut = y4 * envLevel

            // Reverb
            var reverbOut: Float = 0
            for j in 0..<4 {
                let delay = combBuffers[j][combIndices[j]]
                reverbOut += delay
                combBuffers[j][combIndices[j]] = filteredOut + (delay * 0.8)
                combIndices[j] = (combIndices[j] + 1) % combBuffers[j].count
            }
            reverbOut *= 0.25
            for j in 0..<2 {
                let delay = allpassBuffers[j][allpassIndices[j]]
                let nextVal = -0.5 * reverbOut + delay
                allpassBuffers[j][allpassIndices[j]] = reverbOut + 0.5 * nextVal
                reverbOut = nextVal
                allpassIndices[j] = (allpassIndices[j] + 1) % allpassBuffers[j].count
            }

            let mixedVal = (filteredOut * (1.0 - reverbLevel)) + (reverbOut * reverbLevel)
            var finalVal = mixedVal * masterVol

            if !finalVal.isFinite {
                finalVal = 0
                y1 = 0; y2 = 0; y3 = 0; y4 = 0
                oldx = 0; oldy1 = 0; oldy2 = 0; oldy3 = 0; oldy4 = 0
            }
            finalVal = max(-1.0, min(1.0, finalVal))

            buffer[i*2] = finalVal
            buffer[i*2 + 1] = finalVal
            lBuf[i] = finalVal
            rBuf[i] = finalVal

            peaks[0] = max(peaks[0], abs(finalVal))
            peaks[1] = max(peaks[1], abs(finalVal))
            rmsSums[0] += finalVal * finalVal
            rmsSums[1] += finalVal * finalVal

            phase += phaseStep1
            if phase > 2.0 * .pi { phase -= 2.0 * .pi }
        }

        if let deviceID = manager?.synthesizerDeviceID {
            _ = Mixer_FeedSingleChannelToMixer(UInt32(deviceID), 0, 0, lBuf, Int32(frameCount))
            _ = Mixer_FeedSingleChannelToMixer(UInt32(deviceID), 0, 1, rBuf, Int32(frameCount))
        }

        let rms = [
            sqrt(rmsSums[0] / Float(max(1, frameCount))),
            sqrt(rmsSums[1] / Float(max(1, frameCount)))
        ]
        manager?.pushSynthMeters(peaks: peaks, rms: rms)
    }

    func handleMIDI(status: UInt8, data1: UInt8, data2: UInt8) {
        let type = status & 0xF0
        if type == 0x90 && data2 > 0 { // Note On
            activeNotes.append(data1)
            targetFreq = 440.0 * pow(2.0, (Float(data1) - 69.0) / 12.0)
            if envState == .idle || envState == .release {
                currentFreq = targetFreq
            }
            envState = .attack
        } else if type == 0x80 || (type == 0x90 && data2 == 0) { // Note Off
            activeNotes.removeAll { $0 == data1 }
            if let last = activeNotes.last {
                targetFreq = 440.0 * pow(2.0, (Float(last) - 69.0) / 12.0)
            } else {
                envState = .release
            }
        }
    }
}

private class UtilityDrumMachineEngine: InstrumentAudioRenderDelegate {
    private let sampleRate: Double
    weak var manager: UtilityInstrumentManager?

    // Global Filter State
    private var y1: Float = 0, y2: Float = 0, y3: Float = 0, y4: Float = 0
    private var oldx: Float = 0, oldy1: Float = 0, oldy2: Float = 0, oldy3: Float = 0, oldy4: Float = 0

    // Per-instrument Filter State
    private struct FilterState {
        var y1: Float = 0, y2: Float = 0, y3: Float = 0, y4: Float = 0
        var oldx: Float = 0, oldy1: Float = 0, oldy2: Float = 0, oldy3: Float = 0, oldy4: Float = 0

        mutating func process(_ input: Double, cutoff: Double, res: Double, sr: Double) -> Double {
            let cutoffFreq = 20.0 * pow(1000.0, cutoff)
            let cutoffParam = Float(min(0.99, max(0.01, cutoffFreq / (sr * 0.5))))
            let resParam = Float(res)

            let f = cutoffParam * 1.16
            let fb = resParam * 4.0 * (1.0 - 0.15 * f * f)
            let inputF = Float(input) - y4 * fb
            let clipped = max(-1.0, min(1.0, inputF))

            y1 = y1 + f * (clipped - y1 + oldx - oldy1)
            y2 = y2 + f * (y1 - y2 + oldy1 - oldy2)
            y3 = y3 + f * (y2 - y3 + oldy2 - oldy3)
            y4 = y4 + f * (y3 - y4 + oldy3 - oldy4)

            oldx = clipped
            oldy1 = y1
            oldy2 = y2
            oldy3 = y3
            oldy4 = y4

            return Double(y4)
        }
    }

    private var instrumentFilters: [String: FilterState] = [
        "BD": FilterState(), "SD": FilterState(), "LT": FilterState(), "MT": FilterState(),
        "HT": FilterState(), "RS": FilterState(), "CP": FilterState(), "CB": FilterState(),
        "CY": FilterState(), "OH": FilterState(), "CH": FilterState()
    ]

    // Realtime buffers
    private var leftBuffer: UnsafeMutablePointer<Float>?
    private var rightBuffer: UnsafeMutablePointer<Float>?
    private var maxFrames: Int = 0

    // --- Instrument States ---

    // BD (Kick)
    private var bdTrigger = false
    private var bdPhase = 0.0
    private var bdEnv = 0.0

    // SD (Snare)
    private var sdTrigger = false
    private var sdPhase1 = 0.0
    private var sdPhase2 = 0.0
    private var sdEnvTonal = 0.0
    private var sdEnvNoise = 0.0

    // Hats (CH / OH)
    private var hhTrigger = false
    private var hhIsClosed = true
    private var hhEnv = 0.0
    private var hhPhases: [Double] = [0, 0, 0, 0, 0, 0]
    private let hhRatios: [Double] = [2.0, 3.0, 4.16, 5.43, 6.79, 8.21]
    private var hhFilterY1: Double = 0
    private var hhFilterX1: Double = 0

    // Toms (LT, MT, HT)
    private var ltTrigger = false, mtTrigger = false, htTrigger = false
    private var ltPhase = 0.0, mtPhase = 0.0, htPhase = 0.0
    private var ltEnv = 0.0, mtEnv = 0.0, htEnv = 0.0

    // Clap (CP)
    private var cpTrigger = false
    private var cpEnv = 0.0
    private var cpTime = 0.0

    // Cowbell (CB)
    private var cbTrigger = false
    private var cbPhase1 = 0.0
    private var cbPhase2 = 0.0
    private var cbEnv = 0.0

    // Rimshot (RS)
    private var rsTrigger = false
    private var rsPhase1 = 0.0
    private var rsPhase2 = 0.0
    private var rsEnv = 0.0

    // Cymbal (CY)
    private var cyTrigger = false
    private var cyEnv = 0.0
    private var cyPhases: [Double] = [0, 0, 0, 0, 0, 0]
    private var cyFilterY1: Double = 0
    private var cyFilterX1: Double = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    deinit {
        leftBuffer?.deallocate()
        rightBuffer?.deallocate()
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        if frameCount > maxFrames {
            leftBuffer?.deallocate()
            rightBuffer?.deallocate()
            leftBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            rightBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            maxFrames = frameCount
        }

        guard let lBuf = leftBuffer, let rBuf = rightBuffer else { return }

        let rawCutoff = Float(manager?.drumGlobalCutoff ?? 1.0)
        let cutoffFreq = 20.0 * pow(1000.0, rawCutoff)
        let cutoffParam = min(0.99, max(0.01, cutoffFreq / (Float(sampleRate) * 0.5)))
        let resParam = Float(manager?.drumGlobalResonance ?? 0.0)

        // Fetch params (not per-sample to save CPU, but per-buffer is fine)
        func getParam(_ inst: String, _ key: String) -> Double {
            return manager?.drumParams[inst]?[key] ?? 0.5
        }

        var peaks: [Float] = [0, 0]
        var rmsSums: [Float] = [0, 0]

        for i in 0..<frameCount {
            var outVal: Double = 0

            // --- Bass Drum (BD) ---
            if bdTrigger { bdPhase = 0; bdEnv = 1.0; bdTrigger = false }
            if bdEnv > 0 {
                let tune = getParam("BD", "Tune")
                let decay = getParam("BD", "Decay")
                let level = getParam("BD", "Level")
                let filt = getParam("BD", "Filter")
                let res = getParam("BD", "Res")
                let mod = getParam("BD", "Mod")

                let baseFreq = 30.0 + (60.0 * tune)
                let freq = baseFreq + (100.0 * mod * bdEnv) // Pitch sweep depth from Mod
                let raw = sin(bdPhase) * bdEnv * level
                bdPhase += (2.0 * .pi * freq) / sampleRate
                let decaySpeed = 1.0 / (sampleRate * (0.1 + (0.5 * decay)))
                bdEnv -= decaySpeed
                if bdEnv < 0 { bdEnv = 0 }
                outVal += instrumentFilters["BD"]!.process(raw, cutoff: filt, res: res, sr: sampleRate)
            }

            // --- Snare Drum (SD) ---
            if sdTrigger { sdPhase1 = 0; sdPhase2 = 0; sdEnvTonal = 1.0; sdEnvNoise = 1.0; sdTrigger = false }
            if sdEnvTonal > 0 || sdEnvNoise > 0 {
                let tune = getParam("SD", "Tune")
                let decay = getParam("SD", "Decay")
                let level = getParam("SD", "Level")
                let snappy = getParam("SD", "Snappy")
                let filt = getParam("SD", "Filter")
                let res = getParam("SD", "Res")
                let mod = getParam("SD", "Mod")

                let freq1 = (180.0 + (200.0 * tune)) * (0.5 + mod)
                let freq2 = (330.0 + (300.0 * tune)) * (0.5 + mod)
                let tonal = (sin(sdPhase1) + sin(sdPhase2)) * 0.5 * sdEnvTonal
                sdPhase1 += (2.0 * .pi * freq1) / sampleRate
                sdPhase2 += (2.0 * .pi * freq2) / sampleRate

                let noise = Double.random(in: -1...1) * sdEnvNoise * snappy * 1.5
                let raw = (tonal + noise) * level

                let decaySpeedTonal = 1.0 / (sampleRate * (0.05 + (0.15 * decay)))
                let decaySpeedNoise = 1.0 / (sampleRate * (0.1 + (0.25 * decay)))
                sdEnvTonal -= decaySpeedTonal
                sdEnvNoise -= decaySpeedNoise
                if sdEnvTonal < 0 { sdEnvTonal = 0 }
                if sdEnvNoise < 0 { sdEnvNoise = 0 }
                outVal += instrumentFilters["SD"]!.process(raw, cutoff: filt, res: res, sr: sampleRate)
            }

            // --- Hi-Hats (CH / OH) ---
            if hhTrigger { hhEnv = 1.0; hhTrigger = false }
            if hhEnv > 0 {
                let inst = hhIsClosed ? "CH" : "OH"
                let tune = getParam(inst, "Tune")
                let decay = getParam(inst, "Decay")
                let level = getParam(inst, "Level")
                let filt = getParam(inst, "Filter")
                let res = getParam(inst, "Res")
                let mod = getParam(inst, "Mod")

                var hhOsc: Double = 0
                let baseFreq = (200.0 + (200.0 * tune)) * (0.5 + mod)
                for j in 0..<6 {
                    hhPhases[j] += (2.0 * .pi * baseFreq * hhRatios[j]) / sampleRate
                    hhOsc += (hhPhases[j].truncatingRemainder(dividingBy: 2.0 * .pi) < .pi) ? 1.0 : -1.0
                }
                hhOsc /= 6.0

                let fc = 7000.0 / sampleRate
                let alpha = fc / (fc + 1.0)
                let highpassed = alpha * (hhFilterY1 + hhOsc - hhFilterX1)
                hhFilterX1 = hhOsc
                hhFilterY1 = highpassed

                let raw = highpassed * hhEnv * 0.5 * level
                let decayTime = hhIsClosed ? (0.05 + 0.1 * decay) : (0.2 + 0.4 * decay)
                let decaySpeed = 1.0 / (sampleRate * decayTime)
                hhEnv -= decaySpeed
                if hhEnv < 0 { hhEnv = 0 }
                outVal += instrumentFilters[inst]!.process(raw, cutoff: filt, res: res, sr: sampleRate)
            }

            // --- Toms (LT, MT, HT) ---
            func processTom(_ inst: String, _ trigger: inout Bool, _ phase: inout Double, _ env: inout Double) -> Double {
                if trigger { phase = 0; env = 1.0; trigger = false }
                if env > 0 {
                    let tune = getParam(inst, "Tune")
                    let decay = getParam(inst, "Decay")
                    let level = getParam(inst, "Level")
                    let filt = getParam(inst, "Filter")
                    let res = getParam(inst, "Res")
                    let mod = getParam(inst, "Mod")
                    let baseF = inst == "LT" ? 70.0 : (inst == "MT" ? 110.0 : 160.0)
                    let freq = (baseF + (baseF * 1.1 * tune)) * (0.5 + mod)
                    let raw = sin(phase) * env * 0.7 * level
                    phase += (2.0 * .pi * freq) / sampleRate
                    env -= 1.0 / (sampleRate * (0.1 + (0.3 * decay)))
                    if env < 0 { env = 0 }
                    return instrumentFilters[inst]!.process(raw, cutoff: filt, res: res, sr: sampleRate)
                }
                return 0
            }
            outVal += processTom("LT", &ltTrigger, &ltPhase, &ltEnv)
            outVal += processTom("MT", &mtTrigger, &mtPhase, &mtEnv)
            outVal += processTom("HT", &htTrigger, &htPhase, &htEnv)

            // --- Clap (CP) ---
            if cpTrigger { cpTime = 0; cpEnv = 1.0; cpTrigger = false }
            if cpEnv > 0 {
                let decay = getParam("CP", "Decay")
                let level = getParam("CP", "Level")
                let filt = getParam("CP", "Filter")
                let res = getParam("CP", "Res")
                let mod = getParam("CP", "Mod")
                let noise = Double.random(in: -1...1)

                var multiEnv = 0.0
                let t = cpTime
                if t < 0.01 { multiEnv = t / 0.01 }
                else if t < 0.02 { multiEnv = (t - 0.01) / 0.01 }
                else if t < 0.03 { multiEnv = (t - 0.02) / 0.01 }
                else { multiEnv = cpEnv }

                let raw = noise * multiEnv * 0.6 * level * (0.5 + mod)
                cpTime += 1.0 / sampleRate
                if cpTime > 0.03 {
                    cpEnv -= 1.0 / (sampleRate * (0.1 + (0.3 * decay)))
                }
                if cpEnv < 0 { cpEnv = 0 }
                outVal += instrumentFilters["CP"]!.process(raw, cutoff: filt, res: res, sr: sampleRate)
            }

            // --- Cowbell (CB) ---
            if cbTrigger { cbPhase1 = 0; cbPhase2 = 0; cbEnv = 1.0; cbTrigger = false }
            if cbEnv > 0 {
                let tune = getParam("CB", "Tune")
                let decay = getParam("CB", "Decay")
                let level = getParam("CB", "Level")
                let filt = getParam("CB", "Filter")
                let res = getParam("CB", "Res")
                let mod = getParam("CB", "Mod")
                let freq1 = (540.0 + (200.0 * tune)) * (0.5 + mod)
                let freq2 = (800.0 + (300.0 * tune)) * (0.5 + mod)
                let rawOsc = ((cbPhase1 < .pi ? 1.0 : -1.0) + (cbPhase2 < .pi ? 1.0 : -1.0)) * 0.5 * cbEnv
                cbPhase1 += (2.0 * .pi * freq1) / sampleRate
                cbPhase2 += (2.0 * .pi * freq2) / sampleRate
                if cbPhase1 > 2 * .pi { cbPhase1 -= 2 * .pi }
                if cbPhase2 > 2 * .pi { cbPhase2 -= 2 * .pi }

                cbEnv -= 1.0 / (sampleRate * (0.1 + (0.4 * decay)))
                if cbEnv < 0 { cbEnv = 0 }
                let raw = rawOsc * 0.5 * level
                outVal += instrumentFilters["CB"]!.process(raw, cutoff: filt, res: res, sr: sampleRate)
            }

            // --- Rimshot (RS) ---
            if rsTrigger { rsPhase1 = 0; rsPhase2 = 0; rsEnv = 1.0; rsTrigger = false }
            if rsEnv > 0 {
                let tune = getParam("RS", "Tune")
                let decay = getParam("RS", "Decay")
                let level = getParam("RS", "Level")
                let filt = getParam("RS", "Filter")
                let res = getParam("RS", "Res")
                let mod = getParam("RS", "Mod")
                let f1 = (1700.0 + (500.0 * tune)) * (0.5 + mod)
                let f2 = (400.0 + (200.0 * tune)) * (0.5 + mod)
                let rawOsc = (sin(rsPhase1) + sin(rsPhase2)) * rsEnv
                rsPhase1 += (2.0 * .pi * f1) / sampleRate
                rsPhase2 += (2.0 * .pi * f2) / sampleRate
                rsEnv -= 1.0 / (sampleRate * (0.02 + (0.05 * decay)))
                if rsEnv < 0 { rsEnv = 0 }
                let raw = rawOsc * 0.5 * level
                outVal += instrumentFilters["RS"]!.process(raw, cutoff: filt, res: res, sr: sampleRate)
            }

            // --- Cymbal (CY) ---
            if cyTrigger { cyEnv = 1.0; cyTrigger = false }
            if cyEnv > 0 {
                let tune = getParam("CY", "Tune")
                let decay = getParam("CY", "Decay")
                let level = getParam("CY", "Level")
                let filt = getParam("CY", "Filter")
                let res = getParam("CY", "Res")
                let mod = getParam("CY", "Mod")
                var cyOsc: Double = 0
                let baseFreq = (250.0 + (200.0 * tune)) * (0.5 + mod)
                for j in 0..<6 {
                    cyPhases[j] += (2.0 * .pi * baseFreq * hhRatios[j]) / sampleRate
                    cyOsc += (cyPhases[j].truncatingRemainder(dividingBy: 2.0 * .pi) < .pi) ? 1.0 : -1.0
                }
                cyOsc /= 6.0

                let fc = 5000.0 / sampleRate
                let alpha = fc / (fc + 1.0)
                let highpassed = alpha * (cyFilterY1 + cyOsc - cyFilterX1)
                cyFilterX1 = cyOsc
                cyFilterY1 = highpassed

                let raw = highpassed * cyEnv * 0.5 * level
                cyEnv -= 1.0 / (sampleRate * (0.5 + (1.5 * decay)))
                if cyEnv < 0 { cyEnv = 0 }
                outVal += instrumentFilters["CY"]!.process(raw, cutoff: filt, res: res, sr: sampleRate)
            }

            let finalDrums = outVal * 0.6 // Master kit scalar

            // Apply Global Filter
            let f = cutoffParam * 1.16
            let fb = resParam * 4.0 * (1.0 - 0.15 * f * f)
            let input = Float(finalDrums) - y4 * fb
            let clipped = max(-1.0, min(1.0, input))

            y1 = y1 + f * (clipped - y1 + oldx - oldy1)
            y2 = y2 + f * (y1 - y2 + oldy1 - oldy2)
            y3 = y3 + f * (y2 - y3 + oldy2 - oldy3)
            y4 = y4 + f * (y3 - y4 + oldy3 - oldy4)

            oldx = clipped
            oldy1 = y1
            oldy2 = y2
            oldy3 = y3
            oldy4 = y4

            let finalVal = y4

            buffer[i*2] = finalVal
            buffer[i*2 + 1] = finalVal

            lBuf[i] = finalVal
            rBuf[i] = finalVal

            peaks[0] = max(peaks[0], abs(finalVal))
            peaks[1] = max(peaks[1], abs(finalVal))
            rmsSums[0] += finalVal * finalVal
            rmsSums[1] += finalVal * finalVal
        }

        // Push directly to C mixer ring buffer
        if let deviceID = manager?.drumMachineDeviceID {
            _ = Mixer_FeedSingleChannelToMixer(UInt32(deviceID), 0, 0, lBuf, Int32(frameCount))
            _ = Mixer_FeedSingleChannelToMixer(UInt32(deviceID), 0, 1, rBuf, Int32(frameCount))
        }

        // Push metering
        let rms = [
            sqrt(rmsSums[0] / Float(max(1, frameCount))),
            sqrt(rmsSums[1] / Float(max(1, frameCount)))
        ]
        manager?.pushDrumMeters(peaks: peaks, rms: rms)
    }

    func handleMIDI(status: UInt8, data1: UInt8, data2: UInt8) {
        let type = status & 0xF0
        if type == 0x90 && data2 > 0 {
            switch data1 {
            case 36: bdTrigger = true
            case 38, 40: sdTrigger = true
            case 42, 44: hhTrigger = true; hhIsClosed = true
            case 46: hhTrigger = true; hhIsClosed = false
            case 41: ltTrigger = true
            case 43: mtTrigger = true
            case 45, 47: htTrigger = true
            case 39: cpTrigger = true
            case 56: cbTrigger = true
            case 37: rsTrigger = true
            case 49, 51, 52, 53, 55, 57: cyTrigger = true
            default: break
            }
        }
    }
}

private class UtilityPhysicalModelEngine: InstrumentAudioRenderDelegate {
    private let sampleRate: Double
    weak var manager: UtilityInstrumentManager?

    private struct PMVoice {
        var delayLine: UnsafeMutablePointer<Float>
        var length: Int = 100
        var readIndex: Int = 0
        var note: UInt8 = 0
        var isActive: Bool = false
        var envelope: Float = 0

        // Filter state
        var y1: Float = 0, y2: Float = 0, y3: Float = 0, y4: Float = 0
        var oldx: Float = 0, oldy1: Float = 0, oldy2: Float = 0, oldy3: Float = 0, oldy4: Float = 0

        static func create() -> PMVoice {
            let line = UnsafeMutablePointer<Float>.allocate(capacity: 4800)
            line.initialize(repeating: 0, count: 4800)
            return PMVoice(delayLine: line)
        }

        func deallocate() {
            delayLine.deallocate()
        }

        mutating func resetFilter() {
            y1 = 0; y2 = 0; y3 = 0; y4 = 0
            oldx = 0; oldy1 = 0; oldy2 = 0; oldy3 = 0; oldy4 = 0
        }
    }

    private var voices: UnsafeMutablePointer<PMVoice>
    private let maxVoices = 8
    private let voiceLock = NSLock()

    // Realtime buffers
    private var leftBuffer: UnsafeMutablePointer<Float>?
    private var rightBuffer: UnsafeMutablePointer<Float>?
    private var maxFrames: Int = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        voices = UnsafeMutablePointer<PMVoice>.allocate(capacity: maxVoices)
        for i in 0..<maxVoices {
            voices[i] = PMVoice.create()
        }
    }

    deinit {
        leftBuffer?.deallocate()
        rightBuffer?.deallocate()
        for i in 0..<maxVoices {
            voices[i].deallocate()
        }
        voices.deallocate()
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        if frameCount > maxFrames {
            leftBuffer?.deallocate()
            rightBuffer?.deallocate()
            leftBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            rightBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            maxFrames = frameCount
        }

        guard let lBuf = leftBuffer, let rBuf = rightBuffer else { return }

        // Character Mapping from XY Pad
        // X: 0 (Wood) -> 1 (Metal)
        // Y: 0 (Glass) -> 1 (String)
        let pmX = Float(manager?.pmX ?? 0.5)
        let pmY = Float(manager?.pmY ?? 0.5)

        // Interpolate base params from XY position
        // Damping: Wood is high, Metal is low
        let baseDamping = (1.0 - pmX) * 0.4 + 0.1 // Wood has higher loss
        // Brightness: Glass/Metal high, Wood low
        let baseBrightness = pmX * 0.5 + (1.0 - pmY) * 0.3 + 0.2
        // Decay: String long, Wood short
        let baseDecay = pmY * 0.6 + pmX * 0.3 + 0.1

        let damping = (1.0 - baseDamping) * 0.5 + 0.495
        let brightness = baseBrightness
        let masterVol = Float(manager?.pmMasterVolume ?? 0.8)
        let drive = Float(manager?.pmDistortion ?? 0.0) * 10.0

        // Filter Params
        let rawCutoff = Float(manager?.pmCutoff ?? 1.0)
        let cutoffFreq = 20.0 * pow(1000.0, rawCutoff)
        let cutoffParam = min(0.99, max(0.01, cutoffFreq / (Float(sampleRate) * 0.5)))
        let resParam = Float(manager?.pmResonance ?? 0.0)

        var peaks: [Float] = [0, 0]
        var rmsSums: [Float] = [0, 0]

        memset(buffer, 0, frameCount * 2 * MemoryLayout<Float>.size)
        memset(lBuf, 0, frameCount * MemoryLayout<Float>.size)
        memset(rBuf, 0, frameCount * MemoryLayout<Float>.size)

        let locked = voiceLock.try()

        for i in 0..<frameCount {
            var outVal: Float = 0

            for vIdx in 0..<maxVoices {
                if !voices[vIdx].isActive { continue }

                let current = voices[vIdx].delayLine[voices[vIdx].readIndex]
                let nextIndex = (voices[vIdx].readIndex + 1) % voices[vIdx].length
                let next = voices[vIdx].delayLine[nextIndex]

                var filtered = (current + next) * 0.5
                filtered = (current * (1.0 - brightness)) + (filtered * brightness)

                let damped = filtered * damping
                voices[vIdx].delayLine[voices[vIdx].readIndex] = damped
                voices[vIdx].readIndex = nextIndex

                // Expressive Filter
                let f = cutoffParam * 1.16
                let fb = resParam * 4.0 * (1.0 - 0.15 * f * f)
                let input = current - voices[vIdx].y4 * fb
                let clippedInput = max(-1.0, min(1.0, input))

                voices[vIdx].y1 = voices[vIdx].y1 + f * (clippedInput - voices[vIdx].y1 + voices[vIdx].oldx - voices[vIdx].oldy1)
                voices[vIdx].y2 = voices[vIdx].y2 + f * (voices[vIdx].y1 - voices[vIdx].y2 + voices[vIdx].oldy1 - voices[vIdx].oldy2)
                voices[vIdx].y3 = voices[vIdx].y3 + f * (voices[vIdx].y2 - voices[vIdx].y3 + voices[vIdx].oldy2 - voices[vIdx].oldy3)
                voices[vIdx].y4 = voices[vIdx].y4 + f * (voices[vIdx].y3 - voices[vIdx].y4 + voices[vIdx].oldy3 - voices[vIdx].oldy4)

                voices[vIdx].oldx = clippedInput
                voices[vIdx].oldy1 = voices[vIdx].y1
                voices[vIdx].oldy2 = voices[vIdx].y2
                voices[vIdx].oldy3 = voices[vIdx].y3
                voices[vIdx].oldy4 = voices[vIdx].y4

                outVal += voices[vIdx].y4 * voices[vIdx].envelope

                // Natural string decay using character-based multiplier
                voices[vIdx].envelope *= (0.9999 + (baseDecay * 0.00008))
                if voices[vIdx].envelope < 0.001 {
                    voices[vIdx].isActive = false
                }
            }

            // Saturation / Distortion
            var finalVal = outVal
            if drive > 0.01 {
                // Tanh approximation for soft saturation
                let driven = finalVal * (1.0 + drive)
                finalVal = driven / (1.0 + abs(driven))
            }

            finalVal = max(-1.0, min(1.0, finalVal * masterVol))

            buffer[i*2] = finalVal
            buffer[i*2 + 1] = finalVal
            lBuf[i] = finalVal
            rBuf[i] = finalVal

            peaks[0] = max(peaks[0], abs(finalVal))
            peaks[1] = max(peaks[1], abs(finalVal))
            rmsSums[0] += finalVal * finalVal
            rmsSums[1] += finalVal * finalVal
        }

        if locked { voiceLock.unlock() }

        if let deviceID = manager?.physicalModelDeviceID {
            _ = Mixer_FeedSingleChannelToMixer(UInt32(deviceID), 0, 0, lBuf, Int32(frameCount))
            _ = Mixer_FeedSingleChannelToMixer(UInt32(deviceID), 0, 1, rBuf, Int32(frameCount))
        }

        let rms = [
            sqrt(rmsSums[0] / Float(max(1, frameCount))),
            sqrt(rmsSums[1] / Float(max(1, frameCount)))
        ]
        manager?.pushPhysicalModelMeters(peaks: peaks, rms: rms)
    }

    func handleMIDI(status: UInt8, data1: UInt8, data2: UInt8) {
        let type = status & 0xF0
        if type == 0x90 && data2 > 0 {
            let freq = 440.0 * pow(2.0, (Double(data1) - 69.0) / 12.0)
            let periodSamples = Int(sampleRate / freq)
            let length = min(4800, max(10, periodSamples))

            voiceLock.lock()
            defer { voiceLock.unlock() }

            var bestIdx = 0
            for i in 0..<maxVoices {
                if !voices[i].isActive { bestIdx = i; break }
            }

            voices[bestIdx].length = length
            voices[bestIdx].readIndex = 0
            voices[bestIdx].note = data1
            voices[bestIdx].isActive = true
            voices[bestIdx].envelope = 1.0

            let excitation = Float(manager?.pmExcitation ?? 0.8)
            for i in 0..<length {
                voices[bestIdx].delayLine[i] = Float.random(in: -1.0...1.0) * excitation
            }
        } else if type == 0x80 || (type == 0x90 && data2 == 0) {
            voiceLock.lock()
            defer { voiceLock.unlock() }
            for i in 0..<maxVoices {
                if voices[i].isActive && voices[i].note == data1 {
                    voices[i].envelope *= 0.5
                }
            }
        }
    }
}

private class UtilitySamplerEngine: InstrumentAudioRenderDelegate {
    private let sampleRate: Double
    weak var manager: UtilityInstrumentManager?

    private class SamplerVoice {
        var bankIndex: Int = 0
        var position: Double = 0
        var isActive: Bool = false
        var note: UInt8 = 0
        var playbackRate: Double = 1.0

        // Envelope
        var envLevel: Float = 0
        var envState: EnvState = .idle
        enum EnvState { case idle, attack, decay, sustain, release }

        // Filter state
        var y1: Float = 0, y2: Float = 0, y3: Float = 0, y4: Float = 0
        var oldx: Float = 0, oldy1: Float = 0, oldy2: Float = 0, oldy3: Float = 0, oldy4: Float = 0

        func resetFilter() {
            y1 = 0; y2 = 0; y3 = 0; y4 = 0
            oldx = 0; oldy1 = 0; oldy2 = 0; oldy3 = 0; oldy4 = 0
        }
    }

    private var voices: [SamplerVoice] = []
    private let maxVoices = 16

    // Realtime buffers
    private var leftBuffer: UnsafeMutablePointer<Float>?
    private var rightBuffer: UnsafeMutablePointer<Float>?
    private var maxFrames: Int = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        for _ in 0..<maxVoices {
            voices.append(SamplerVoice())
        }
    }

    deinit {
        leftBuffer?.deallocate()
        rightBuffer?.deallocate()
    }

    func render(into buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        if frameCount > maxFrames {
            leftBuffer?.deallocate()
            rightBuffer?.deallocate()
            leftBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            rightBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            maxFrames = frameCount
        }

        guard let lBuf = leftBuffer, let rBuf = rightBuffer else { return }

        let masterVol = Float(manager?.samplerMasterVolume ?? 0.8)

        let attackParam = Float(manager?.samplerAttack ?? 0.01)
        let decayParam = Float(manager?.samplerDecay ?? 0.1)
        let sustainParam = Float(manager?.samplerSustain ?? 1.0)
        let releaseParam = Float(manager?.samplerRelease ?? 0.2)

        let attackRate = 1.0 / (Float(sampleRate) * max(0.001, attackParam * 2.0))
        let decayRate = 1.0 / (Float(sampleRate) * max(0.001, decayParam * 2.0))
        let releaseRate = 1.0 / (Float(sampleRate) * max(0.001, releaseParam * 3.0))

        // Filter Params
        let rawCutoff = Float(manager?.samplerCutoff ?? 1.0)
        let cutoffFreq = 20.0 * pow(1000.0, rawCutoff)
        let cutoffParam = min(0.99, max(0.01, cutoffFreq / (Float(sampleRate) * 0.5)))
        let resParam = Float(manager?.samplerResonance ?? 0.0)

        var peaks: [Float] = [0, 0]
        var rmsSums: [Float] = [0, 0]

        memset(buffer, 0, frameCount * 2 * MemoryLayout<Float>.size)
        memset(lBuf, 0, frameCount * MemoryLayout<Float>.size)
        memset(rBuf, 0, frameCount * MemoryLayout<Float>.size)

        for i in 0..<frameCount {
            var outVal: Float = 0

            for voice in voices {
                if voice.envState == .idle { continue }

                guard let bank = manager?.samplerBanks[voice.bankIndex],
                      let data = bank.sampleData else {
                    voice.envState = .idle
                    continue
                }

                // Envelope
                switch voice.envState {
                case .attack:
                    voice.envLevel += attackRate
                    if voice.envLevel >= 1.0 { voice.envLevel = 1.0; voice.envState = .decay }
                case .decay:
                    voice.envLevel -= decayRate
                    if voice.envLevel <= sustainParam { voice.envLevel = sustainParam; voice.envState = .sustain }
                case .sustain:
                    voice.envLevel = sustainParam
                case .release:
                    voice.envLevel -= releaseRate
                    if voice.envLevel <= 0 { voice.envLevel = 0; voice.envState = .idle; continue }
                case .idle:
                    continue
                }

                let startFrame = Double(data.count) * bank.trimStart
                let endFrame = Double(data.count) * bank.trimEnd

                let currentPos = startFrame + voice.position

                if currentPos >= endFrame || Int(currentPos) >= data.count {
                    // Force release if sample ends
                    if voice.envState != .release {
                        voice.envState = .release
                    }
                    if voice.envLevel <= 0 {
                        voice.envState = .idle
                        continue
                    }
                }

                // Linear interpolation
                let idx = Int(currentPos)
                let frac = Float(currentPos - Double(idx))
                let s1 = (idx < data.count) ? data[idx] : 0
                let s2 = (idx + 1 < data.count) ? data[idx + 1] : s1
                let rawSample = s1 + (s2 - s1) * frac

                // Filter
                let f = cutoffParam * 1.16
                let fb = resParam * 4.0 * (1.0 - 0.15 * f * f)
                let input = rawSample - voice.y4 * fb
                let clipped = max(-1.0, min(1.0, input))

                voice.y1 = voice.y1 + f * (clipped - voice.y1 + voice.oldx - voice.oldy1)
                voice.y2 = voice.y2 + f * (voice.y1 - voice.y2 + voice.oldy1 - voice.oldy2)
                voice.y3 = voice.y3 + f * (voice.y2 - voice.y3 + voice.oldy2 - voice.oldy3)
                voice.y4 = voice.y4 + f * (voice.y3 - voice.y4 + voice.oldy3 - voice.oldy4)

                voice.oldx = clipped
                voice.oldy1 = voice.y1
                voice.oldy2 = voice.y2
                voice.oldy3 = voice.y3
                voice.oldy4 = voice.y4

                outVal += voice.y4 * Float(bank.level) * voice.envLevel
                voice.position += voice.playbackRate
            }

            let finalVal = max(-1.0, min(1.0, outVal * masterVol))
            buffer[i*2] = finalVal
            buffer[i*2 + 1] = finalVal
            lBuf[i] = finalVal
            rBuf[i] = finalVal

            peaks[0] = max(peaks[0], abs(finalVal))
            peaks[1] = max(peaks[1], abs(finalVal))
            rmsSums[0] += finalVal * finalVal
            rmsSums[1] += finalVal * finalVal
        }

        if let deviceID = manager?.samplerDeviceID {
            _ = Mixer_FeedSingleChannelToMixer(UInt32(deviceID), 0, 0, lBuf, Int32(frameCount))
            _ = Mixer_FeedSingleChannelToMixer(UInt32(deviceID), 0, 1, rBuf, Int32(frameCount))
        }

        let rms = [
            sqrt(rmsSums[0] / Float(max(1, frameCount))),
            sqrt(rmsSums[1] / Float(max(1, frameCount)))
        ]
        manager?.pushSamplerMeters(peaks: peaks, rms: rms)
    }

    func handleMIDI(status: UInt8, data1: UInt8, data2: UInt8) {
        let type = status & 0xF0
        if type == 0x90 && data2 > 0 {
            var bankIdx = -1
            var rate = 1.0

            if data1 >= 36 && data1 <= 46 {
                bankIdx = Int(data1) - 36
            } else if data1 >= 60 {
                bankIdx = manager?.selectedSamplerBankIndex ?? 0
                rate = pow(2.0, Double(Int(data1) - 60) / 12.0)
            }

            if bankIdx != -1 {
                let voice = voices.first(where: { $0.envState == .idle }) ?? voices[0]
                voice.bankIndex = bankIdx
                voice.position = 0
                voice.playbackRate = rate
                voice.envState = .attack
                voice.envLevel = 0
                voice.note = data1
                voice.resetFilter()
            }
        } else if type == 0x80 || (type == 0x90 && data2 == 0) {
            for voice in voices where voice.note == data1 && voice.envState != .idle {
                voice.envState = .release
            }
        }
    }
}
