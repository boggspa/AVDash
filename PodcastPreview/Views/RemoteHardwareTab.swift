//
//  RemoteHardwareTab.swift
//  PodcastPreview
//
//  The "Remote Hardware" tab showing discovered/connected remote Macs,
//  each represented as a tile that expands into a full hardware stats view.
//

import SwiftUI
import AppKit
import PodcastPreviewCore
import PodcastPreviewShared

// MARK: - RemoteHardwareTab

struct RemoteHardwareTab: View {
    @ObservedObject private var manager = RemoteHardwareManager.shared
    @Environment(\.appUIScale) private var appUIScale
    private let topHeadroom: CGFloat = 70

    @State private var showAddSheet = false
    @State private var showManualEntry = false
    @State private var manualAddress = ""
    @State private var manualPort = ""
    @State private var connectPasscode = ""
    @State private var selectedDiscoveredMachine: DiscoveredRemoteMachine?
    @State private var highlightedConnectionID: String?
    @State private var highlightedDiscoveredID: String?

    var body: some View {
        if let selectedID = manager.selectedMachineID,
           let connection = manager.connection(for: selectedID) {
            RemoteMachineDetailView(connection: connection) {
                manager.selectedMachineID = nil
            }
        } else {
            remoteLandingView
        }
    }

    // MARK: - Landing View

    private var remoteLandingView: some View {
        HStack(spacing: 0) {
            remoteMachineSidebar
                .frame(width: 320 * appUIScale, alignment: .topLeading)
                .graphiteSidebarChrome(separatorEdge: .trailing)

            ScrollView {
                remoteMainPane
                    .padding(.top, topHeadroom)
                    .padding(.horizontal, 28 * appUIScale)
                    .padding(.bottom, 28 * appUIScale)
                    .frame(maxWidth: 940 * appUIScale, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear {
            manager.startDiscovery()
            manager.refreshApprovedHosts()
            syncHighlightedMachine()
        }
        .onDisappear {
            manager.stopDiscovery()
        }
        .sheet(isPresented: $showAddSheet) {
            addMachineSheet
        }
    }

    private var remoteMachineSidebar: some View {
        VStack(alignment: .leading, spacing: 18 * appUIScale) {
            VStack(alignment: .leading, spacing: 14 * appUIScale) {
                HStack(spacing: 10 * appUIScale) {
                    Image(systemName: "network")
                        .font(.system(size: 20 * appUIScale, weight: .semibold))
                        .foregroundColor(GraphiteSlateTheme.accentBlue)

                    VStack(alignment: .leading, spacing: 2 * appUIScale) {
                        Text("Remote")
                            .font(.system(size: 11 * appUIScale, weight: .medium))
                            .foregroundColor(GraphiteSlateTheme.tertiaryText)
                        Text("Machines")
                            .font(.system(size: 17 * appUIScale, weight: .bold))
                            .foregroundColor(GraphiteSlateTheme.primaryText)
                    }

                    Spacer()

                    Button {
                        selectedDiscoveredMachine = nil
                        showManualEntry = true
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12 * appUIScale, weight: .bold))
                            .frame(width: 28 * appUIScale, height: 28 * appUIScale)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(GraphiteSlateTheme.primaryText)
                    .background(GraphiteSlatePillBackground())
                    .help("Add Mac")
                }

                remoteSidebarStatusStrip
            }
            .padding(.top, topHeadroom)
            .padding(.horizontal, 18 * appUIScale)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18 * appUIScale) {
                    remoteSidebarSection(title: "Connected") {
                        if manager.connectedMachines.isEmpty {
                            remoteSidebarEmptyText("No connected Macs")
                        } else {
                            VStack(spacing: 8 * appUIScale) {
                                ForEach(manager.connectedMachines) { connection in
                                    remoteConnectedSidebarRow(connection)
                                }
                            }
                        }
                    }

                    remoteSidebarSection(title: "Discovered") {
                        if manager.discoveredMachines.isEmpty {
                            VStack(alignment: .leading, spacing: 8 * appUIScale) {
                                HStack(spacing: 8 * appUIScale) {
                                    ProgressView()
                                        .scaleEffect(0.55)
                                        .frame(width: 14 * appUIScale, height: 14 * appUIScale)
                                    Text("Scanning")
                                        .font(.system(size: 11 * appUIScale, weight: .medium))
                                        .foregroundColor(GraphiteSlateTheme.tertiaryText)
                                }
                                remoteSidebarEmptyText("No remote Macs found yet")
                            }
                        } else {
                            VStack(spacing: 8 * appUIScale) {
                                ForEach(manager.discoveredMachines) { machine in
                                    remoteDiscoveredSidebarRow(machine)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18 * appUIScale)
                .padding(.bottom, 24 * appUIScale)
            }
        }
    }

    private var remoteSidebarStatusStrip: some View {
        HStack(spacing: 8 * appUIScale) {
            remoteSidebarMetric("Live", "\(manager.connectedMachines.count)")
            remoteSidebarMetric("Seen", "\(manager.discoveredMachines.count)")
            remoteSidebarMetric("Trusted", "\(manager.approvedHosts.count)")
        }
    }

    private func remoteSidebarMetric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2 * appUIScale) {
            Text(value)
                .font(.system(size: 13 * appUIScale, weight: .semibold, design: .monospaced))
                .foregroundColor(GraphiteSlateTheme.primaryText)
            Text(label)
                .font(.system(size: 9 * appUIScale, weight: .medium))
                .foregroundColor(GraphiteSlateTheme.subduedText)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8 * appUIScale)
        .graphiteSurface(.control, cornerRadius: 9 * appUIScale)
    }

    private func remoteSidebarSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9 * appUIScale) {
            Text(title)
                .font(.system(size: 11 * appUIScale, weight: .semibold))
                .foregroundColor(GraphiteSlateTheme.tertiaryText)
                .textCase(.uppercase)
            content()
        }
    }

