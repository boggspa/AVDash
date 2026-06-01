// File: PowerMetricsServiceConstants.swift
// PodcastPreview
// Shared constants for the Power Metrics privileged helper foundation.
// This file is intended to be included in both the main app target and the helper target.

import Foundation

public enum PowerMetricsServiceConstants {
    // Main app bundle identifier
    public static let mainAppBundleID = "com.chrisizatt.PodcastPreview"

    // MARK: - Modern Helper (macOS 13+ SMAppService)
    
    // Helper/daemon bundle identifier for SMAppService (macOS 13+)
    public static let modernHelperBundleID = "com.chrisizatt.PodcastPreview.PowerMetricsService"
    
    // Mach service name for SMAppService (macOS 13+)
    public static let modernMachServiceName = "com.chrisizatt.PodcastPreview.PowerMetricsService"
    
    // The launchd property list file name for SMAppService (macOS 13+)
    // This plist will be included in the main app bundle Resources.
    public static let modernDaemonPlistName = "PowerMetricsService-Info.plist"
    
    // MARK: - Legacy Helper (macOS 11-12 SMJobBless)
    
    // Helper/daemon bundle identifier for SMJobBless (macOS 11-12)
    public static let legacyHelperBundleID = "com.chrisizatt.PodcastPreview.PowerMetricsJobBless"
    
    // Mach service name for SMJobBless (macOS 11-12)
    public static let legacyMachServiceName = "com.chrisizatt.PodcastPreview.PowerMetricsJobBless"
    
    // Embedded launchd plist name for SMJobBless (macOS 11-12)
    // This plist is embedded in the helper's Info.plist under the "Launchd" key
    public static let legacyDaemonPlistName = "PowerMetricsJobBless-launchd.plist"
    
    // MARK: - Runtime Active Values
    
    // Returns the appropriate helper bundle ID based on the current OS version
    public static var activeHelperBundleID: String {
        if #available(macOS 13.0, *) {
            return modernHelperBundleID
        } else {
            return legacyHelperBundleID
        }
    }
    
    // Returns the appropriate Mach service name based on the current OS version
    public static var activeMachServiceName: String {
        if #available(macOS 13.0, *) {
            return modernMachServiceName
        } else {
            return legacyMachServiceName
        }
    }

    // powermetrics invocation we intend to use.
    public static let powermetricsPath = "/usr/bin/powermetrics"
    public static let powermetricsSampleIntervalMilliseconds = 1000
    
    // Dynamic arguments based on architecture
    public static var powermetricsArgs: [String] {
        var samplers = "cpu_power,gpu_power"
        
        #if arch(arm64)
        // Apple Silicon has ANE (Neural Engine)
        samplers += ",ane_power"
        #endif
        
        return [
            "--samplers", samplers,
            "-i", String(powermetricsSampleIntervalMilliseconds),
            "-n", "1",
            "-f", "plist"
        ]
    }
}
