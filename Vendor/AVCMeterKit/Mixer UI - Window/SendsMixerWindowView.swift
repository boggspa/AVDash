//
//  SendsMixerWindowView.swift
//  AVCMeter
//
//  Created by Chris Izatt on 08/07/2025.
//


import SwiftUI

struct SendsMixerWindowView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var virtualChannelManager: VirtualChannelManager

    private var fxSendStrips: [(VirtualChannelManager.VirtualMeteringContext, Int, VirtualChannel)] {
        virtualChannelManager.outputContexts
            .filter { $0.type == .fxSend }
            .flatMap { ctx in
                ctx.channels.enumerated().map { (index, channel) in (ctx, index, channel) }
            }
    }

    private var auxSendStrips: [(VirtualChannelManager.VirtualMeteringContext, Int, VirtualChannel)] {
        virtualChannelManager.outputContexts
            .filter { $0.type == .auxSend }
            .flatMap { ctx in
                ctx.channels.enumerated().map { (index, channel) in (ctx, index, channel) }
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

    private func meterStrips(for strips: [(VirtualChannelManager.VirtualMeteringContext, Int, VirtualChannel)], width: CGFloat) -> some View {
        GeometryReader { geo in
            HStack(spacing: 4) {
                Spacer(minLength: max(0, (geo.size.width - width) / 2))
                ForEach(Array(strips.enumerated()), id: \.1.2.id) { (_, tuple) in
                    let (ctx, index, channel) = tuple
                    let virtualContext = VirtualMeteringContext(name: ctx.name, channels: ctx.channels)
                    MetalFXSendStripRepresentable(
                        context: virtualContext,
                        channelIndex: index
                    )
                    .frame(width: 80, height: 650)
                }
            }
        }
        .frame(height: 650)
    }

    var body: some View {
        let fx = fxSendStrips
        let aux = auxSendStrips
        let allStrips = fx + aux
        let stripCount = CGFloat(allStrips.count)
        let innerWidth = stripCount * 84.5
        let innerHeight: CGFloat = 640

        ZStack(alignment: .topTrailing) {
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

                                        meterStrips(for: allStrips, width: stripCount * 84.5)
                                    }
                                    .frame(width: stripCount * 84.5 + 32, height: 615)
                                }
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

            Button(action: {
                NSApplication.shared.keyWindow?.close()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.gray)
                    .font(.system(size: 16, weight: .medium))
            }
        }
        .onAppear {
            let auxChannelIDs = aux.map { $0.2.id }
            ChannelStateManager.shared.initializeVirtualLinkedPairsIfNeeded(channelIDs: auxChannelIDs, channelType: .auxSend)
        }
        .frame(
            minWidth: max(stripCount * 84.5 + 80, 1100),
            minHeight: 440
        )
        .background(Color.clear)
        .ignoresSafeArea()
    }
}

#Preview {
    SendsMixerWindowView()
        .environmentObject(ThemeManager())
        .environmentObject(VirtualChannelManager.shared)
}
