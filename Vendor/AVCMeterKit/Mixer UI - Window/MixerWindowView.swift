import CoreAudio
import SwiftUI

struct MixerWindowView: View {
    @EnvironmentObject var manager: AudioDeviceManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var virtualChannelManager: VirtualChannelManager

    private var filteredMeterContexts: [DeviceMeteringContext] {
        manager.activeDevices
            .compactMap { $0.value }
            .filter { context in
                context.device.deviceID != 999_999 && context.device.deviceID != systemAudioDeviceID
            }
    }

    private var allVisibleStrips: [(DeviceMeteringContext, Int)] {
        filteredMeterContexts
            .flatMap { context in
                let mask = manager.selectedChannelMasks[context.device.deviceID] ?? Array(repeating: true, count: Int(context.device.inputChannels))
                return mask.enumerated().compactMap { $0.element ? (context, $0.offset) : nil }
            }
    }

    private var stripCount: CGFloat {
        let deviceCountSum: Int = filteredMeterContexts.reduce(0) { acc, context in
            let mask = manager.selectedChannelMasks[context.device.deviceID] ?? Array(repeating: true, count: Int(context.device.inputChannels))
            return acc + mask.filter { $0 }.count
        }
        return CGFloat(deviceCountSum)
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
        let stripCount = self.stripCount

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

            // Main UI content wrapped in ZStack with offset
            ZStack {
                GeometryReader { geometry in
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
                                            VStack(spacing: 2) {
                                                HStack(spacing: 4) {
                                                    ForEach(Array(filteredMeterContexts), id: \.device.deviceID) { context in
                                                        let deviceID = context.device.deviceID
                                                        let channelCount = manager.selectedChannelMasks[deviceID]?.filter { $0 }.count ?? Int(context.device.inputChannels)
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

                                            HStack(spacing: 1) {
                                                ForEach(Array(filteredMeterContexts), id: \.device.deviceID) { context in
                                                    let deviceID = context.device.deviceID
                                                    let channelCount = manager.selectedChannelMasks[deviceID]?.filter { $0 }.count ?? Int(context.device.inputChannels)
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

                                            HStack(spacing: 4) {
                                                ForEach(Array(allVisibleStrips.enumerated()), id: \.0) { _, pair in
                                                    let (context, channelIndex) = pair

                                                    ZStack {
                                                        RoundedRectangle(cornerRadius: 8)
                                                            .fill(channelStripColor(for: themeManager.deviceChannelStripColors[context.device.deviceID] ?? .standard))
                                                            .offset(x: -18, y: -24)
                                                        MetalMixerStripRepresentable(context: context, channelIndex: channelIndex)
                                                            .frame(width: 80, height: 650)
                                                    }
                                                    .frame(width: 80, height: 280)
                                                    .offset(x: 18, y: 1)
                                                }
                                            }
                                            .padding(.horizontal, 8)
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
            }
            .background(
                Group {
                    if themeManager.currentThemeMode == .liquidGlass {
                        Color.clear
                    } else {
                        Color.white.opacity(0.05)
                    }
                }
            )
            .offset(y: 0)
        }
        .frame(
            minWidth: stripCount > 10 ? (stripCount * 82 + 80) : 900,
            minHeight: 440
        )
        .background(Color.clear)
        .ignoresSafeArea()
        .onAppear {
            ensureChannelStatesPopulated()
        }
    }

    private func ensureChannelStatesPopulated() {
        for (context, channelIndex) in allVisibleStrips {
            let key = "\(context.device.deviceID)-\(channelIndex)"
            if ChannelStateManager.shared.channelStates[key] == nil {
                ChannelStateManager.shared.channelStates[key] = ChannelStripState(id: key)
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

}





// MARK: - Preview
#if DEBUG

private class PreviewAudioDeviceManager: AudioDeviceManager {
    override init() {
        super.init()
        // Setup minimal fake devices
        let device = AudioDevice(deviceID: 1, name: "Test Device", inputChannels: 2, outputChannels: 2, sampleRate: 48000, transportType: "unknown")
        let context = DeviceMeteringContext(device: device, handler: LevelHandler())
        self.activeDevices = [1: context]
        self.selectedChannelMasks = [1: [true, true]]
    }
}

private class PreviewThemeManager: ThemeManager {
    override init() {
        super.init()
        self.currentThemeMode = .liquidGlass
        self.accentColor = NSColor.systemBlue.withAlphaComponent(0.6)
    }
}

#Preview("MixerWindowView") {
    MixerWindowView()
        .environmentObject(PreviewAudioDeviceManager())
        .environmentObject(PreviewThemeManager())
        .environmentObject(VirtualChannelManager())
        .environmentObject(ChannelStateManager.shared)
}

#endif
