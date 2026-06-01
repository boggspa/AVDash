import Foundation

enum AudioRoutingServiceConstants {
    static let mainAppBundleID = "com.chrisizatt.PodcastPreview"
    static let helperBundleID = "com.chrisizatt.PodcastPreview.AudioAgent"
    static let machServiceName = "com.chrisizatt.PodcastPreview.AudioAgent"
    static let launchAgentPlistName = "PodcastPreviewAudioAgent-LaunchAgent.plist"
    static let loopbackDeviceUID = "com.chrisizatt.FireWireNetBridge.device"
    static let driverBundleName = "FireWireNetBridgeDriver.driver"
    static let bundledDriverRelativePath = "Contents/Library/Audio/Plug-Ins/HAL/\(driverBundleName)"
    static let installedDriverPath = "/Library/Audio/Plug-Ins/HAL/\(driverBundleName)"
    static let defaultLoopbackSampleRate = 48_000.0
    static let supportedLoopbackSampleRates: [Double] = [44_100.0, 48_000.0, 88_200.0, 96_000.0]

    static func normalizeLoopbackSampleRate(_ sampleRate: Double) -> Double {
        supportedLoopbackSampleRates.min(by: { abs($0 - sampleRate) < abs($1 - sampleRate) }) ?? defaultLoopbackSampleRate
    }
}
