import CoreAudio
import SwiftUI

struct AllMixersWindowView: View {
    @EnvironmentObject var manager: AudioDeviceManager
    @EnvironmentObject var outputManager: OutputDeviceManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var virtualChannelManager: VirtualChannelManager
    @EnvironmentObject var channelStateManager: ChannelStateManager

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

    private var inputContexts: [DeviceMeteringContext] {
        manager.activeDevices
            .compactMap { $0.value }
            .filter { context in
                context.device.deviceID != viDeviceID && context.device.deviceID != systemAudioDeviceID
            }
            .sorted { $0.device.name.localizedCaseInsensitiveCompare($1.device.name) == .orderedAscending }
    }

    private var inputStrips: [(DeviceMeteringContext, Int)] {
        inputContexts.flatMap { context in
            let mask = manager.selectedChannelMasks[context.device.deviceID] ?? Array(repeating: true, count: Int(context.device.inputChannels))
            return mask.enumerated().compactMap { $0.element ? (context, $0.offset) : nil }
        }
    }

    private var viContext: DeviceMeteringContext {
        manager.activeDevices[viDeviceID] ?? Self.fallbackVIContext
    }

    private var virtualInputStrips: [(DeviceMeteringContext, Int)] {
        Array(0..<Int(viContext.device.inputChannels)).map { (viContext, $0) }
    }

    private var returnStrips: [(VirtualChannelManager.VirtualMeteringContext, Int, VirtualChannel)] {
        virtualChannelManager.inputContexts
            .filter { $0.type == .fxReturn || $0.type == .auxReturn }
            .flatMap { ctx in
                ctx.channels.enumerated().map { (index, channel) in (ctx, index, channel) }
            }
    }

    private var sendStrips: [(VirtualChannelManager.VirtualMeteringContext, Int, VirtualChannel)] {
        virtualChannelManager.outputContexts
            .filter { $0.type == .fxSend || $0.type == .auxSend }
            .flatMap { ctx in
                ctx.channels.enumerated().map { (index, channel) in (ctx, index, channel) }
            }
    }

    private var outputContexts: [OutputMeteringContext] {
        outputManager.activeOutputDevices
            .compactMap { outputManager.outputContexts[$0] }
            .sorted { $0.device.name.localizedCaseInsensitiveCompare($1.device.name) == .orderedAscending }
    }

    private var outputStrips: [(OutputMeteringContext, Int)] {
        outputContexts.flatMap { context in
            let mask = outputManager.selectedChannelMasks[context.device.deviceID] ?? Array(repeating: true, count: Int(context.device.outputChannels))
            return mask.enumerated().compactMap { $0.element ? (context, $0.offset) : nil }
        }
    }

    private var dcaGroup: VirtualChannelManager.VirtualMeteringContext? {
        virtualChannelManager.outputGroups.first(where: { $0.type == .dca })
    }

    private var dcaStrips: [(VirtualChannelManager.VirtualMeteringContext, Int, VirtualChannel)] {
        guard let dcaGroup else { return [] }
        return dcaGroup.channels.enumerated().map { (index, channel) in (dcaGroup, index, channel) }
    }

