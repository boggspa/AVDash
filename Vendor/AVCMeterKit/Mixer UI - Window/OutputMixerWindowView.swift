//
//  OutputMixerWindowView.swift
//  AVCMeter
//
//  Created by Chris Izatt on 06/07/2025.
//
import CoreAudio
import SwiftUI
import MetalKit


struct OutputMixerWindowView: View {
    @EnvironmentObject var manager: OutputDeviceManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var virtualChannelManager: VirtualChannelManager

    // Always fetch fresh output contexts directly from the environment-backed manager on each render pass.
    private var contexts: [OutputMeteringContext] {
        manager.activeOutputDevices.compactMap { manager.outputContexts[$0] }
    }

    // Computed properties for output contexts and visible strips
    private var allVisibleStrips: [(OutputMeteringContext, Int)] {
        _ = manager.selectedChannelMaskVersion
        return contexts.flatMap { context in
            let mask = manager.selectedChannelMasks[context.device.deviceID]
                ?? Array(repeating: true, count: Int(context.device.outputChannels))
            return mask.enumerated().compactMap { $0.element ? (context, $0.offset) : nil }
        }
    }

    private var outputChannelCounts: [(context: OutputMeteringContext, count: Int)] {
        contexts.map { context in
            let deviceID = context.device.deviceID
            let count = manager.selectedChannelMasks[deviceID]?.filter { $0 }.count
                ?? Int(context.device.outputChannels)
            return (context, count)
        }
    }

    private var isLiquidGlass: Bool {
        themeManager.currentThemeMode == .liquidGlass
    }

    private var outerShellFill: Color {
        if isLiquidGlass {
            return Color.white.opacity(0.04)
        }
        return themeManager.accentFillColor.opacity(0.65)
    }

    private var innerShellFill: Color {
        if isLiquidGlass {
            return Color.white.opacity(0.03)
        }
        return Color(red: 0.18, green: 0.18, blue: 0.25).opacity(0.64)
    }

    var body: some View {
        let stripCount = calculateStripCount(using: contexts)
        let innerWidth = stripCount * 84.5
        let innerHeight: CGFloat = 640

        return ZStack(alignment: .topTrailing) {
            mainMixerUI(stripCount: stripCount, innerWidth: innerWidth, innerHeight: innerHeight)
                .background(
                    Group {
                        if themeManager.currentThemeMode == .liquidGlass {
                            Color.clear
                        } else {
                            Color.clear.opacity(0.05)
                        }
                    }
                )
                .offset(y: 0)

            Button(action: {
                FloatingWindowController.shared.closeOutputMixerWindow()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.gray)
                    .font(.system(size: 16, weight: .medium))
            }
        }
        .frame(
            minWidth: stripCount > 10 ? (stripCount * 82 + 80) : 900,
            minHeight: 440
        )
        .background(Color.clear)
        .ignoresSafeArea()
        .onAppear {
            for context in contexts {
                ChannelStateManager.shared.initializeOutputChannelStatesIfNeeded(for: context.device.deviceID, channelCount: Int(context.device.outputChannels))
            }
        }
    }
    // Helper to map ChannelStripColor enum to Color for overlay fill
    func channelStripColor(for style: ChannelStripColor) -> Color {
        switch style {
        case .standard: return Color.black.opacity(0.3)
        case .red: return Color.red.opacity(0.1)
        case .blue: return Color.blue.opacity(0.1)
        case .green: return Color.green.opacity(0.1)
        case .orange: return Color.orange.opacity(0.1)
        case .yellow: return Color.yellow.opacity(0.1)
        case .gray: return Color.gray.opacity(0.1)
        case .white: return Color.white.opacity(0.1)
        case .mint: return Color(red: 0.62, green: 0.96, blue: 0.78).opacity(0.1)
        case .pink: return Color.pink.opacity(0.1)
        case .purple: return Color.purple.opacity(0.1)
        }
    }

