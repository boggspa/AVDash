//
//  OutputDeviceManager.swift
//  AVCMeter
//
//  Created by Chris Izatt on 06/07/2025.
//

import Foundation
import CoreAudio
import Darwin

@_silgen_name("getAllOutputAudioDeviceIDs")
func getAllOutputAudioDeviceIDs(_ outDevices: UnsafeMutablePointer<AudioDeviceID>?, _ maxDevices: Int32) -> Int32

@_silgen_name("HAL_StartOutputStream")
func HAL_StartOutputStream(_ deviceID: AudioDeviceID) -> OSStatus

@_silgen_name("HAL_StopOutputStream")
func HAL_StopOutputStream(_ deviceID: AudioDeviceID) -> OSStatus

// Added bridging for InitOutputRingBuffer that takes a pointer to OutputChannelRingBuffer array
@_silgen_name("InitOutputRingBuffer")
func InitOutputRingBuffer(_ ringBufferPtr: UnsafeMutablePointer<OutputChannelRingBuffer>, _ channelCount: Int32, _ bufferSize: Int32)

@_silgen_name("WriteToOutputBuffer")
func WriteToOutputBuffer(_ ringBufferPtr: UnsafeMutablePointer<OutputChannelRingBuffer>, _ channel: Int32, _ data: UnsafePointer<Float>?, _ frameCount: Int32)

@_silgen_name("ReadFromOutputBuffer")
func ReadFromOutputBuffer(_ ringBufferPtr: UnsafeMutablePointer<OutputChannelRingBuffer>, _ channel: Int32, _ output: UnsafeMutablePointer<Float>?, _ frameCount: Int32)

@_silgen_name("ClearOutputBuffers")
func ClearOutputBuffers(_ ringBufferPtr: UnsafeMutablePointer<OutputChannelRingBuffer>, _ channelCount: Int32)

@_silgen_name("FreeOutputBuffers")
func FreeOutputBuffers(_ ringBufferPtr: UnsafeMutablePointer<OutputChannelRingBuffer>, _ channelCount: Int32)

// MARK: - Static API wrappers for C functions

final class OutputDeviceManager: ObservableObject {
    @Published var outputDevices: [AudioDevice] = []
    @Published var activeOutputDevices: Set<AudioDeviceID> = []
    @Published var outputContexts: [AudioDeviceID: OutputMeteringContext] = [:]
    @Published var selectedChannelMasks: [AudioDeviceID: [Bool]] = [:]
    @Published var selectedChannelMaskVersion: Int = 0

    // Store per-device ring buffer pointers to OutputChannelRingBuffer arrays
    // This is necessary to maintain the lifetime of the buffers for each device
    private var outputRingBuffers: [AudioDeviceID: UnsafeMutablePointer<OutputChannelRingBuffer>] = [:]

    static let shared = OutputDeviceManager()

    private static let handle = dlopen(nil, RTLD_NOW)

    // Removed old function pointer usage in favor of direct @_silgen_name bridging


    static func startOutputStream(for deviceID: AudioDeviceID) -> OSStatus {
        HAL_StartOutputStream(deviceID)
    }


    static func stopOutputStream(for deviceID: AudioDeviceID) -> OSStatus {
        HAL_StopOutputStream(deviceID)
    }

    static func clearOutputBuffers(_ ringBufferPtr: UnsafeMutablePointer<OutputChannelRingBuffer>, channelCount: Int) {
        ClearOutputBuffers(ringBufferPtr, Int32(channelCount))
    }

    static func freeOutputBuffers(_ ringBufferPtr: UnsafeMutablePointer<OutputChannelRingBuffer>, channelCount: Int) {
        FreeOutputBuffers(ringBufferPtr, Int32(channelCount))
    }

    // Wrapper calls for write/read with ring buffer pointer
    static func writeToOutputBuffer(ringBufferPtr: UnsafeMutablePointer<OutputChannelRingBuffer>, channel: Int, data: UnsafePointer<Float>, frameCount: Int) {
        WriteToOutputBuffer(ringBufferPtr, Int32(channel), data, Int32(frameCount))
    }

    static func readFromOutputBuffer(ringBufferPtr: UnsafeMutablePointer<OutputChannelRingBuffer>, channel: Int, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        ReadFromOutputBuffer(ringBufferPtr, Int32(channel), output, Int32(frameCount))
    }
}

