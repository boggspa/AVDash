import CoreAudio
import SwiftUI

struct VirtualInstrumentMixerWindowView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var virtualChannelManager: VirtualChannelManager
    @EnvironmentObject var channelStateManager: ChannelStateManager
    @EnvironmentObject var manager: AudioDeviceManager

    private let channelCount = 8
    private let viDeviceID: AudioDeviceID = 999_999

    private static let fallbackVIContext: DeviceMeteringContext = {
        let viDevice = AudioDevice(
            deviceID: 999_999,
            name: "Virtual Instruments",
            inputChannels: 8,
            outputChannels: 0,
            sampleRate: 48_000,
            transportType: "virtual"
        )
        return DeviceMeteringContext(device: viDevice, handler: LevelHandler())
    }()

    private var viContext: DeviceMeteringContext {
        manager.activeDevices[viDeviceID] ?? Self.fallbackVIContext
    }

    private var stripCount: CGFloat {
        CGFloat(channelCount)
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
        let innerWidth = stripCount * 84.5
        let innerHeight: CGFloat = 640

        ZStack(alignment: .topTrailing) {
            Button(action: {
                NSApplication.shared.keyWindow?.close()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.gray)
                    .font(.system(size: 16, weight: .medium))
            }

            ZStack {
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
                                            Text("Virtual Instruments")
                                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                .foregroundColor(.white)
                                                .frame(width: CGFloat(channelCount) * 80, alignment: .center)
                                                .offset(y: -364)

                                            ZStack {
                                                Rectangle()
                                                    .fill(Color.white.opacity(isLiquidGlass ? 0.02 : 0.06))
                                                Rectangle()
                                                    .stroke(Color.white.opacity(isLiquidGlass ? 0.22 : 0.8), lineWidth: 1)
                                            }
                                            .frame(width: CGFloat(channelCount) * 84.5, height: innerHeight + 48)
                                            .offset(y: -35)

                                            HStack(spacing: 4) {
                                                ForEach(0..<channelCount, id: \.self) { channelIndex in
                                                    ZStack {
                                                        RoundedRectangle(cornerRadius: 8)
                                                            .fill(channelStripColor(for: .purple))
                                                            .offset(x: -18, y: -24)

                                                        MetalMixerStripRepresentable(
                                                            context: viContext,
                                                            channelIndex: channelIndex,
                                                            isVirtualInstrument: true
                                                        )
                                                        .environmentObject(themeManager)
                                                        .environmentObject(channelStateManager)
                                                        .environmentObject(virtualChannelManager)
                                                        .frame(width: 80, height: 650)
                                                    }
                                                    .frame(width: 80, height: 280)
                                                    .offset(x: 18, y: 1)
                                                }
                                            }
                                            .padding(.horizontal, 8)
                                        }
                                    }
                                    .frame(width: stripCount * 48 + 24, height: 615)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)

                            Spacer()
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(
                Group {
                    if isLiquidGlass {
                        Color.clear
                    } else {
                        Color.white.opacity(0.05)
                    }
                }
            )
            .offset(y: 0)
        }
        .frame(minWidth: stripCount > 10 ? (stripCount * 82 + 80) : 900, minHeight: 440)
        .background(Color.clear)
        .ignoresSafeArea()
        .onAppear {
            ensureChannelStatesPopulated()
            VirtualInstrumentHostManager.shared.start(
                deviceID: viContext.device.deviceID,
                channelCount: channelCount,
                sampleRate: viContext.device.sampleRate
            )
        }
    }

    private func ensureChannelStatesPopulated() {
        ChannelStateManager.shared.initializeInputChannelStatesIfNeeded(
            for: viContext.device.deviceID,
            channelCount: channelCount
        )

        for channelIndex in 0..<channelCount {
            let key = "\(viContext.device.deviceID)-\(channelIndex)"
            if ChannelStateManager.shared.channelStates[key] == nil {
                ChannelStateManager.shared.channelStates[key] = ChannelStripState(id: key)
            }
        }
    }

    private func channelStripColor(for style: ChannelStripColor) -> Color {
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
}
