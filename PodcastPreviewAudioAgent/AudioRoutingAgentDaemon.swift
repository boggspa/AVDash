import Foundation
import os.log

final class AudioRoutingAgentDaemon: NSObject, AudioRoutingXPCProtocol {
    static let shared = AudioRoutingAgentDaemon()

    private let logger = Logger(subsystem: AudioRoutingServiceConstants.helperBundleID, category: "Daemon")
    private let queue = DispatchQueue(label: "com.chrisizatt.PodcastPreview.AudioAgent.route")
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()
    private let configStore = AudioRoutingConfigStore()

    private var configuration: AudioRoutingConfiguration
    private var appliedOutputDeviceUID: String = ""
    private var appliedBufferFrames: UInt32 = 0

    override init() {
        configuration = configStore.load()
        super.init()
        queue.sync {
            self.reconcileRouteLocked(forceRestart: true)
        }
    }

    func fetchStatus(_ reply: @escaping (Data?) -> Void) {
        queue.async {
            reply(self.encode(self.statusSnapshotLocked()))
        }
    }

    func setConfiguration(_ configurationData: Data, reply: @escaping (Data?) -> Void) {
        queue.async {
            guard let decoded = try? self.decoder.decode(AudioRoutingConfiguration.self, from: configurationData) else {
                reply(nil)
                return
            }

            self.configuration = decoded
            self.configStore.save(decoded)
            self.reconcileRouteLocked(forceRestart: false)
            reply(self.encode(self.statusSnapshotLocked()))
        }
    }

    func fetchTapSnapshot(_ maxFrames: NSNumber, reply: @escaping (Data?) -> Void) {
        queue.async {
            let requestedFrames = max(64, min(maxFrames.intValue, 4096))
            reply(self.encode(self.tapSnapshotLocked(maxFrames: requestedFrames)))
        }
    }

    private func stringFromFixedCBuffer<T>(_ buffer: T) -> String {
        withUnsafeBytes(of: buffer) { rawBuffer in
            let prefix = rawBuffer.prefix { $0 != 0 }
            return String(decoding: prefix, as: UTF8.self)
        }
    }

    private func statusSnapshotLocked() -> AudioRoutingStatusSnapshot {
        var routerStatus = PPVirtualLoopbackRouterStatus()
        PPVirtualLoopbackRouter_GetStatus(&routerStatus)

        var transportStatus = PPVirtualLoopbackStatus()
        PPVirtualLoopbackTransport_GetStatus(&transportStatus)

        return AudioRoutingStatusSnapshot(
            configuration: configuration,
            isRouteRunning: routerStatus.isRunning,
            activeOutputDeviceUID: stringFromFixedCBuffer(transportStatus.activeOutputDeviceUID),
            sampleRate: routerStatus.sampleRate,
            channels: routerStatus.channels,
            framesRendered: routerStatus.framesRendered,
            framesAvailable: routerStatus.framesAvailable,
            overruns: routerStatus.overruns,
            underruns: routerStatus.underruns,
            systemWriterConnected: transportStatus.systemWriterConnected,
            inputWriterConnected: transportStatus.inputWriterConnected,
            systemFramesWritten: transportStatus.systemFramesWritten,
            inputFramesWritten: transportStatus.inputFramesWritten,
            lastError: currentTransportErrorLocked()
        )
    }

    private func tapSnapshotLocked(maxFrames: Int) -> AudioRoutingTapSnapshot {
        guard configuration.tapAnalysisEnabled else {
            return AudioRoutingTapSnapshot(channels: 0, sampleRate: 0, frames: 0, interleavedPCM: Data())
        }

        guard PPVirtualLoopbackRouter_IsRunning(),
              let tapRingBuffer = PPVirtualLoopbackRouter_GetTapRingBuffer() else {
            return AudioRoutingTapSnapshot(channels: 0, sampleRate: 0, frames: 0, interleavedPCM: Data())
        }

        let channels = max(PPVirtualLoopbackRouter_GetTapChannelCount(), 1)
        let sampleRate = PPVirtualLoopbackRouter_GetTapSampleRate()

        var perChannel: [[Float]] = Array(repeating: Array(repeating: 0, count: maxFrames), count: Int(channels))
        var framesRead = 0

        for channel in 0..<Int(channels) {
            let readCount = perChannel[channel].withUnsafeMutableBufferPointer { buffer in
                RingBuffer_Read(tapRingBuffer, buffer.baseAddress, maxFrames, UInt32(channel))
            }
            framesRead = (channel == 0) ? readCount : min(framesRead, readCount)
        }

        guard framesRead > 0 else {
            return AudioRoutingTapSnapshot(channels: channels, sampleRate: sampleRate, frames: 0, interleavedPCM: Data())
        }

        var interleaved = Array(repeating: Float(0), count: framesRead * Int(channels))
        for frame in 0..<framesRead {
            for channel in 0..<Int(channels) {
                interleaved[frame * Int(channels) + channel] = perChannel[channel][frame]
            }
        }

        let data = interleaved.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }

