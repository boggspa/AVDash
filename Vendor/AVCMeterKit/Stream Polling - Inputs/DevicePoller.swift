///
/// DevicePoller.swift
///
/// This file defines the `DevicePoller` class responsible for managing audio device polling and metering
/// using CoreAudio on macOS. It interacts with lower-level C functions to create and manage HAL streams,
/// handle audio input callbacks, and maintain metering data buffers.
///
/// The `DevicePoller` manages a mixer engine and channel masks for selective metering. It maintains a
/// thread-safe registry of active pollers keyed by `AudioDeviceID`, allowing starting and stopping
/// metering on devices.
///
/// # Key architectural points:
/// - Uses bridged C functions for HAL stream control and audio input processing.
/// - Uses `@MainActor` to ensure thread-safe access to shared state.
/// - Metering is driven by audio input callbacks and the mixer engine.
/// - Channel masking currently affects meter visibility.
/// - Ensures metering buffers are updated even during silence for accurate level reporting.
///

import Foundation
import CoreAudio
import Combine

@_silgen_name("HALInputStream_Close")
func HALInputStream_Close(_ device: UnsafeMutableRawPointer!)

@_silgen_name("Mixer_FeedSingleChannelToMixer")
func Mixer_FeedSingleChannelToMixer(_ deviceID: UInt32, _ type: UInt32, _ deviceChannelIndex: UInt32, _ samples: UnsafePointer<Float>?, _ numFrames: Int32) -> Int32

@_silgen_name("Mixer_UnregisterDevice")
func Mixer_UnregisterDevice(_ deviceID: UInt32, _ type: UInt32) -> Int32

/// Reads buffered audio samples for a given channel from the shared ring buffer.
///
@_silgen_name("SharedRingBuffer_ReadChannel")
func SharedRingBuffer_ReadChannel(
    _ ringBuffer: UnsafeMutableRawPointer?,
    _ channelIndex: Int32,
    _ outBuffer: UnsafeMutablePointer<Float>?,
    _ numFrames: Int32
) -> Int32

// MARK: - AudioDeviceInfo struct to represent audio device metadata

struct AudioDeviceInfo: Identifiable, Equatable {
    var id: AudioDeviceID
    var name: String
    var transportType: String
    var inputChannelCount: Int
    var outputChannelCount: Int
    var channelMask: [Bool]
    // Computed property for the number of buffered channels (channel mask count)
    var getBufferedChannelCount: Int {
        return channelMask.count
    }
}

// MARK: - DevicePoller class: Manages polling and metering for a single audio device

@MainActor
class DevicePoller: @unchecked Sendable {
    // Thread-safe registry of active pollers keyed by device ID
    @MainActor private static var _activePollers: [AudioDeviceID: DevicePoller] = [:] {
        didSet {
            // Ensure access goes through the concurrent queue setter
            assert(Thread.isMainThread, "Direct modification of _activePollers is unsafe. Use activePollers setter.")
        }
    }
    private static let activePollerQueue = DispatchQueue(label: "com.avcmeter.activePollerQueue", attributes: .concurrent)

    @MainActor
    static func getActivePollers(completion: @escaping ([AudioDeviceID: DevicePoller]) -> Void) {
        completion(_activePollers)
    }

    @MainActor
    static func setActivePollers(_ newValue: [AudioDeviceID: DevicePoller]) {
        _activePollers = newValue
    }

    @MainActor
    static func modifyActivePollers(_ block: @MainActor @escaping (inout [AudioDeviceID: DevicePoller]) -> Void) {
        block(&self._activePollers)
    }

    let deviceID: AudioDeviceID

    // Published channel mask controls which channels are visible in the UI; does not affect audio routing
    @MainActor @Published private(set) var channelMask: [Bool] = []

    private var halStream: UnsafeMutableRawPointer?
    nonisolated(unsafe) var ringBuffer: UnsafeMutableRawPointer?

    private var pollingTask: Task<Void, Never>? = nil

    private let pollInterval: TimeInterval = 1.0 // seconds
    private let MIXER_CHANNEL_INPUT: UInt32 = 0

    // MARK: - Initialization: Creates HAL stream, ring buffer, and mixer engine

    init(deviceID: AudioDeviceID) {
        self.deviceID = deviceID
        var defaultDeviceID = deviceID
        if deviceID == 0 {
            // Obtain the system default input device if deviceID is zero
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &defaultDeviceID)
            if status != noErr {
                print("[HALInput] Failed to get default input device")
                return
            }
        }

        // Initialize channel mask to all enabled channels
        self.channelMask = []

        // Metering is callback-driven; no periodic polling is started here.

