import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

#if os(macOS)
import AppKit
#endif

final class VirtualInstrumentPreFaderTap {
    static let shared = VirtualInstrumentPreFaderTap()

    private struct ChannelRingBuffer {
        let capacity: Int
        var storage: [Float]
        var writeIndex: Int = 0
        var filledCount: Int = 0

        init(capacity: Int) {
            self.capacity = max(1, capacity)
            self.storage = Array(repeating: 0.0, count: max(1, capacity))
        }

        mutating func write(_ samples: [Float]) {
            guard !samples.isEmpty else { return }
            for sample in samples {
                storage[writeIndex] = sample
                writeIndex += 1
                if writeIndex == capacity {
                    writeIndex = 0
                }
                if filledCount < capacity {
                    filledCount += 1
                }
            }
        }

        func readLatest(frameCount: Int) -> [Float] {
            let requested = max(1, frameCount)
            let readCount = min(requested, filledCount)
            guard readCount > 0 else { return [] }

            var output = Array(repeating: Float(0.0), count: readCount)
            let start = (writeIndex - readCount + capacity) % capacity

            if start + readCount <= capacity {
                for i in 0..<readCount {
                    output[i] = storage[start + i]
                }
                return output
            }

            let firstPartCount = capacity - start
            for i in 0..<firstPartCount {
                output[i] = storage[start + i]
            }
            let secondPartCount = readCount - firstPartCount
            if secondPartCount > 0 {
                for i in 0..<secondPartCount {
                    output[firstPartCount + i] = storage[i]
                }
            }
            return output
        }
    }

    private let lock = NSLock()
    private var channelBuffers: [AudioDeviceID: [Int: ChannelRingBuffer]] = [:]

    private init() {}

    func configure(deviceID: AudioDeviceID, channelCount: Int, sampleRate: Double) {
        let safeChannelCount = max(1, channelCount)
        let capacity = max(2_048, Int(sampleRate) * 4)

        var perChannel: [Int: ChannelRingBuffer] = [:]
        perChannel.reserveCapacity(safeChannelCount)
        for channel in 0..<safeChannelCount {
            perChannel[channel] = ChannelRingBuffer(capacity: capacity)
        }

        lock.lock()
        channelBuffers[deviceID] = perChannel
        lock.unlock()
    }

    func remove(deviceID: AudioDeviceID) {
        lock.lock()
        channelBuffers.removeValue(forKey: deviceID)
        lock.unlock()
    }

    func write(deviceID: AudioDeviceID, channelIndex: Int, samples: [Float]) {
        guard !samples.isEmpty else { return }

        lock.lock()
        guard var perChannel = channelBuffers[deviceID], var buffer = perChannel[channelIndex] else {
            lock.unlock()
            return
        }

        buffer.write(samples)
        perChannel[channelIndex] = buffer
        channelBuffers[deviceID] = perChannel
        lock.unlock()
    }

    func readLatest(deviceID: AudioDeviceID, channelIndex: Int, frameCount: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard let perChannel = channelBuffers[deviceID], let buffer = perChannel[channelIndex] else {
            return []
        }
        return buffer.readLatest(frameCount: frameCount)
    }

    func availableFrames(deviceID: AudioDeviceID, channelIndex: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let perChannel = channelBuffers[deviceID], let buffer = perChannel[channelIndex] else {
            return 0
        }
        return buffer.filledCount
    }
}

final class VirtualInstrumentPreFaderAudioSource: FFTAudioSource {
    let deviceID: AudioDeviceID
    let name: String
    private let defaultChannelIndex: Int

    init(deviceID: AudioDeviceID, channelIndex: Int) {
        self.deviceID = deviceID
        self.defaultChannelIndex = max(0, channelIndex)
        self.name = "Virtual Instrument Pre-Fader"
    }

    func read(channel: Int, into outBuffer: inout [Float]) -> Int {
        guard !outBuffer.isEmpty else { return 0 }
        let targetChannel = max(0, channel)
        let samples = VirtualInstrumentPreFaderTap.shared.readLatest(
            deviceID: deviceID,
            channelIndex: targetChannel,
            frameCount: outBuffer.count
        )
        guard !samples.isEmpty else { return 0 }

        let copyCount = min(outBuffer.count, samples.count)
        for i in 0..<copyCount {
            outBuffer[i] = samples[i]
        }
        return copyCount
    }

    func readSamples(frameCount: Int) -> [Float] {
        VirtualInstrumentPreFaderTap.shared.readLatest(
            deviceID: deviceID,
            channelIndex: defaultChannelIndex,
            frameCount: frameCount
        )
    }