        return AudioRoutingTapSnapshot(
            channels: channels,
            sampleRate: sampleRate,
            frames: UInt32(framesRead),
            interleavedPCM: data
        )
    }

    private func reconcileRouteLocked(forceRestart: Bool) {
        configuration.sampleRate = AudioRoutingServiceConstants.normalizeLoopbackSampleRate(configuration.sampleRate)
        let sampleRateStatus = AudioDevices_SetDeviceSampleRateByUID(AudioRoutingServiceConstants.loopbackDeviceUID,
                                                                     configuration.sampleRate)
        if sampleRateStatus != noErr {
            logger.error("Unable to set loopback device sample rate to \(self.configuration.sampleRate, privacy: .public) Hz (status \(sampleRateStatus))")
        }

        _ = PPVirtualLoopbackTransport_SetRequestedOutputDeviceUID(configuration.outputDeviceUID)
        _ = PPVirtualLoopbackTransport_SetSourceEnabled(kPPVirtualLoopbackSourceSystem, configuration.includeSystemAudio)
        _ = PPVirtualLoopbackTransport_SetSourceEnabled(kPPVirtualLoopbackSourceInput, configuration.includeSelectedInput)
        _ = PPVirtualLoopbackTransport_SetSourceGain(kPPVirtualLoopbackSourceSystem, configuration.systemAudioGain)
        _ = PPVirtualLoopbackTransport_SetSourceGain(kPPVirtualLoopbackSourceInput, configuration.selectedInputGain)
        PPVirtualLoopbackRouter_SetTapAnalysisEnabled(configuration.tapAnalysisEnabled)

        let shouldRun = configuration.routeEnabled && !configuration.outputDeviceUID.isEmpty
        let isRunning = PPVirtualLoopbackRouter_IsRunning()
        let routeChanged = configuration.outputDeviceUID != appliedOutputDeviceUID || configuration.bufferFrames != appliedBufferFrames

        if !shouldRun {
            if isRunning {
                PPVirtualLoopbackRouter_Stop()
            }
            appliedOutputDeviceUID = ""
            appliedBufferFrames = 0
            return
        }

        guard routeChanged || forceRestart || !isRunning else {
            return
        }

        if isRunning {
            PPVirtualLoopbackRouter_Stop()
        }

        let result = configuration.outputDeviceUID.withCString { uidCString in
            PPVirtualLoopbackRouter_Start(uidCString, configuration.bufferFrames)
        }

        if result == 0 {
            PPVirtualLoopbackTransport_SetLastError("")
            appliedOutputDeviceUID = configuration.outputDeviceUID
            appliedBufferFrames = configuration.bufferFrames
            logger.log("Audio route active on \(self.appliedOutputDeviceUID, privacy: .public)")
        } else {
            let errorText = currentTransportErrorLocked()
            if errorText.isEmpty {
                logger.error("Failed to start audio route helper")
            } else {
                logger.error("Failed to start audio route helper: \(errorText, privacy: .public)")
            }
        }
    }

    private func currentTransportErrorLocked() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PP_LOOPBACK_ERROR_TEXT_MAX))
        guard PPVirtualLoopbackTransport_CopyLastError(&buffer, UInt32(buffer.count)) == 0 else {
            return ""
        }
        return String(cString: buffer)
    }

    private func encode<T: Encodable>(_ value: T) -> Data? {
        try? encoder.encode(value)
    }
}
