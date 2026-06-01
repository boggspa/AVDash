//
//  CompanionApp.swift
//  PodcastPreviewCompanion
//
//  Menu-bar companion app for the remote Mac.
//  Runs a RemoteMonitoringServer and shows a status window/popover
//  with the passcode and connection status.
//

import SwiftUI
import PodcastPreviewCore

@main
struct PodcastPreviewCompanionApp: App {
    @StateObject private var serverModel = CompanionServerModel()

    var body: some Scene {
        MenuBarExtra {
            CompanionMenuBarView(model: serverModel)
        } label: {
            if #available(macOS 14.0, *) {
                Image(systemName: serverModel.server.isRunning ? "cpu.fill" : "cpu")
                    .symbolEffect(.pulse, isActive: serverModel.server.isRunning)
            } else {
                Image(systemName: serverModel.server.isRunning ? "cpu.fill" : "cpu")
            }
        }
        .menuBarExtraStyle(.window)

        // Main window shown on launch or when user clicks "Open Window"
        Window("Remote Hardware Companion", id: "companion-main") {
            CompanionMainWindow(model: serverModel)
                .frame(minWidth: 400, idealWidth: 440, maxWidth: 480,
                       minHeight: 520, idealHeight: 560, maxHeight: 700)
        }
        .windowResizability(.contentSize)
    }
}