    private func remoteSidebarEmptyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11 * appUIScale))
            .foregroundColor(GraphiteSlateTheme.subduedText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10 * appUIScale)
            .graphiteSurface(.row, cornerRadius: 9 * appUIScale, stroke: GraphiteSlateTheme.softSeparator)
    }

    private func remoteConnectedSidebarRow(_ connection: RemoteMachineConnection) -> some View {
        let isSelected = highlightedConnectionID == connection.id
        return HStack(spacing: 10 * appUIScale) {
            Circle()
                .fill(remoteConnectionTint(for: connection))
                .frame(width: 8 * appUIScale, height: 8 * appUIScale)

            VStack(alignment: .leading, spacing: 2 * appUIScale) {
                Text(connection.identity?.displayName ?? connection.machineName)
                    .font(.system(size: 12 * appUIScale, weight: .semibold))
                    .foregroundColor(GraphiteSlateTheme.primaryText)
                    .lineLimit(1)
                Text(connection.identity?.chipType ?? connection.identity?.modelIdentifier ?? remoteConnectionLabel(for: connection))
                    .font(.system(size: 10 * appUIScale))
                    .foregroundColor(GraphiteSlateTheme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8 * appUIScale)

            Button {
                manager.selectedMachineID = connection.id
            } label: {
                Image(systemName: "arrow.right")
                    .font(.system(size: 10 * appUIScale, weight: .bold))
                    .frame(width: 22 * appUIScale, height: 22 * appUIScale)
            }
            .buttonStyle(.plain)
            .foregroundColor(GraphiteSlateTheme.secondaryText)
        }
        .padding(10 * appUIScale)
        .contentShape(ThemeRoundedRectangle(cornerRadius: 10 * appUIScale, style: .continuous))
        .graphiteSurface(isSelected ? .selectedRow : .row, cornerRadius: 10 * appUIScale)
        .onTapGesture {
            highlightedConnectionID = connection.id
            highlightedDiscoveredID = nil
        }
    }

    private func remoteDiscoveredSidebarRow(_ machine: DiscoveredRemoteMachine) -> some View {
        let isSelected = highlightedDiscoveredID == machine.id
        return HStack(spacing: 10 * appUIScale) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 14 * appUIScale, weight: .medium))
                .foregroundColor(GraphiteSlateTheme.secondaryText)
                .frame(width: 18 * appUIScale)

            VStack(alignment: .leading, spacing: 2 * appUIScale) {
                Text(machine.name)
                    .font(.system(size: 12 * appUIScale, weight: .semibold))
                    .foregroundColor(GraphiteSlateTheme.primaryText)
                    .lineLimit(1)
                Text(machine.modelIdentifier ?? machine.displayName)
                    .font(.system(size: 10 * appUIScale))
                    .foregroundColor(GraphiteSlateTheme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8 * appUIScale)
        }
        .padding(10 * appUIScale)
        .contentShape(ThemeRoundedRectangle(cornerRadius: 10 * appUIScale, style: .continuous))
        .graphiteSurface(isSelected ? .selectedRow : .row, cornerRadius: 10 * appUIScale)
        .onTapGesture {
            highlightedDiscoveredID = machine.id
            highlightedConnectionID = nil
        }
    }

    @ViewBuilder
    private var remoteMainPane: some View {
        if let connection = highlightedConnection {
            selectedConnectionSummary(connection)
        } else if let machine = highlightedDiscoveredMachine {
            selectedDiscoveredSummary(machine)
        } else {
            VStack(spacing: 20 * appUIScale) {
                headerSection
                shareThisMacSection
                companionSyncSection
            }
        }
    }

    private var highlightedConnection: RemoteMachineConnection? {
        guard let highlightedConnectionID else { return nil }
        return manager.connection(for: highlightedConnectionID)
    }

    private var highlightedDiscoveredMachine: DiscoveredRemoteMachine? {
        guard let highlightedDiscoveredID else { return nil }
        return manager.discoveredMachines.first { $0.id == highlightedDiscoveredID }
    }

    private func selectedConnectionSummary(_ connection: RemoteMachineConnection) -> some View {
        VStack(alignment: .leading, spacing: 18 * appUIScale) {
            HStack(alignment: .center, spacing: 14 * appUIScale) {
                Image(systemName: remoteMachineIconName(for: connection.identity?.modelIdentifier))
                    .font(.system(size: 34 * appUIScale, weight: .medium))
                    .foregroundColor(GraphiteSlateTheme.secondaryText)
                    .frame(width: 48 * appUIScale, height: 48 * appUIScale)

                VStack(alignment: .leading, spacing: 4 * appUIScale) {
                    Text(connection.identity?.displayName ?? connection.machineName)
                        .font(.system(size: 24 * appUIScale, weight: .bold))
                        .foregroundColor(GraphiteSlateTheme.primaryText)
                    Text(connection.identity?.modelIdentifier ?? remoteConnectionLabel(for: connection))
                        .font(.system(size: 12 * appUIScale))
                        .foregroundColor(GraphiteSlateTheme.tertiaryText)
                }

                Spacer()

                Button {
                    manager.selectedMachineID = connection.id
                } label: {
                    Label("Open Monitor", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 13 * appUIScale, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14 * appUIScale)
                .padding(.vertical, 9 * appUIScale)
                .foregroundColor(GraphiteSlateTheme.primaryText)
                .graphiteSurface(.activeControl, cornerRadius: 10 * appUIScale)
            }

            HStack(spacing: 12 * appUIScale) {
                selectedConnectionMetric("Status", remoteConnectionLabel(for: connection), tint: remoteConnectionTint(for: connection))
                selectedConnectionMetric("CPU", remoteMetric(connection, .cpuTotalUsage) { String(format: "%.0f%%", $0 * 100) })
                selectedConnectionMetric("RAM", remoteMetric(connection, .ramUsageRatio) { String(format: "%.0f%%", $0 * 100) })
                selectedConnectionMetric("Power", remoteMetric(connection, .combinedPowerWatts) { String(format: "%.1fW", $0) })
            }

            VStack(alignment: .leading, spacing: 10 * appUIScale) {
                Text("Machine Details")
                    .font(.system(size: 13 * appUIScale, weight: .semibold))
                    .foregroundColor(GraphiteSlateTheme.secondaryText)
                    .textCase(.uppercase)
                remoteDetailRow("Chip", connection.identity?.chipType ?? "--")
                remoteDetailRow("macOS", connection.identity?.macOSVersion ?? "--")
                remoteDetailRow("RAM", connection.identity?.totalRAMGB.map { String(format: "%.0f GB", $0) } ?? "--")
                remoteDetailRow("Session", connection.sessionStartDate.map { relativeConnectionText(for: $0) } ?? "Not started")
            }
            .padding(16 * appUIScale)
            .graphiteSurface(.panel, cornerRadius: 14 * appUIScale)
        }
        .padding(20 * appUIScale)
        .graphiteSurface(.elevated, cornerRadius: 18 * appUIScale)
    }

    private func selectedDiscoveredSummary(_ machine: DiscoveredRemoteMachine) -> some View {
        VStack(alignment: .leading, spacing: 18 * appUIScale) {
            HStack(alignment: .center, spacing: 14 * appUIScale) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 34 * appUIScale, weight: .medium))
                    .foregroundColor(GraphiteSlateTheme.secondaryText)
                    .frame(width: 48 * appUIScale, height: 48 * appUIScale)

                VStack(alignment: .leading, spacing: 4 * appUIScale) {
                    Text(machine.name)
                        .font(.system(size: 24 * appUIScale, weight: .bold))
                        .foregroundColor(GraphiteSlateTheme.primaryText)
                    Text(machine.modelIdentifier ?? machine.displayName)
                        .font(.system(size: 12 * appUIScale))
                        .foregroundColor(GraphiteSlateTheme.tertiaryText)
                }

                Spacer()

                Button {
                    selectedDiscoveredMachine = machine
                    connectPasscode = ""
                    showAddSheet = true
                } label: {
                    Label("Connect", systemImage: "link")
                        .font(.system(size: 13 * appUIScale, weight: .semibold))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14 * appUIScale)
                .padding(.vertical, 9 * appUIScale)
                .foregroundColor(GraphiteSlateTheme.primaryText)
                .graphiteSurface(.activeControl, cornerRadius: 10 * appUIScale)
            }

            Text("Enter the passcode shown on this Mac to start monitoring. Bonjour discovery has already found the machine, so no manual address is needed.")
                .font(.system(size: 12 * appUIScale))
                .foregroundColor(GraphiteSlateTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10 * appUIScale) {
                remoteDetailRow("Hostname", machine.hostname ?? "--")
                remoteDetailRow("Model", machine.modelIdentifier ?? "--")
                remoteDetailRow("Discovery", machine.displayName)
            }
            .padding(16 * appUIScale)
            .graphiteSurface(.panel, cornerRadius: 14 * appUIScale)
        }
        .padding(20 * appUIScale)
        .graphiteSurface(.elevated, cornerRadius: 18 * appUIScale)
    }

    private func selectedConnectionMetric(_ label: String, _ value: String, tint: Color = GraphiteSlateTheme.primaryText) -> some View {
        VStack(alignment: .leading, spacing: 4 * appUIScale) {
            Text(label)
                .font(.system(size: 10 * appUIScale, weight: .semibold))
                .foregroundColor(GraphiteSlateTheme.subduedText)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 15 * appUIScale, weight: .semibold, design: .monospaced))
                .foregroundColor(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14 * appUIScale)
        .graphiteSurface(.control, cornerRadius: 12 * appUIScale)
    }

    private func remoteDetailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12 * appUIScale) {
            Text(label)
                .font(.system(size: 11 * appUIScale, weight: .semibold))
                .foregroundColor(GraphiteSlateTheme.tertiaryText)
                .frame(width: 86 * appUIScale, alignment: .leading)
            Text(value)
                .font(.system(size: 12 * appUIScale, weight: .medium))
                .foregroundColor(GraphiteSlateTheme.secondaryText)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func syncHighlightedMachine() {
        if let highlightedConnectionID,
           manager.connection(for: highlightedConnectionID) != nil {
            return
        }
        if let highlightedDiscoveredID,
           manager.discoveredMachines.contains(where: { $0.id == highlightedDiscoveredID }) {
            return
        }
        highlightedConnectionID = manager.connectedMachines.first?.id
        highlightedDiscoveredID = highlightedConnectionID == nil ? manager.discoveredMachines.first?.id : nil
    }

    private func remoteConnectionTint(for connection: RemoteMachineConnection) -> Color {
        switch connection.state {
        case .connected:
            return .green
        case .connecting, .authenticating, .awaitingApproval:
            return GraphiteSlateTheme.accentBlue
        case .failed:
            return .orange
        case .disconnected:
            return .gray.opacity(0.55)
        @unknown default:
            return .gray.opacity(0.55)
        }
    }

    private func remoteConnectionLabel(for connection: RemoteMachineConnection) -> String {
        switch connection.state {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting"
        case .authenticating:
            return "Authenticating"
        case .awaitingApproval:
            return "Awaiting approval"
        case .failed:
            return "Failed"
        case .disconnected:
            return "Disconnected"
        @unknown default:
            return "Disconnected"
        }
    }

    private func remoteMetric(_ connection: RemoteMachineConnection, _ metric: HardwareMetricKey, formatter: (Double) -> String) -> String {
        guard let value = connection.latestTelemetryFrame?.snapshot?.metric(metric) else {
            return "--"
        }
        return formatter(value)
    }

    private func remoteMachineIconName(for modelIdentifier: String?) -> String {
        guard let modelIdentifier else { return "desktopcomputer" }
        if modelIdentifier.contains("MacBook") { return "laptopcomputer" }
        if modelIdentifier.contains("MacPro") { return "macpro.gen3" }
        if modelIdentifier.contains("Macmini") { return "macmini" }
        return "desktopcomputer"
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4 * appUIScale) {
                Text("Remote Hardware")
                    .font(.system(size: 22 * appUIScale, weight: .bold))
                    .foregroundColor(.white)

                Text("Monitor hardware stats from other Macs on your network")
                    .font(.system(size: 12 * appUIScale))
                    .foregroundColor(.white.opacity(0.5))
            }

            Spacer()

            Button(action: { showAddSheet = true }) {
                HStack(spacing: 6 * appUIScale) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14 * appUIScale))
                    Text("Add Mac")
                        .font(.system(size: 13 * appUIScale, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14 * appUIScale)
                .padding(.vertical, 8 * appUIScale)
                .background(
                    ThemeRoundedRectangle(cornerRadius: 8 * appUIScale, style: .continuous).themed(fill: Color.accentColor.opacity(0.3), stroke: Color.accentColor.opacity(0.5))
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Share This Mac

    private var shareThisMacSection: some View {
        VStack(alignment: .leading, spacing: 14 * appUIScale) {
            HStack(alignment: .top, spacing: 12 * appUIScale) {
                VStack(alignment: .leading, spacing: 4 * appUIScale) {
                    Text("Share This Mac")
                        .font(.system(size: 13 * appUIScale, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .textCase(.uppercase)

                    Text(manager.localMachineName)
                        .font(.system(size: 16 * appUIScale, weight: .semibold))
                        .foregroundColor(.white)

                    Text(manager.localMachineSubtitle)
                        .font(.system(size: 11 * appUIScale))
                        .foregroundColor(.white.opacity(0.45))

                    Text(manager.localServerIsRunning
                         ? "This Mac is advertising on your local network. Connect from another Mac's Remote Hardware tab with the passcode below."
                         : "Turn this on to host the remote monitor directly in PodcastPreview. The passcode and approval prompt will appear here.")
                        .font(.system(size: 12 * appUIScale))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 2 * appUIScale)
                }

                Spacer(minLength: 12 * appUIScale)

                Toggle("", isOn: Binding(
                    get: { manager.localServerIsRunning },
                    set: { enabled in
                        if enabled {
                            manager.startSharingThisMac()
                        } else {
                            manager.stopSharingThisMac()
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            if manager.localServerIsRunning {
                sharingPasscodeCard
                sharingSummaryCard
                if !manager.localConnectedHosts.isEmpty {
                    localConnectedHostsCard
                }
            }

            trustedHostsCard
        }
        .padding(16 * appUIScale)
        .background(
            ThemeRoundedRectangle(cornerRadius: 14 * appUIScale, style: .continuous).themed(
                fill: Color.white.opacity(0.04),
                stroke: manager.localServerIsRunning ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.06)
            )
        )
    }

    private var sharingPasscodeCard: some View {
        VStack(alignment: .leading, spacing: 10 * appUIScale) {
            Text("Connection Passcode")
                .font(.system(size: 12 * appUIScale, weight: .medium))
                .foregroundColor(.white.opacity(0.55))

            HStack(spacing: 12 * appUIScale) {
                Text(RemotePasscodeGenerator.formatted(manager.localServerPasscode))
                    .font(.system(size: 30 * appUIScale, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .kerning(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8 * appUIScale) {
                    Button(action: copyLocalPasscode) {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 12 * appUIScale, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10 * appUIScale)
                    .padding(.vertical, 8 * appUIScale)
                    .background(
                        ThemeRoundedRectangle(cornerRadius: 8 * appUIScale, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )

                    Button(action: manager.rotateLocalPasscode) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 12 * appUIScale, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10 * appUIScale)
                    .padding(.vertical, 8 * appUIScale)
                    .background(
                        ThemeRoundedRectangle(cornerRadius: 8 * appUIScale, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                }
            }

            Text("Trusted Macs skip the approval prompt on reconnect. Every connection still uses the current passcode.")
                .font(.system(size: 11 * appUIScale))
                .foregroundColor(.white.opacity(0.45))

            if let port = manager.localListeningPort {
                Text("Manual IP connections use port \(port). Bonjour discovery fills this in automatically.")
                    .font(.system(size: 11 * appUIScale))
                    .foregroundColor(.white.opacity(0.45))
            }
        }
        .padding(14 * appUIScale)
        .background(
            ThemeRoundedRectangle(cornerRadius: 12 * appUIScale, style: .continuous).themed(
                fill: Color.accentColor.opacity(0.12),
                stroke: Color.accentColor.opacity(0.25)
            )
        )
    }

    private var sharingSummaryCard: some View {
        HStack(spacing: 0) {
            sharingStat(label: "Status", value: "Active", accent: .green)
            sharingDivider
            sharingStat(label: "Connected", value: "\(manager.localConnectedHosts.count)")
            sharingDivider
            sharingStat(label: "Trusted", value: "\(manager.approvedHosts.count)")
        }
        .background(
            ThemeRoundedRectangle(cornerRadius: 12 * appUIScale, style: .continuous).themed(
                fill: Color.white.opacity(0.03),
                stroke: Color.white.opacity(0.06)
            )
        )
    }

    private var sharingDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(width: 1)
            .padding(.vertical, 12 * appUIScale)
    }

    private func sharingStat(label: String, value: String, accent: Color = .white) -> some View {
        VStack(spacing: 4 * appUIScale) {
            Text(value)
                .font(.system(size: 15 * appUIScale, weight: .semibold))
                .foregroundColor(accent)
            Text(label)
                .font(.system(size: 11 * appUIScale))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14 * appUIScale)
    }

    private var localConnectedHostsCard: some View {
        VStack(alignment: .leading, spacing: 10 * appUIScale) {
            Text("Connected Now")
                .font(.system(size: 12 * appUIScale, weight: .medium))
                .foregroundColor(.white.opacity(0.55))

            VStack(spacing: 8 * appUIScale) {
                ForEach(manager.localConnectedHosts) { host in
                    HStack(spacing: 10 * appUIScale) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8 * appUIScale, height: 8 * appUIScale)

                        VStack(alignment: .leading, spacing: 2 * appUIScale) {
                            Text(host.name)
                                .font(.system(size: 13 * appUIScale, weight: .medium))
                                .foregroundColor(.white)
                            Text("Connected \(relativeConnectionText(for: host.connectedAt))")
                                .font(.system(size: 11 * appUIScale))
                                .foregroundColor(.white.opacity(0.4))
                        }

                        Spacer()

                        Button("Disconnect") {
                            manager.disconnectLocalHost(host.id)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11 * appUIScale, weight: .medium))
                        .foregroundColor(.red.opacity(0.8))
                    }
                    .padding(12 * appUIScale)
                    .background(
                        ThemeRoundedRectangle(cornerRadius: 10 * appUIScale, style: .continuous)
                            .fill(Color.white.opacity(0.03))
                    )
                }
            }
        }
    }

    private var trustedHostsCard: some View {
        VStack(alignment: .leading, spacing: 10 * appUIScale) {
            Text("Trusted Macs")
                .font(.system(size: 12 * appUIScale, weight: .medium))
                .foregroundColor(.white.opacity(0.55))

            if manager.approvedHosts.isEmpty {
                Text("No trusted Macs yet. Approve a connection and keep \"Always allow\" checked to add it here.")
                    .font(.system(size: 12 * appUIScale))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12 * appUIScale)
                    .background(
                        ThemeRoundedRectangle(cornerRadius: 10 * appUIScale, style: .continuous)
                            .fill(Color.white.opacity(0.03))
                    )
            } else {
                VStack(spacing: 8 * appUIScale) {
                    ForEach(Array(manager.approvedHosts.keys).sorted(), id: \.self) { machineID in
                        HStack(spacing: 10 * appUIScale) {
                            Image(systemName: "checkmark.shield")
                                .foregroundColor(.accentColor.opacity(0.8))

                            Text(manager.approvedHosts[machineID] ?? machineID)
                                .font(.system(size: 13 * appUIScale, weight: .medium))
                                .foregroundColor(.white)

                            Spacer()

                            Button("Revoke") {
                                manager.revokeApprovedHost(machineID)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11 * appUIScale, weight: .medium))
                            .foregroundColor(.red.opacity(0.8))
                        }
                        .padding(12 * appUIScale)
                        .background(
                            ThemeRoundedRectangle(cornerRadius: 10 * appUIScale, style: .continuous)
                                .fill(Color.white.opacity(0.03))
                        )
                    }
                }
            }
        }
    }

    private func copyLocalPasscode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(manager.localServerPasscode, forType: .string)
    }

    private func relativeConnectionText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - iOS Companion Sync

    private var companionSyncSection: some View {
        VStack(alignment: .leading, spacing: 14 * appUIScale) {
            HStack(alignment: .top, spacing: 12 * appUIScale) {
                VStack(alignment: .leading, spacing: 4 * appUIScale) {
                    Text("iOS Companion Sync")
                        .font(.system(size: 13 * appUIScale, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .textCase(.uppercase)

                    Text("Sync with iPhone & iPad")
                        .font(.system(size: 16 * appUIScale, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Syncs hardware telemetry via iCloud so you can monitor this Mac from your iOS device when not on the same local network.")
                        .font(.system(size: 12 * appUIScale))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.top, 2 * appUIScale)
                }

                Spacer(minLength: 12 * appUIScale)

                Toggle("", isOn: $manager.isCompanionSyncEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if manager.isCompanionSyncEnabled {
                HStack(spacing: 20 * appUIScale) {
                    VStack(alignment: .leading, spacing: 4 * appUIScale) {
                        Text("Status")
                            .font(.system(size: 11 * appUIScale, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                            .textCase(.uppercase)

                        HStack(spacing: 6 * appUIScale) {
                            Circle()
                                .fill(manager.cloudLastErrorMessage == nil ? Color.green : Color.red)
                                .frame(width: 8 * appUIScale, height: 8 * appUIScale)

                            Text(manager.cloudLastErrorMessage == nil ? "Active" : "Error")
                                .font(.system(size: 13 * appUIScale, weight: .medium))
                                .foregroundColor(.white)
                        }
                    }

                    if let lastPublished = manager.cloudLastPublishedAt {
                        VStack(alignment: .leading, spacing: 4 * appUIScale) {
                            Text("Last Published")
                                .font(.system(size: 11 * appUIScale, weight: .medium))
                                .foregroundColor(.white.opacity(0.4))
                                .textCase(.uppercase)

                            Text(lastPublished, style: .time)
                                .font(.system(size: 13 * appUIScale, weight: .medium))
                                .foregroundColor(.white)
                        }
                    }

                    Spacer()
                }
                .padding(14 * appUIScale)
                .background(
                    ThemeRoundedRectangle(cornerRadius: 12 * appUIScale, style: .continuous).themed(
                        fill: Color.white.opacity(0.04),
                        stroke: Color.white.opacity(0.06)
                    )
                )

                if let error = manager.cloudLastErrorMessage {
                    Text(error)
                        .font(.system(size: 11 * appUIScale))
                        .foregroundColor(.red.opacity(0.8))
                        .padding(.horizontal, 4 * appUIScale)
                }
            }
        }
        .padding(20 * appUIScale)
        .background(
            ThemeRoundedRectangle(cornerRadius: 16 * appUIScale, style: .continuous).themed(
                fill: Color.white.opacity(0.03),
                stroke: Color.white.opacity(0.06)
            )
        )
    }

    // MARK: - Connected Machines

    @ViewBuilder
    private var connectedMachinesSection: some View {
        if !manager.connectedMachines.isEmpty {
            VStack(alignment: .leading, spacing: 12 * appUIScale) {
                Text("Connected")
                    .font(.system(size: 13 * appUIScale, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .textCase(.uppercase)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280 * appUIScale), spacing: 16 * appUIScale)],
                    spacing: 16 * appUIScale
                ) {
                    ForEach(manager.connectedMachines) { connection in
                        RemoteMachineTile(connection: connection) {
                            manager.selectedMachineID = connection.id
                        } onDisconnect: {
                            manager.disconnect(machineID: connection.id)
                        }
                        .floatingMonitorContextMenu(cardKind: .remoteMachineTile, source: .remote(connection))
                    }
                }
            }
        }
    }

    // MARK: - Discovered Machines

    @ViewBuilder
    private var discoveredMachinesSection: some View {
        VStack(alignment: .leading, spacing: 12 * appUIScale) {
            HStack {
                Text("Discovered on Network")
                    .font(.system(size: 13 * appUIScale, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .textCase(.uppercase)

                Spacer()

                if manager.discoveredMachines.isEmpty {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16 * appUIScale, height: 16 * appUIScale)

                    Text("Scanning...")
                        .font(.system(size: 11 * appUIScale))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            if manager.discoveredMachines.isEmpty {
                emptyDiscoveryCard
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280 * appUIScale), spacing: 16 * appUIScale)],
                    spacing: 16 * appUIScale
                ) {
                    ForEach(manager.discoveredMachines) { machine in
                        DiscoveredMachineTile(machine: machine) {
                            selectedDiscoveredMachine = machine
                            connectPasscode = ""
                            showAddSheet = true
                        }
                    }
                }
            }
        }
    }

    private var emptyDiscoveryCard: some View {
        VStack(spacing: 12 * appUIScale) {
            Image(systemName: "network")
                .font(.system(size: 36 * appUIScale))
                .foregroundColor(.white.opacity(0.2))

            Text("No remote Macs found")
                .font(.system(size: 14 * appUIScale, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            Text("Enable sharing in PodcastPreview or run the companion app on\nthe remote Mac, then keep both Macs on the same network.")
                .font(.system(size: 12 * appUIScale))
                .foregroundColor(.white.opacity(0.35))
                .multilineTextAlignment(.center)

            Button("Add Manually") {
                showManualEntry = true
                selectedDiscoveredMachine = nil
                showAddSheet = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 12 * appUIScale, weight: .medium))
            .foregroundColor(.accentColor)
            .padding(.top, 4 * appUIScale)
        }
        .frame(maxWidth: .infinity)
        .padding(32 * appUIScale)
        .background(
            ThemeRoundedRectangle(cornerRadius: 12 * appUIScale, style: .continuous).themed(
                fill: Color.white.opacity(0.03),
                stroke: Color.white.opacity(0.06)
            )
        )
    }

    // MARK: - Add Machine Sheet

    private var addMachineSheet: some View {
        VStack(spacing: 20) {
            Text(selectedDiscoveredMachine != nil ? "Connect to \(selectedDiscoveredMachine!.name)" : "Add Remote Mac")
                .font(.headline)

            if selectedDiscoveredMachine == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("IP Address")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    TextField("e.g. 192.168.1.42", text: $manualAddress)
                        .textFieldStyle(.roundedBorder)

                    Text("Port")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    TextField("Enter the remote Mac's port", text: $manualPort)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Passcode")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text("Enter the passcode shown on the remote Mac. Spaces are ignored.")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))

                SecureField("Passcode", text: $connectPasscode)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") {
                    showAddSheet = false
                    selectedDiscoveredMachine = nil
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Connect") {
                    if let machine = selectedDiscoveredMachine {
                        manager.connect(to: machine, passcode: connectPasscode)
                    } else if !manualAddress.isEmpty,
                              let port = UInt16(manualPort),
                              port > 0 {
                        manager.connectByAddress(manualAddress, port: port, passcode: connectPasscode)
                    }
                    showAddSheet = false
                    selectedDiscoveredMachine = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmitConnection)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private var canSubmitConnection: Bool {
        let normalizedPasscode = RemotePasscodeGenerator.normalized(connectPasscode)
        guard normalizedPasscode.count == RemotePasscodeGenerator.length else {
            return false
        }

        if selectedDiscoveredMachine != nil {
            return true
        }

        return !manualAddress.isEmpty && (UInt16(manualPort).map { $0 > 0 } ?? false)
    }
}

// MARK: - LocalRemoteConsentDialog

struct LocalRemoteConsentDialog: View {
    let request: RemoteMonitoringServer.PendingAuthRequest
    @ObservedObject var manager: RemoteHardwareManager
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
                Text("This grants live access to CPU, GPU, RAM, power, and other telemetry from this machine.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Toggle("Always allow this Mac", isOn: $remember)
                .toggleStyle(.checkbox)

            HStack(spacing: 12) {
                Button("Deny") {
                    manager.denyPendingRequest(request)
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)

                Button("Allow") {
                    manager.approvePendingRequest(request, remember: remember)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .frame(width: 380)
    }
}

// MARK: - RemoteMachineTile (Connected)

struct RemoteMachineTile: View {
    private struct QuickStatItem: Identifiable {
        let label: String
        let value: String

        var id: String { label }
    }

    @ObservedObject var connection: RemoteMachineConnection
    @Environment(\.appUIScale) private var appUIScale
    let onSelect: () -> Void
    let onDisconnect: () -> Void

    private var scaledCornerRadius: CGFloat { 12 * appUIScale }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10 * appUIScale) {
                // Header
                HStack(spacing: 10 * appUIScale) {
                    machineIcon
                    VStack(alignment: .leading, spacing: 2 * appUIScale) {
                        Text(connection.identity?.displayName ?? connection.machineName)
                            .font(.system(size: 14 * appUIScale, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        if let identity = connection.identity {
                            Text(identity.chipType ?? identity.modelIdentifier)
                                .font(.system(size: 11 * appUIScale))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    connectionStatusBadge
                }

                // Quick stats from latest telemetry
                if !quickStats.isEmpty {
                    HStack(spacing: 10 * appUIScale) {
                        ForEach(quickStats) { stat in
                            quickStat(label: stat.label, value: stat.value)
                                .frame(maxWidth: .infinity)
                        }
                    }
                } else if connection.state == .connected {
                    Text("Waiting for data...")
                        .font(.system(size: 11 * appUIScale))
                        .foregroundColor(.white.opacity(0.35))
                }

                // Disconnect button
                HStack {
                    Spacer()
                    Button(action: onDisconnect) {
                        Text("Disconnect")
                            .font(.system(size: 11 * appUIScale, weight: .medium))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14 * appUIScale)
            .background(
                ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous).themed(
                    fill: Color.white.opacity(0.05),
                    stroke: connection.state == .connected ? Color.green.opacity(0.3) : Color.white.opacity(0.08)
                )
            )
        }
        .buttonStyle(.plain)
    }

    private var quickStats: [QuickStatItem] {
        guard let frame = connection.latestTelemetryFrame, let snapshot = frame.snapshot else { return [] }

        var stats: [QuickStatItem] = [
            QuickStatItem(
                label: "CPU",
                value: snapshot.metric(.cpuTotalUsage).map { String(format: "%.0f%%", $0 * 100) } ?? "--"
            ),
            QuickStatItem(
                label: "RAM",
                value: snapshot.metric(.ramUsageRatio).map { String(format: "%.0f%%", $0 * 100) } ?? "--"
            )
        ]

        if let gpuUtil = frame.deviceSnapshots.first?.metric(.utilizationRatio) {
            stats.append(QuickStatItem(
                label: "GPU",
                value: String(format: "%.0f%%", gpuUtil * 100)
            ))
        }

        if let power = snapshot.metric(.combinedPowerWatts) {
            stats.append(QuickStatItem(
                label: "Power",
                value: String(format: "%.1fW", power)
            ))
        }

        if let batteryPercent = connection.latestPollingSnapshot?.power.latestSystemSnapshot?.batteryPercent {
            stats.append(QuickStatItem(
                label: "Battery",
                value: "\(batteryPercent)%"
            ))
        }

        return stats
    }

    private var machineIcon: some View {
        Image(systemName: machineIconName)
            .font(.system(size: 24 * appUIScale))
            .foregroundColor(.white.opacity(0.6))
            .frame(width: 36 * appUIScale, height: 36 * appUIScale)
    }

    private var machineIconName: String {
        guard let model = connection.identity?.modelIdentifier else { return "desktopcomputer" }
        if model.contains("MacBook") { return "laptopcomputer" }
        if model.contains("MacPro") { return "macpro.gen3" }
        if model.contains("iMac") { return "desktopcomputer" }
        if model.contains("Macmini") || model.contains("Mac14") { return "macmini" }
        return "desktopcomputer"
    }

    @ViewBuilder
    private var connectionStatusBadge: some View {
        switch connection.state {
        case .connected:
            Circle()
                .fill(Color.green)
                .frame(width: 8 * appUIScale, height: 8 * appUIScale)
        case .connecting, .authenticating, .awaitingApproval:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 16 * appUIScale, height: 16 * appUIScale)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 12 * appUIScale))
        case .disconnected:
            Circle()
                .fill(Color.gray.opacity(0.5))
                .frame(width: 8 * appUIScale, height: 8 * appUIScale)
        @unknown default:
            Circle()
                .fill(Color.gray.opacity(0.5))
                .frame(width: 8 * appUIScale, height: 8 * appUIScale)
        }
    }

    private func quickStat(label: String, value: String) -> some View {
        VStack(spacing: 2 * appUIScale) {
            Text(value)
                .font(.system(size: 14 * appUIScale, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(label)
                .font(.system(size: 10 * appUIScale))
                .foregroundColor(.white.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

// MARK: - DiscoveredMachineTile

struct DiscoveredMachineTile: View {
    let machine: DiscoveredRemoteMachine
    @Environment(\.appUIScale) private var appUIScale
    let onConnect: () -> Void

    private var scaledCornerRadius: CGFloat { 12 * appUIScale }

    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: 12 * appUIScale) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 22 * appUIScale))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 32 * appUIScale, height: 32 * appUIScale)

                VStack(alignment: .leading, spacing: 2 * appUIScale) {
                    Text(machine.name)
                        .font(.system(size: 13 * appUIScale, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let model = machine.modelIdentifier {
                        Text(model)
                            .font(.system(size: 11 * appUIScale))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 16 * appUIScale))
                    .foregroundColor(.accentColor.opacity(0.7))
            }
            .padding(12 * appUIScale)
            .background(
                ThemeRoundedRectangle(cornerRadius: scaledCornerRadius, style: .continuous).themed(
                    fill: Color.white.opacity(0.03),
                    stroke: Color.white.opacity(0.06)
                )
            )
        }
        .buttonStyle(.plain)
    }
}
