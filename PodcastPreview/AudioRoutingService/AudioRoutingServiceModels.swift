import Foundation

enum AudioRoutingClientError: LocalizedError {
    case unavailable
    case registrationFailed
    case connectionFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Audio routing helper is unavailable on this macOS version."
        case .registrationFailed:
            return "Unable to register the audio routing helper."
        case .connectionFailed:
            return "Unable to connect to the audio routing helper."
        case .invalidResponse:
            return "The audio routing helper returned an invalid response."
        }
    }
}

struct AudioRoutingConfiguration: Codable, Equatable {
    var routeEnabled: Bool
    var outputDeviceUID: String
    var bufferFrames: UInt32
    var includeSystemAudio: Bool
    var includeSelectedInput: Bool
    var tapAnalysisEnabled: Bool
    var systemAudioGain: Float
    var selectedInputGain: Float
    var sampleRate: Double

    init(routeEnabled: Bool = false,
         outputDeviceUID: String = "",
         bufferFrames: UInt32 = 512,
         includeSystemAudio: Bool = true,
         includeSelectedInput: Bool = true,
         tapAnalysisEnabled: Bool = true,
         systemAudioGain: Float = 1.0,
         selectedInputGain: Float = 1.0,
         sampleRate: Double = AudioRoutingServiceConstants.defaultLoopbackSampleRate) {
        self.routeEnabled = routeEnabled
        self.outputDeviceUID = outputDeviceUID
        self.bufferFrames = bufferFrames
        self.includeSystemAudio = includeSystemAudio
        self.includeSelectedInput = includeSelectedInput
        self.tapAnalysisEnabled = tapAnalysisEnabled
        self.systemAudioGain = systemAudioGain
        self.selectedInputGain = selectedInputGain
        self.sampleRate = AudioRoutingServiceConstants.normalizeLoopbackSampleRate(sampleRate)
    }

    private enum CodingKeys: String, CodingKey {
        case routeEnabled
        case outputDeviceUID
        case bufferFrames
        case includeSystemAudio
        case includeSelectedInput
        case tapAnalysisEnabled
        case systemAudioGain
        case selectedInputGain
        case sampleRate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        routeEnabled = try container.decodeIfPresent(Bool.self, forKey: .routeEnabled) ?? false
        outputDeviceUID = try container.decodeIfPresent(String.self, forKey: .outputDeviceUID) ?? ""
        bufferFrames = try container.decodeIfPresent(UInt32.self, forKey: .bufferFrames) ?? 512
        includeSystemAudio = try container.decodeIfPresent(Bool.self, forKey: .includeSystemAudio) ?? true
        includeSelectedInput = try container.decodeIfPresent(Bool.self, forKey: .includeSelectedInput) ?? true
        tapAnalysisEnabled = try container.decodeIfPresent(Bool.self, forKey: .tapAnalysisEnabled) ?? true
        systemAudioGain = try container.decodeIfPresent(Float.self, forKey: .systemAudioGain) ?? 1.0
        selectedInputGain = try container.decodeIfPresent(Float.self, forKey: .selectedInputGain) ?? 1.0
        let decodedSampleRate = try container.decodeIfPresent(Double.self, forKey: .sampleRate)
            ?? AudioRoutingServiceConstants.defaultLoopbackSampleRate
        sampleRate = AudioRoutingServiceConstants.normalizeLoopbackSampleRate(decodedSampleRate)
    }
}

struct AudioRoutingStatusSnapshot: Codable, Equatable {
    var configuration: AudioRoutingConfiguration
    var isRouteRunning: Bool
    var activeOutputDeviceUID: String
    var sampleRate: Double
    var channels: UInt32
    var framesRendered: UInt64
    var framesAvailable: UInt64
    var overruns: UInt64
    var underruns: UInt64
    var systemWriterConnected: Bool
    var inputWriterConnected: Bool
    var systemFramesWritten: UInt64
    var inputFramesWritten: UInt64
    var lastError: String

    static let empty = AudioRoutingStatusSnapshot(
        configuration: AudioRoutingConfiguration(),
        isRouteRunning: false,
        activeOutputDeviceUID: "",
        sampleRate: 0,
        channels: 0,
        framesRendered: 0,
        framesAvailable: 0,
        overruns: 0,
        underruns: 0,
        systemWriterConnected: false,
        inputWriterConnected: false,
        systemFramesWritten: 0,
        inputFramesWritten: 0,
        lastError: ""
    )
}

struct AudioRoutingTapSnapshot: Codable, Equatable {
    var channels: UInt32
    var sampleRate: Double
    var frames: UInt32
    var interleavedPCM: Data

    static let empty = AudioRoutingTapSnapshot(
        channels: 0,
        sampleRate: 0,
        frames: 0,
        interleavedPCM: Data()
    )
}