// MARK: - Channel Mask Helpers
extension OutputDeviceManager {
    private func syncRoutingMatrixOutputs() {
        let outputMap = MultiOutputStreamManager.shared.getActiveOutputChannels()
        AudioRoutingMatrixManager.shared.updateOutputs(outputMap)
        AudioRoutingMatrixManager.shared.updateRoutingMatrixMappings()
    }

    func channelMask(for deviceID: AudioDeviceID, channelCount: Int) -> [Bool] {
        if let mask = selectedChannelMasks[deviceID], mask.count == channelCount {
            return mask
        } else {
            let fallback = Array(repeating: true, count: channelCount)
            var updatedMasks = selectedChannelMasks
            updatedMasks[deviceID] = fallback
            selectedChannelMasks = updatedMasks
            return fallback
        }
    }

    func updateChannelMask(for deviceID: AudioDeviceID, mask: [Bool]) {
        var updatedMasks = selectedChannelMasks
        updatedMasks[deviceID] = mask
        selectedChannelMasks = updatedMasks
        selectedChannelMaskVersion += 1
        Task { @MainActor in
            MultiOutputStreamManager.shared.updateChannelMask(for: deviceID, mask: mask)
            self.syncRoutingMatrixOutputs()
        }
    }
}

// MARK: - OutputDeviceManager (Main Class)
extension OutputDeviceManager {

