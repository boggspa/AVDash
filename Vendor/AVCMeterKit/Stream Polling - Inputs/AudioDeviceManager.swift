///
///  AudioDeviceManager.swift
///
///
///  AudioDeviceManager.swift
///
///  Manages audio input devices and routes metering data (RMS and Peak) for all active audio devices.
///  This file:
///  - Initializes and polls input audio devices
///  - Buffers and normalizes incoming level data
///  - Handles starting/stopping of HAL input stream meters
///  - Supports device aggregation for combined device metering
///
///  Used by AVCMeter for visualizing per-channel levels across input devices.
///

import Foundation
import Combine
import CoreAudio
import AVFoundation
import Dispatch

typealias WriteToInputBufferC = @convention(c) (Int32, UnsafePointer<Float>?, Int32) -> Void





// MARK: - C-Compatible Metering Callback
// Called from the CoreAudio HAL audio thread. Must be real-time safe:
// NO ARC operations, NO Swift dictionary lookups, NO allocations.
// Uses pre-cached raw C RingBuffer pointers set up at registration time.
@_cdecl("SwiftMeterCallback")
public func SwiftMeterCallback(rmsArray: UnsafePointer<Float>?, peakArray: UnsafePointer<Float>?, channelCount: Int32, deviceID: AudioDeviceID, ctx: UnsafeMutableRawPointer?) {
    guard let rmsArray = rmsArray, let peakArray = peakArray, let ctx = ctx else { return }

    // takeUnretainedValue() is a no-op pointer cast — no ARC retain/release.
    let cache = Unmanaged<MeterCallbackCache>.fromOpaque(ctx).takeUnretainedValue()
    let count = min(Int(channelCount), cache.channelCount)
    for i in 0..<count {
        if let buf = cache.peakBuffers[i] { writeRingBuffer(buf, peakArray[i]) }
        if let buf = cache.rmsBuffers[i] { writeRingBuffer(buf, rmsArray[i]) }
    }
}



// MARK: - AudioDeviceContext

/// Represents an active audio device context used in routing and metering.
struct AudioDeviceContext {
    var device: AudioDevice
    var stream: PCMStream?
    var poller: DevicePoller?
}


// MARK: - AudioDeviceManager (Main Class)
/// `AudioDeviceManager`
///
/// Singleton observable class responsible for:
/// - Discovering and listing all input audio devices
/// - Starting and managing HAL input streams per device
/// - Collecting and buffering real-time audio levels (RMS and peak)
/// - Supporting aggregate device creation and per-channel masking
///
/// This manager feeds level data to the main SwiftUI interface for visual metering.
class AudioDeviceManager: ObservableObject {
    private static let handle: UnsafeMutableRawPointer = {
        guard let h = dlopen(nil, RTLD_NOW) else {
            fatalError("Could not open main program handle")
        }
        return h
    }()


    static let shared = AudioDeviceManager()
    private var refreshTimer: Timer?
    private var lastLogTime: Date = .distantPast

    @Published var inputDevices: [AudioDevice] = []
    @Published internal var activeDevices: [AudioDeviceID: DeviceMeteringContext] = [:]
    @Published var selectedChannelMasks: [AudioDeviceID: [Bool]] = [:]
    @Published internal var activeContexts: [AudioDeviceID: AudioDeviceContext] = [:]

    var isMetering: Bool {
        !activeDevices.isEmpty
    }

    // Meter levels: NOT @Published individually — batched via single objectWillChange.send()
    // to avoid 4 separate view invalidation passes per tick.
    var rmsLevel: Float = -100
    var peakLevel: Float = -100
    var levels: [Float] = []
    var peakLevels: [Float] = []
    var rmsLevels: [Float] = []

    private var fallbackCaptureSession: AVCaptureMeteringSession?