    func availableFrames(channel: Int? = nil) -> Int {
        let targetChannel = channel ?? defaultChannelIndex
        return VirtualInstrumentPreFaderTap.shared.availableFrames(
            deviceID: deviceID,
            channelIndex: max(0, targetChannel)
        )
    }

    func stop() throws {
        // No-op: lifecycle is owned by VirtualInstrumentHostManager.
    }
}

final class VirtualInstrumentSpectrogramFeed {
    private let source: VirtualInstrumentPreFaderAudioSource
    private let deviceID: Int32
    private let channelIndex: Int32
    private let queue = DispatchQueue(label: "com.avcmeter.spectrogram.vifeed", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    init(source: VirtualInstrumentPreFaderAudioSource, deviceID: Int32, channelIndex: Int32) {
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
        let samples = source.readSamples(frameCount: frameCount)
        guard !samples.isEmpty else { return }

        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            SpectroProcessor_HandleInput(deviceID, channelIndex, base, Int32(samples.count))
        }
    }
}

final class VirtualInstrumentHostManager: ObservableObject {
    static let shared = VirtualInstrumentHostManager()

    private let hostQueue = DispatchQueue(label: "com.avcmeter.virtual-instrument-host")
    private let mixerChannelInput: UInt32 = 0
    private let renderFrameCount: AVAudioFrameCount = 128

    private var activeDeviceID: AudioDeviceID = 999_999
    private var activeChannelCount: Int = 8
    private var activeSampleRate: Double = 48_000

    private var slotHosts: [Int: SlotHost] = [:]
    private var meteringContext: DeviceMeteringContext?
    private var renderTimer: DispatchSourceTimer?
    private var isStarted = false

    private init() {}

    @MainActor
    func start(deviceID: AudioDeviceID, channelCount: Int, sampleRate: Double) {
        guard channelCount > 0 else { return }
        guard MultiDeviceStreamManager.shared.ensureMixerReadyForStream(sampleRate: sampleRate) else {
            print("[VIHost] Failed to ensure mixer ready")
            return
        }

        let viMeteringContext = ensureVirtualInstrumentMeteringContext(
            deviceID: deviceID,
            channelCount: channelCount,
            sampleRate: sampleRate
        )

        let selections: [VirtualInstrumentDescriptor?] = (0..<channelCount).map { channelIndex in
            VirtualChannelManager.shared.selectedVirtualInstrument(for: deviceID, channelIndex: channelIndex)
        }

        hostQueue.async { [weak self] in
            guard let self = self else { return }
            if self.isStarted,
               self.activeDeviceID == deviceID,
               self.activeChannelCount == channelCount {
                self.meteringContext = viMeteringContext
                return
            }
            self.meteringContext = viMeteringContext
            self.startLocked(
                deviceID: deviceID,
                channelCount: channelCount,
                sampleRate: sampleRate,
                selections: selections
            )
        }
    }

    @MainActor
    func stop() {
        hostQueue.async { [weak self] in
            self?.stopLocked()
        }
    }

    @MainActor
    private func ensureVirtualInstrumentMeteringContext(
        deviceID: AudioDeviceID,
        channelCount: Int,
        sampleRate: Double
    ) -> DeviceMeteringContext {
        let manager = AudioDeviceManager.shared

        if let existing = manager.activeDevices[deviceID],
           Int(existing.device.inputChannels) == channelCount {
            manager.selectedChannelMasks[deviceID] = Array(repeating: true, count: channelCount)
            MultiDeviceStreamManager.shared.channelMaskCache[deviceID] = Array(repeating: true, count: channelCount)
            return existing
        }

        let viDevice = AudioDevice(
            deviceID: deviceID,
            name: "Virtual Instruments",
            inputChannels: UInt32(channelCount),
            outputChannels: 0,
            sampleRate: sampleRate,
            transportType: "virtual"
        )
        let handler = LevelHandler()
        handler.manager = manager
        let context = DeviceMeteringContext(device: viDevice, handler: handler)

        manager.activeDevices[deviceID] = context
        manager.selectedChannelMasks[deviceID] = Array(repeating: true, count: channelCount)
        MultiDeviceStreamManager.shared.channelMaskCache[deviceID] = Array(repeating: true, count: channelCount)
        return context
    }