    private var dcaChannelIDs: [UUID] {
        dcaGroup?.channels.map { $0.id } ?? []
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 14) {
                sectionCard(title: "Input", stripCount: inputStrips.count) {
                    stripRow(width: CGFloat(inputStrips.count) * 84.5) {
                        ForEach(Array(inputStrips.enumerated()), id: \.offset) { _, pair in
                            let (context, channelIndex) = pair
                            inputStripView(context: context, channelIndex: channelIndex)
                        }
                    }
                }

                sectionCard(title: "Virtual Input", stripCount: virtualInputStrips.count) {
                    stripRow(width: CGFloat(virtualInputStrips.count) * 84.5) {
                        ForEach(Array(virtualInputStrips.enumerated()), id: \.offset) { _, pair in
                            let (context, channelIndex) = pair
                            virtualInputStripView(context: context, channelIndex: channelIndex)
                        }
                    }
                }

                sectionCard(title: "Returns", stripCount: returnStrips.count) {
                    stripRow(width: CGFloat(returnStrips.count) * 84.5) {
                        ForEach(Array(returnStrips.enumerated()), id: \.offset) { _, tuple in
                            let (ctx, index, channel) = tuple
                            returnStripView(context: ctx, channelIndex: index, channel: channel)
                        }
                    }
                }

                sectionCard(title: "Sends", stripCount: sendStrips.count) {
                    stripRow(width: CGFloat(sendStrips.count) * 84.5) {
                        ForEach(Array(sendStrips.enumerated()), id: \.offset) { _, tuple in
                            let (ctx, index, channel) = tuple
                            sendStripView(context: ctx, channelIndex: index, channel: channel)
                        }
                    }
                }

                sectionCard(title: "Outputs", stripCount: outputStrips.count) {
                    stripRow(width: CGFloat(outputStrips.count) * 84.5) {
                        ForEach(Array(outputStrips.enumerated()), id: \.offset) { _, tuple in
                            let (context, channelIndex) = tuple
                            outputStripView(context: context, channelIndex: channelIndex)
                        }
                    }
                }

                sectionCard(title: "DCA", stripCount: dcaStrips.count, contentAlignment: .bottom) {
                    stripRow(width: CGFloat(dcaStrips.count) * 84.5) {
                        ForEach(Array(dcaStrips.enumerated()), id: \.offset) { _, tuple in
                            let (ctx, index, channel) = tuple
                            dcaStripView(context: ctx, channelIndex: index, channel: channel)
                        }
                    }
                    .offset(x: 18)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.accentFillColor)
        .onAppear {
            ensureChannelStatesPopulated()
            initializeVirtualGroupsIfNeeded()
            VirtualInstrumentHostManager.shared.start(
                deviceID: viContext.device.deviceID,
                channelCount: Int(viContext.device.inputChannels),
                sampleRate: viContext.device.sampleRate
            )
        }
    }

    private enum SectionContentAlignment {
        case center
        case bottom
    }

    private func sectionCard<Content: View>(title: String, stripCount: Int, contentAlignment: SectionContentAlignment = .center, contentBottomInset: CGFloat = 0, @ViewBuilder content: () -> Content) -> some View {
        let width = max(CGFloat(stripCount) * 84.5 + 24, 220)

        return VStack(alignment: .center, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)

            if contentAlignment == .center {
                Spacer(minLength: 0)

                content()
                    .padding(.vertical, contentBottomInset)

                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)

                content()
                    .padding(.bottom, contentBottomInset)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .frame(width: width, height: 700, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private func stripRow<Content: View>(width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 4) {
            content()
        }
        .frame(width: max(width, 80), alignment: .center)
    }

    private func inputStripView(context: DeviceMeteringContext, channelIndex: Int) -> some View {
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

    private func virtualInputStripView(context: DeviceMeteringContext, channelIndex: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(channelStripColor(for: .purple))
                .offset(x: -18, y: -24)
            MetalMixerStripRepresentable(
                context: context,
                channelIndex: channelIndex,
                isVirtualInstrument: true
            )
            .frame(width: 80, height: 650)
        }
        .frame(width: 80, height: 280)
        .offset(x: 18, y: 1)
    }

    private func returnStripView(context: VirtualChannelManager.VirtualMeteringContext, channelIndex: Int, channel: VirtualChannel) -> some View {
        FXReturnStripView(
            channel: channel,
            context: VirtualMeteringContext(name: context.name, channels: context.channels),
            channelIndex: channelIndex
        )
        .frame(width: 80, height: 650)
    }

    private func sendStripView(context: VirtualChannelManager.VirtualMeteringContext, channelIndex: Int, channel: VirtualChannel) -> some View {
        let virtualContext = VirtualMeteringContext(name: context.name, channels: context.channels)
        return MetalFXSendStripRepresentable(context: virtualContext, channelIndex: channelIndex)
            .frame(width: 80, height: 650)
    }

    private func outputStripView(context: OutputMeteringContext, channelIndex: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(channelStripColor(for: themeManager.deviceChannelStripColors[context.device.deviceID] ?? .standard))
                .offset(x: -18, y: -24)
            MetalMasterBusStripRepresentable(context: context, channelIndex: channelIndex)
                .frame(width: 80, height: 650)
        }
        .frame(width: 80, height: 280)
        .offset(x: 18, y: 1)
    }

