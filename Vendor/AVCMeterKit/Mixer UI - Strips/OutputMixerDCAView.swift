//
//  OutputMixerDCAView.swift
//  AVCMeter
//
//  Created by Chris Izatt on 06/07/2025.
//

import SwiftUI

struct DCAMixerStripView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var channelStateManager: ChannelStateManager
    @State private var showAssignmentPopover: Bool = false

    let channel: VirtualChannel
    let context: VirtualMeteringContext
    let channelIndex: Int
    let groupChannelIDs: [UUID]

    private var assignmentTargets: Set<ChannelStateManager.DCATarget> {
        channelStateManager.dcaTargets(for: channel.id)
    }

    private var assignmentSummaryText: String {
        let count = assignmentTargets.count
        if count == 0 {
            return "In --"
        }
        if count == 1, let first = assignmentTargets.first {
            return compactTargetLabel(first)
        }
        return "\(count) tgt"
    }

    private var inputTargets: [(ChannelStateManager.DCATarget, String)] {
        AudioDeviceManager.shared.activeDevices
            .values
            .sorted { $0.device.name.localizedCaseInsensitiveCompare($1.device.name) == .orderedAscending }
            .flatMap { context in
                (0..<Int(context.device.inputChannels)).map { channelIndex in
                    let target: ChannelStateManager.DCATarget = .input(deviceID: context.device.deviceID, channel: channelIndex)
                    return (target, "\(context.device.name) • In \(channelIndex + 1)")
                }
            }
    }

    private func virtualTypeLabel(_ type: VirtualChannelType) -> String {
        switch type {
        case .fxReturn: return "FX Return"
        case .auxReturn: return "Aux Return"
        case .virtualInstrument: return "VI"
        case .fxSend: return "FX Send"
        case .auxSend: return "Aux Send"
        case .dca: return "DCA"
        }
    }

    private var outputTargets: [(ChannelStateManager.DCATarget, String)] {
        OutputDeviceManager.shared.outputDevices
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .flatMap { device in
                (0..<Int(device.outputChannels)).map { channelIndex in
                    let target: ChannelStateManager.DCATarget = .output(deviceID: device.deviceID, channel: channelIndex)
                    return (target, "\(device.name) • Out \(channelIndex + 1)")
                }
            }
    }

    private var virtualTargets: [(ChannelStateManager.DCATarget, String)] {
        VirtualChannelManager.shared.allChannels
            .filter { $0.type != .dca && $0.id != channel.id }
            .sorted { lhs, rhs in
                if lhs.type == rhs.type {
                    return lhs.index < rhs.index
                }
                return lhs.type.rawValue < rhs.type.rawValue
            }
            .map { virtualChannel in
                let target: ChannelStateManager.DCATarget = .virtual(channelID: virtualChannel.id)
                return (target, "\(virtualChannel.name) • \(virtualTypeLabel(virtualChannel.type))")
            }
    }

    private func colorForChannelStrip(_ color: ChannelStripColor) -> Color {
        switch color {
        case .standard:
            return Color(.black).opacity(0.75)
        case .red:
            return Color.red.opacity(0.6)
        case .blue:
            return Color.blue.opacity(0.6)
        case .green:
            return Color.green.opacity(0.6)
        case .orange:
            return Color.orange.opacity(0.6)
        case .yellow:
            return Color.yellow.opacity(0.6)
        case .gray:
            return Color.gray.opacity(0.6)
        case .white:
            return Color.white.opacity(0.6)
        case .mint:
            return Color(red: 0.62, green: 0.96, blue: 0.78).opacity(0.6)
        case .pink:
            return Color.pink.opacity(0.6)
        case .purple:
            return Color.purple.opacity(0.6)
        }
    }

    private var isMuted: Bool {
        channelStateManager.isVirtualMuted(channelID: channel.id, in: groupChannelIDs)
    }

    private var isSoloed: Bool {
        channelStateManager.isVirtualSoloed(channelID: channel.id, in: groupChannelIDs)
    }

    private var isLinked: Bool {
        channelStateManager.isVirtualLinked(channelID: channel.id, in: groupChannelIDs)
    }

    private var faderBinding: Binding<Double> {
        Binding(
            get: { Double(channelStateManager.fader(for: channel.id)) },
            set: { channelStateManager.setFader(for: channel.id, value: Float($0)) }
        )
    }

    private func toggleMute() {
        channelStateManager.toggleMute(for: channel.id)
    }

    private func toggleSolo() {
        channelStateManager.toggleVirtualSolo(for: channel.id, in: groupChannelIDs)
    }

    private func toggleLink() {
        channelStateManager.toggleVirtualLink(for: channel.id, in: groupChannelIDs)
    }

    private func compactTargetLabel(_ target: ChannelStateManager.DCATarget) -> String {
        switch target {
        case .input(_, let channel):
            return "In \(channel + 1)"
        case .output(_, let channel):
            return "Out \(channel + 1)"
        case .virtual(let channelID):
            if let virtual = VirtualChannelManager.shared.channel(for: channelID) {
                return virtual.name
            }
            return "Virtual"
        }
    }

    private func targetLabel(_ target: ChannelStateManager.DCATarget) -> String {
        switch target {
        case .input(let deviceID, let channel):
            if let context = AudioDeviceManager.shared.activeDevices[deviceID] {
                return "\(context.device.name) • In \(channel + 1)"
            }
            return "Input \(deviceID) • In \(channel + 1)"
        case .output(let deviceID, let channel):
            if let device = OutputDeviceManager.shared.outputDevices.first(where: { $0.deviceID == deviceID }) {
                return "\(device.name) • Out \(channel + 1)"
            }
            return "Output \(deviceID) • Out \(channel + 1)"
        case .virtual(let channelID):
            if let virtual = VirtualChannelManager.shared.channel(for: channelID) {
                return "\(virtual.name) • \(virtualTypeLabel(virtual.type))"
            }
            return "Virtual Channel"
        }
    }

    private func isAssigned(_ target: ChannelStateManager.DCATarget) -> Bool {
        assignmentTargets.contains(target)
    }

    private func toggleAssignment(_ target: ChannelStateManager.DCATarget) {
        if isAssigned(target) {
            channelStateManager.removeDCATarget(target, from: channel.id)
        } else {
            channelStateManager.addDCATarget(target, to: channel.id)
        }
    }

    private var assignmentPill: some View {
        Button {
            showAssignmentPopover = true
        } label: {
            Text(assignmentSummaryText)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 72, height: 24)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.45))
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAssignmentPopover) {
            dcaAssignmentPopover
        }
    }

    private var dcaAssignmentPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DCA Assignment")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    channelStateManager.clearDCATargets(for: channel.id)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !assignmentTargets.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Assigned")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.secondary)
                            ForEach(Array(assignmentTargets), id: \.self) { target in
                                assignmentRow(title: targetLabel(target), isAssigned: true) {
                                    toggleAssignment(target)
                                }
                            }
                        }
                    }

                    assignmentSection(title: "Input Channels", targets: inputTargets)
                    assignmentSection(title: "Output Channels", targets: outputTargets)
                    assignmentSection(title: "Virtual Channels", targets: virtualTargets)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(12)
        .frame(width: 360, height: 430)
    }

    private func assignmentSection(
        title: String,
        targets: [(ChannelStateManager.DCATarget, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
            if targets.isEmpty {
                Text("No channels available")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            } else {
                ForEach(targets, id: \.0) { target, label in
                    assignmentRow(title: label, isAssigned: isAssigned(target)) {
                        toggleAssignment(target)
                    }
                }
            }
        }
    }

    private func assignmentRow(title: String, isAssigned: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isAssigned ? Color.green.opacity(0.9) : Color.white.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(isAssigned ? Color.green.opacity(0.95) : Color.white.opacity(0.28), lineWidth: 1)
                    )
                    .frame(width: 14, height: 14)

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
        }
        .buttonStyle(.plain)
    }

    private var backgroundRectangles: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(themeManager.accentFillColor)
            .opacity(0.94)
            .frame(width: 80, height: 412)
            .offset(x: -18, y: -24)
    }

    private var faderAndButtonsView: some View {
        VStack {
            assignmentPill
                .padding(.bottom, 4)
                .offset(x: -18)

#if os(macOS)
            FaderView(
                value: faderBinding,
                minValue: 0.0,
                maxValue: 1.2,
                trackHeight: 260,
                trackWidth: 2,
                thumbHeight: 42,
                thumbWidth: 45,
                capStyle: .dca,
                deviceID: context.deviceID,
                channelIndex: channelIndex,
                role: .input
            )
            .frame(width: 28, height: 270)
            .offset(y: 66)
#else
            Slider(value: faderBinding, in: 0.0...1.2)
                .rotationEffect(.degrees(-90))
                .frame(height: 280)
                .padding(.leading, 6)
#endif
            VStack {
                Button(action: {
                    toggleLink()
                }) {
                    Image(systemName: "link")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(isLinked ? .white : .blue)
                        .padding(.horizontal, 2)
                        .background(
                            ZStack {
                                isLinked ? Color.blue : Color.black.opacity(0.6)
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
                            }
                        )
                        .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .offset(x: -48, y: 62)

            VStack {
                Text("M")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(isMuted ? .white : .red)
                    .padding(.horizontal, 2)
                    .background(
                        ZStack {
                            isMuted ? Color.red : Color.black.opacity(0.6)
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.6), lineWidth: 1)
                        }
                    )
                    .cornerRadius(6)
                    .onTapGesture {
                        toggleMute()
                    }
            }
            .offset(x: -23, y: 43)

            VStack {
                Text("S")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(isSoloed ? .white : .yellow)
                    .padding(.horizontal, 6)
                    .background(
                        ZStack {
                            isSoloed ? Color.yellow : Color.black.opacity(0.6)
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.6), lineWidth: 1)
                        }
                    )
                    .cornerRadius(6)
                    .onTapGesture {
                        toggleSolo()
                    }
            }
            .offset(x: -2, y: 24)
        }
        .frame(width: 36)
    }

    private var channelLabelOverlayView: some View {
        ZStack {
            Rectangle()
                .fill(themeManager.accentFillColor)
                .frame(width: 80, height: 22)
            Rectangle()
                .stroke(colorForChannelStrip(.standard), lineWidth: 2)
                .frame(width: 80, height: 22)
            Text(channel.name)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.primary)
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
                .offset(y: -1)
        }
        .offset(y: 232)
    }

    var body: some View {
        ZStack {
            backgroundRectangles
            ZStack(alignment: .bottom) {
                HStack(spacing: 4) {
                    Color.clear
                        .frame(width: 26, height: 270)
                    Color.clear
                        .frame(width: 12, height: 260)
                    faderAndButtonsView
                    Spacer(minLength: 10)
                }
                .frame(width: 80, height: 412)
                .overlay(channelLabelOverlayView)
                .offset(x: -18, y: -34)

                Rectangle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 2)
                    .offset(x: -18, y: -24)
            }
        }
        .frame(width: 80, height: 412)
        .id(channel.id)
    }
}
