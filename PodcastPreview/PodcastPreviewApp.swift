//
//  PodcastPreviewApp.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 07/12/2025.
//

import SwiftUI
import PodcastPreviewShared
import AppKit
import AVFoundation
import ServiceManagement
import PodcastPreviewCore  // Import the framework

@main
struct PodcastPreviewApp: App {
    private func registerAudioRoutingServiceIfNeeded() {
        DispatchQueue.global(qos: .utility).async {
            let registrar = AudioRoutingServiceRegistrar()
            registrar.registerIfNeeded { result in
                switch result {
                case .success:
                    NSLog("Success: AudioRoutingService registration succeeded")
                case .failure(let error):
                    NSLog("Error: AudioRoutingService registration failed: %@", error.localizedDescription)
                }
            }
        }
    }

    private func registerPowerMetricsServiceIfNeeded() {
        if PowerMetricsServiceAvailability.usesSMJobBless,
           !PowerMetricsServiceAvailability.isLegacyPrivilegedHelperInstalled {
            return
        }
        // Run on all supported OS versions (macOS 11+)
        // The PowerMetricsServiceRegistrar internally handles OS version checks
        // and uses SMAppService on macOS 13+ or SMJobBless on macOS 11-12
        DispatchQueue.global(qos: .utility).async {
            let registrar = PowerMetricsServiceRegistrar()
            registrar.registerIfNeeded { result in
                switch result {
                case .success:
                    NSLog("Success: PowerMetricsService registration succeeded")
                    #if DEBUG
                    Task { @MainActor in
                        AppDebugConsole.log("Success: PowerMetricsService registration succeeded", category: "PowerMetrics")
                    }
                    #endif
                case .failure(let error):
                    NSLog("Error: PowerMetricsService registration failed: %@", error.localizedDescription)
                    #if DEBUG
                    Task { @MainActor in
                        AppDebugConsole.log("Error: PowerMetricsService registration failed: \(error.localizedDescription)", category: "PowerMetrics")
                    }
                    #endif
                }
            }
        }
    }

    /// Requests microphone, camera, and screen recording permissions on first-ever launch.
    private func requestPermissionsOnFirstLaunch() {
        let key = "hasRequestedInitialPermissions"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        // Microphone
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            NSLog(granted
                  ? "Success: Microphone permission granted"
                  : "Warning: Microphone permission denied")
        }

        // Camera
        AVCaptureDevice.requestAccess(for: .video) { granted in
            NSLog(granted
                  ? "Success: Camera permission granted"
                  : "Warning: Camera permission denied")
        }

        // Screen Recording (synchronous prompt via CoreGraphics)
        DispatchQueue.main.async {
            let granted = CGRequestScreenCaptureAccess()
            NSLog(granted
                  ? "Success: Screen recording permission granted"
                  : "Warning: Screen recording permission denied")
        }
    }

    private func registerHardwareMonitoringServiceIfNeeded() {
        guard HardwareMonitoringFeatureFlags.usesHeadlessAgent else {
            return
        }
        guard !HardwareMonitoringServiceAvailability.usesLegacyPrivilegedHelper else {
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let registrar = HardwareMonitoringServiceRegistrar()
            registrar.registerIfNeeded { result in
                switch result {
                case .success:
                    NSLog("Success: HardwareMonitoringService registration succeeded")
                    Task { @MainActor in
                        HardwareMonitoringModel.shared.ensureHistoryCollectionIsRunning()
                    }
                case .failure(let error):
                    NSLog("Error: HardwareMonitoringService registration failed: %@", error.localizedDescription)
                }
            }
        }
    }
    var body: some Scene {
        WindowGroup {
            WindowScaledRootView {
                MainWindowView()
                    .onAppear {
                        requestPermissionsOnFirstLaunch()
                        registerAudioRoutingServiceIfNeeded()
                        registerPowerMetricsServiceIfNeeded()
                        registerHardwareMonitoringServiceIfNeeded()
                        Task { @MainActor in
                            HardwareMonitoringModel.shared.ensureHistoryCollectionIsRunning()
                        }
                    }
            }
            .applyThemeEnvironment()
        }
        .windowStyle(.hiddenTitleBar) // optional, if you want the clean glass look

        #if DEBUG
        // Debug console window - using WindowGroup with ID for manual opening
        // This prevents the view from being instantiated at app launch
        // To open: Window → Show Debug Console (or press ⇧⌘D)
        WindowGroup("Debug Console", id: "debug-console") {
            WindowScaledRootView {
                DebugConsoleWindowContent()
            }
            .applyThemeEnvironment()
        }
        .commands {
            // Add keyboard shortcut via commands for macOS 11 compatibility
            CommandGroup(after: .windowArrangement) {
                Button("Show Debug Console") {
                    // Window will open automatically via WindowGroup
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
        #endif
    }
}

#if DEBUG
// Separate struct to defer loading of AppDebugConsoleView
private struct DebugConsoleWindowContent: View {
    var body: some View {
        AppDebugConsoleView()
    }
}
#endif