    private func dcaStripView(context: VirtualChannelManager.VirtualMeteringContext, channelIndex: Int, channel: VirtualChannel) -> some View {
        DCAMixerStripView(
            channel: channel,
            context: VirtualMeteringContext(name: context.name, channels: context.channels),
            channelIndex: channelIndex,
            groupChannelIDs: dcaChannelIDs
        )
    }

    private func ensureChannelStatesPopulated() {
        for context in inputContexts {
            ChannelStateManager.shared.initializeInputChannelStatesIfNeeded(for: context.device.deviceID, channelCount: Int(context.device.inputChannels))
            let mask = manager.selectedChannelMasks[context.device.deviceID] ?? Array(repeating: true, count: Int(context.device.inputChannels))
            for channelIndex in mask.indices where mask[channelIndex] {
                let key = "\(context.device.deviceID)-\(channelIndex)"
                if ChannelStateManager.shared.channelStates[key] == nil {
                    ChannelStateManager.shared.channelStates[key] = ChannelStripState(id: key)
                }
            }
        }

        ChannelStateManager.shared.initializeInputChannelStatesIfNeeded(for: viDeviceID, channelCount: Int(viContext.device.inputChannels))
        for channelIndex in 0..<Int(viContext.device.inputChannels) {
            let key = "\(viContext.device.deviceID)-\(channelIndex)"
            if ChannelStateManager.shared.channelStates[key] == nil {
                ChannelStateManager.shared.channelStates[key] = ChannelStripState(id: key)
            }
        }

        for context in outputContexts {
            ChannelStateManager.shared.initializeOutputChannelStatesIfNeeded(for: context.device.deviceID, channelCount: Int(context.device.outputChannels))
            let mask = outputManager.selectedChannelMasks[context.device.deviceID] ?? Array(repeating: true, count: Int(context.device.outputChannels))
            for channelIndex in mask.indices where mask[channelIndex] {
                let key = "\(context.device.deviceID)-\(channelIndex)"
                if ChannelStateManager.shared.outputChannelStates[key] == nil {
                    ChannelStateManager.shared.outputChannelStates[key] = ChannelStripState(id: key)
                }
            }
        }
    }

    private func initializeVirtualGroupsIfNeeded() {
        let fxReturnIDs = virtualChannelManager.inputContexts
            .filter { $0.type == .fxReturn }
            .flatMap { $0.channels.map(\.id) }
        let auxReturnIDs = virtualChannelManager.inputContexts
            .filter { $0.type == .auxReturn }
            .flatMap { $0.channels.map(\.id) }
        let fxSendIDs = virtualChannelManager.outputContexts
            .filter { $0.type == .fxSend }
            .flatMap { $0.channels.map(\.id) }
        let auxSendIDs = virtualChannelManager.outputContexts
            .filter { $0.type == .auxSend }
            .flatMap { $0.channels.map(\.id) }

        ChannelStateManager.shared.initializeVirtualLinkedPairsIfNeeded(channelIDs: fxReturnIDs, channelType: .fxReturn)
        ChannelStateManager.shared.initializeVirtualLinkedPairsIfNeeded(channelIDs: auxReturnIDs, channelType: .auxReturn)
        ChannelStateManager.shared.initializeVirtualLinkedPairsIfNeeded(channelIDs: fxSendIDs, channelType: .fxSend)
        ChannelStateManager.shared.initializeVirtualLinkedPairsIfNeeded(channelIDs: auxSendIDs, channelType: .auxSend)
        ChannelStateManager.shared.initializeVirtualLinkedPairsIfNeeded(channelIDs: dcaChannelIDs, channelType: .dca)
    }
}