    init() {
        // Timer updates UI every 100ms (10Hz refresh rate) - only when there are active devices and values change
        let newTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task(priority: .userInitiated) {
                // Skip processing if no active devices
                guard !self.activeDevices.isEmpty else { return }

                let allRMS = self.activeDevices.flatMap { $0.value.rmsBuffer.allMostRecent() }
                let allPeak = self.activeDevices.flatMap { $0.value.peakBuffer.allMostRecent() }

                let rmsDb = allRMS.average()
                let peakDb = allPeak.max() ?? -100

                let newRMSLevels = allRMS.map { $0 <= 0.000_01 ? -100.0 : linearToDb($0) }
                let newPeakLevels = allPeak.map { $0 <= 0.000_01 ? -100.0 : linearToDb($0) }

                await MainActor.run {
                    // Only update published properties if values changed significantly
                    // This prevents excessive SwiftUI view invalidation
                    let rmsChanged = abs(self.rmsLevel - rmsDb) >= 0.1 || (rmsDb <= -99.5) != (self.rmsLevel <= -99.5)
                    let peakChanged = abs(self.peakLevel - peakDb) >= 0.1 || (peakDb <= -99.5) != (self.peakLevel <= -99.5)
                    let arraysChanged = newRMSLevels.count != self.rmsLevels.count || newPeakLevels.count != self.peakLevels.count

                    if rmsChanged || peakChanged || arraysChanged {
                        self.objectWillChange.send()
                        self.rmsLevels = newRMSLevels
                        self.peakLevels = newPeakLevels
                        self.rmsLevel = rmsDb
                        self.peakLevel = peakDb
                    }
                }
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        refreshTimer = newTimer
    }

    // MARK: - Device Discovery
    /// Scans and registers all input-capable audio devices, including renaming known aggregates.
    ///
    /// Devices with zero input channels or missing UIDs are filtered out.
    /// This function runs synchronously and posts updates to the `inputDevices` property on the main thread.
    func refreshDeviceList() {
        var buffer: [AudioDeviceID] = Array(repeating: 0, count: 128)
        var count: Int = 0
        buffer.withUnsafeMutableBufferPointer {
            count = Int(getAllInputAudioDeviceIDs($0.baseAddress, 128))
        }
        var devices: [AudioDevice] = []

        for i in 0..<count {
            let id = buffer[i]
            guard id != 0 else { continue }
            let name = String(cString: getDeviceName(id))
            guard let cUID = getDeviceUID(deviceID: id) else {
                print("Skipping device \(name) due to missing UID")
                GlobalChannelLogStore.shared.add("[InputDevice] Skipping device \(name) due to missing UID")
                continue
            }
            let uid = String(cString: cUID)
            let sampleRate = getSampleRate(id)
            let inputCh = getDeviceInputChannelCount(id)
            let outputCh = getDeviceOutputChannelCount(id)
            let transport = String(cString: getDeviceTransportType(id))

            var device = AudioDevice(
                deviceID: id,
                name: name,
                inputChannels: inputCh,
                outputChannels: outputCh,
                sampleRate: sampleRate,
                transportType: transport
            )

            // If you want to keep aggregate device renaming, you can keep this block;
            // If not, comment/remove it. For now, keep as a harmless rename.
            if name == "AVCMeter Aggregate" || uid.lowercased() == "com.avcmeter.aggregate" {
                print("Found aggregate device. Renaming to 'All Devices'")
                GlobalChannelLogStore.shared.add("[InputDevice] Found aggregate device. Renaming to 'All Devices'")
                device = AudioDevice(
                    deviceID: id,
                    name: "All Devices",
                    inputChannels: inputCh,
                    outputChannels: outputCh,
                    sampleRate: sampleRate,
                    transportType: transport
                )
            }

            devices.append(device)
        }

        // Filter out devices with deviceID == 0 before setting inputDevices
        devices = devices.filter { $0.deviceID != 0 }

        DispatchQueue.main.async {
            print("Refreshing input devices — found \(devices.count) total")
            GlobalChannelLogStore.shared.add("[InputDevice] Refreshing input devices — found \(devices.count) total")
            for device in devices {
                print("\(device.name) (\(device.deviceID)) - \(device.inputChannels) ch @ \(device.sampleRate) Hz")
                GlobalChannelLogStore.shared.add("[InputDevice] \(device.name) (\(device.deviceID)) - \(device.inputChannels) ch @ \(device.sampleRate) Hz")
            }
            self.inputDevices = []           // force flush
            self.inputDevices = devices      // assign fresh list to trigger UI update

            // Update ChannelStateManager global index mapping for all input and output devices
            let inputTuples = devices.map { ($0.deviceID, Int($0.inputChannels)) }
            let outputDevices = OutputDeviceManager.shared.outputDevices
            let outputTuples = outputDevices.map { ($0.deviceID, Int($0.outputChannels)) }
            ChannelStateManager.shared.rebuildGlobalChannelIndexes(inputDevices: inputTuples, outputDevices: outputTuples)
        }
    }

    /// Refreshes the device list and awaits its completion.
    ///
    /// This method calls the synchronous `refreshDeviceList` on the main actor and then polls,
    /// waiting up to one second for the `inputDevices` array to update with at least one device.
    ///
    /// Use this async method in contexts that require the device list to be refreshed and ready before continuing.
    func refreshDeviceListAsync() async {
        await MainActor.run {
            self.refreshDeviceList()
        }
        // Wait until inputDevices updates (max 1s)
        let start = Date()
        while Date().timeIntervalSince(start) < 1.0 {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            let count = await MainActor.run { self.inputDevices.count }
            if count > 0 { break }
        }
    }

    // MARK: - Metering Lifecycle
    /// Starts HAL-level metering and initializes shared ring buffers for a given audio device.
    ///
    /// - Parameter device: The `AudioDevice` to begin metering.
    /// If the device is already being metered, this function will no-op.
    func beginMetering(device: AudioDevice) {
        print("Attempting to start metering for device: \(device.name) (ID: \(device.deviceID))")
        GlobalChannelLogStore.shared.add("[InputDevice] Attempting to start metering for device: \(device.name) (ID: \(device.deviceID))")

        if activeDevices[device.deviceID] != nil {
            print("Device \(device.name) is already being metered.")
            GlobalChannelLogStore.shared.add("[InputDevice] Device \(device.name) is already being metered.")
            return
        }

        let handler = LevelHandler()
        handler.manager = self
        let meteringContext = DeviceMeteringContext(device: device, handler: handler)
        self.activeDevices[device.deviceID] = meteringContext

        // Build the callback cache: extract raw C RingBuffer* pointers so the audio
        // callback can write directly without any Swift ARC/dictionary operations.
        let chCount = Int(device.inputChannels)
        let cache = MeterCallbackCache(channelCount: chCount)
        for i in 0..<chCount {
            cache.peakBuffers[i] = meteringContext.peakBuffer.buffers[i].buffer
            cache.rmsBuffers[i] = meteringContext.rmsBuffer.buffers[i].buffer
        }
        let cachePtr = Unmanaged.passRetained(cache).toOpaque()
        meteringContext.callbackCacheContext = cachePtr

        // Ensure input channel UI state is initialized for this device
        ChannelStateManager.shared.initializeInputChannelStatesIfNeeded(for: device.deviceID, channelCount: chCount)
        RingBuffer_GlobalInit()

        // Set panning and mute state per instructions
        for channel in 0..<device.inputChannels {
            if ChannelStateManager.shared.isLinked(deviceID: device.deviceID, channel: Int(channel)) {
                if channel % 2 == 0 {
                    ChannelStateManager.shared.setPan(for: device.deviceID, channel: Int(channel), value: 0.0)
                } else {
                    ChannelStateManager.shared.setPan(for: device.deviceID, channel: Int(channel), value: 127.0)
                }
            } else {
                ChannelStateManager.shared.setPan(for: device.deviceID, channel: Int(channel), value: 63.0)
            }
            if ChannelStateManager.shared.isMuted(deviceID: device.deviceID, channel: Int(channel)) {
                ChannelStateManager.shared.toggleMute(deviceID: device.deviceID, channel: Int(channel))
            }
        }

        // Pass the cache pointer as the callback context — the audio callback
        // only touches raw C ring buffer pointers, no Swift objects.
        let status: OSStatus = startMeteringWithCallback(device.deviceID, SwiftMeterCallback, cachePtr)

        if status == 0 {
            if self.selectedChannelMasks[device.deviceID] == nil {
                self.selectedChannelMasks[device.deviceID] = Array(repeating: true, count: chCount)
            }
            GlobalChannelLogStore.shared.add("[InputDevice] Started metering for device: \(device.name) (ID: \(device.deviceID))")
        } else {
            self.activeDevices.removeValue(forKey: device.deviceID)
            Unmanaged<MeterCallbackCache>.fromOpaque(cachePtr).release()
            print("Failed to start HAL metering for device \(device.name) (ID: \(device.deviceID)) — status: \(status)")
            GlobalChannelLogStore.shared.add("[InputDevice] Failed to start HAL metering for device \(device.name) (ID: \(device.deviceID)) — status: \(status)")
        }
    }

    /// Stops metering and cleans up all related buffers and context pointers for a given device.
    ///
    /// - Parameter device: The `AudioDevice` for which metering should stop.
    func endMetering(for device: AudioDevice) {
        guard let context = activeDevices[device.deviceID] else { return }

        self.activeDevices.removeValue(forKey: device.deviceID)
        stopMetering(device.deviceID)

        // Release the callback cache (balances passRetained in beginMetering)
        if let cachePtr = context.callbackCacheContext {
            Unmanaged<MeterCallbackCache>.fromOpaque(cachePtr).release()
        }
        print("Stopped metering for device: \(device.name)")
        GlobalChannelLogStore.shared.add("[InputDevice] Stopped metering for device: \(device.name)")
    }

    /// Toggles metering on or off for the given device, depending on current state.
    ///
    /// - Parameter device: The `AudioDevice` to toggle metering for.
    func toggleMetering(for device: AudioDevice) {
        if activeDevices[device.deviceID] != nil {
            endMetering(for: device)
        } else {
            beginMetering(device: device)
            // Automatically update routing matrix with device's input channels
            if let context = self.activeDevices[device.deviceID] {
                let inputChannels = Array(0..<Int(device.inputChannels))
                AudioRoutingMatrixManager.shared.updateInputs([device.deviceID: inputChannels])
            }
        }
    }

    /// Ensures all current inputDevices are being metered and have channel masks. Removes state for stale devices.
    ///
    /// This method:
    /// - Starts metering on any input device not currently active.
    /// - Ensures the `selectedChannelMasks` entry exists and matches the input channel count.
    /// - Removes any `activeDevices` and `selectedChannelMasks` entries for devices no longer present.
    @MainActor
    func ensureMeteringActiveForAllInputDevices() {
        let validIDs = Set(inputDevices.map { $0.deviceID })
        let syntheticMeterIDs: Set<AudioDeviceID> = [888_888, 999_999]
        // Include virtual utility instrument IDs to prevent pruning
        let utilityIDs: Set<AudioDeviceID> = [1_000_000, 1_000_001, 1_000_002, 1_000_003, 1_000_004]
        let retainedIDs = validIDs.union(syntheticMeterIDs).union(utilityIDs)

        // Start metering and initialize masks
        for device in inputDevices {
            if activeDevices[device.deviceID] == nil {
                beginMetering(device: device)
            }
            let mask = selectedChannelMasks[device.deviceID] ?? Array(repeating: true, count: Int(device.inputChannels))
            if mask.count != Int(device.inputChannels) {
                let fixedMask = Array(repeating: true, count: Int(device.inputChannels))
                selectedChannelMasks[device.deviceID] = fixedMask
            }
        }

        // Prune state for devices no longer present
        for deviceID in activeDevices.keys where !retainedIDs.contains(deviceID) {
            if let dev = activeDevices[deviceID]?.device {
                endMetering(for: dev)
            } else {
                activeDevices.removeValue(forKey: deviceID)
            }
            selectedChannelMasks.removeValue(forKey: deviceID)
        }
    }
}