    /// Scans and registers all output-capable audio devices.
    ///
    /// Devices with zero output channels or missing UIDs are filtered out.
    func refreshOutputDeviceList() {
        var buffer: [AudioDeviceID] = Array(repeating: 0, count: 128)
        var count: Int = 0
        buffer.withUnsafeMutableBufferPointer {
            count = Int(getAllOutputAudioDeviceIDs($0.baseAddress, 128))
        }
        print("Output scan started - devices found: \(count)")
        GlobalChannelLogStore.shared.add("[OutputDevice] Output scan started - devices found: \(count)")

        var devices: [AudioDevice] = []

        for i in 0..<count {
            let id = buffer[i]
            guard id != 0 else { continue }
            let name = String(cString: getDeviceName(id))
            print("Checking device \(i): \(name)")
            GlobalChannelLogStore.shared.add("[OutputDevice] Checking device \(i): \(name)")
            guard let cUID = getDeviceUID(deviceID: id) else {
                print("Warning: Skipping output device \(name) due to missing UID")
                GlobalChannelLogStore.shared.add("[OutputDevice] Warning: Skipping output device \(name) due to missing UID")
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

            if name == "AVCMeter Aggregate" || uid.lowercased() == "com.avcmeter.aggregate" {
                print("Found aggregate output device. Renaming to 'All Outputs'")
                GlobalChannelLogStore.shared.add("[OutputDevice] Found aggregate output device. Renaming to 'All Outputs'")
                device = AudioDevice(
                    deviceID: id,
                    name: "All Outputs",
                    inputChannels: inputCh,
                    outputChannels: outputCh,
                    sampleRate: sampleRate,
                    transportType: transport
                )
            }

            devices.append(device)
        }

        devices = devices.filter { $0.deviceID != 0 }
        print("Final output device count after filtering: \(devices.count)")
        GlobalChannelLogStore.shared.add("[OutputDevice] Final output device count after filtering: \(devices.count)")

        DispatchQueue.main.async {
            print("Refreshing output devices - found \(devices.count) total")
            GlobalChannelLogStore.shared.add("[OutputDevice] Refreshing output devices - found \(devices.count) total")
            for device in devices {
                print("\(device.name) (\(device.deviceID)) - \(device.outputChannels) ch @ \(device.sampleRate) Hz")
                GlobalChannelLogStore.shared.add("[OutputDevice] \(device.name) (\(device.deviceID)) - \(device.outputChannels) ch @ \(device.sampleRate) Hz")
            }
            self.outputDevices = []           // flush
            self.outputDevices = devices      // trigger UI

            // Update ChannelStateManager global index mapping for all input and output devices
            let inputDevices = AudioDeviceManager.shared.inputDevices
            let inputTuples = inputDevices.map { ($0.deviceID, Int($0.inputChannels)) }
            let outputTuples = devices.map { ($0.deviceID, Int($0.outputChannels)) }
            ChannelStateManager.shared.rebuildGlobalChannelIndexes(inputDevices: inputTuples, outputDevices: outputTuples)
        }
    }

    // MARK: - Device Lifecycle

    @MainActor func startOutputStream(for device: AudioDevice) async {
        guard !activeOutputDevices.contains(device.deviceID) else {
            print("Info: Output stream already started for device: \(device.name)")
            GlobalChannelLogStore.shared.add("[OutputDevice] Info: Output stream already started for device: \(device.name)")
            return
        }

        await MultiDeviceStreamManager.shared.syncMeteredInputDevicesWithMixer()
        guard MultiDeviceStreamManager.shared.ensureMixerReadyForStream(sampleRate: device.sampleRate) else {
            print("Error: Mixer runtime not ready for output device: \(device.name)")
            return
        }
        ChannelStateManager.shared.initializeOutputChannelStatesIfNeeded(for: device.deviceID, channelCount: Int(device.outputChannels))

        let result = OutputDeviceManager.startOutputStream(for: device.deviceID)
        if result == noErr {
            // Create context directly without OutputLevelHandler
            let peakBuffer = MultiChannelOutputRingBuffer(
                channels: Int(device.outputChannels),
                capacity: 128
            )
            let rmsBuffer = MultiChannelOutputRingBuffer(
                channels: Int(device.outputChannels),
                capacity: 128
            )
            let handler = OutputLevelHandler(peakBuffer: peakBuffer)
            let context = OutputMeteringContext(device: device, handler: handler, peakBuffer: peakBuffer, rmsBuffer: rmsBuffer)

            // Crucially, do this synchronously:
            let defaultMask = Array(repeating: true, count: Int(device.outputChannels))
            var updatedMasks = selectedChannelMasks
            updatedMasks[device.deviceID] = defaultMask
            selectedChannelMasks = updatedMasks
            selectedChannelMaskVersion += 1
            var updatedContexts = outputContexts
            updatedContexts[device.deviceID] = context
            outputContexts = updatedContexts

            MultiOutputStreamManager.shared.updateChannelMask(for: device.deviceID, mask: defaultMask)
            MultiOutputStreamManager.shared.startStream(for: device.deviceID)

            var updatedActiveDevices = activeOutputDevices
            updatedActiveDevices.insert(device.deviceID)
            activeOutputDevices = updatedActiveDevices
            syncRoutingMatrixOutputs()
            print("Success: Started output for device: \(device.name)")
            GlobalChannelLogStore.shared.add("[OutputDevice] Success: Started output for device: \(device.name)")
        } else {
            print("Error: Failed to start output for device \(device.name): \(result)")
            GlobalChannelLogStore.shared.add("[OutputDevice] Error: Failed to start output for device \(device.name): \(result)")
        }
    }

    @MainActor
    func endOutput(for device: AudioDevice) {
        guard activeOutputDevices.contains(device.deviceID) else { return }
        MultiOutputStreamManager.shared.stopStream(for: device.deviceID)
        _ = OutputDeviceManager.stopOutputStream(for: device.deviceID)

        var updatedActiveDevices = activeOutputDevices
        updatedActiveDevices.remove(device.deviceID)
        activeOutputDevices = updatedActiveDevices
        print("ActiveOutputDevices after stop: \(activeOutputDevices)")
        GlobalChannelLogStore.shared.add("[OutputDevice] ActiveOutputDevices after stop: \(activeOutputDevices)")
        let hasActiveOutputs = !activeOutputDevices.isEmpty
        MultiDeviceStreamManager.shared.shutdownMixerIfIdle(hasActiveOutputs: hasActiveOutputs)

        var updatedContexts = outputContexts
        if updatedContexts.removeValue(forKey: device.deviceID) != nil {
            outputContexts = updatedContexts
            print("Removed output context for device: \(device.name)")
            GlobalChannelLogStore.shared.add("[OutputDevice] Removed output context for device: \(device.name)")
        }
        var updatedMasks = selectedChannelMasks
        if updatedMasks.removeValue(forKey: device.deviceID) != nil {
            selectedChannelMasks = updatedMasks
            print("Removed selected channel mask for device: \(device.name)")
            GlobalChannelLogStore.shared.add("[OutputDevice] Removed selected channel mask for device: \(device.name)")
        }
        MultiOutputStreamManager.shared.channelMaskCache.removeValue(forKey: device.deviceID)

        selectedChannelMaskVersion += 1
        syncRoutingMatrixOutputs()

        print("Stopped output for device: \(device.name)")
        GlobalChannelLogStore.shared.add("[OutputDevice] Stopped output for device: \(device.name)")
    }

    @MainActor func toggleOutput(for device: AudioDevice) async {
        if activeOutputDevices.contains(device.deviceID) {
            endOutput(for: device)
        } else {
            await startOutputStream(for: device)
        }
    }
}