    private func calculateStripCount(using contexts: [OutputMeteringContext]) -> CGFloat {
        return CGFloat(contexts.reduce(into: 0) { acc, context in
            let deviceID = context.device.deviceID
            let mask = manager.selectedChannelMasks[deviceID] ?? Array(repeating: true, count: Int(context.device.outputChannels))
            acc += mask.filter { $0 }.count
        })
    }

    private func mainMixerUI(stripCount: CGFloat, innerWidth: CGFloat, innerHeight: CGFloat) -> some View {
        let channelCountsByDeviceID = Dictionary(uniqueKeysWithValues: outputChannelCounts.map { ($0.context.device.deviceID, $0.count) })
        return AnyView(
            GeometryReader { _ in
                VStack {
                    Spacer()

                    HStack {
                        Spacer()

                        VStack(alignment: .center) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(outerShellFill)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14)
                                            .stroke(Color.white.opacity(isLiquidGlass ? 0.38 : 0.8), lineWidth: 1)
                                    )
                                    .frame(width: innerWidth + 54, height: innerHeight + 72)
                                    .offset(y: -38)

                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(innerShellFill)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.white.opacity(isLiquidGlass ? 0.32 : 0.8), lineWidth: 1)
                                        )
                                        .offset(y: -35)

                                    ZStack {
                                        headerLabelsView(channelCountsByDeviceID: channelCountsByDeviceID)
                                        deviceFrameOverlayView(channelCountsByDeviceID: channelCountsByDeviceID, innerHeight: innerHeight)
                                        masterBusStripsView(allVisibleStrips: allVisibleStrips)
                                    }
                                }
                                .frame(
                                    width: stripCount * 48 + 24,
                                    height: 615
                                )
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)

                        Spacer()
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        )
    }

    private func headerLabelsView(channelCountsByDeviceID: [AudioDeviceID: Int]) -> some View {
        HStack(spacing: 4) {
            ForEach(contexts, id: \.device.deviceID) { context in
                let deviceID = context.device.deviceID
                let channelCount = channelCountsByDeviceID[deviceID] ?? Int(context.device.outputChannels)
                if channelCount > 0 {
                    Text(context.device.name)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: CGFloat(channelCount) * 80, alignment: .center)
                        .offset(y: -364)
                }
            }
        }
    }

    private func deviceFrameOverlayView(channelCountsByDeviceID: [AudioDeviceID: Int], innerHeight: CGFloat) -> some View {
        HStack(spacing: 1) {
            ForEach(contexts, id: \.device.deviceID) { context in
                let deviceID = context.device.deviceID
                let channelCount = channelCountsByDeviceID[deviceID] ?? Int(context.device.outputChannels)
                if channelCount > 0 {
                    ZStack {
                        Rectangle()
                            .fill(Color.white.opacity(isLiquidGlass ? 0.02 : 0.06))
                        Rectangle()
                            .stroke(Color.white.opacity(isLiquidGlass ? 0.22 : 0.8), lineWidth: 1)
                    }
                    .frame(width: CGFloat(channelCount) * 84.5, height: innerHeight + 48)
                    .offset(x: 0, y: -35)
                }
            }
        }
    }

    private func masterBusStripsView(allVisibleStrips: [(OutputMeteringContext, Int)]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(allVisibleStrips.enumerated()), id: \.offset) { pair in
                let (index, (context, channelIndex)) = pair
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(channelStripColor(for: themeManager.deviceChannelStripColors[context.device.deviceID] ?? .standard))
                        .offset(x: -18, y: -24)
                    MetalMasterBusStripRepresentable(
                        context: context,
                        channelIndex: channelIndex,
                    )
                    .frame(width: 80, height: 650)
                }
                .frame(width: 80, height: 280)
                .offset(x: 18, y: 1)
            }
        }
        .padding(.horizontal, 8)
    }
}
