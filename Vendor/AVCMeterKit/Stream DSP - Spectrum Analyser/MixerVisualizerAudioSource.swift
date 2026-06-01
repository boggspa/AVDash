import Foundation
import CoreAudio

@_silgen_name("Mixer_ReadOutputChannelVisualBuffer")
private func Mixer_ReadOutputChannelVisualBuffer(
    _ deviceID: UInt32,
    _ deviceChannelIndex: UInt32,
    _ outputArray: UnsafeMutablePointer<Float>,
    _ maxCount: Int32
) -> Int32

@_silgen_name("Mixer_OutputChannelVisualBufferFilled")
private func Mixer_OutputChannelVisualBufferFilled(
    _ deviceID: UInt32,
    _ deviceChannelIndex: UInt32
) -> Int32

@_silgen_name("Mixer_ReadAuxSendBuffer")
private func Mixer_ReadAuxSendBuffer(_ busIndex: UInt32, _ outputArray: UnsafeMutablePointer<Float>, _ maxCount: Int32) -> Int32

@_silgen_name("Mixer_AuxSendBufferFilled")
private func Mixer_AuxSendBufferFilled(_ busIndex: UInt32) -> Int32

@_silgen_name("Mixer_ReadFXSendBuffer")
private func Mixer_ReadFXSendBuffer(_ busIndex: UInt32, _ outputArray: UnsafeMutablePointer<Float>, _ maxCount: Int32) -> Int32

@_silgen_name("Mixer_FXSendBufferFilled")
private func Mixer_FXSendBufferFilled(_ busIndex: UInt32) -> Int32

@_silgen_name("Mixer_ReadAuxReturnBuffer")
private func Mixer_ReadAuxReturnBuffer(_ busIndex: UInt32, _ outputArray: UnsafeMutablePointer<Float>, _ maxCount: Int32) -> Int32

@_silgen_name("Mixer_AuxReturnBufferFilled")
private func Mixer_AuxReturnBufferFilled(_ busIndex: UInt32) -> Int32

@_silgen_name("Mixer_ReadFXReturnBuffer")
private func Mixer_ReadFXReturnBuffer(_ busIndex: UInt32, _ outputArray: UnsafeMutablePointer<Float>, _ maxCount: Int32) -> Int32

@_silgen_name("Mixer_FXReturnBufferFilled")
private func Mixer_FXReturnBufferFilled(_ busIndex: UInt32) -> Int32

enum MixerVisualizerSource: Hashable {
    case output(deviceID: AudioDeviceID, channelIndex: Int)
    case auxSend(busIndex: Int)
    case fxSend(busIndex: Int)
    case auxReturn(busIndex: Int)
    case fxReturn(busIndex: Int)
}

final class MixerVisualizerAudioSource: FFTAudioSource {
    let source: MixerVisualizerSource
    let deviceID: AudioDeviceID
    let name: String

    init(source: MixerVisualizerSource, visualDeviceID: AudioDeviceID? = nil) {
        self.source = source
        self.deviceID = visualDeviceID ?? {
            switch source {
            case .output(let deviceID, _):
                return deviceID
            case .auxSend:
                return 80_000
            case .fxSend:
                return 81_000
            case .auxReturn:
                return 82_000
            case .fxReturn:
                return 83_000
            }
        }()

        switch source {
        case .output(let deviceID, _):
            self.name = String(cString: getDeviceName(deviceID))
        case .auxSend: self.name = "Aux Send"
        case .fxSend: self.name = "FX Send"
        case .auxReturn: self.name = "Aux Return"
        case .fxReturn: self.name = "FX Return"
        }
    }

    func read(channel _: Int, into outBuffer: inout [Float]) -> Int {
        readLatest(into: &outBuffer)
    }

    func readSamples(frameCount: Int) -> [Float] {
        let requested = max(1, frameCount)
        var buffer = [Float](repeating: 0.0, count: requested)
        let count = readLatest(into: &buffer)
        guard count > 0 else { return [] }
        if count < buffer.count {
            buffer.removeLast(buffer.count - count)
        }
        return buffer
    }

    func availableFrames() -> Int {
        switch source {
        case .output(let deviceID, let channelIndex):
            return Int(Mixer_OutputChannelVisualBufferFilled(UInt32(deviceID), UInt32(max(channelIndex, 0))))
        case .auxSend(let busIndex):
            return Int(Mixer_AuxSendBufferFilled(UInt32(max(busIndex, 0))))
        case .fxSend(let busIndex):
            return Int(Mixer_FXSendBufferFilled(UInt32(max(busIndex, 0))))
        case .auxReturn(let busIndex):
            return Int(Mixer_AuxReturnBufferFilled(UInt32(max(busIndex, 0))))
        case .fxReturn(let busIndex):
            return Int(Mixer_FXReturnBufferFilled(UInt32(max(busIndex, 0))))
        }
    }

    func stop() throws {
        // No-op: lifecycle is owned by mixer process.
    }

    private func readLatest(into outBuffer: inout [Float]) -> Int {
        guard !outBuffer.isEmpty else { return 0 }
        return outBuffer.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return 0 }
            switch source {
            case .output(let deviceID, let channelIndex):
                return Int(
                    Mixer_ReadOutputChannelVisualBuffer(
                        UInt32(deviceID),
                        UInt32(max(channelIndex, 0)),
                        base,
                        Int32(ptr.count)
                    )
                )
            case .auxSend(let busIndex):
                return Int(Mixer_ReadAuxSendBuffer(UInt32(max(busIndex, 0)), base, Int32(ptr.count)))
            case .fxSend(let busIndex):
                return Int(Mixer_ReadFXSendBuffer(UInt32(max(busIndex, 0)), base, Int32(ptr.count)))
            case .auxReturn(let busIndex):
                return Int(Mixer_ReadAuxReturnBuffer(UInt32(max(busIndex, 0)), base, Int32(ptr.count)))
            case .fxReturn(let busIndex):
                return Int(Mixer_ReadFXReturnBuffer(UInt32(max(busIndex, 0)), base, Int32(ptr.count)))
            }
        }
    }
}

final class MixerSpectrogramFeed {
    private let source: FFTAudioSource
    private let deviceID: Int32
    private let channelIndex: Int32
    private let queue = DispatchQueue(label: "com.avcmeter.spectrogram.mixerfeed", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    init(source: FFTAudioSource, deviceID: Int32, channelIndex: Int32) {
        self.source = source
        self.deviceID = deviceID
        self.channelIndex = channelIndex
    }

    func start() {
        guard timer == nil else { return }
        let newTimer = DispatchSource.makeTimerSource(flags: [], queue: queue)
        newTimer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
        newTimer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = newTimer
        newTimer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit {
        stop()
    }

    private func tick() {
        let fftSize = max(256, VisualisationSettings.shared.spectrumFFTSize)
        let frameCount = max(128, fftSize / 2)
        var samples = [Float](repeating: 0, count: frameCount)
        let readCount = source.read(channel: Int(channelIndex), into: &samples)
        guard readCount > 0 else { return }

        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            SpectroProcessor_HandleInput(deviceID, channelIndex, base, Int32(readCount))
        }
    }
}