    func updateInstrumentSelection(for deviceID: AudioDeviceID, channelIndex: Int, instrument: VirtualInstrumentDescriptor?) {
        hostQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.isStarted else { return }
            guard deviceID == self.activeDeviceID else { return }
            self.applySelectionLocked(channelIndex: channelIndex, instrument: instrument)
        }
    }

    func sendMIDINote(
        for deviceID: AudioDeviceID,
        channelIndex: Int,
        note: UInt8,
        velocity: UInt8
    ) {
        hostQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.isStarted, deviceID == self.activeDeviceID else { return }
            guard let host = self.slotHosts[channelIndex] else { return }

            if velocity == 0 {
                host.sendMIDINoteOff(note: note)
            } else {
                host.sendMIDINoteOn(note: note, velocity: velocity)
            }
        }
    }

    func triggerPreviewNote(
        for deviceID: AudioDeviceID,
        channelIndex: Int,
        note: UInt8,
        velocity: UInt8,
        duration: TimeInterval = 0.35
    ) {
        hostQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.isStarted, deviceID == self.activeDeviceID else { return }
            guard let host = self.slotHosts[channelIndex] else { return }

            host.sendMIDINoteOn(note: note, velocity: velocity)
            let loadedInstrumentID = host.instrumentID

            self.hostQueue.asyncAfter(deadline: .now() + max(0.05, duration)) { [weak self] in
                guard let self = self else { return }
                guard let currentHost = self.slotHosts[channelIndex],
                      currentHost.instrumentID == loadedInstrumentID else {
                    return
                }
                currentHost.sendMIDINoteOff(note: note)
            }
        }
    }

#if os(macOS)
    @MainActor
    func showInstrumentEditor(for deviceID: AudioDeviceID, channelIndex: Int) {
        hostQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.isStarted, deviceID == self.activeDeviceID else { return }
            guard let host = self.slotHosts[channelIndex] else { return }

            DispatchQueue.main.async {
                host.requestEditorViewController { viewController in
                    FloatingWindowController.shared.showVirtualInstrumentPluginWindow(
                        deviceID: deviceID,
                        channelIndex: channelIndex,
                        title: "VI \(channelIndex + 1) - \(host.instrumentDisplayName)",
                        viewController: viewController
                    )
                }
            }
        }
    }