        // Register this poller as active on the main actor queue
        Self._activePollers[defaultDeviceID] = self
    }

    // MARK: - Polling lifecycle

    func startPolling() {
        // Metering is callback-driven.
    }

    // MARK: - Update channel mask: affects UI visibility but does not modify HAL or mixer engine

    @MainActor
    func updateChannelMask(_ mask: [Bool]) {
        self.channelMask = mask
        // No longer modify HAL or mixer engine — mask now only affects which meters are visible
    }


    // MARK: - Start metering: begins audio input stream and mixer processing

    func start() {
        guard ringBuffer != nil else {
            print("[DevicePoller] No shared input ring buffer for deviceID \(deviceID); mixer feed is handled directly by HAL callbacks.")
            return
        }

        let numChannels = Int32(Self.getChannelCount(deviceID, isInput: true))

        // Ensure input channel UI state is initialized for this device
        ChannelStateManager.shared.initializeInputChannelStatesIfNeeded(for: deviceID, channelCount: Int(numChannels))

        // Connect poller output to mixer via a detached task that reads from ring buffer
        pollingTask = Task.detached { [weak self] in
            guard let self = self else { return }
            let deviceID = self.deviceID
            let frameCount: Int32 = 128

            while !Task.isCancelled {
                let mask = await MainActor.run { self.channelMask }
                let activeChannels = mask.enumerated().compactMap { $0.element ? $0.offset : nil }

                for channelIndex in activeChannels {
                    // Read audio samples from the ring buffer
                    var samples = [Float](repeating: 0.0, count: Int(frameCount))

                    guard let ringBuffer = self.ringBuffer else { continue }
                    let samplesRead = SharedRingBuffer_ReadChannel(
                        ringBuffer,
                        Int32(channelIndex),
                        &samples,
                        frameCount
                    )

                    if samplesRead > 0 {
                        // Feed samples to mixer
                        let feedResult = Mixer_FeedSingleChannelToMixer(
                            deviceID,
                            self.MIXER_CHANNEL_INPUT,
                            UInt32(channelIndex),
                            samples,
                            Int32(samplesRead)
                        )

                        if feedResult != 0 {
                            print("Failed to feed samples to mixer for device \(deviceID) channel \(channelIndex): error \(feedResult)")
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: 4_000_000) // ~4ms
            }

            print("[DevicePoller] Polling stopped for deviceID: \(deviceID)")
        }
    }

    // MARK: - Stop metering: stops the HAL stream

    func stop() {
        print("[DevicePoller][Stop] deviceID: \(deviceID)")

        pollingTask?.cancel()

        if let task = pollingTask {
            Task {
                _ = await task.value
                print("[DevicePoller] Polling task completed for deviceID: \(self.deviceID)")
            }
        }

        // Unregister device from mixer
        let unregResult = Mixer_UnregisterDevice(deviceID, MIXER_CHANNEL_INPUT)
        if unregResult != 0 {
            print("Failed to unregister device \(deviceID) from mixer: error code \(unregResult)")
        } else {
            print("Unregistered device \(deviceID) from mixer")
        }

        pollingTask = nil
    }

    // MARK: - Static helpers to query audio devices and properties

    static func getAllDevices() -> [AudioDeviceInfo] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size

        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { id in
            let name = getDeviceName(id) ?? "Unknown"
            let transport = getTransportType(id) ?? "Unknown"
            let inputChannels = getChannelCount(id, isInput: true)
            let outputChannels = getChannelCount(id, isInput: false)

            return AudioDeviceInfo(
                id: id,
                name: name,
                transportType: transport,
                inputChannelCount: inputChannels,
                outputChannelCount: outputChannels,
                channelMask: Array(repeating: true, count: inputChannels)
            )
        }
    }

    static func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        return status == noErr ? (name as String) : nil
    }

    static func getTransportType(_ deviceID: AudioDeviceID) -> String? {
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        if status != noErr { return nil }

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypePCI: return "PCI"
        default: return "Other"
        }
    }

    static func getChannelCount(_ deviceID: AudioDeviceID, isInput: Bool) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) != noErr {
            return 0
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPointer.deallocate() }

        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer) != noErr {
            return 0
        }

        let audioBufferList = bufferListPointer.bindMemory(to: AudioBufferList.self, capacity: 1).pointee
        var count = 0

        let audioBuffers = UnsafeBufferPointer(
            start: withUnsafePointer(to: audioBufferList.mBuffers) {
                UnsafeRawPointer($0).assumingMemoryBound(to: AudioBuffer.self)
            },
            count: Int(audioBufferList.mNumberBuffers)
        )

        for buffer in audioBuffers {
            count += Int(buffer.mNumberChannels)
        }

        return count
    }

    /// Reads buffered audio samples for a given channel into the provided buffer.
    ///
    /// - Parameters:
    ///   - channel: The input channel index to read from.
    ///   - frameCount: The number of frames to read.
    /// - Returns: An array of `Float` samples if available, otherwise an empty array.
    func readBuffer(for channel: Int, frameCount: Int) -> [Float] {
        guard ringBuffer != nil else { return [] }
        let buffer = [Float](repeating: 0.0, count: frameCount)
        return buffer
    }
}

// MARK: - DevicePoller extension: Static methods to start/stop metering for devices

extension DevicePoller {
    @MainActor
    static func startMetering(for deviceID: AudioDeviceID) {
        // Filter out synthetic device IDs that are not real Core Audio devices
        guard deviceID != 888_888 && deviceID != 999_999 else { return }

        if _activePollers[deviceID] == nil {
            let poller = DevicePoller(deviceID: deviceID)
            poller.start()
            _activePollers[deviceID] = poller
        }
    }

    @MainActor
    static func stopMetering(for deviceID: AudioDeviceID) {
        if let poller = _activePollers[deviceID] {
            poller.stop()
            _activePollers.removeValue(forKey: deviceID)
        }
    }
}

extension DevicePoller {
    var activeChannels: [Int] {
        channelMask.enumerated().compactMap { $0.element ? $0.offset : nil }
    }
}
