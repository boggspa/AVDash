import Foundation

public enum HardwareMonitoringServiceConstants {
    public static let mainAppBundleID = "com.chrisizatt.PodcastPreview"
    public static let modernHelperBundleID = "com.chrisizatt.PodcastPreview.HardwareAgent"
    public static let modernMachServiceName = "com.chrisizatt.PodcastPreview.HardwareAgent"
    public static let modernHelperExecutableName = "PodcastPreviewHardwareAgent"
    public static let legacyHelperBundleID = "com.chrisizatt.PodcastPreview.HardwareJobBless"
    public static let legacyMachServiceName = "com.chrisizatt.PodcastPreview.HardwareJobBless"
    public static let legacyHelperExecutableName = "com.chrisizatt.PodcastPreview.HardwareJobBless"
    public static let modernDaemonPlistName = "HardwareMonitoringService-Info.plist"
    public static let legacyHelperInfoPlistName = "HardwareMonitoringJobBless-Info.plist"
    public static let legacyPrivilegedHelperLaunchdPlistName = "HardwareMonitoringJobBless-launchd.plist"
    public static let legacyLaunchAgentPlistName = "PodcastPreviewHardwareAgent-LaunchAgent.plist"
    public static let legacyLaunchAgentLabel = modernHelperBundleID
    public static let legacyLaunchAgentHelperExecutableName = modernHelperExecutableName

    public static var helperBundleID: String {
        if #available(macOS 13.0, *) {
            return modernHelperBundleID
        }
        return legacyHelperBundleID
    }

    public static var machServiceName: String {
        if #available(macOS 13.0, *) {
            return modernMachServiceName
        }
        return legacyMachServiceName
    }

    public static var helperExecutableName: String {
        if #available(macOS 13.0, *) {
            return modernHelperExecutableName
        }
        return legacyHelperExecutableName
    }
}
