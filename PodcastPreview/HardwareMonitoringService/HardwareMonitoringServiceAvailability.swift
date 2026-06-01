import Foundation
import ServiceManagement
import PodcastPreviewCore

enum HardwareMonitoringServiceAvailability {
    static var isSupportedOS: Bool {
        if #available(macOS 11.0, *) { return true }
        return false
    }

    static var usesSMAppServiceDaemon: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    static var modernDaemonInstallURL: URL {
        URL(fileURLWithPath: "/Library/LaunchDaemons")
            .appendingPathComponent(HardwareMonitoringServiceConstants.modernDaemonPlistName)
    }

    static var isModernDaemonInstalled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.daemon(plistName: HardwareMonitoringServiceConstants.modernDaemonPlistName).status == .enabled
        }
        return FileManager.default.fileExists(atPath: modernDaemonInstallURL.path)
    }

    private static var hasSystemSwiftConcurrencyRuntime: Bool {
        FileManager.default.fileExists(atPath: "/usr/lib/swift/libswift_Concurrency.dylib")
    }

    static var usesLegacyPrivilegedHelper: Bool {
        isSupportedOS && !usesSMAppServiceDaemon && hasSystemSwiftConcurrencyRuntime
    }

    static var usesLegacyUserLaunchAgent: Bool {
        isSupportedOS && !usesSMAppServiceDaemon && !hasSystemSwiftConcurrencyRuntime
    }

    static var legacyPrivilegedHelperInstallURL: URL {
        URL(fileURLWithPath: "/Library/PrivilegedHelperTools")
            .appendingPathComponent(HardwareMonitoringServiceConstants.legacyHelperBundleID)
    }

    static var isLegacyPrivilegedHelperInstalled: Bool {
        FileManager.default.fileExists(atPath: legacyPrivilegedHelperInstallURL.path)
    }
}
