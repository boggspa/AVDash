import Foundation
import AVFoundation
import CoreAudio

/// Manages an isolated AUHAL-based audio output pipeline for utility instruments.
/// Operates independently of the C-based mixer/ring buffer pipeline.
final class InstrumentOutputManager {
    static let shared = InstrumentOutputManager()

    private var outputUnit: AudioUnit?
    private var instruments: [InstrumentAudioRenderDelegate] = []
    private let lock = NSLock()

    private var tempBuffer: UnsafeMutablePointer<Float>?
    private var instrumentBuffer: UnsafeMutablePointer<Float>?
    private var maxFrames: UInt32 = 0

    private init() {
        setupAUHAL()
    }

    deinit {
        if let temp = tempBuffer { temp.deallocate() }
        if let inst = instrumentBuffer { inst.deallocate() }
    }

    private func setupAUHAL() {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else { return }
        AudioComponentInstanceNew(component, &outputUnit)

        var renderCallback = AURenderCallbackStruct(
            inputProc: { (inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData) -> OSStatus in
                let manager = Unmanaged<InstrumentOutputManager>.fromOpaque(inRefCon).takeUnretainedValue()
                return manager.render(ioActionFlags: ioActionFlags, inTimeStamp: inTimeStamp, inBusNumber: inBusNumber, inNumberFrames: inNumberFrames, ioData: ioData)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        AudioUnitSetProperty(outputUnit!, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &renderCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        AudioUnitSetProperty(outputUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        AudioUnitInitialize(outputUnit!)
        AudioOutputUnitStart(outputUnit!)
    }

    func register(instrument: InstrumentAudioRenderDelegate) {
        lock.lock()
        defer { lock.unlock() }
        instruments.append(instrument)
    }

    func unregister(instrument: InstrumentAudioRenderDelegate) {
        lock.lock()
        defer { lock.unlock() }
        instruments.removeAll { $0 === instrument }
    }

    private func render(ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, inTimeStamp: UnsafePointer<AudioTimeStamp>, inBusNumber: UInt32, inNumberFrames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData = ioData else { return noErr }

        if inNumberFrames > maxFrames {
            if let temp = tempBuffer { temp.deallocate() }
            if let inst = instrumentBuffer { inst.deallocate() }
            tempBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(inNumberFrames) * 2)
            instrumentBuffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(inNumberFrames) * 2)
            maxFrames = inNumberFrames
        }

        guard let tempBuf = tempBuffer, let instBuf = instrumentBuffer else { return noErr }

        let buffers = UnsafeMutableAudioBufferListPointer(ioData)

        // Zero out output buffers
        for buffer in buffers {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }

        // Clear temp buffer
        memset(tempBuf, 0, Int(inNumberFrames) * 2 * MemoryLayout<Float>.size)

        // Render each instrument into the output buffer
        lock.lock()
        let currentInstruments = instruments
        lock.unlock()

        for instrument in currentInstruments {
            memset(instBuf, 0, Int(inNumberFrames) * 2 * MemoryLayout<Float>.size)
            instrument.render(into: instBuf, frameCount: Int(inNumberFrames))

            for i in 0..<Int(inNumberFrames) * 2 {
                tempBuf[i] += instBuf[i]
            }
        }

        // Copy to AUHAL buffers
        for i in 0..<buffers.count {
            let buffer = buffers[i]
            let data = buffer.mData?.assumingMemoryBound(to: Float.self)
            for j in 0..<Int(inNumberFrames) {
                data?[j] = tempBuf[j * 2 + i] // Assuming interleaved inputs
            }
        }

        return noErr
    }
}
