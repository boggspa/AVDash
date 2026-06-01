import SwiftUI

struct DCAMixerWindowView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var virtualChannelManager: VirtualChannelManager
    @EnvironmentObject var channelStateManager: ChannelStateManager

    private var dcaGroup: VirtualChannelManager.VirtualMeteringContext? {
        virtualChannelManager.outputGroups.first(where: { $0.type == .dca })
    }

    private var dcaChannelIDs: [UUID] {
        guard let dcaGroup else { return [] }
        return dcaGroup.channels.map { $0.id }
    }

    private var dcaStripContext: VirtualMeteringContext? {
        guard let dcaGroup else { return nil }
        return VirtualMeteringContext(name: dcaGroup.name, channels: dcaGroup.channels, deviceID: 0)
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
        let stripCount = CGFloat(dcaGroup?.channels.count ?? 0)
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
                            Spacer(minLength: 0)

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

                                        GeometryReader { geo in
                                            HStack(spacing: 4) {
                                                Spacer(minLength: max(0, (geo.size.width - stripCount * 84.5) / 2))
                                                if let stripContext = dcaStripContext, let dcaGroup {
                                                    ForEach(dcaGroup.channels.indices, id: \.self) { index in
                                                        let channel = dcaGroup.channels[index]
                                                        DCAMixerStripView(
                                                            channel: channel,
                                                            context: stripContext,
                                                            channelIndex: index,
                                                            groupChannelIDs: dcaChannelIDs
                                                        )
                                                        .frame(width: 80, height: 650)
                                                    }
                                                }
                                            }
                                        }
                                        .frame(height: 650)
                                    }
                                    .frame(width: stripCount * 84.5 + 32, height: 615)
                                }

                                // DCA Input Routing label above assignment pills
                                Text("DCA Input Routing")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(Color.black.opacity(0.4))
                                            .overlay(
                                                Capsule()
                                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                                            )
                                    )
                                    .offset(y: 320)
                            }
                            .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 0)
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
                        Color.clear.opacity(0.05)
                    }
                }
            )
            .offset(y: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: max(stripCount * 84.5 + 80, 1100), minHeight: 440)
        .background(Color.clear)
        .ignoresSafeArea()
        .onAppear {
            channelStateManager.initializeVirtualLinkedPairsIfNeeded(channelIDs: dcaChannelIDs, channelType: .dca)
        }
    }
}
