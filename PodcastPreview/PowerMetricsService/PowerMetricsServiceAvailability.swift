// File: PowerMetricsServiceAvailability.swift
// PodcastPreview
// Small availability helper for privileged power telemetry registration.

import Foundation
import os.log

public enum PowerMetricsServiceAvailability {
    /// The minimum macOS version that supports helper service registration.
    /// - macOS 11-12: SMJobBless (legacy)
    /// - macOS 13+: SMAppService (modern)
    public static var isSupportedOS: Bool {
        if #available(macOS 11.0, *) { return true }
        return false
    }
    
    /// Returns true if the modern SMAppService API is available (macOS 13+)
    public static var usesSMAppService: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }
    
    /// Returns true if we need to use legacy SMJobBless (macOS 11-12)
    public static var usesSMJobBless: Bool {
        return isSupportedOS && !usesSMAppService
    }

    public static var legacyPrivilegedHelperInstallURL: URL {
        URL(fileURLWithPath: "/Library/PrivilegedHelperTools")
            .appendingPathComponent(PowerMetricsServiceConstants.legacyHelperBundleID)
    }

    public static var isLegacyPrivilegedHelperInstalled: Bool {
        FileManager.default.fileExists(atPath: legacyPrivilegedHelperInstallURL.path)
    }

    /// Returns a user-visible unavailable reason if not supported.
    public static var unsupportedReason: String? {
        guard !isSupportedOS else { return nil }
        return "Privileged power telemetry requires macOS Big Sur (11.0) or later."
    }
}
