//
//  CompanionMainWindow.swift
//  PodcastPreviewCompanion
//
//  Main window showing server status, passcode, connected hosts,
//  and trusted host management for the companion Mac.
//

import SwiftUI
import PodcastPreviewCore

struct CompanionMainWindow: View {
    @ObservedObject var model: CompanionServerModel

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            ScrollView {
                VStack(spacing: 20) {
                    serverControlSection
                    cloudSyncSection
                    if model.server.isRunning {
                        passcodeSection
                    }
                    connectedHostsSection
                    trustedHostsSection
                }
                .padding(20)
            }
        }
        .sheet(item: Binding(
            get: { model.server.pendingAuthRequest },
            set: { _ in }
        )) { request in
            ConsentDialog(request: request, model: model)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "macwindow.and.cursorarrow")
                .font(.system(size: 28))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Remote Hardware Companion")
                    .font(.headline)
                Text("Allow other Macs to monitor this machine's hardware stats")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Server Control

    private var serverControlSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Monitoring Server", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.server.isRunning ? "Active — advertising on local network" : "Inactive")
                        .font(.subheadline)
                        .foregroundColor(model.server.isRunning ? .green : .secondary)
                    if model.server.isRunning {
                        Text("Advertising on local network via Bonjour")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { model.server.isRunning },
                    set: { enabled in
                        if enabled { model.startServer() } else { model.stopServer() }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }

    private var cloudSyncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("CloudKit Sync", systemImage: "icloud")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.isCloudSyncRunning ? "Publishing hardware snapshots to CloudKit" : "CloudKit publisher inactive")
                        .font(.subheadline)
                        .foregroundColor(model.isCloudSyncRunning ? .green : .secondary)
                    Spacer()
                    if let publishedAt = model.cloudLastPublishedAt {
                        Text("Last push \(publishedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let error = model.cloudLastErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("The iOS companion expects a MachineIdentity record plus a live CurrentSnapshot record for each source Mac.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }

    // MARK: - Passcode Section

    private var passcodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connection Passcode", systemImage: "key.horizontal")
                .font(.headline)

            Text("Share this code with the other Mac when prompted in PodcastPreview")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text(RemotePasscodeGenerator.formatted(model.server.currentPasscode))
                    .font(.system(size: 38, weight: .bold, design: .monospaced))
                    .kerning(4)
                    .frame(maxWidth: .infinity)

                VStack(spacing: 8) {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.server.currentPasscode, forType: .string)
                    }) {

                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)

                    Button(action: { model.rotatePasscode() }) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1))

            Text("Trusted Macs skip the approval prompt on reconnect. Every connection still uses the current passcode.")
                .font(.caption2)
                .foregroundColor(.secondary)

            if let port = model.server.listeningPort {
                Text("Manual IP connections use port \(port).")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Connected Hosts

    @ViewBuilder
    private var connectedHostsSection: some View {
        if !model.server.connectedHosts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Connected Now", systemImage: "circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green, .green)

                VStack(spacing: 1) {
                    ForEach(model.server.connectedHosts) { host in
                        HStack {
                            Image(systemName: "desktopcomputer")
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name)
                                    .font(.subheadline)
                                Text("Connected \(host.connectedAt.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Disconnect") {
                                model.server.disconnectHost(host.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .foregroundColor(.red)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            }
        }
    }

    // MARK: - Trusted Hosts

    private var trustedHostsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Trusted Macs", systemImage: "checkmark.shield")
                .font(.headline)

            if model.approvedHosts.isEmpty {
                Text("No trusted Macs yet. When you approve a connection and choose \"Always Allow\", it will appear here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor)))
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(model.approvedHosts.keys), id: \.self) { machineID in
                        HStack {
                            Image(systemName: "desktopcomputer.and.arrow.down")
                                .foregroundColor(.accentColor)
                            Text(model.approvedHosts[machineID] ?? machineID)
                                .font(.subheadline)
                            Spacer()
                            Button("Revoke") {
                                model.revokeHost(machineID)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .foregroundColor(.red)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            }
        }
    }
}

// MARK: - Consent Dialog

struct ConsentDialog: View {
    let request: RemoteMonitoringServer.PendingAuthRequest
    @ObservedObject var model: CompanionServerModel
    @State private var remember = true

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "desktopcomputer.and.arrow.down")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Connection Request")
                .font(.title2.bold())

            VStack(spacing: 6) {
                Text("**\(request.hostName)** wants to monitor this Mac's hardware stats.")
                    .multilineTextAlignment(.center)
                Text("This will give them live access to CPU, GPU, RAM, power, and other metrics.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Toggle("Always allow this Mac (don't ask again)", isOn: $remember)
                .toggleStyle(.checkbox)

            HStack(spacing: 12) {
                Button("Deny") {
                    model.denyRequest(request)
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)

                Button("Allow") {
                    model.approveRequest(request, remember: remember)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 380)
    }
}

// MARK: - Menu Bar View

struct CompanionMenuBarView: View {
    @ObservedObject var model: CompanionServerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status summary
            HStack {
                Circle()
                    .fill(model.server.isRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(model.server.isRunning ? "Server active" : "Server inactive")
                    .font(.subheadline.bold())
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.server.isRunning },
                    set: { enabled in
                        if enabled { model.startServer() } else { model.stopServer() }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if model.server.isRunning {
                Divider()

                // Passcode
                VStack(alignment: .leading, spacing: 4) {
                    Text("Passcode")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(RemotePasscodeGenerator.formatted(model.server.currentPasscode))
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .kerning(2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                if !model.server.connectedHosts.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(model.server.connectedHosts.count) connected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(model.server.connectedHosts) { host in
                            Text(host.name)
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }

            Divider()

            // Actions
            Button("Open Companion Window") {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows {
                    if window.identifier?.rawValue == "companion-main" {
                        window.makeKeyAndOrderFront(nil)
                        return
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .padding(.bottom, 8)
        }
        .frame(width: 260)
    }
}