#endif

    private func startLocked(
        deviceID: AudioDeviceID,
        channelCount: Int,
        sampleRate: Double,
        selections: [VirtualInstrumentDescriptor?]
    ) {
        activeDeviceID = deviceID
        activeChannelCount = channelCount
        activeSampleRate = sampleRate

        let registerResult = Mixer_RegisterDevice(UInt32(deviceID), mixerChannelInput, UInt32(channelCount))
        if registerResult != 0 {
            print("[VIHost] Failed to register virtual instrument device \(deviceID): \(registerResult)")
            return
        }

        VirtualInstrumentPreFaderTap.shared.configure(
            deviceID: deviceID,
            channelCount: channelCount,
            sampleRate: sampleRate
        )

        isStarted = true
        startRenderTimerIfNeeded()

        for channelIndex in 0..<channelCount {
            let instrument = selections.indices.contains(channelIndex) ? selections[channelIndex] : nil
            applySelectionLocked(channelIndex: channelIndex, instrument: instrument)
        }
    }

    private func stopLocked() {
        let closingDeviceID = activeDeviceID
        let closingChannelCount = activeChannelCount
        meteringContext = nil

        renderTimer?.cancel()
        renderTimer = nil

        for host in slotHosts.values {
            host.stop()
        }
        slotHosts.removeAll()

        if isStarted {
            let unregisterResult = Mixer_UnregisterDevice(UInt32(activeDeviceID), mixerChannelInput)
            if unregisterResult != 0 {
                print("[VIHost] Failed to unregister virtual instrument device \(activeDeviceID): \(unregisterResult)")
            }
        }

        VirtualInstrumentPreFaderTap.shared.remove(deviceID: closingDeviceID)

#if os(macOS)
        DispatchQueue.main.async {
            for channelIndex in 0..<closingChannelCount {
                FloatingWindowController.shared.closeVirtualInstrumentPluginWindow(
                    deviceID: closingDeviceID,
                    channelIndex: channelIndex
                )
            }
        }
#endif

        DispatchQueue.main.async {
            AudioDeviceManager.shared.activeDevices.removeValue(forKey: closingDeviceID)
            AudioDeviceManager.shared.selectedChannelMasks.removeValue(forKey: closingDeviceID)
            MultiDeviceStreamManager.shared.channelMaskCache.removeValue(forKey: closingDeviceID)
        }

        isStarted = false
    }

    private func applySelectionLocked(channelIndex: Int, instrument: VirtualInstrumentDescriptor?) {
        guard channelIndex >= 0, channelIndex < activeChannelCount else {
            return
        }

        guard let instrument else {
            slotHosts[channelIndex]?.stop()
            slotHosts.removeValue(forKey: channelIndex)
#if os(macOS)
            DispatchQueue.main.async { [activeDeviceID] in
                FloatingWindowController.shared.closeVirtualInstrumentPluginWindow(
                    deviceID: activeDeviceID,
                    channelIndex: channelIndex
                )
            }
#endif
            return
        }

        if let existingHost = slotHosts[channelIndex], existingHost.instrumentID == instrument.id {
            return
        }

        slotHosts[channelIndex]?.stop()
#if os(macOS)
        DispatchQueue.main.async { [activeDeviceID] in
            FloatingWindowController.shared.closeVirtualInstrumentPluginWindow(
                deviceID: activeDeviceID,
                channelIndex: channelIndex
            )
        }
#endif

        do {
            let host = try SlotHost(
                channelIndex: channelIndex,
                instrument: instrument,
                sampleRate: activeSampleRate,
                renderFrameCount: renderFrameCount
            )
            slotHosts[channelIndex] = host
            print("[VIHost] Loaded instrument '\(instrument.displayName)' on VI \(channelIndex + 1)")
        } catch {
            slotHosts.removeValue(forKey: channelIndex)
            print("[VIHost] Failed to load instrument '\(instrument.displayName)' on VI \(channelIndex + 1): \(error.localizedDescription)")
        }
    }

    private func startRenderTimerIfNeeded() {
        guard renderTimer == nil else { return }

        let period = max(0.001, Double(renderFrameCount) / max(activeSampleRate, 1.0))
        let timer = DispatchSource.makeTimerSource(queue: hostQueue)
        timer.schedule(deadline: .now(), repeating: period, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.renderTick()
        }
        timer.resume()
        renderTimer = timer
    }

    private func renderTick() {
        guard isStarted else { return }
        let deviceID = UInt32(activeDeviceID)
        var peakValues = Array(repeating: Float(0.0), count: activeChannelCount)
        var rmsValues = Array(repeating: Float(0.0), count: activeChannelCount)

        for (channelIndex, host) in slotHosts {
            guard channelIndex >= 0, channelIndex < activeChannelCount else { continue }
            guard let meterValues = host.renderAndFeed(
                deviceID: deviceID,
                channelIndex: channelIndex,
                mixerChannelType: mixerChannelInput
            ) else {
                continue
            }

            peakValues[channelIndex] = meterValues.peak
            rmsValues[channelIndex] = meterValues.rms
            VirtualInstrumentPreFaderTap.shared.write(
                deviceID: activeDeviceID,
                channelIndex: channelIndex,
                samples: meterValues.renderedSamples
            )
        }

        if let meteringContext {
            meteringContext.peakBuffer.write(peakValues)
            meteringContext.rmsBuffer.write(rmsValues)
        }
    }
}

private final class SlotHost {
    let instrumentID: String
    let instrumentDisplayName: String

    private let channelIndex: Int
    private let engine = AVAudioEngine()
    private let audioUnit: AVAudioUnit
    private let scheduleMIDIEventBlock: AUScheduleMIDIEventBlock?
    private let renderBuffer: AVAudioPCMBuffer
    private var monoScratch: [Float]

    init(
        channelIndex: Int,
        instrument: VirtualInstrumentDescriptor,
        sampleRate: Double,
        renderFrameCount: AVAudioFrameCount
    ) throws {
        self.channelIndex = channelIndex
        self.instrumentID = instrument.id
        self.instrumentDisplayName = instrument.displayName

        self.audioUnit = try SlotHost.instantiateAudioUnit(description: instrument.audioComponentDescription)
        self.scheduleMIDIEventBlock = self.audioUnit.auAudioUnit.scheduleMIDIEventBlock

        guard let renderFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw NSError(domain: "VirtualInstrumentHostManager", code: -100, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create render format"
            ])
        }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: renderFrameCount) else {
            throw NSError(domain: "VirtualInstrumentHostManager", code: -101, userInfo: [
                NSLocalizedDescriptionKey: "Failed to allocate render buffer"
            ])
        }
        self.renderBuffer = pcmBuffer
        self.monoScratch = Array(repeating: 0.0, count: Int(renderFrameCount))

        engine.attach(audioUnit)
        engine.connect(audioUnit, to: engine.mainMixerNode, format: renderFormat)
        try engine.enableManualRenderingMode(
            .offline,
            format: renderFormat,
            maximumFrameCount: renderFrameCount
        )
        try engine.start()
    }

    func stop() {
        engine.stop()
        engine.reset()
        engine.detach(audioUnit)
    }

    func sendMIDINoteOn(note: UInt8, velocity: UInt8, channel: UInt8 = 0) {
        sendMIDI(status: 0x90 | (channel & 0x0F), data1: note, data2: velocity)
    }

    func sendMIDINoteOff(note: UInt8, channel: UInt8 = 0) {
        sendMIDI(status: 0x80 | (channel & 0x0F), data1: note, data2: 0)
    }

#if os(macOS)
    func requestEditorViewController(completion: @escaping (NSViewController?) -> Void) {
        audioUnit.auAudioUnit.requestViewController { viewController in
            completion(viewController)
        }
    }
#endif

    struct MeterValues {
        let peak: Float
        let rms: Float
        let renderedSamples: [Float]
    }

    func renderAndFeed(deviceID: UInt32, channelIndex: Int, mixerChannelType: UInt32) -> MeterValues? {
        let frameCount = renderBuffer.frameCapacity
        renderBuffer.frameLength = frameCount

        do {
            let status = try engine.renderOffline(frameCount, to: renderBuffer)
            switch status {
            case .success, .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                break
            case .error:
                return nil
            @unknown default:
                return nil
            }
        } catch {
            return nil
        }

        guard let channelData = renderBuffer.floatChannelData else {
            return nil
        }

        let outputChannelCount = max(1, Int(renderBuffer.format.channelCount))
        let renderedFrameCount = Int(renderBuffer.frameLength)
        guard renderedFrameCount > 0 else { return nil }

        if monoScratch.count < renderedFrameCount {
            monoScratch = Array(repeating: 0.0, count: renderedFrameCount)
        }

        if outputChannelCount == 1 {
            let source = channelData[0]
            for frame in 0..<renderedFrameCount {
                monoScratch[frame] = source[frame]
            }
        } else {
            for frame in 0..<renderedFrameCount {
                var sum: Float = 0.0
                for channel in 0..<outputChannelCount {
                    sum += channelData[channel][frame]
                }
                monoScratch[frame] = sum / Float(outputChannelCount)
            }
        }

        monoScratch.withUnsafeBufferPointer { samples in
            guard let baseAddress = samples.baseAddress else { return }
            _ = Mixer_FeedSingleChannelToMixer(
                deviceID,
                mixerChannelType,
                UInt32(channelIndex),
                baseAddress,
                Int32(renderedFrameCount)
            )
        }

        var sumSquares: Float = 0.0
        var peak: Float = 0.0
        for frame in 0..<renderedFrameCount {
            let sample = monoScratch[frame]
            sumSquares += sample * sample
            let magnitude = abs(sample)
            if magnitude > peak {
                peak = magnitude
            }
        }

        let rms = renderedFrameCount > 0 ? sqrt(sumSquares / Float(renderedFrameCount)) : 0.0
        return MeterValues(
            peak: peak,
            rms: rms,
            renderedSamples: Array(monoScratch.prefix(renderedFrameCount))
        )
    }

    private static func instantiateAudioUnit(description: AudioComponentDescription) throws -> AVAudioUnit {
        let semaphore = DispatchSemaphore(value: 0)
        var instantiatedUnit: AVAudioUnit?
        var instantiationError: Error?

        AVAudioUnit.instantiate(with: description, options: []) { audioUnit, error in
            instantiatedUnit = audioUnit
            instantiationError = error
            semaphore.signal()
        }

        semaphore.wait()

        if let instantiationError {
            throw instantiationError
        }

        guard let instantiatedUnit else {
            throw NSError(domain: "VirtualInstrumentHostManager", code: -102, userInfo: [
                NSLocalizedDescriptionKey: "Audio Unit instantiation returned nil"
            ])
        }

        return instantiatedUnit
    }

    private func sendMIDI(status: UInt8, data1: UInt8, data2: UInt8) {
        if let scheduleMIDIEventBlock {
            var bytes = [status, data1, data2]
            bytes.withUnsafeBufferPointer { pointer in
                guard let baseAddress = pointer.baseAddress else { return }
                scheduleMIDIEventBlock(AUEventSampleTimeImmediate, 0, pointer.count, baseAddress)
            }
            return
        }

        _ = MusicDeviceMIDIEvent(
            audioUnit.audioUnit,
            UInt32(status),
            UInt32(data1),
            UInt32(data2),
            0
        )
    }
}
