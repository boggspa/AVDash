///
/// @file ContentView.swift
/// AVCMeter
///
/// Main SwiftUI View and supporting UI components for the AVCMeter app.
///
/// This file defines the application's UI layout, device management, theme controls,
/// and real-time audio metering visualization. Views are documented using Apple Developer
/// style doc comments.
///
/// © 2024 AVCMeter Contributors. All rights reserved.
///




import SwiftUI
import Accelerate
import MetalKit
import ScreenCaptureKit
import AVFoundation
import Combine
import CoreAudio
import AudioToolbox


// MARK: - C/C++ input stream lifetime management
/// Keeps track of HAL input streams created for each audio device.
private var halInputStreams: [AudioDeviceID: UnsafeMutableRawPointer] = [:]





func getVirtualDeviceVolume(channel: Int) -> Float {
    // Default level used when no virtual-device volume binding is active.
    return 0.5
}

func setVirtualDeviceVolume(channel: Int, value: Float) {
    _ = (channel, value)
}

func pushInterleavedAudioToVirtualDevice(_ buffer: [Float], sampleRate: Float64, channels: Int) {
    _ = (buffer, sampleRate, channels)
}

enum MeteringCardLayout {
    static let cardCornerRadius: CGFloat = 14
    static let cardHeight: CGFloat = 415
    static let cardContentSpacing: CGFloat = 8
    static let cardContentPadding: CGFloat = 16
    static let cardContentOffsetY: CGFloat = -24
    static let cardTopPadding: CGFloat = 16
    static let floatingWindowInset: CGFloat = 24

    static let headerOuterSpacing: CGFloat = 8
    static let headerInnerSpacing: CGFloat = 24
    static let headerYOffset: CGFloat = -4
    static let headerSubtitleYOffset: CGFloat = -18
    static let headerVerticalPadding: CGFloat = -16
    static let headerMaxWidth: CGFloat = 128

    static let cardRowSpacing: CGFloat = 20
    static let sectionGapWidth: CGFloat = 28

    static let viContentVerticalNudge: CGFloat = -38
    static let viFeatureControlsTopPadding: CGFloat = 28
    static let viFeatureControlsBottomPadding: CGFloat = -12
    static let viFeatureControlsLeadingNudge: CGFloat = 38
    static let viChannelHeaderYOffset: CGFloat = -4

    // System Audio card layout parameters
    static let systemAudioContentVerticalNudge: CGFloat = -32
    static let systemAudioFeatureControlsTopPadding: CGFloat = 24
    static let systemAudioFeatureControlsBottomPadding: CGFloat = -8
    static let systemAudioFeatureControlsLeadingNudge: CGFloat = 24
    static let systemAudioCardHeaderYOffset: CGFloat = 0
    static let systemAudioCardHeaderSubtitleYOffset: CGFloat = -18
    static let systemAudioChannelHeaderYOffset: CGFloat = 32
    static let systemAudioChannelHeaderYOffsetCPU: CGFloat = 32
    static let systemAudioCapsuleYOffset: CGFloat = -14
    static let systemAudioTickMarkYOffset: CGFloat = 0
    static let systemAudioTickMarkYOffsetCPU: CGFloat = 0
    static let systemAudioCardVerticalOffset: CGFloat = -15

    // Tick mark Y offsets for metering groups
    static let inputTickMarkYOffset: CGFloat = 0
    static let inputTickMarkYOffsetCPU: CGFloat = 0
    static let outputTickMarkYOffset: CGFloat = -12
    static let outputTickMarkYOffsetCPU: CGFloat = -12
    static let viTickMarkYOffset: CGFloat = 0
    static let viTickMarkYOffsetCPU: CGFloat = 0

    // Card header Y offsets for metering cards
    static let inputCardHeaderYOffset: CGFloat = 0
    static let inputCardHeaderSubtitleYOffset: CGFloat = -18
    static let outputCardHeaderYOffset: CGFloat = 18
    static let outputCardHeaderSubtitleYOffset: CGFloat = 18
    static let viCardHeaderYOffset: CGFloat = 0
    static let viCardHeaderSubtitleYOffset: CGFloat = -18

    static let inputChannelHeaderYOffset: CGFloat = 32
    static let inputChannelHeaderYOffsetCPU: CGFloat = 32
    static let inputCapsuleYOffset: CGFloat = -14
    static let outputChannelHeaderYOffset: CGFloat = 32
    static let outputChannelHeaderYOffsetCPU: CGFloat = 32
    static let outputCapsuleYOffset: CGFloat = -14
    static let outputFeatureControlsTopPadding: CGFloat = 24
    static let outputFeatureControlsBottomPadding: CGFloat = -80
    static let outputFeatureControlsLeadingNudge: CGFloat = 2
    static let outputFeatureControlsYOffset: CGFloat = 0
    static let outputSpectrumIconYOffset: CGFloat = 4
    static let outputSpectrogramIconYOffset: CGFloat = 4
    static let outputWaveformIconYOffset: CGFloat = 4
    static let outputContentVerticalNudge: CGFloat = 42

    // VI metering capsule Y offset
    static let viCapsuleYOffset: CGFloat = -48

    // Output metering card spacing
    static let outputCardSpacing: CGFloat = 38

    // Capsule dimensions for system audio metering
    static let capsuleWidth: CGFloat = 12.8
    static let capsuleHeight: CGFloat = 280
}

func meteringCardHeader(
    title: String,
    subtitle: String,
    subtitleLineLimit: Int = 1,
    headerYOffset: CGFloat = MeteringCardLayout.headerYOffset,
    headerSubtitleYOffset: CGFloat = MeteringCardLayout.headerSubtitleYOffset
) -> some View {
    VStack(spacing: MeteringCardLayout.headerOuterSpacing) {
        VStack(alignment: .center, spacing: MeteringCardLayout.headerInnerSpacing) {
            Text(title)
                .font(.caption)
                .bold()
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(subtitleLineLimit)
                .offset(y: headerSubtitleYOffset)
        }
        .offset(y: headerYOffset)
        .padding(.vertical, MeteringCardLayout.headerVerticalPadding)
        .frame(maxWidth: MeteringCardLayout.headerMaxWidth, alignment: .center)
    }
}

func meteringCardWidth(forVisibleChannelCount visibleCount: Int) -> CGFloat {
    let channelCount = max(1, visibleCount)
    let axisWidth: CGFloat = 26
    let axisToMeterSpacing: CGFloat = 4.5
    let meterWidth: CGFloat = 12.8
    let meterSpacing: CGFloat = 4

    let meterBodyWidth = axisWidth
        + axisToMeterSpacing
        + CGFloat(channelCount) * meterWidth
        + CGFloat(max(0, channelCount - 1)) * meterSpacing

    return max(96, meterBodyWidth + 24)
}

/// Displays a vertical group of capsule meters and dB labels for a set of input channels.
/// - Parameters:
///   - deviceID: The unique identifier of the audio input device.
///   - channelIndices: An array of channel indices to visualize.
struct ChannelMeteringGroupView: View {
    let deviceID: AudioDeviceID
    let channelIndices: [Int]
    var showsPerChannelFeatureIcons: Bool = true
    var showsPerChannelLevelTexts: Bool = true
    var channelHeaderYOffset: CGFloat = 42
    var channelHeaderYOffsetCPU: CGFloat = 42
    var capsuleYOffset: CGFloat = 0
    var tickMarkYOffset: CGFloat = 0
    var tickMarkYOffsetCPU: CGFloat = 0

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var manager: AudioDeviceManager
    @ObservedObject private var settings = VisualisationSettings.shared

    var body: some View {
        let isCPUBackend = RenderBackendResolver.resolveMeterBackend() == .cpu
        let effectiveTickMarkYOffset = isCPUBackend ? tickMarkYOffsetCPU : tickMarkYOffset
        HStack(alignment: .bottom, spacing: 4.5) {
            // dB labels as a dictionary for mapping dB values to offsets and label positions
            let yAxisLabels: [Float: (label: String, position: CGFloat)] = [
                0:    ("0",    0.01),
                -3:   ("-3",   0.05),
                -6:   ("-6",   0.10),
                -9:   ("-9",   0.19),
                -12:  ("-12",  0.28),
                -15:  ("-15",  0.37),
                -18:  ("-18",  0.44),
                -21:  ("-21",  0.51),
                -24:  ("-24",  0.58),
                -30:  ("-30",  0.68),
                -36:  ("-36",  0.76),
                -40:  ("-40",  0.81),
                -50:  ("-50",  0.89),
                -60:  ("-60",  0.92),
                -100:  ("-∞",  0.96)
            ]
            ZStack(alignment: .topTrailing) {
                GeometryReader { geo in
                    ForEach(yAxisLabels.keys.sorted(by: >), id: \.self) { db in
                        if let label = yAxisLabels[db] {
                            Text(label.label)
                                .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                                .foregroundColor(.secondary)
                                .position(
                                    x: geo.size.width - 12,
                                    y: geo.size.height * label.position + effectiveTickMarkYOffset
                                )
                        }
                    }
                }
            }
            .frame(width: 26, height: 270)

            if let context = manager.activeDevices[deviceID] {
                let mask = manager.selectedChannelMasks[deviceID] ?? Array(repeating: true, count: Int(context.device.inputChannels))
                let visibleIndices = channelIndices.filter { index in
                    mask.indices.contains(index) && mask[index]
                }

                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(visibleIndices.enumerated()), id: \.offset) { _, index in
                        MetalCapsuleWithText(
                            context: context,
                            channelIndex: index,
                            showsFeatureIcons: showsPerChannelFeatureIcons,
                            showsLevelTexts: showsPerChannelLevelTexts,
                            channelHeaderYOffset: channelHeaderYOffset,
                            channelHeaderYOffsetCPU: channelHeaderYOffsetCPU,
                            capsuleYOffset: capsuleYOffset
                        )
                            .environmentObject(themeManager)
                            .frame(width: 12.8, height: 280)
                    }
                }
            } else {
                // Context not yet ready, show placeholder
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(channelIndices.enumerated()), id: \.offset) { _, _ in
                        ThemeRoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 12.8, height: 280)
                    }
                }
            }
        }
        .offset(x: -6.4, y: 2.4)
    }
}


/// The main SwiftUI content view for AVCMeter.
///
/// Displays the device list, theme controls, and live metering UI.
/// This view observes device updates and controls stream activation.
struct ContentView: View {
    @EnvironmentObject var manager: AudioDeviceManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var bridgeManager: AudioBridgeManager
    @EnvironmentObject var outputManager: OutputDeviceManager
    @EnvironmentObject var matrixManager: AudioRoutingMatrixManager
    @EnvironmentObject var midiManager: MIDIStateManager
    @Environment(\.colorScheme) private var colorScheme

    // Palette Popover
    @State var showPalettePopover = false
    @State var showKeyboardPopover = false
    @State var showMIDICCControlPopover = false

    // Demo ChannelPickerView state
    @State private var channels: [Channel] = [
        Channel(name: "Mic 1", index: 0, isSelected: true),
        Channel(name: "Mic 2", index: 1, isSelected: false),
        Channel(name: "Mic 3", index: 2, isSelected: true)
    ]
    @State private var selectedDeviceID: AudioDeviceID = 0
    @ObservedObject private var streamManager = MultiDeviceStreamManager.shared
    @ObservedObject private var virtualChannelManager = VirtualChannelManager.shared
    @State private var selectedDeviceForPopover: AudioDeviceID? = nil
    @State private var selectedVirtualInstrumentPopoverIndex: Int? = nil
    @State private var visibleVirtualInstrumentMeterIndices: Set<Int> = []
    @State var showMixerPopover = false
    @State var showVisualisationSettings = false

    private let virtualInstrumentDeviceID: AudioDeviceID = 999_999
    private let virtualInstrumentChannelCount = 8

    private var panelBackgroundFill: Color {
        colorScheme == .light ? Color.black.opacity(0.12) : Color.black.opacity(0.5)
    }

    var body: some View {
        let embeddedTopContentPadding: CGFloat = themeManager.isEmbeddedInHost ? 70 : 0

        ZStack {
            if themeManager.isEmbeddedInHost == false {
                if themeManager.currentThemeMode == .liquidGlass {
                    LiquidGlassBackground()
                        .edgesIgnoringSafeArea(.all)
                } else if themeManager.currentThemeMode == .thinMaterial {
                    VisualEffectView(material: .sidebar)
                        .edgesIgnoringSafeArea(.all)
                        .environmentObject(themeManager)
                } else if themeManager.currentThemeMode == .poorMansGlass {
                    PoorMansGlassBackground(
                        style: .panel,
                        cornerRadius: 0,
                        reduceBlur: false,
                        tuning: PoorMansGlassTuning(
                            intensity: 0.15,
                            haze: 0.2,
                            highlight: 0.4,
                            chroma: 0.3,
                            rim: 0.4
                        ),
                        themeMode: themeManager.currentThemeMode
                    )
                    .edgesIgnoringSafeArea(.all)
                }
            }

            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 32) {
                    VStack(spacing: 18) {
                        // Global Toolbar row
                        HStack {
                            GlassToolbarPill {
                                HStack(spacing: 0) {
                                    Button { showPalettePopover = true } label: {
                                        Image(systemName: "paintpalette.fill")
                                            .font(.system(size: 14))
                                            .foregroundColor(.primary.opacity(0.8))
                                            .frame(width: 30, height: 30)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Theme Settings")
                                    .popover(isPresented: $showPalettePopover) {
                                        VStack(alignment: .leading, spacing: 12) {
                                            Text("Theme Settings")
                                                .font(.headline)
                                            Picker("App Theme", selection: $themeManager.currentThemeMode) {
                                                Text("Light").tag(ThemeMode.light)
                                                Text("Dark").tag(ThemeMode.dark)
                                                Text("Thin Material").tag(ThemeMode.thinMaterial)
                                                Text("Liquid Glass").tag(ThemeMode.liquidGlass)
                                                Text("Liquid Glass (Legacy)").tag(ThemeMode.poorMansGlass)
                                            }
                                            Picker("Tile Color", selection: $themeManager.accentColor) {
                                                ForEach(themeManager.accentColors, id: \.self) { color in
                                                    HStack {
                                                        Circle()
                                                            .fill(Color(color))
                                                            .frame(width: 12, height: 12)
                                                        Text(themeManager.accentColorLabel(for: color))
                                                    }
                                                    .tag(color)
                                                }
                                            }
                                        }
                                        .padding()
                                        .frame(width: 240)
                                    }

                                    GlassToolbarDivider()

                                    Button { showKeyboardPopover.toggle() } label: {
                                        Image(systemName: "pianokeys")
                                            .font(.system(size: 14))
                                            .foregroundColor(showKeyboardPopover ? .green : .primary.opacity(0.8))
                                            .frame(width: 30, height: 30)
                                    }
                                    .buttonStyle(.plain)
                                    .help("On-Screen Keyboard")
                                    .onChange(of: showKeyboardPopover) { newValue in
                                        if newValue {
                                            FloatingWindowController.shared.showPianoKeyboardWindow {
                                                PianoKeyboardView()
                                                    .environmentObject(manager)
                                                    .environmentObject(VirtualChannelManager.shared)
                                                    .environmentObject(midiManager)
                                            }
                                        } else {
                                            FloatingWindowController.shared.closePianoKeyboardWindow()
                                        }
                                    }
                                    .onReceive(NotificationCenter.default.publisher(for: .floatingPianoKeyboardWindowDidClose)) { _ in
                                        showKeyboardPopover = false
                                    }

                                    Button { showMIDICCControlPopover.toggle() } label: {
                                        Image(systemName: "music.note.square.stack.fill")
                                            .font(.system(size: 14))
                                            .foregroundColor(showMIDICCControlPopover ? .green : .primary.opacity(0.8))
                                            .frame(width: 30, height: 30)
                                    }
                                    .buttonStyle(.plain)
                                    .help("MIDI CC Control")
                                    .onChange(of: showMIDICCControlPopover) { newValue in
                                        if newValue {
                                            FloatingWindowController.shared.showMIDICCControlWindow {
                                                MIDICCControlView()
                                                    .environmentObject(manager)
                                                    .environmentObject(VirtualChannelManager.shared)
                                                    .environmentObject(midiManager)
                                                    .environmentObject(themeManager)
                                            }
                                        } else {
                                            FloatingWindowController.shared.closeMIDICCControlWindow()
                                        }
                                    }
                                    .onReceive(NotificationCenter.default.publisher(for: .floatingMIDICCControlWindowDidClose)) { _ in
                                        showMIDICCControlPopover = false
                                    }

                                    Button {
                                        if FloatingWindowController.shared.routingWindow == nil {
                                            updateRoutingMatrixMappings()
                                            FloatingWindowController.shared.showRoutingWindow {
                                                AudioRoutingMatrixView(manager: matrixManager)
                                            }
                                        } else {
                                            FloatingWindowController.shared.closeRoutingWindow()
                                        }
                                    } label: {
                                        Image(systemName: "square.grid.3x3.fill")
                                            .font(.system(size: 14))
                                            .foregroundColor(.primary.opacity(0.8))
                                            .frame(width: 30, height: 30)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open Routing Matrix")

                                    GlassToolbarDivider()

                                    Button {
                                        FloatingWindowController.shared.showGlobalChannelWindow {
                                            GlobalChannelIDView()
                                        }
                                    } label: {
                                        Image(systemName: "list.bullet.rectangle")
                                            .font(.system(size: 14))
                                            .foregroundColor(.primary.opacity(0.8))
                                            .frame(width: 30, height: 30)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Show Global Channel Log")

                                    GlassToolbarDivider()

                                    Button { showMixerPopover.toggle() } label: {
                                        Image(systemName: "slider.horizontal.3")
                                            .font(.system(size: 14))
                                            .foregroundColor(.primary.opacity(0.8))
                                            .frame(width: 30, height: 30)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open Mixer")
                                    .popover(isPresented: $showMixerPopover) {
                                        VStack(alignment: .leading) {
                                            Toggle("Input Mixer", isOn: Binding(
                                                get: { FloatingWindowController.shared.mixerWindow != nil },
                                                set: { isOn in
                                                    if isOn {
                                                        FloatingWindowController.shared.showMixerWindow {
                                                            MixerWindowView()
                                                                .environmentObject(manager)
                                                                .environmentObject(themeManager)
                                                                .environmentObject(ChannelStateManager.shared)
                                                                .environmentObject(VirtualChannelManager.shared)
                                                        }
                                                    } else {
                                                        FloatingWindowController.shared.closeMixerWindow()
                                                    }
                                                }
                                            ))
                                            Toggle("Output Mixer", isOn: Binding(
                                                get: { FloatingWindowController.shared.outputMixerWindow != nil },
                                                set: { isOn in
                                                    if isOn {
                                                        FloatingWindowController.shared.showOutputMixerWindow(themeManager: themeManager) {
                                                            OutputMixerWindowView()
                                                                .environmentObject(OutputDeviceManager.shared)
                                                                .environmentObject(themeManager)
                                                                .environmentObject(ChannelStateManager.shared)
                                                                .environmentObject(VirtualChannelManager.shared)
                                                        }
                                                    } else {
                                                        FloatingWindowController.shared.closeOutputMixerWindow()
                                                    }
                                                }
                                            ))
                                            Toggle("Aux/FX Returns", isOn: Binding(
                                                get: { FloatingWindowController.shared.returnMixerWindow != nil },
                                                set: { isOn in
                                                    if isOn {
                                                        FloatingWindowController.shared.showReturnMixerWindow {
                                                            AuxFXReturnsMixerWindowView()
                                                                .environmentObject(manager)
                                                                .environmentObject(themeManager)
                                                                .environmentObject(ChannelStateManager.shared)
                                                                .environmentObject(VirtualChannelManager.shared)
                                                        }
                                                    } else {
                                                        FloatingWindowController.shared.closeReturnMixerWindow()
                                                    }
                                                }
                                            ))
                                            Toggle("Sends Mixer", isOn: Binding(
                                                get: { FloatingWindowController.shared.sendsMixerWindow != nil },
                                                set: { isOn in
                                                    if isOn {
                                                        FloatingWindowController.shared.showSendsMixerWindow {
                                                            SendsMixerWindowView()
                                                                .environmentObject(manager)
                                                                .environmentObject(themeManager)
                                                                .environmentObject(ChannelStateManager.shared)
                                                                .environmentObject(VirtualChannelManager.shared)
                                                        }
                                                    } else {
                                                        FloatingWindowController.shared.closeSendsMixerWindow()
                                                    }
                                                }
                                            ))
                                            Divider()
                                                .padding(.vertical, 4)
                                            Toggle("Virtual Instrument Mixer", isOn: Binding(
                                                get: { FloatingWindowController.shared.virtualInstrumentMixerWindow != nil },
                                                set: { isOn in
                                                    if isOn {
                                                        FloatingWindowController.shared.showVirtualInstrumentMixerWindow {
                                                            VirtualInstrumentMixerWindowView()
                                                                .environmentObject(manager)
                                                                .environmentObject(themeManager)
                                                                .environmentObject(ChannelStateManager.shared)
                                                                .environmentObject(VirtualChannelManager.shared)
                                                        }
                                                    } else {
                                                        FloatingWindowController.shared.closeVirtualInstrumentMixerWindow()
                                                    }
                                                }
                                            ))
                                            Toggle("DCA Mixer", isOn: Binding(
                                                get: { FloatingWindowController.shared.dcaMixerWindow != nil },
                                                set: { isOn in
                                                    if isOn {
                                                        FloatingWindowController.shared.showDCAMixerWindow {
                                                            DCAMixerWindowView()
                                                                .environmentObject(themeManager)
                                                                .environmentObject(ChannelStateManager.shared)
                                                                .environmentObject(VirtualChannelManager.shared)
                                                        }
                                                    } else {
                                                        FloatingWindowController.shared.closeDCAMixerWindow()
                                                    }
                                                }
                                            ))
                                            Toggle("All Mixers", isOn: Binding(
                                                get: { FloatingWindowController.shared.allMixersWindow != nil },
                                                set: { isOn in
                                                    if isOn {
                                                        FloatingWindowController.shared.showAllMixersWindow {
                                                            AllMixersWindowView()
                                                                .environmentObject(manager)
                                                                .environmentObject(outputManager)
                                                                .environmentObject(themeManager)
                                                                .environmentObject(ChannelStateManager.shared)
                                                                .environmentObject(VirtualChannelManager.shared)
                                                        }
                                                    } else {
                                                        FloatingWindowController.shared.closeAllMixersWindow()
                                                    }
                                                }
                                            ))
                                        }
                                        .padding()
                                        .frame(width: 220)
                                    }

                                    GlassToolbarDivider()

                                    Button { showVisualisationSettings.toggle() } label: {
                                        Image(systemName: "waveform.path.ecg.rectangle")
                                            .font(.system(size: 14))
                                            .foregroundColor(.primary.opacity(0.8))
                                            .frame(width: 30, height: 30)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Visualisation Settings")
                                    .popover(isPresented: $showVisualisationSettings) {
                                        VisualisationSettingsView()
                                    }
                                }
                                .padding(.horizontal, 4)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 2)

                        HStack(alignment: .top, spacing: 32) {
                            // Input device list — far left
                            VStack(alignment: .center, spacing: 12) {
                                HStack(spacing: 8) {
                                    GlassToolbarPill {
                                        Text("Audio Input Devices")
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                    }
                                    Spacer()
                                    GlassToolbarPill {
                                        Button {
                                            manager.refreshDeviceList()
                                        } label: {
                                            Image(systemName: "arrow.clockwise.circle.fill")
                                                .font(.system(size: 14))
                                                .foregroundColor(.primary.opacity(0.8))
                                                .frame(width: 30, height: 30)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Refresh device list")
                                    }
                                }

                                VStack(spacing: 14) {
                                    deviceListView()
                                    virtualInstrumentListView()
                                    midiDeviceListView()
                                }
                                .padding(.bottom, 8)

                                Spacer()
                            }
                            .frame(minWidth: 300, maxWidth: 400)

                            // Output device list — center
                            VStack(alignment: .center, spacing: 12) {
                                HStack(spacing: 8) {
                                    GlassToolbarPill {
                                        Text("Audio Output Devices")
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                    }
                                    Spacer()
                                    GlassToolbarPill {
                                        Button {
                                            outputManager.refreshOutputDeviceList()
                                        } label: {
                                            Image(systemName: "arrow.clockwise.circle.fill")
                                                .font(.system(size: 14))
                                                .foregroundColor(.primary.opacity(0.8))
                                                .frame(width: 30, height: 30)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Refresh output devices")
                                    }
                                }

                                outputDeviceListView()
                                systemAudioListView()
                                audioServerPluginListView()
                                UtilityListView()
                                Spacer()
                            }
                            .frame(minWidth: 300, maxWidth: 400)
                        }
                    }
                    .padding(.top, embeddedTopContentPadding)
                    .padding(16)
                    .background(
                        ThemeRoundedRectangle(cornerRadius: 24, style: .continuous).themed(fill: panelBackgroundFill)
                    )

                    // Metering — far right
                    VStack(spacing: 24) {
                        ScrollView(.horizontal) {
                            HStack {
                                Spacer()
                                meteringView()
                            }
                        }

                        if !outputManager.activeOutputDevices.isEmpty || SystemAudioCaptureManager.shared.isCapturing {
                            ScrollView(.horizontal) {
                                HStack {
                                    Spacer()
                                    outputMeteringView()
                                }
                            }
                        }
                    }
                    .padding(.top, embeddedTopContentPadding)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            .ignoresSafeArea()
            .onAppear {
                manager.refreshDeviceList() /// Refreshes Input Devices on Launch
                outputManager.refreshOutputDeviceList() /// Refreshes Output Devices on Launch
                for device in manager.inputDevices {
                    ChannelStateManager.shared.initializeLinkedPairsIfNeeded(for: device.deviceID, channelCount: Int(device.inputChannels))
                }
                for device in manager.inputDevices {
                    for channel in 0..<Int(device.inputChannels) {
                        let key = "\(device.deviceID)-\(channel)"
                        if ChannelStateManager.shared.channelStates[key] == nil {
                            ChannelStateManager.shared.channelStates[key] = ChannelStripState(id: key)
                        }
                    }
                }
                // Nudge pan values immediately after channel states are initialized
                ChannelStateManager.shared.nudgeAllPanValues()

                themeManager.updateWindowForCurrentTheme()
                VirtualInstrumentHostManager.shared.start(
                    deviceID: virtualInstrumentDeviceID,
                    channelCount: virtualInstrumentChannelCount,
                    sampleRate: manager.activeDevices[virtualInstrumentDeviceID]?.device.sampleRate ?? 48_000
                )
            }
        }
        .onChange(of: manager.inputDevices.count) { _ in
            if FloatingWindowController.shared.routingWindow != nil {
                updateRoutingMatrixMappings()
            }
        }
        .onChange(of: themeManager.currentThemeMode) { _ in
            themeManager.updateWindowForCurrentTheme()
        }
        // Floating window show logic moved out for now (see issue re: Binding vs method call)
        /*
        DispatchQueue.main.async {
            if manager.isMetering {
                FloatingWindowController.shared.showMixerWindow {
                    MixerWindowView()
                        .environmentObject(manager)
                        .environmentObject(themeManager)
                }
            }
        }
        */
    }
}

struct DeviceMeterLevels {
    let peakLevels: [Float]
    let rmsLevels: [Float]
}

/// A grouped list of `MeteringDeviceView` tiles for all active audio devices.
/// - Parameter contexts: An array of `DeviceMeteringContext` entries representing each device.
struct MeteringDeviceList: View {
    let contexts: [DeviceMeteringContext]
    var body: some View {
        ForEach(contexts, id: \.device.deviceID) { context in
            MeteringDeviceView(context: context)
        }
    }
}


// MARK: - Input Metering Card (reusable standalone card for floating windows)
private struct InputMeteringCard: View {
    let deviceID: AudioDeviceID
    @EnvironmentObject var manager: AudioDeviceManager
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let mask = manager.selectedChannelMasks[deviceID] ?? []
        let visibleIndices = mask.enumerated().compactMap { $0.element ? $0.offset : nil }
        let grouped = stride(from: 0, to: visibleIndices.count, by: 64).map {
            Array(visibleIndices[$0..<min($0 + 64, visibleIndices.count)])
        }
        let widestGroupCount = grouped.map(\.count).max() ?? 1
        let cardWidth = meteringCardWidth(forVisibleChannelCount: widestGroupCount)
        ZStack(alignment: .trailing) {
            ThemeRoundedRectangle(cornerRadius: MeteringCardLayout.cardCornerRadius, style: .continuous).themed(fill: themeManager.accentFillColor)

            VStack(alignment: .center, spacing: MeteringCardLayout.cardContentSpacing) {
                if let context = manager.activeDevices[deviceID] {
                    let device = context.device
                    meteringCardHeader(
                        title: "\(device.name):",
                        subtitle: "Inputs: 1 - \(device.inputChannels)",
                        headerYOffset: MeteringCardLayout.inputCardHeaderYOffset,
                        headerSubtitleYOffset: MeteringCardLayout.inputCardHeaderSubtitleYOffset
                    )
                }
                ForEach(grouped, id: \.self) { group in
                    ChannelMeteringGroupView(
                        deviceID: deviceID,
                        channelIndices: group,
                        channelHeaderYOffset: MeteringCardLayout.inputChannelHeaderYOffset,
                        channelHeaderYOffsetCPU: MeteringCardLayout.inputChannelHeaderYOffsetCPU,
                        capsuleYOffset: MeteringCardLayout.inputCapsuleYOffset,
                        tickMarkYOffset: MeteringCardLayout.inputTickMarkYOffset,
                        tickMarkYOffsetCPU: MeteringCardLayout.inputTickMarkYOffsetCPU
                    )
                }
            }
            .padding(MeteringCardLayout.cardContentPadding)
            .offset(y: MeteringCardLayout.cardContentOffsetY)
        }
        .frame(width: cardWidth, height: MeteringCardLayout.cardHeight)
    }
}

private struct VirtualInstrumentMeteringCard: View {
    let deviceID: AudioDeviceID
    let viIndex: Int
    let defaultChannelCount: Int
    let virtualInstrumentCount: Int

    @EnvironmentObject var manager: AudioDeviceManager
    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject private var virtualChannelManager = VirtualChannelManager.shared
    @ObservedObject private var settings = VisualisationSettings.shared

    @State private var heldPeakValue: Float = -100.0
    @State private var formattedPeakDbText: String = "−∞"
    @State private var formattedRmsDbText: String = "−∞"
    @State private var showSpectrum: Bool = false
    @State private var showSpectrogram: Bool = false
    @State private var showWaveform: Bool = false
    @State private var spectrogramFeed: VirtualInstrumentSpectrogramFeed?
    @StateObject private var waveformBuffer = AudioSampleBuffer()
    private let floatingWindowController = FloatingWindowController.shared
    @State private var showVISelectionPopover: Bool = false

    var body: some View {
        let activeContext = manager.activeDevices[deviceID]
        let channelCount = max(0, activeContext.map { Int($0.device.inputChannels) } ?? defaultChannelCount)
        let meterIndices = meterChannelIndices(channelCount: channelCount)
        guard !meterIndices.isEmpty else {
            return AnyView(EmptyView())
        }
        let primaryChannelIndex = meterIndices[0]

        let instrumentName = virtualChannelManager.selectedVirtualInstrumentDisplayName(for: deviceID, channelIndex: viIndex) ?? "Empty"
        let cardWidth = meteringCardWidth(forVisibleChannelCount: meterIndices.count)

        return AnyView(
            ZStack(alignment: .bottomTrailing) {
                ThemeRoundedRectangle(cornerRadius: MeteringCardLayout.cardCornerRadius, style: .continuous).themed(fill: themeManager.accentFillColor)

                VStack(alignment: .center, spacing: MeteringCardLayout.cardContentSpacing) {
                    meteringCardHeader(
                        title: "VI \(viIndex + 1):",
                        subtitle: instrumentName,
                        headerYOffset: MeteringCardLayout.viCardHeaderYOffset,
                        headerSubtitleYOffset: MeteringCardLayout.viCardHeaderSubtitleYOffset
                    )

                    ChannelMeteringGroupView(
                        deviceID: deviceID,
                        channelIndices: meterIndices,
                        showsPerChannelFeatureIcons: false,
                        showsPerChannelLevelTexts: false,
                        channelHeaderYOffset: MeteringCardLayout.viChannelHeaderYOffset,
                        channelHeaderYOffsetCPU: MeteringCardLayout.viChannelHeaderYOffset,
                        capsuleYOffset: MeteringCardLayout.viCapsuleYOffset,
                        tickMarkYOffset: MeteringCardLayout.viTickMarkYOffset,
                        tickMarkYOffsetCPU: MeteringCardLayout.viTickMarkYOffsetCPU
                    )
                }
                .padding(MeteringCardLayout.cardContentPadding)
                .offset(y: MeteringCardLayout.cardContentOffsetY + MeteringCardLayout.viContentVerticalNudge)

                VStack {
                    Spacer(minLength: 0)
                    virtualInstrumentFeatureControls(
                        channelIndex: primaryChannelIndex,
                        channelCount: max(channelCount, defaultChannelCount),
                        instrumentName: instrumentName
                    )
                    .padding(.top, MeteringCardLayout.viFeatureControlsTopPadding)
                    .padding(.bottom, MeteringCardLayout.viFeatureControlsBottomPadding)
                    .offset(x: MeteringCardLayout.viFeatureControlsLeadingNudge)
                }
                .offset(y: MeteringCardLayout.viContentVerticalNudge)
            }
            .frame(width: cardWidth, height: MeteringCardLayout.cardHeight)
            .onAppear {
                MeterUpdateCoordinator.shared.start()
                refreshPeakDisplay(channelIndex: primaryChannelIndex)
            }
            .onReceive(MeterUpdateCoordinator.shared.publisher) { _ in
                refreshPeakDisplay(channelIndex: primaryChannelIndex)
            }
            .onReceive(NotificationCenter.default.publisher(for: .floatingSpectrumWindowDidClose)) { notification in
                if notification.matchesFloatingWindow(deviceID: deviceID, channelIndex: primaryChannelIndex, suffix: "spectrum") {
                    showSpectrum = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .floatingWaveformWindowDidClose)) { notification in
                if notification.matchesFloatingWindow(deviceID: deviceID, channelIndex: primaryChannelIndex, suffix: "waveform") {
                    showWaveform = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .floatingSpectrogramWindowDidClose)) { notification in
                if notification.matchesFloatingWindow(deviceID: deviceID, channelIndex: primaryChannelIndex, suffix: "spectrogram") {
                    showSpectrogram = false
                    spectrogramFeed?.stop()
                    spectrogramFeed = nil
                }
            }
        )
    }

    @ViewBuilder
    private func virtualInstrumentFeatureControls(channelIndex: Int, channelCount: Int, instrumentName: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                heldPeakValue = -100.0
                formattedPeakDbText = "−∞"
                formattedRmsDbText = "−∞"
                refreshPeakDisplay(channelIndex: channelIndex)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(formattedPeakDbText)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(formattedRmsDbText)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundColor(.secondary)
                }
                .frame(width: 20, alignment: .leading)
                .foregroundColor(peakColor(for: heldPeakValue))
            }
            .buttonStyle(.plain)
            .help("Reset held peak dB")

            VStack(spacing: 5) {
                Button {
                    showVISelectionPopover = true
                } label: {
                    Image(systemName: "music.note")
                        .font(.system(size: 9, weight: .medium, design: .default))
                        .foregroundColor(iconColor(isOn: showVISelectionPopover))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showVISelectionPopover) {
                    viInstrumentSelectionPopover
                }
                .help("Virtual Instrument Settings")

                Button {
                    toggleSpectrum(channelIndex: channelIndex, channelCount: channelCount)
                } label: {
                    Image(systemName: "waveform")
                        .font(.system(size: 9, weight: .medium, design: .default))
                        .foregroundColor(iconColor(isOn: showSpectrum))
                }
                .buttonStyle(.plain)
                .help(showSpectrum ? "Close FFT Spectrum" : "Open FFT Spectrum")

                Button {
                    toggleSpectrogram(channelIndex: channelIndex, channelCount: channelCount)
                } label: {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.system(size: 9, weight: .medium, design: .default))
                        .foregroundColor(iconColor(isOn: showSpectrogram))
                }
                .buttonStyle(.plain)
                .help(showSpectrogram ? "Close Spectrogram" : "Open Spectrogram")

                Button {
                    toggleWaveform(channelIndex: channelIndex, instrumentName: instrumentName)
                } label: {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 9, weight: .medium, design: .default))
                        .foregroundColor(iconColor(isOn: showWaveform))
                }
                .buttonStyle(.plain)
                .help(showWaveform ? "Close Waveform" : "Open Waveform")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleSpectrum(channelIndex: Int, channelCount: Int) {
        showSpectrum.toggle()
        let scale = themeManager.deviceSpectrumScaleFactors[deviceID] ?? 1.0

        if showSpectrum {
            let fftSize = settings.spectrumFFTSize
            let source = VirtualInstrumentPreFaderAudioSource(
                deviceID: deviceID,
                channelIndex: channelIndex
            )
            let processor = SafeFFTSpectrumProcessor(
                streamManager: source,
                channelIndex: channelIndex,
                channelCount: max(1, channelCount),
                fftSize: fftSize
            )
            processor.start()

            let pickedTheme = themeManager.deviceCapsuleThemes[deviceID] ?? themeManager.capsuleThemeMode
            floatingWindowController.showSpectrumWindow(
                deviceID: deviceID,
                channelIndex: channelIndex,
                scale: scale
            ) {
                SpectrumContainer(
                    processor: processor,
                    themeMode: pickedTheme,
                    scale: scale
                )
                .environmentObject(themeManager)
                .frame(width: 750 * scale, height: 380 * scale)
                .background(Color.clear)
            }
        } else {
            floatingWindowController.closeSpectrumWindow(for: deviceID, channelIndex: channelIndex)
        }
    }

    private func toggleSpectrogram(channelIndex: Int, channelCount: Int) {
        showSpectrogram.toggle()
        if showSpectrogram {
            let pickedTheme = themeManager.deviceCapsuleThemes[deviceID] ?? themeManager.capsuleThemeMode
            let simdTheme = simdColor(from: spectrumLineColor(for: SpectrumThemeMode(from: pickedTheme)))
            let uDeviceID = UInt32(deviceID)

            guard SpectroManager.shared.acquireExternalSpectrogramSession(
                deviceID: uDeviceID,
                channelCount: UInt32(max(1, channelCount)),
                channel: Int32(channelIndex)
            ) else {
                showSpectrogram = false
                return
            }

            let source = VirtualInstrumentPreFaderAudioSource(deviceID: deviceID, channelIndex: channelIndex)
            let feed = VirtualInstrumentSpectrogramFeed(
                source: source,
                deviceID: Int32(deviceID),
                channelIndex: Int32(channelIndex)
            )
            feed.start()
            spectrogramFeed = feed

            let scale = themeManager.deviceSpectrumScaleFactors[deviceID] ?? 1.0
            floatingWindowController.showSpectrogramWindow(
                deviceID: deviceID,
                channelIndex: channelIndex,
                scale: scale
            ) {
                SpectroBackendView(
                    deviceID: Int32(deviceID),
                    channelIndex: Int32(channelIndex),
                    fftSize: 512,
                    themeColor: simdTheme,
                    themeMode: Int32(pickedTheme.rawValue),
                    deviceName: "VI \(viIndex + 1)",
                    scale: scale
                )
                .environmentObject(themeManager)
                .frame(width: 750 * scale, height: 380 * scale)
                .background(Color.clear)
            }
        } else {
            spectrogramFeed?.stop()
            floatingWindowController.closeSpectrogramWindow(for: deviceID, channelIndex: channelIndex)
        }
    }

    private var viInstrumentSelectionPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Select Virtual Instrument")
                    .font(.headline)
                Spacer()
                Button {
                    virtualChannelManager.refreshAvailableVirtualInstruments()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Refresh installed Audio Units")
            }

            if virtualChannelManager.availableVirtualInstruments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No Audio Unit instruments found.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("Install an AU Music Device and refresh this list.")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(virtualChannelManager.availableVirtualInstruments) { instrument in
                            let selectedID = virtualChannelManager.selectedVirtualInstrumentID(
                                for: deviceID,
                                channelIndex: viIndex
                            )
                            let isSelected = selectedID == instrument.id

                            Button {
                                virtualChannelManager.selectVirtualInstrument(
                                    instrument,
                                    for: deviceID,
                                    channelIndex: viIndex
                                )
                                showVISelectionPopover = false
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(isSelected ? Color(red: 0.8, green: 0.4, blue: 1.0) : .secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(instrument.displayName)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)

                                        Text(instrument.manufacturerName)
                                            .font(.system(size: 10, weight: .regular))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    ThemeRoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isSelected ? Color.purple.opacity(0.18) : Color.white.opacity(0.05))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if virtualChannelManager.selectedVirtualInstrumentID(
                for: deviceID,
                channelIndex: viIndex
            ) != nil {
                HStack {
                    Button("Clear Selection") {
                        virtualChannelManager.clearVirtualInstrumentSelection(
                            for: deviceID,
                            channelIndex: viIndex
                        )
                    }
                    .buttonStyle(.plain)

#if os(macOS)
                    Button("Open Plugin UI") {
                        VirtualInstrumentHostManager.shared.showInstrumentEditor(
                            for: deviceID,
                            channelIndex: viIndex
                        )
                        showVISelectionPopover = false
                    }
                    .buttonStyle(.plain)
#endif

                    Spacer()

                    if let selectedName = virtualChannelManager.selectedVirtualInstrumentDisplayName(
                        for: deviceID,
                        channelIndex: viIndex
                    ) {
                        Text("Selected: \(selectedName)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320, height: 340)
        .onAppear {
            virtualChannelManager.refreshAvailableVirtualInstruments()
        }
    }

    private func toggleWaveform(channelIndex: Int, instrumentName: String) {
        showWaveform.toggle()
        let scale = themeManager.deviceSpectrumScaleFactors[deviceID] ?? 1.0

        if showWaveform {
            let source = VirtualInstrumentPreFaderAudioSource(deviceID: deviceID, channelIndex: channelIndex)
            floatingWindowController.showWaveformWindow(
                deviceID: deviceID,
                channelIndex: channelIndex,
                scale: scale
            ) {
                WaveformView(
                    buffer: waveformBuffer,
                    deviceID: deviceID,
                    channelIndex: channelIndex,
                    themeMode: WaveformThemeMode(rawValue: (themeManager.deviceCapsuleThemes[deviceID] ?? themeManager.capsuleThemeMode).rawValue) ?? .light,
                    deviceName: "VI \(viIndex + 1): \(instrumentName)",
                    mixerAudioSource: source,
                    scale: scale
                )
                .frame(width: 750 * scale, height: 180 * scale)
                .background(Color.clear)
            }
        } else {
            floatingWindowController.closeWaveformWindow(for: deviceID, channelIndex: channelIndex)
        }
    }

    private func refreshPeakDisplay(channelIndex: Int) {
        guard let context = manager.activeDevices[deviceID] else {
            formattedPeakDbText = "−∞"
            return
        }

        let rawPeak = context.peakBuffer.mostRecent(for: channelIndex)
        let peakDb = linearToDb(rawPeak)
        if peakDb > heldPeakValue {
            heldPeakValue = peakDb
        }

        let displayDb = heldPeakValue + 4.0
        formattedPeakDbText = displayDb <= -99.5 ? "−∞" : String(format: "%d", Int(displayDb))

        let rms = context.rmsBuffer.mostRecent(for: channelIndex)
        let rmsDb = linearToDb(rms) + 4.0
        formattedRmsDbText = rmsDb <= -99.5 ? "−∞" : String(format: "%d", Int(rmsDb))
    }

    private func linearToDb(_ linear: Float) -> Float {
        linear <= 0.000_01 ? -100.0 : 20.0 * log10(linear)
    }

    private func peakColor(for clampedPeakDb: Float) -> Color {
        if clampedPeakDb >= -6.0 {
            return .red
        } else if clampedPeakDb >= -18.0 {
            return .orange
        } else if clampedPeakDb >= -24.0 {
            return Color(red: 0.4, green: 1.0, blue: 0.4)
        } else if clampedPeakDb >= -40.0 {
            return .green
        } else if clampedPeakDb >= -64.0 {
            return Color(red: 0.1, green: 0.6, blue: 0.1)
        } else {
            return .secondary
        }
    }

    private func iconColor(isOn: Bool) -> Color {
        if isOn {
            return .white
        }
        return waveformIconColor(for: themeManager.deviceCapsuleThemes[deviceID] ?? themeManager.capsuleThemeMode)
    }

    private func waveformIconColor(for theme: ThemeMode) -> Color {
        switch theme {
        case .light:
            return Color(red: 0.2, green: 0.6, blue: 0.2)
        case .dark:
            return Color(red: 0.2, green: 0.6, blue: 1.0)
        case .thinMaterial:
            return Color(red: 0.0, green: 0.6, blue: 0.7)
        case .purple:
            return Color(red: 0.6, green: 0.2, blue: 1.0)
        case .mint:
            return Color(red: 0.62, green: 0.96, blue: 0.78)
        case .lavender:
            return Color.purple.opacity(0.6)
        case .indigo:
            return Color(red: 0.29, green: 0.0, blue: 0.51)
        case .gray:
            return Color.gray
        case .hollow:
            return Color.clear
        case .liquidGlass, .poorMansGlass:
            return Color(red: 0.6, green: 0.9, blue: 1.0)
        }
    }

    private func meterChannelIndices(channelCount: Int) -> [Int] {
        guard viIndex >= 0 else { return [] }

        // If each VI exposes a dedicated stereo pair, use interleaved pairs.
        if channelCount >= virtualInstrumentCount * 2 {
            let left = viIndex * 2
            let right = left + 1
            guard right < channelCount else { return [] }
            return [left, right]
        }

        // Current pipeline fallback: one channel per VI slot, rendered dual-mono for stereo-style display.
        guard viIndex < channelCount else { return [] }
        return [viIndex, viIndex]
    }
}

// MARK: - System Audio Metering Card
private struct SystemAudioMeteringCard: View {
    @EnvironmentObject var manager: AudioDeviceManager
    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject private var systemAudioManager = SystemAudioCaptureManager.shared

    var body: some View {
        let channelCount = systemAudioManager.channelCount
        let sampleRate = systemAudioManager.sampleRate
        let cardWidth = meteringCardWidth(forVisibleChannelCount: min(channelCount, 2))

        ZStack(alignment: .bottomTrailing) {
            ThemeRoundedRectangle(cornerRadius: MeteringCardLayout.cardCornerRadius, style: .continuous).themed(fill: themeManager.accentFillColor)

            VStack(alignment: .center, spacing: MeteringCardLayout.cardContentSpacing) {
                meteringCardHeader(
                    title: "System Audio:",
                    subtitle: "\(channelCount) channels @ \(Int(sampleRate)) Hz",
                    headerYOffset: MeteringCardLayout.systemAudioCardHeaderYOffset,
                    headerSubtitleYOffset: MeteringCardLayout.systemAudioCardHeaderSubtitleYOffset
                )

                ChannelMeteringGroupView(
                    deviceID: systemAudioDeviceID,
                    channelIndices: Array(0..<min(channelCount, 2)),
                    channelHeaderYOffset: MeteringCardLayout.systemAudioChannelHeaderYOffset,
                    channelHeaderYOffsetCPU: MeteringCardLayout.systemAudioChannelHeaderYOffsetCPU,
                    capsuleYOffset: MeteringCardLayout.systemAudioCapsuleYOffset,
                    tickMarkYOffset: MeteringCardLayout.systemAudioTickMarkYOffset,
                    tickMarkYOffsetCPU: MeteringCardLayout.systemAudioTickMarkYOffsetCPU
                )
            }
            .padding(MeteringCardLayout.cardContentPadding)
            .offset(y: MeteringCardLayout.cardContentOffsetY + MeteringCardLayout.systemAudioContentVerticalNudge)
        }
        .frame(width: cardWidth, height: MeteringCardLayout.cardHeight)
    }
}

// MARK: - System Audio SpectroProcessor
final class SystemAudioSpectroProcessor: ObservableObject {
    private let source: SystemAudioSource
    private let deviceID: Int32
    private let channelIndex: Int32
    private let queue = DispatchQueue(label: "com.avcmeter.spectroprocessor.systemaudio", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    // History buffer for spectrogram data
    private var historyBuffer: [[Float]] = []
    private let maxHistoryFrames = 30

    @Published var spectrogramData: [[Float]] = []

    init(source: SystemAudioSource = .shared, deviceID: Int32 = 888_888, channelIndex: Int32 = 0) {
        self.source = source
        self.deviceID = deviceID
        self.channelIndex = channelIndex
    }

    func start() {
        guard timer == nil else { return }
        let newTimer = DispatchSource.makeTimerSource(flags: [], queue: queue)
        newTimer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
        newTimer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = newTimer
        newTimer.resume()
    }

    func stop() {
        if let timer = timer {
            timer.cancel()
            self.timer = nil
        }
    }

    private func tick() {
        let fftSize = VisualisationSettings.shared.spectrumFFTSize
        var samples = [Float](repeating: 0.0, count: fftSize)
        let count = source.read(channel: Int(channelIndex), into: &samples)

        guard count > 0 else { return }

        // Compute FFT
        let fftData = computeFFT(samples: samples, fftSize: fftSize)

        // Ensure history buffer exists for this device/channel
        if SpectroManager.shared.historyRingBuffer(for: deviceID, channel: channelIndex) == nil {
            let numBins = fftData.count
            let numFrames = SpectroManager.spectrogramHistoryFrames
            if let bufHist = SpectroManager.shared.createHistoryRingBuffer(numBins: numBins, numFrames: numFrames) {
                SpectroManager.shared.registerHistoryBuffer(bufHist, for: deviceID, channel: channelIndex)
            }
        }

        // Write to history buffer
        if let historyBuf = SpectroManager.shared.historyRingBuffer(for: deviceID, channel: channelIndex) {
            SpectroManager.shared.writeHistoryFrame(
                historyBuf,
                magnitudes: fftData
            )
        }
    }

    private func computeFFT(samples: [Float], fftSize: Int) -> [Float] {
        // Ensure we have enough samples
        guard samples.count >= fftSize else { return [Float](repeating: 0.0, count: fftSize / 2) }

        // Create FFT setup
        guard let fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(fftSize))), FFTRadix(kFFTRadix2)) else {
            return [Float](repeating: 0.0, count: fftSize / 2)
        }

        // Remove DC offset
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(fftSize))
        var centeredSamples = [Float](repeating: 0.0, count: fftSize)
        vDSP_vsadd(samples, 1, [-mean], &centeredSamples, 1, vDSP_Length(fftSize))

        // Apply input gain reduction (8e-10) to prevent hot FFT magnitudes
        let inputGain: Float = 0.00000008
        vDSP_vsmul(centeredSamples, 1, [inputGain], &centeredSamples, 1, vDSP_Length(fftSize))

        // Apply Hann window
        var windowedSamples = [Float](repeating: 0.0, count: fftSize)
        var hannWindow = [Float](repeating: 0.0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))
        vDSP_vmul(centeredSamples, 1, hannWindow, 1, &windowedSamples, 1, vDSP_Length(fftSize))

        var magnitudes = [Float](repeating: 0.0, count: fftSize / 2)
        var realIn = [Float](repeating: 0.0, count: fftSize / 2)
        var imagIn = [Float](repeating: 0.0, count: fftSize / 2)

        realIn.withUnsafeMutableBufferPointer { realBuffer in
            imagIn.withUnsafeMutableBufferPointer { imagBuffer in
                guard let realBase = realBuffer.baseAddress,
                      let imagBase = imagBuffer.baseAddress else { return }

                var splitComplex = DSPSplitComplex(realp: realBase, imagp: imagBase)

                windowedSamples.withUnsafeBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    baseAddress.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                    }
                }

                // Perform FFT
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, vDSP_Length(log2(Float(fftSize))), FFTDirection(FFT_FORWARD))

                // Compute magnitudes
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        // Track peak magnitude for automatic gain control
        var currentPeak: Float = 0
        vDSP_maxv(magnitudes, 1, &currentPeak, vDSP_Length(fftSize / 2))

        // Use VisualisationSettings for normalization
        let vis = VisualisationSettings.shared
        let scale = 2.0 / Float(fftSize)
        var scaledMagnitudes = [Float](repeating: 0.0, count: fftSize / 2)
        vDSP_vsmul(magnitudes, 1, [scale], &scaledMagnitudes, 1, vDSP_Length(fftSize / 2))

        var dbMagnitudes = [Float](repeating: -200.0, count: fftSize / 2)
        var zero: Float = 1e-10
        vDSP_vdbcon(scaledMagnitudes, 1, &zero, &dbMagnitudes, 1, vDSP_Length(fftSize / 2), 0)

        // Apply gain trim from settings
        if vis.spectrogramGainTrimDB != 0 {
            for i in 0..<dbMagnitudes.count {
                dbMagnitudes[i] += vis.spectrogramGainTrimDB
            }
        }

        // Clamp to [thresholdDB, 0] range and normalize to [0,1]
        let clamped = dbMagnitudes.map { db -> Float in
            let clamped = min(max(db, vis.spectrogramThresholdDB), 0.0)
            return (clamped - vis.spectrogramThresholdDB) / abs(vis.spectrogramThresholdDB)
        }

        // Apply gate and power curve from settings
        let compressed = clamped.map { value -> Float in
            let gated = max(0.0, (value - vis.spectrogramGate) / max(1.0 - vis.spectrogramGate, 0.001))
            return pow(gated, vis.spectrogramPowerCurve)
        }

        vDSP_destroy_fftsetup(fftSetup)
        return compressed
    }
}

// MARK: - System Audio Spectrogram View
struct SystemAudioSpectrogramView: View {
    let deviceID: AudioDeviceID
    let channelIndex: Int
    let themeMode: WaveformThemeMode
    let deviceName: String
    let scale: CGFloat
    let themeColor: SIMD4<Float>

    @StateObject private var processor = SystemAudioSpectroProcessor()

    var body: some View {
        // Use SpectroBackendView which handles both CPU and Metal rendering
        SpectroBackendView(
            deviceID: Int32(deviceID),
            channelIndex: Int32(channelIndex),
            fftSize: 512,
            themeColor: themeColor,
            themeMode: Int32(themeMode.rawValue),
            deviceName: "System Audio",
            scale: scale,
            externalAudioSource: nil
        )
        .onAppear {
            processor.start()
        }
        .onDisappear {
            processor.stop()
        }
    }
}

// MARK: - System Audio Waveform View
struct SystemAudioWaveformView: View {
    let deviceID: AudioDeviceID
    let channelIndex: Int
    let themeMode: WaveformThemeMode
    let deviceName: String
    let scale: CGFloat

    @StateObject private var waveformBuffer = AudioSampleBuffer()
    @ObservedObject private var visualisationSettings = VisualisationSettings.shared
    private let source = SystemAudioSource.shared
    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private let sampleRate = 48_000
    private var maxSamples: Int {
        max(1, visualisationSettings.waveformDurationSeconds) * sampleRate
    }

    var body: some View {
        WaveformView(
            buffer: waveformBuffer,
            deviceID: deviceID,
            channelIndex: channelIndex,
            themeMode: themeMode,
            deviceName: deviceName,
            scale: scale
        )
        .frame(width: 750 * scale, height: 180 * scale)
        .background(Color.clear)
        .onReceive(timer) { _ in
            // Read directly from SystemAudioSource like the FFT Spectrum does
            let expectedFrames = max(256, Int(Float(sampleRate) * Float(1.0 / 30.0) * 1.25))
            var samples = [Float](repeating: 0.0, count: expectedFrames)
            let count = source.read(channel: channelIndex, into: &samples)

            if count > 0 {
                // Maintain rolling history like regular WaveformView
                var history = waveformBuffer.samples
                history.append(contentsOf: samples.prefix(count))
                if history.count > maxSamples {
                    history.removeFirst(history.count - maxSamples)
                }
                waveformBuffer.samples = history

                // Rebuild vertices from samples
                rebuildWaveformVertices(from: waveformBuffer.samples, buffer: waveformBuffer, viewWidth: 750, themeMode: themeMode)
            }
        }
        .onAppear {
            waveformBuffer.samples = Array(repeating: Float(0.0), count: maxSamples)
            waveformBuffer.cachedVertices = []
            waveformBuffer.cachedColors = []
            rebuildWaveformVertices(from: waveformBuffer.samples, buffer: waveformBuffer, viewWidth: 750, themeMode: themeMode)
        }
    }

    private func rebuildWaveformVertices(from samples: [Float], buffer: AudioSampleBuffer, viewWidth: CGFloat, themeMode: WaveformThemeMode) {
        let pixelWidth = max(8, Int(viewWidth.rounded(.down)))
        let sampleCount = samples.count
        let samplesPerPixel = max(1.0, Float(sampleCount) / Float(pixelWidth))
        let verticalScale: Float = 2.2

        let base = waveformLineColor(for: themeMode)
        let nsBase = NSColor(base).usingColorSpace(.deviceRGB) ?? .white
        let baseColor = SIMD4<Float>(
            Float(nsBase.redComponent),
            Float(nsBase.greenComponent),
            Float(nsBase.blueComponent),
            Float(nsBase.alphaComponent)
        )

        var vertices: [SIMD2<Float>] = []
        var colors: [SIMD4<Float>] = []
        vertices.reserveCapacity(pixelWidth * 2)
        colors.reserveCapacity(pixelWidth * 2)

        for px in 0..<pixelWidth {
            let start = min(sampleCount - 1, Int(Float(px) * samplesPerPixel))
            let end = min(sampleCount, max(start + 1, Int(Float(px + 1) * samplesPerPixel)))

            var minY = Float.greatestFiniteMagnitude
            var maxY = -Float.greatestFiniteMagnitude
            for idx in start..<end {
                let y = (samples[idx] * verticalScale).clamped(to: -1.0...1.0)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
            if !minY.isFinite || !maxY.isFinite {
                minY = 0.0
                maxY = 0.0
            }

            let x = (Float(px) / Float(max(pixelWidth - 1, 1))) * 2.0 - 1.0
            vertices.append(SIMD2<Float>(x, minY))
            vertices.append(SIMD2<Float>(x, maxY))

            let magnitude = max(abs(minY), abs(maxY))
            let color = colorVector(for: magnitude, baseColor: baseColor)
            colors.append(color)
            colors.append(color)
        }

        buffer.cachedVertices = vertices
        buffer.cachedColors = colors
    }

    private func colorVector(for magnitude: Float, baseColor: SIMD4<Float>) -> SIMD4<Float> {
        if magnitude >= 1.0 {
            return SIMD4<Float>(1.0, 0.1, 0.1, baseColor.w)
        }
        if magnitude >= 0.85 {
            return SIMD4<Float>(1.0, 0.5, 0.1, baseColor.w)
        }
        return baseColor
    }
}

// MARK: - System Audio Audio Source (for FFT/Waveform)
final class SystemAudioSource: ObservableObject, @unchecked Sendable, WaveformAudioSource, FFTAudioSource {
    static let shared = SystemAudioSource()

    // Cache these values for nonisolated access
    private nonisolated(unsafe) var cachedSampleRate: Double = 48_000
    private nonisolated(unsafe) var cachedChannelCount: Int = 2
    private nonisolated(unsafe) var analysisBufferHandle: OpaquePointer?

    nonisolated var sampleRate: Double {
        cachedSampleRate
    }

    nonisolated var channelCount: Int {
        cachedChannelCount
    }

    nonisolated var deviceID: AudioDeviceID { systemAudioDeviceID }
    nonisolated var name: String { "System Audio" }

    private init() {}

    /// Update cached values from manager (call from main actor when capture starts)
    @MainActor func updateCachedValues() {
        let manager = SystemAudioCaptureManager.shared
        cachedSampleRate = manager.sampleRate
        cachedChannelCount = manager.channelCount
        analysisBufferHandle = manager.analysisBufferHandle
    }

    nonisolated func readSamples(frameCount: Int) -> [Float] {
        // Read interleaved samples and return first channel (for mono spectrum)
        let channels = channelCount
        var buffer = [Float](repeating: 0.0, count: frameCount * channels)
        guard let analysisBufferHandle else { return [] }
        let readCount = buffer.withUnsafeMutableBufferPointer { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else { return 0 }
            return Int(RingBuffer_ReadAllInterleaved(analysisBufferHandle, baseAddress, frameCount))
        }

        guard readCount > 0 else { return [] }

        // Deinterleave and return first channel
        let actualChannels = min(channels, 2)
        let firstChannel = stride(from: 0, to: readCount * actualChannels, by: actualChannels).map { buffer[$0] }
        return firstChannel
    }

    nonisolated func read(channel: Int, into outBuffer: inout [Float]) -> Int {
        let frameCount = outBuffer.count
        let channels = channelCount
        var interleaved = [Float](repeating: 0.0, count: frameCount * channels)
        guard let analysisBufferHandle else { return 0 }
        let readCount = interleaved.withUnsafeMutableBufferPointer { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else { return 0 }
            return Int(RingBuffer_ReadAllInterleaved(analysisBufferHandle, baseAddress, frameCount))
        }

        guard readCount > 0 else { return 0 }

        // Deinterleave to get the requested channel
        let actualChannels = min(channels, 2)
        let channelOffset = min(channel, actualChannels - 1)
        for i in 0..<min(frameCount, readCount) {
            outBuffer[i] = interleaved[i * actualChannels + channelOffset]
        }

        return min(frameCount, readCount)
    }

    nonisolated func stop() throws {
        // No-op - managed by SystemAudioCaptureManager
    }
}

// MARK: - System Audio Spectrogram Feed
final class SystemAudioSpectrogramFeed: ObservableObject {
    private let source: SystemAudioSource
    private let deviceID: Int32
    private let channelIndex: Int32
    private let queue = DispatchQueue(label: "com.avcmeter.spectrogram.systemaudio", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    init(source: SystemAudioSource = .shared, deviceID: Int32 = 888_888, channelIndex: Int32 = 0) {
        self.source = source
        self.deviceID = deviceID
        self.channelIndex = channelIndex
    }

    func start() {
        guard timer == nil else { return }
        let newTimer = DispatchSource.makeTimerSource(flags: [], queue: queue)
        newTimer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
        newTimer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = newTimer
        newTimer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    deinit {
        stop()
    }

    private func tick() {
        let fftSize = VisualisationSettings.shared.spectrumFFTSize
        var samples = [Float](repeating: 0.0, count: fftSize)
        let count = source.read(channel: Int(channelIndex), into: &samples)

        guard count > 0 else { return }

        // Compute FFT
        let fftData = computeFFT(samples: samples, fftSize: fftSize)

        // Ensure history buffer exists for external spectrogram
        if SpectroManager.shared.historyRingBuffer(for: deviceID, channel: channelIndex) == nil {
            let numBins = fftData.count
            let numFrames = SpectroManager.spectrogramHistoryFrames
            if let bufHist = SpectroManager.shared.createHistoryRingBuffer(numBins: numBins, numFrames: numFrames) {
                SpectroManager.shared.registerHistoryBuffer(bufHist, for: deviceID, channel: channelIndex)
            }
        }

        // Write to spectrogram history via SpectroManager
        SpectroManager.shared.writeFFTFrame(
            deviceID: deviceID,
            channel: channelIndex,
            magnitudes: fftData
        )
    }

    private func computeFFT(samples: [Float], fftSize: Int) -> [Float] {
        // Ensure we have enough samples
        guard samples.count >= fftSize else { return [Float](repeating: 0.0, count: fftSize / 2) }

        // Create FFT setup
        guard let fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(fftSize))), FFTRadix(kFFTRadix2)) else {
            return [Float](repeating: 0.0, count: fftSize / 2)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var magnitudes = [Float](repeating: 0.0, count: fftSize / 2)
        var realParts = [Float](repeating: 0.0, count: fftSize / 2)
        var imagParts = [Float](repeating: 0.0, count: fftSize / 2)

        realParts.withUnsafeMutableBufferPointer { realBuffer in
            imagParts.withUnsafeMutableBufferPointer { imagBuffer in
                guard let realBase = realBuffer.baseAddress,
                      let imagBase = imagBuffer.baseAddress else { return }

                var splitComplex = DSPSplitComplex(realp: realBase, imagp: imagBase)

                // Convert real samples to split complex format
                samples.withUnsafeBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    baseAddress.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                    }
                }

                // Perform FFT
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, vDSP_Length(log2(Float(fftSize))), FFTDirection(FFT_FORWARD))

                // Compute magnitudes
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        // Scale and take square root
        let scale = 1.0 / Float(fftSize)
        for i in 0..<magnitudes.count {
            magnitudes[i] *= scale
            magnitudes[i] = sqrt(magnitudes[i])
        }

        return magnitudes
    }
}

// MARK: - Glass Toolbar Helpers

struct GlassToolbarPill<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                content
                    .glassEffect(in: .capsule)
            }
        } else {
            content
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}

struct GlassToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.18))
            .frame(width: 0.5, height: 16)
            .padding(.horizontal, 2)
    }
}

private extension ContentView {

    @ViewBuilder
    func systemAudioListView() -> some View {
        @ObservedObject var systemAudioManager = SystemAudioCaptureManager.shared

        VStack(alignment: .leading, spacing: 10) {
            GlassToolbarPill {
                Text("System Audio")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }

            systemAudioTile()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    @ViewBuilder
    private func systemAudioTile() -> some View {
        @ObservedObject var systemAudioManager = SystemAudioCaptureManager.shared

        VStack(spacing: 0) {
            systemAudioInfoRow()
                .frame(minWidth: 200)
                .padding()
                .background(ThemeRoundedRectangle(cornerRadius: 10, style: .continuous).themed(fill: themeManager.accentFillColor))
        }
    }

    @ViewBuilder
    private func systemAudioInfoRow() -> some View {
        @ObservedObject var systemAudioManager = SystemAudioCaptureManager.shared

        let isCapturing = systemAudioManager.isCapturing
        let channelCount = systemAudioManager.channelCount
        let sampleRate = systemAudioManager.sampleRate
        let statusText = systemAudioManager.statusText

        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("System Audio")
                    .font(.subheadline)
                Text("\(channelCount) Output Channels – \(Int(sampleRate)) Hz")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Transport: Screen Capture")
                        .font(.caption2)
                        .foregroundColor(.gray)

                    if isCapturing {
                        Text("Capturing")
                            .font(.caption2)
                            .foregroundColor(.green)
                    } else if systemAudioManager.status == .permissionNeeded {
                        Text("Permission Required")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    } else {
                        Text(statusText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            if systemAudioManager.status == .permissionNeeded {
                Button {
                    systemAudioManager.openSystemPreferences()
                } label: {
                    Text("Enable")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.2))
                        .foregroundColor(.orange)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Open System Preferences to enable screen recording permission")
            } else {
                Button {
                    if isCapturing {
                        systemAudioManager.stopCapture()
                    } else {
                        systemAudioManager.startCapture()
                    }
                } label: {
                    Image(systemName: isCapturing ? "waveform" : "play.circle")
                        .foregroundColor(isCapturing ? .red : .green)
                }
                .buttonStyle(.plain)
                .help(isCapturing ? "Stop system audio capture" : "Start system audio capture")
            }
        }
    }

    // MARK: - Audio Server Plugin Section

    func audioServerPluginListView() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassToolbarPill {
                Text("Audio Server Plugin")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            audioServerPluginTile()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    @ViewBuilder
    private func audioServerPluginTile() -> some View {
        @ObservedObject var floatingWindowController = FloatingWindowController.shared

        VStack(spacing: 0) {
            audioServerPluginInfoRow()
                .frame(minWidth: 200)
                .padding()
                .background(ThemeRoundedRectangle(cornerRadius: 10, style: .continuous).themed(fill: themeManager.accentFillColor))
        }
    }

    @ViewBuilder
    private func audioServerPluginInfoRow() -> some View {
        @ObservedObject var floatingWindowController = FloatingWindowController.shared

        let isOpen = floatingWindowController.fireWireNetBridgeWindow != nil

        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("FireWire Net Bridge")
                    .font(.subheadline)
                Text("Network Audio Bridge · TX / RX")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text(isOpen ? "Window Open" : "Inactive")
                    .font(.caption2)
                    .foregroundColor(isOpen ? .green : .secondary)
            }

            Spacer()

            Button {
                if isOpen {
                    FloatingWindowController.shared.closeFireWireNetBridgeWindow()
                } else {
                    FloatingWindowController.shared.showFireWireNetBridgeWindow()
                }
            } label: {
                Image(systemName: isOpen ? "waveform" : "play.circle")
                    .foregroundColor(isOpen ? .red : .green)
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Close FireWire Net Bridge" : "Open FireWire Net Bridge")
        }
    }

    /// Renders the list of all available audio input devices.
    ///
    /// Each device is shown as a tile with details and a toggle for metering.
    /// Used in the left panel of the main ContentView.
    @ViewBuilder
    func deviceListView() -> some View {
        VStack(spacing: 12) {
            ForEach(manager.inputDevices) { device in
                deviceTile(for: device)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    func midiDeviceListView() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                GlassToolbarPill {
                    Text("MIDI Devices")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
                Spacer()
                GlassToolbarPill {
                    Button {
                        midiManager.refreshDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.primary.opacity(0.8))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh MIDI devices")
                }
            }

            ForEach(midiManager.availableDevices) { device in
                MIDIDeviceCard(device: device)
            }
        }
    }

    @ViewBuilder
    func virtualInstrumentListView() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassToolbarPill {
                Text("Virtual Instruments")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }

            ForEach(0..<virtualInstrumentChannelCount, id: \.self) { channelIndex in
                virtualInstrumentTile(channelIndex: channelIndex)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func virtualInstrumentTile(channelIndex: Int) -> some View {
        VStack(spacing: 0) {
            virtualInstrumentInfoRow(channelIndex: channelIndex)
                .frame(minWidth: 200)
                .padding()
                .background(ThemeRoundedRectangle(cornerRadius: 10, style: .continuous).themed(fill: themeManager.accentFillColor))
                .onTapGesture {
                    selectedVirtualInstrumentPopoverIndex =
                        (selectedVirtualInstrumentPopoverIndex == channelIndex) ? nil : channelIndex
                }
                .popover(isPresented: Binding(
                    get: { selectedVirtualInstrumentPopoverIndex == channelIndex },
                    set: { show in
                        if !show { selectedVirtualInstrumentPopoverIndex = nil }
                    }
                )) {
                    virtualInstrumentSettingsSelector(channelIndex: channelIndex)
                        .frame(width: 220)
                        .padding()
                }
        }
    }

    @ViewBuilder
    private func virtualInstrumentInfoRow(channelIndex: Int) -> some View {
        let selectedName = virtualChannelManager.selectedVirtualInstrumentDisplayName(
            for: virtualInstrumentDeviceID,
            channelIndex: channelIndex
        )
        let isVisible = visibleVirtualInstrumentMeterIndices.contains(channelIndex)

        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("VI \(channelIndex + 1)")
                    .font(.subheadline)
                Text(selectedName ?? "No instrument selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text("Input Channel \(channelIndex + 1)")
                    .font(.caption2)
                    .foregroundColor(.gray)
                if isVisible {
                    Text("Meter Group Visible")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }

            Spacer()

            Button {
                if isVisible {
                    visibleVirtualInstrumentMeterIndices.remove(channelIndex)
                } else {
                    visibleVirtualInstrumentMeterIndices.insert(channelIndex)
                }
            } label: {
                Image(systemName: isVisible ? "waveform" : "play.circle")
                    .foregroundColor(isVisible ? .red : .green)
            }
            .buttonStyle(.plain)
            .help(isVisible ? "Hide VI meter group" : "Show VI meter group")
        }
    }

    @ViewBuilder
    private func virtualInstrumentSettingsSelector(channelIndex: Int) -> some View {
        VStack(alignment: .leading) {
            Text("VI \(channelIndex + 1) Settings")
                .font(.headline)

            Text("These settings apply to all Virtual Instrument meter cards.")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()
                .padding(.vertical, 6)

            Text("Capsule Theme")
                .font(.subheadline)

            Picker("Capsule Theme", selection: Binding<ThemeMode>(
                get: {
                    themeManager.deviceCapsuleThemes[virtualInstrumentDeviceID] ?? themeManager.capsuleThemeMode
                },
                set: { newTheme in
                    themeManager.deviceCapsuleThemes[virtualInstrumentDeviceID] = newTheme
                }
            )) {
                Text("Green").tag(ThemeMode.light)
                Text("Blue").tag(ThemeMode.dark)
                Text("Turquoise").tag(ThemeMode.thinMaterial)
                Text("Chilled").tag(ThemeMode.liquidGlass)
                Text("Purple").tag(ThemeMode.purple)
                Text("Mint").tag(ThemeMode.mint)
                Text("Lavender").tag(ThemeMode.lavender)
                Text("Indigo").tag(ThemeMode.indigo)
                Text("Gray").tag(ThemeMode.gray)
                Text("Hollow").tag(ThemeMode.hollow)
            }
            .pickerStyle(PopUpButtonPickerStyle())

            Divider()
                .padding(.vertical, 6)

            Text("Channel Strip Color")
                .font(.subheadline)

            Picker("Channel Strip Color", selection: Binding<ChannelStripColor>(
                get: {
                    themeManager.deviceChannelStripColors[virtualInstrumentDeviceID] ?? .standard
                },
                set: { newColor in
                    themeManager.deviceChannelStripColors[virtualInstrumentDeviceID] = newColor
                }
            )) {
                Text("Standard").tag(ChannelStripColor.standard)
                Text("Red").tag(ChannelStripColor.red)
                Text("Blue").tag(ChannelStripColor.blue)
                Text("Green").tag(ChannelStripColor.green)
                Text("Orange").tag(ChannelStripColor.orange)
                Text("Yellow").tag(ChannelStripColor.yellow)
                Text("Gray").tag(ChannelStripColor.gray)
                Text("White").tag(ChannelStripColor.white)
                Text("Mint").tag(ChannelStripColor.mint)
                Text("Pink").tag(ChannelStripColor.pink)
                Text("Purple").tag(ChannelStripColor.purple)
            }
            .pickerStyle(PopUpButtonPickerStyle())

            Divider()
                .padding(.vertical, 6)

            Text("Floating Window Size")
                .font(.subheadline)

            Picker("Scale", selection: Binding<Double>(
                get: {
                    themeManager.deviceSpectrumScaleFactors[virtualInstrumentDeviceID] ?? 1.0
                },
                set: { newScale in
                    themeManager.deviceSpectrumScaleFactors[virtualInstrumentDeviceID] = newScale
                }
            )) {
                Text("1/8x").tag(0.125)
                Text("1/4x").tag(0.25)
                Text("1/2x").tag(0.5)
                Text("1x").tag(1.0)
                Text("2x").tag(2.0)
                Text("4x").tag(4.0)
            }
            .pickerStyle(PopUpButtonPickerStyle())
        }
    }

    /// Renders a single device tile with info and channel selector popover.
    /// - Parameter device: The audio input device to display.
    @ViewBuilder
    private func deviceTile(for device: AudioDevice) -> some View {
        VStack(spacing: 0) {
            deviceInfoRow(for: device)
                .frame(minWidth: 200)
                .padding()
                .background(ThemeRoundedRectangle(cornerRadius: 10, style: .continuous).themed(fill: themeManager.accentFillColor))
                .onTapGesture {
                    if manager.selectedChannelMasks[device.deviceID] == nil {
                        manager.selectedChannelMasks[device.deviceID] = Array(repeating: true, count: Int(device.inputChannels))
                    }
                    selectedDeviceForPopover = (selectedDeviceForPopover == device.deviceID) ? nil : device.deviceID
                }
                .popover(isPresented: Binding(
                    get: { selectedDeviceForPopover == device.deviceID },
                    set: { show in
                        if !show { selectedDeviceForPopover = nil }
                    }
                )) {
                    inputChannelSelector(for: device)
                        .frame(width: 220)
                        .padding()
                }
        }
    }

    /// Renders the main information row for a device, including name, channel count, and sync status.
    /// - Parameter device: The audio input device to describe.
    @ViewBuilder
    private func deviceInfoRow(for device: AudioDevice) -> some View {
        let isSynced = streamManager.isDeviceSynced(deviceID: device.deviceID)
        let isActive = manager.isDeviceActive(deviceID: device.deviceID)
        HStack {
            VStack(alignment: .leading) {
                Text(device.name)
                    .font(.subheadline)
                Text("\(device.inputChannels) In / \(device.outputChannels) Out – \(device.sampleRate, specifier: "%.0f") Hz")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Transport: \(device.transportType)")
                        .font(.caption2)
                        .foregroundColor(.gray)

                    if isSynced {
                        Text("Synced")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            }

            Spacer()

            Image(systemName: isActive ? "waveform" : "play.circle")
                .foregroundColor(isActive ? .red : .green)
                .onTapGesture {
                    if isActive {
                        Task { @MainActor in
                            manager.endMetering(for: device)
                            streamManager.stopStream(for: device.deviceID)
                            manager.selectedChannelMasks[device.deviceID] = nil
                            // Mute all channels for this device
                            for channel in 0..<device.inputChannels {
                                if !ChannelStateManager.shared.isMuted(deviceID: device.deviceID, channel: Int(channel)) {
                                    ChannelStateManager.shared.toggleMute(deviceID: device.deviceID, channel: Int(channel))
                                }
                            }
                        }
                    } else {
                        Task { @MainActor in
                            await streamManager.startStream(for: device.deviceID)
                            manager.beginMetering(device: device)
                            selectedDeviceID = device.deviceID
                        }
                    }
                }
        }
    }

    /// Renders a popover for selecting active input channels, capsule theme, channel strip color, and spectrum size for a device.
    /// - Parameter device: The audio device whose channels are being configured.
    @ViewBuilder
    private func inputChannelSelector(for device: AudioDevice) -> some View {
        VStack(alignment: .leading) {
            Text("Select Input Channels")
                .font(.headline)

            let channelCount = manager.activeDevices[device.deviceID]?.device.inputChannels ?? device.inputChannels

            if channelCount > 8 {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(0..<Int(channelCount), id: \.self) { index in
                            let isOnBinding = Binding<Bool>(
                                get: {
                                    streamManager.channelMask(for: device.deviceID, channelCount: Int(channelCount))[index]
                                },
                                set: { newValue in
                                    var updated = streamManager.channelMask(for: device.deviceID, channelCount: Int(channelCount))
                                    updated[index] = newValue
                                    streamManager.updateChannelMask(for: device.deviceID, mask: updated)
                                    manager.selectedChannelMasks[device.deviceID] = updated
                                    DeviceStreamController.registerDeviceWithMixer(deviceID: device.deviceID, channelMask: updated) // Sync mixer registration with new mask
                                }
                            )
                            Toggle("Channel \(index + 1)", isOn: isOnBinding)
                        }
                    }
                }
                .frame(height: 220)
            } else {
                ForEach(0..<Int(channelCount), id: \.self) { index in
                    let isOnBinding = Binding<Bool>(
                        get: {
                            streamManager.channelMask(for: device.deviceID, channelCount: Int(channelCount))[index]
                        },
                        set: { newValue in
                            var updated = streamManager.channelMask(for: device.deviceID, channelCount: Int(channelCount))
                            updated[index] = newValue
                            streamManager.updateChannelMask(for: device.deviceID, mask: updated)
                            manager.selectedChannelMasks[device.deviceID] = updated
                            DeviceStreamController.registerDeviceWithMixer(deviceID: device.deviceID, channelMask: updated) // Sync mixer registration with new mask
                        }
                    )
                    Toggle("Channel \(index + 1)", isOn: isOnBinding)
                }
            }

            Divider()
                .padding(.vertical, 6)

            Text("Capsule Theme")
                .font(.subheadline)

            Picker("Capsule Theme", selection: Binding<ThemeMode>(
                get: {
                    themeManager.deviceCapsuleThemes[device.deviceID] ?? themeManager.capsuleThemeMode
                },
                set: { newTheme in
                    themeManager.deviceCapsuleThemes[device.deviceID] = newTheme
                }
            )) {
                Text("Green").tag(ThemeMode.light)
                Text("Blue").tag(ThemeMode.dark)
                Text("Turquoise").tag(ThemeMode.thinMaterial)
                Text("Chilled").tag(ThemeMode.liquidGlass)
                Text("Purple").tag(ThemeMode.purple)
                Text("Mint").tag(ThemeMode.mint)
                Text("Lavender").tag(ThemeMode.lavender)
                Text("Indigo").tag(ThemeMode.indigo)
                Text("Gray").tag(ThemeMode.gray)
                Text("Hollow").tag(ThemeMode.hollow)
            }
            .pickerStyle(PopUpButtonPickerStyle())

            Divider()
                .padding(.vertical, 6)

            Text("Channel Strip Color")
                .font(.subheadline)

            Picker("Channel Strip Color", selection: Binding<ChannelStripColor>(
                get: {
                    themeManager.deviceChannelStripColors[device.deviceID] ?? .standard
                },
                set: { newColor in
                    themeManager.deviceChannelStripColors[device.deviceID] = newColor
                }
            )) {
                Text("Standard").tag(ChannelStripColor.standard)
                Text("Red").tag(ChannelStripColor.red)
                Text("Blue").tag(ChannelStripColor.blue)
                Text("Green").tag(ChannelStripColor.green)
                Text("Orange").tag(ChannelStripColor.orange)
                Text("Yellow").tag(ChannelStripColor.yellow)
                Text("Gray").tag(ChannelStripColor.gray)
                Text("White").tag(ChannelStripColor.white)
                Text("Mint").tag(ChannelStripColor.mint)
                Text("Pink").tag(ChannelStripColor.pink)
                Text("Purple").tag(ChannelStripColor.purple)
            }
            .pickerStyle(PopUpButtonPickerStyle())

            Divider()
                .padding(.vertical, 6)

            Text("Floating Window Size")
                .font(.subheadline)

            Picker("Scale", selection: Binding<Double>(
                get: {
                    themeManager.deviceSpectrumScaleFactors[device.deviceID] ?? 1.0
                },
                set: { newScale in
                    themeManager.deviceSpectrumScaleFactors[device.deviceID] = newScale
                }
            )) {
                Text("1/8x").tag(0.125)
                Text("1/4x").tag(0.25)
                Text("1/2x").tag(0.5)
                Text("1x").tag(1.0)
                Text("2x").tag(2.0)
                Text("4x").tag(4.0)
            }
            .pickerStyle(PopUpButtonPickerStyle())
        }
    }


    /// Shows a capsule meter grid for each actively monitored audio input device.
    ///
    /// Each device's input channels are grouped and visualized using `ChannelMeteringGroupView`.
    /// Used in the right panel of the ContentView.
    @ViewBuilder
    func meteringView() -> some View {
        let activeDevices = manager.activeDevices.filter { $0.key != virtualInstrumentDeviceID && $0.key != systemAudioDeviceID }
        let visibleVirtualInstrumentIndices = Array(0..<virtualInstrumentChannelCount)
            .filter { visibleVirtualInstrumentMeterIndices.contains($0) }

        HStack(alignment: .top, spacing: MeteringCardLayout.cardRowSpacing) {
            ForEach(Array(activeDevices.keys).sorted(), id: \.self) { deviceID in
                if let context = activeDevices[deviceID] {
                    let device = context.device
                    let mask = manager.selectedChannelMasks[deviceID] ?? Array(repeating: true, count: Int(device.inputChannels))
                    let visibleIndices = mask.enumerated().compactMap { $0.element ? $0.offset : nil }
                    let grouped = stride(from: 0, to: visibleIndices.count, by: 64).map {
                        Array(visibleIndices[$0..<min($0 + 64, visibleIndices.count)])
                    }
                    let widestGroupCount = grouped.map(\.count).max() ?? 1
                    let cardWidth = meteringCardWidth(forVisibleChannelCount: widestGroupCount)
ZStack(alignment: .trailing) {
    ThemeRoundedRectangle(cornerRadius: MeteringCardLayout.cardCornerRadius, style: .continuous).themed(fill: themeManager.accentFillColor)

    VStack(spacing: 0) {

                                ThemeRoundedRectangle(cornerRadius: MeteringCardLayout.cardCornerRadius, style: .continuous)
                                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                            )
                        VStack(alignment: .center, spacing: MeteringCardLayout.cardContentSpacing) {
                            meteringCardHeader(
                                title: "\(device.name):",
                                subtitle: "Inputs: 1 - \(device.inputChannels)"
                            )
                            ForEach(grouped, id: \.self) { group in
                                ChannelMeteringGroupView(
                                    deviceID: deviceID,
                                    channelIndices: group,
                                    channelHeaderYOffset: MeteringCardLayout.inputChannelHeaderYOffset,
                                    channelHeaderYOffsetCPU: MeteringCardLayout.inputChannelHeaderYOffsetCPU,
                                    capsuleYOffset: MeteringCardLayout.inputCapsuleYOffset
                                )
                            }
                        }
                        .padding(MeteringCardLayout.cardContentPadding)
                        .offset(y: MeteringCardLayout.cardContentOffsetY)
                    }
                    .frame(
                        width: cardWidth,
                        height: MeteringCardLayout.cardHeight
                    )
                    .contextMenu {
                        Button {
                            let key = "\(deviceID)-input-meter"
                            FloatingWindowController.shared.showFloatingMeterWindow(
                                key: key,
                                title: "\(device.name): Inputs 1–\(device.inputChannels)",
                                size: CGSize(
                                    width: cardWidth + MeteringCardLayout.floatingWindowInset,
                                    height: MeteringCardLayout.cardHeight + MeteringCardLayout.floatingWindowInset
                                )
                            ) {
                                InputMeteringCard(deviceID: deviceID)
                                    .environmentObject(manager)
                                    .environmentObject(themeManager)
                            }
                        } label: {
                            Label("Open Floating Window", systemImage: "square.stack.3d.up")
                        }
                        Button {
                            FloatingWindowController.shared.closeFloatingMeterWindow(key: "\(deviceID)-input-meter")
                        } label: {
                            Label("Close Floating Window", systemImage: "xmark.circle")
                        }
                    }
                    .padding(.top, MeteringCardLayout.cardTopPadding)
                } else {
                    // Context not yet initialized, show placeholder
                    ThemeRoundedRectangle(cornerRadius: MeteringCardLayout.cardCornerRadius, style: .continuous).themed(fill: Color.gray.opacity(0.2))
                        .frame(width: 200, height: MeteringCardLayout.cardHeight)
                        .padding(.top, MeteringCardLayout.cardTopPadding)
                }
            }

            if !activeDevices.isEmpty && !visibleVirtualInstrumentIndices.isEmpty {
                Color.clear
                    .frame(width: MeteringCardLayout.sectionGapWidth, height: 1)
            }

            ForEach(visibleVirtualInstrumentIndices, id: \.self) { viIndex in
                let key = "\(virtualInstrumentDeviceID)-vi-meter-\(viIndex)"
                let displayName = virtualChannelManager.selectedVirtualInstrumentDisplayName(
                    for: virtualInstrumentDeviceID,
                    channelIndex: viIndex
                ) ?? "Empty"
                let cardWidth = meteringCardWidth(forVisibleChannelCount: 2)

                VirtualInstrumentMeteringCard(
                    deviceID: virtualInstrumentDeviceID,
                    viIndex: viIndex,
                    defaultChannelCount: virtualInstrumentChannelCount,
                    virtualInstrumentCount: virtualInstrumentChannelCount
                )
                .contextMenu {
                    Button {
                        FloatingWindowController.shared.showFloatingMeterWindow(
                            key: key,
                            title: "VI \(viIndex + 1): \(displayName)",
                            size: CGSize(
                                width: cardWidth + MeteringCardLayout.floatingWindowInset,
                                height: MeteringCardLayout.cardHeight + MeteringCardLayout.floatingWindowInset
                            )
                        ) {
                            VirtualInstrumentMeteringCard(
                                deviceID: virtualInstrumentDeviceID,
                                viIndex: viIndex,
                                defaultChannelCount: virtualInstrumentChannelCount,
                                virtualInstrumentCount: virtualInstrumentChannelCount
                            )
                            .environmentObject(manager)
                            .environmentObject(themeManager)
                        }
                    } label: {
                        Label("Open Floating Window", systemImage: "square.stack.3d.up")
                    }
                    Button {
                        FloatingWindowController.shared.closeFloatingMeterWindow(key: key)
                    } label: {
                        Label("Close Floating Window", systemImage: "xmark.circle")
                    }
                }
                .padding(.top, MeteringCardLayout.cardTopPadding)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
    }
}


private extension MultiDeviceStreamManager {
    /// Returns whether the given device is currently streaming/synced.
    /// - Parameter deviceID: The device identifier.
    /// - Returns: `true` if the device is actively being polled.
    func isDeviceSynced(deviceID: AudioDeviceID) -> Bool {
        activePollers[deviceID] != nil
    }
    /// Returns the channel mask (enabled/disabled) for a device.
    /// - Parameters:
    ///   - deviceID: The audio device identifier.
    ///   - channelCount: The number of input channels.
    /// - Returns: An array of Bool indicating which channels are enabled.
    func channelMask(for deviceID: AudioDeviceID, channelCount: Int) -> [Bool] {
        self.channelMaskCache[deviceID] ?? Array(repeating: true, count: channelCount)
    }
}

private extension AudioDeviceManager {
    /// Returns whether the given device is currently active (metering).
    /// - Parameter deviceID: The device identifier.
    /// - Returns: `true` if the device is in the activeDevices list.
    func isDeviceActive(deviceID: AudioDeviceID) -> Bool {
        activeDevices[deviceID] != nil
    }
}


/// Displays a metering tile for a single audio device, including channel meters and device info.
struct MeteringDeviceView: View {
    let context: DeviceMeteringContext

    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        let mask = MultiDeviceStreamManager.shared.channelMask(for: context.device.deviceID, channelCount: Int(context.device.inputChannels))
        let visibleIndices = mask.enumerated().compactMap { $0.element ? $0.offset : nil }
        let capsuleHeight: CGFloat = 80 * 1.8

        let columns = Array(repeating: GridItem(.fixed(20), spacing: 8), count: min(visibleIndices.count, 8))

        VStack(spacing: 8) {
            let inputEnd = Int(context.device.inputChannels)
            VStack(alignment: .center, spacing: 24) {
                Text("\(context.device.name):")
                    .font(.caption)
                    .bold()
                Text("Inputs: 1 - \(inputEnd)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .offset(y: -10)
            .padding(.vertical, -16)
            .frame(maxWidth: 128, alignment: .center)

            ThemeRoundedRectangle(cornerRadius: 12, style: .continuous).themed()
                .fill(themeManager.currentThemeMode == .thinMaterial ? Color.white.opacity(0.08) : Color(themeManager.accentColor))
                .frame(width: CGFloat(visibleIndices.count) * 20 + 32, height: capsuleHeight * 1.45)
                .overlay(
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(visibleIndices, id: \.self) { channelIndex in
                            CapsuleMeterView(context: context, channelIndex: channelIndex)
                                .frame(width: 12.8, height: 80)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
                )
                .overlay(
                    ThemeRoundedRectangle(cornerRadius: 12, style: .continuous).themed()
                        .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                )
                .padding(.horizontal, 4)
                .offset(x: -18)
        }
        .offset(y: 25)
        .padding(.top, 8)
    }
}





// MARK: - AudioDeviceManager Device Description Helper
extension AudioDeviceManager {
    /// Returns a tuple with device name and sampleRate for a given deviceID, or nil if not found.
    /// - Parameter deviceID: The unique identifier of the audio device.
    /// - Returns: Tuple with device name and sample rate, or nil if not found.
    func getDeviceDescription(deviceID: AudioDeviceID) -> (name: String, sampleRate: Double)? {
        if let device = inputDevices.first(where: { $0.deviceID == deviceID }) {
            return (device.name, device.sampleRate)
        }
        return nil
    }
}




// MARK: - Output Device List Tiles (scoped to ContentView)
private extension ContentView {

    /// Renders the list of all available audio output devices.
    /// Each device is shown as a tile with basic details and channel meters.
    @ViewBuilder
    func outputDeviceListView() -> some View {
        VStack(spacing: 12) {
            ForEach(outputManager.outputDevices) { device in
                outputDeviceTile(for: device)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Renders a single output device tile with info row and channel meters.
    /// - Parameter device: The audio output device to display.
    @ViewBuilder
    func outputDeviceTile(for device: AudioDevice) -> some View {
        VStack(spacing: 0) {
            outputDeviceInfoRow(for: device)
                .frame(minWidth: 200)
                .padding()
                .background(ThemeRoundedRectangle(cornerRadius: 10, style: .continuous).themed(fill: themeManager.accentFillColor))
                .onTapGesture {
                    if outputManager.selectedChannelMasks[device.deviceID] == nil {
                        outputManager.selectedChannelMasks[device.deviceID] = Array(repeating: true, count: Int(device.outputChannels))
                    }
                    selectedDeviceForPopover = (selectedDeviceForPopover == device.deviceID) ? nil : device.deviceID
                }
                .popover(isPresented: Binding(
                    get: { selectedDeviceForPopover == device.deviceID },
                    set: { show in
                        if !show { selectedDeviceForPopover = nil }
                    }
                )) {
                    outputChannelSelector(for: device)
                        .frame(width: 220)
                        .padding()
                }
        }
    }

    /// Renders the main information row for a device, including name and output channel count.
    /// - Parameter device: The audio output device to describe.
    @ViewBuilder
    func outputDeviceInfoRow(for device: AudioDevice) -> some View {
        let isActive = outputManager.activeOutputDevices.contains(device.deviceID)
        HStack {
            VStack(alignment: .leading) {
                Text(device.name)
                    .font(.subheadline)
                Text("\(device.outputChannels) Output Channels – \(device.sampleRate, specifier: "%.0f") Hz")
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Transport: \(device.transportType)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    if isActive {
                        Text("Synced")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundColor(isActive ? .red : .green)
                    .onTapGesture {
                        // 1. Toggle output stream
                        OutputStreamController.toggleOutputStream(for:device,
                                                                  manager:outputManager,
                                                                  streamManager:MultiOutputStreamManager.shared)
                    }
            }
        }
    }
}





// MARK: - Output Metering View
extension ContentView {
    @ViewBuilder
    func outputMeteringView() -> some View {
        let activeOutputIDs = outputManager.activeOutputDevices
        HStack(alignment: .top, spacing: MeteringCardLayout.outputCardSpacing) {
            // Add spacer when there are no output devices but System Audio is capturing
            if activeOutputIDs.isEmpty && SystemAudioCaptureManager.shared.isCapturing {
                Spacer()
                    .frame(width: 12)
            }

            // Output device meters
            ForEach(Array(activeOutputIDs), id: \.self) { deviceID in
                let selectedCount: Int = {
                    guard let device = outputManager.outputDevices.first(where: { $0.deviceID == deviceID }) else {
                        return 1
                    }
                    let defaultMask = Array(repeating: true, count: Int(device.outputChannels))
                    let mask = outputManager.selectedChannelMasks[deviceID] ?? defaultMask
                    return max(1, mask.filter { $0 }.count)
                }()
                let cardWidth = meteringCardWidth(forVisibleChannelCount: selectedCount)

                ZStack(alignment: .top) {
                    OutputMeteringGroupView(
                        deviceID: deviceID,
                        cardWidth: cardWidth,
                        tickMarkYOffset: MeteringCardLayout.outputTickMarkYOffset,
                        tickMarkYOffsetCPU: MeteringCardLayout.outputTickMarkYOffsetCPU,
                        channelHeaderYOffset: MeteringCardLayout.outputChannelHeaderYOffset,
                        channelHeaderYOffsetCPU: MeteringCardLayout.outputChannelHeaderYOffsetCPU,
                        capsuleYOffset: MeteringCardLayout.outputCapsuleYOffset,
                        featureControlsTopPadding: MeteringCardLayout.outputFeatureControlsTopPadding,
                        featureControlsBottomPadding: MeteringCardLayout.outputFeatureControlsBottomPadding,
                        featureControlsLeadingNudge: MeteringCardLayout.outputFeatureControlsLeadingNudge,
                        featureControlsYOffset: MeteringCardLayout.outputFeatureControlsYOffset,
                        spectrumIconYOffset: MeteringCardLayout.outputSpectrumIconYOffset,
                        spectrogramIconYOffset: MeteringCardLayout.outputSpectrogramIconYOffset,
                        waveformIconYOffset: MeteringCardLayout.outputWaveformIconYOffset,
                        contentYOffset: MeteringCardLayout.outputContentVerticalNudge
                    )
                        .environmentObject(themeManager)
                        .environmentObject(OutputDeviceManager.shared)
                        .environmentObject(VirtualChannelManager.shared)
                        .environmentObject(matrixManager)
                        .padding(.top, 0)

                    if let device = outputManager.outputDevices.first(where: { $0.deviceID == deviceID }) {
                        VStack(spacing: 6) {
                            Text(device.name)
                                .font(.system(size: 10))
                                .bold()
                                .layoutPriority(1)
                                .lineLimit(nil)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 80)
                                .offset(y: MeteringCardLayout.outputCardHeaderYOffset)
                            Text("Outputs: 1 - \(device.outputChannels)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .multilineTextAlignment(.center)
                                .frame(width: 80, height: 12)
                                .offset(y: MeteringCardLayout.outputCardHeaderSubtitleYOffset)
                        }
                        .padding(.top, 0.01)
                    } else {
                        VStack(spacing: 6) {
                            Color.gray.opacity(0.3)
                                .frame(width: 60, height: 12)
                            Color.gray.opacity(0.2)
                                .frame(width: 60, height: 10)
                        }
                        .frame(width: 80, height: 40)
                    }
                }
                .contextMenu {
                    Button {
                        let key = "\(deviceID)-output-meter"
                        FloatingWindowController.shared.showFloatingMeterWindow(
                            key: key,
                            title: outputManager.outputDevices.first(where: { $0.deviceID == deviceID }).map {
                                "\($0.name): Outputs 1–\($0.outputChannels)"
                            } ?? "Output",
                            size: CGSize(width: cardWidth + 24, height: 380 + 24)
                        ) {
                            OutputMeteringGroupView(
                                deviceID: deviceID,
                                cardWidth: cardWidth,
                                tickMarkYOffset: MeteringCardLayout.outputTickMarkYOffset,
                                tickMarkYOffsetCPU: MeteringCardLayout.outputTickMarkYOffsetCPU,
                                channelHeaderYOffset: MeteringCardLayout.outputChannelHeaderYOffset,
                                channelHeaderYOffsetCPU: MeteringCardLayout.outputChannelHeaderYOffsetCPU,
                                capsuleYOffset: MeteringCardLayout.outputCapsuleYOffset,
                                featureControlsTopPadding: MeteringCardLayout.outputFeatureControlsTopPadding,
                                featureControlsBottomPadding: MeteringCardLayout.outputFeatureControlsBottomPadding,
                                featureControlsLeadingNudge: MeteringCardLayout.outputFeatureControlsLeadingNudge,
                                featureControlsYOffset: MeteringCardLayout.outputFeatureControlsYOffset,
                                spectrumIconYOffset: MeteringCardLayout.outputSpectrumIconYOffset,
                                spectrogramIconYOffset: MeteringCardLayout.outputSpectrogramIconYOffset,
                                waveformIconYOffset: MeteringCardLayout.outputWaveformIconYOffset,
                                contentYOffset: MeteringCardLayout.outputContentVerticalNudge
                            )
                                .environmentObject(ThemeManager.shared)
                                .environmentObject(OutputDeviceManager.shared)
                                .environmentObject(VirtualChannelManager.shared)
                                .environmentObject(matrixManager)
                        }
                    } label: {
                        Label("Open Floating Window", systemImage: "square.stack.3d.up")
                    }
                    Button {
                        FloatingWindowController.shared.closeFloatingMeterWindow(key: "\(deviceID)-output-meter")
                    } label: {
                        Label("Close Floating Window", systemImage: "xmark.circle")
                    }
                }
            }
            .offset(x: -12, y: 8)

            // System Audio metering card (appears independently, even when no output devices)
            if SystemAudioCaptureManager.shared.isCapturing {
                SystemAudioMeteringCard()
                    .environmentObject(manager)
                    .environmentObject(themeManager)
                    .padding(.top, MeteringCardLayout.cardTopPadding)
                    .offset(x: -12, y: 8 + MeteringCardLayout.systemAudioCardVerticalOffset)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
    }
}

// MARK: - Piano Keyboard View

// HourglassShape for Fader Thumb (from FaderView.swift)
private struct HourglassShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let insetX = rect.width * 0.22
        let topY = rect.minY
        let bottomY = rect.maxY
        let midY = rect.midY

        path.move(to: CGPoint(x: rect.minX + insetX, y: topY))
        path.addLine(to: CGPoint(x: rect.maxX - insetX, y: topY))
        path.addLine(to: CGPoint(x: rect.midX + insetX, y: midY))
        path.addLine(to: CGPoint(x: rect.maxX - insetX, y: bottomY))
        path.addLine(to: CGPoint(x: rect.minX + insetX, y: bottomY))
        path.addLine(to: CGPoint(x: rect.midX - insetX, y: midY))
        path.closeSubpath()

        return path
    }
}

// Simple vertical slider for pitch/modulation
struct VerticalSlider: View {
    @Binding var value: Double
    let trackHeight: CGFloat
    let thumbWidth: CGFloat
    let thumbHeight: CGFloat

    var body: some View {
        GeometryReader { geo in
            let availableHeight = trackHeight - thumbHeight
            let y = ((1.0 - value) * availableHeight)

            ZStack {
                // Track
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 2, height: trackHeight)

                // Thumb (using HourglassShape from FaderView)
                HourglassShape()
                    .fill(LinearGradient(
                        gradient: Gradient(colors: [
                            Color(.sRGB, red: 0.7, green: 0.7, blue: 0.7),
                            Color(.sRGB, red: 0.9, green: 0.9, blue: 0.9),
                            Color(.sRGB, red: 0.7, green: 0.7, blue: 0.7)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .overlay(
                        HourglassShape()
                            .stroke(Color.white.opacity(0.2), lineWidth: 2)
                    )
                    .frame(width: thumbWidth, height: thumbHeight)
                    .shadow(color: Color.black.opacity(0.3), radius: 1, x: 0, y: 1)
                    .position(x: geo.size.width / 2, y: y + thumbHeight / 2)
            }
            .frame(width: geo.size.width, height: trackHeight)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let newValue = 1.0 - (drag.location.y / trackHeight)
                        value = min(max(newValue, 0.0), 1.0)
                    }
            )
        }
        .frame(width: 30, height: trackHeight)
    }
}

struct PianoKeyboardView: View {
    @EnvironmentObject var manager: AudioDeviceManager
    @EnvironmentObject var virtualChannelManager: VirtualChannelManager
    @EnvironmentObject var midiManager: MIDIStateManager
    @State private var pressedKeys: Set<Int> = []
    @State private var octaveOffset: Int = 0
    @State private var sustainEnabled: Bool = false
    @State private var pitchBend: Double = 0.5  // Center position
    @State private var modulation: Double = 0.0  // Bottom position
    @State private var selectedVIChannel: Int = -1  // -1 = all channels
    @State private var sustainedKeys: Set<Int> = []  // Keys held by sustain pedal
    @State private var selectedMIDIOutputIndex: Int = -1  // -1 = None (no hardware MIDI output)

    private let virtualInstrumentDeviceID: AudioDeviceID = 999_999
    private let keyboardVIChannelCount: Int = 8

    // 3 octaves: C3 (48) to B5 (83)
    private let startNote = 48
    private let endNote = 83

    // White keys in each octave
    private let whiteKeyOffsets = [0, 2, 4, 5, 7, 9, 11] // C, D, E, F, G, A, B

    // Black keys (relative to C in each octave)
    private let blackKeyOffsets = [1, 3, 6, 8, 10] // C#, D#, F#, G#, A#

    // Parametric spacing properties
    private let whiteKeyWidth: CGFloat = 30
    private let whiteKeyHeight: CGFloat = 120
    private let blackKeyWidth: CGFloat = 20
    private let blackKeyHeight: CGFloat = 75
    private let whiteKeySpacing: CGFloat = 0
    private let blackKeyHorizontalOffset: CGFloat = 2  // Distance from left edge of white key
    private let blackKeyVerticalOffset: CGFloat = 0     // Distance from top (black keys align to top)

    var body: some View {
        HStack(spacing: 0) {
            // Left control panel
            VStack(spacing: 12) {
                // Octave controls
                VStack(alignment: .leading, spacing: 4) {
                    Text("Octave")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        Button(action: {
                            if octaveOffset > -3 {
                                octaveOffset -= 1
                            }
                        }) {
                            Image(systemName: "minus.square.fill")
                                .font(.system(size: 16))
                                .foregroundColor(octaveOffset > -3 ? .primary : .secondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .disabled(octaveOffset <= -3)

                        Text("\(octaveOffset > 0 ? "+" : "")\(octaveOffset)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(minWidth: 25)

                        Button(action: {
                            if octaveOffset < 3 {
                                octaveOffset += 1
                            }
                        }) {
                            Image(systemName: "plus.square.fill")
                                .font(.system(size: 16))
                                .foregroundColor(octaveOffset < 3 ? .primary : .secondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .disabled(octaveOffset >= 3)
                    }
                }

                // Sustain button (horizontal with text)
                HStack(spacing: 8) {
                    Text("Sustain")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(action: {
                        sustainEnabled.toggle()
                        if !sustainEnabled {
                            releaseSustainedKeys()
                        }
                    }) {
                        Rectangle()
                            .fill(sustainEnabled ? Color.green.opacity(0.7) : Color.gray.opacity(0.3))
                            .frame(width: 40, height: 20)
                            .cornerRadius(4)
                            .overlay(
                                Text(sustainEnabled ? "ON" : "OFF")
                                    .font(.caption2)
                                    .foregroundColor(.white)
                            )
                    }
                    .buttonStyle(.plain)
                }

                // Pitch and Modulation sliders in HStack
                HStack(spacing: 8) {
                    // Pitch Bend slider
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pitch")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        VerticalSlider(
                            value: $pitchBend,
                            trackHeight: 100,
                            thumbWidth: 20,
                            thumbHeight: 30
                        )
                        .onChange(of: pitchBend) { newValue in
                            // Reserved for pitch bend CC or pitch bend message routing.
                            // Convert 0.0-1.0 to pitch bend range
                        }
                    }

                    // Modulation slider
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mod")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        VerticalSlider(
                            value: $modulation,
                            trackHeight: 100,
                            thumbWidth: 20,
                            thumbHeight: 30
                        )
                        .onChange(of: modulation) { newValue in
                            // Reserved for modulation CC routing.
                            // Convert 0.0-1.0 to 0-127 MIDI value
                        }
                    }
                }

                Spacer()
            }
            .frame(width: 120)
            .padding(.leading, 12)
            .padding(.vertical, 12)

            // Divider
            Rectangle()
                .fill(Color.primary.opacity(0.2))
                .frame(width: 0.5)

            // Keyboard area
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("On-Screen Keyboard")
                        .font(.headline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(rangeText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            // MIDI Output Device picker (left of VI picker)
                            Picker("MIDI Output", selection: $selectedMIDIOutputIndex) {
                                Text("None").tag(-1)
                                ForEach(Array(allMIDIOutputEndpoints.enumerated()), id: \.offset) { index, endpoint in
                                    Text(midiManager.getEndpointName(endpoint))
                                        .tag(index)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 100)
                            .help(selectedMIDIOutputIndex == -1 ? "No hardware MIDI output" : "Send MIDI to hardware device")

                            Picker("VI Channel", selection: $selectedVIChannel) {
                                Text("All Channels").tag(-1)
                                ForEach(0..<keyboardVIChannelCount, id: \.self) { channel in
                                    Text("Channel \(channel + 1)").tag(channel)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 120)

#if os(macOS)
                            Button(action: {
                                openSelectedVIPlugin()
                            }) {
                                Text("Open VI")
                                    .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .disabled(!canOpenSelectedVIPlugin)
                            .foregroundColor(canOpenSelectedVIPlugin ? .accentColor : .secondary)
                            .help(canOpenSelectedVIPlugin ? "Open selected VI plugin window" : "Select a VI channel with an assigned instrument")
#endif
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

            // Keyboard
            ZStack(alignment: .top) {
                // White keys
                HStack(spacing: whiteKeySpacing) {
                    ForEach(whiteKeyNotes(), id: \.self) { midiNote in
                        WhiteKey(
                            midiNote: midiNote,
                            isPressed: pressedKeys.contains(midiNote),
                            onPress: { pressKey(midiNote) },
                            onRelease: { releaseKey(midiNote) }
                        )
                    }
                }
                .frame(height: whiteKeyHeight)

                // Black keys (overlay)
                HStack(spacing: 7.1) {
                    ForEach(Array(whiteKeyNotes().enumerated()), id: \.offset) { index, whiteNote in
                        if let blackNote = blackKeyAfter(whiteNote) {
                            if blackNote <= endNote {
                                BlackKey(
                                    midiNote: blackNote,
                                    isPressed: pressedKeys.contains(blackNote),
                                    onPress: { pressKey(blackNote) },
                                    onRelease: { releaseKey(blackNote) }
                                )
                                .offset(x: blackKeyHorizontalOffset)
                            } else {
                                Spacer()
                                    .frame(width: whiteKeyWidth)
                            }
                        } else {
                            Spacer()
                                .frame(width: whiteKeyWidth)
                        }
                    }
                }
                .offset(x: whiteKeyWidth * 0.5)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.3))
            .cornerRadius(8)
        }
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        }
        .frame(width: 980, height: 225)
        .background(Color.clear)
    }

    // Computed properties
    private var rangeText: String {
        let actualStartNote = startNote + (octaveOffset * 12)
        let actualEndNote = endNote + (octaveOffset * 12)
        let startNoteName = noteName(for: actualStartNote)
        let endNoteName = noteName(for: actualEndNote)
        return "\(startNoteName) - \(endNoteName)"
    }

    private func noteName(for midiNote: Int) -> String {
        let notes = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = midiNote / 12 - 1
        let note = notes[midiNote % 12]
        return "\(note)\(octave)"
    }

    private func whiteKeyNotes() -> [Int] {
        var notes: [Int] = []
        for octave in 0..<3 {
            for offset in whiteKeyOffsets {
                let note = startNote + octave * 12 + offset
                if note <= endNote {
                    notes.append(note)
                }
            }
        }
        return notes
    }

    private func blackKeyAfter(_ whiteNote: Int) -> Int? {
        let offset = whiteNote % 12
        if offset == 0 { return whiteNote + 1 } // C -> C#
        if offset == 2 { return whiteNote + 1 } // D -> D#
        if offset == 5 { return whiteNote + 1 } // F -> F#
        if offset == 7 { return whiteNote + 1 } // G -> G#
        if offset == 9 { return whiteNote + 1 } // A -> A#
        return nil
    }

    private func pressKey(_ midiNote: Int) {
        pressedKeys.insert(midiNote)
        sustainedKeys.remove(midiNote) // Remove from sustained if pressed again
        triggerNote(midiNote, velocity: 100)
    }

    private func releaseKey(_ midiNote: Int) {
        pressedKeys.remove(midiNote)
        if sustainEnabled {
            // When sustain is on, add to sustained keys instead of releasing
            sustainedKeys.insert(midiNote)
        } else {
            // Normal release
            triggerNote(midiNote, velocity: 0)
        }
    }

    private func releaseSustainedKeys() {
        for midiNote in sustainedKeys {
            triggerNote(midiNote, velocity: 0)
        }
        sustainedKeys.removeAll()
    }

    // Computed property to get all available MIDI output endpoints from all devices
    private var allMIDIOutputEndpoints: [MIDIEndpointRef] {
        midiManager.availableDevices.flatMap { $0.outputEndpoints }
    }

    private func triggerNote(_ midiNote: Int, velocity: UInt8) {
        let transposedNote = midiNote + (octaveOffset * 12)
        let noteByte = UInt8(transposedNote)

        // Send to Virtual Instruments
        if selectedVIChannel == -1 {
            for channelIndex in 0..<keyboardVIChannelCount {
                VirtualInstrumentHostManager.shared.sendMIDINote(
                    for: virtualInstrumentDeviceID,
                    channelIndex: channelIndex,
                    note: noteByte,
                    velocity: velocity
                )
            }
        } else if (0..<keyboardVIChannelCount).contains(selectedVIChannel) {
            VirtualInstrumentHostManager.shared.sendMIDINote(
                for: virtualInstrumentDeviceID,
                channelIndex: selectedVIChannel,
                note: noteByte,
                velocity: velocity
            )
        }

        // Send to hardware MIDI output if selected
        if selectedMIDIOutputIndex >= 0 && selectedMIDIOutputIndex < allMIDIOutputEndpoints.count {
            let endpoint = allMIDIOutputEndpoints[selectedMIDIOutputIndex]
            if velocity == 0 {
                midiManager.sendNoteOff(to: endpoint, note: noteByte)
            } else {
                midiManager.sendNoteOn(to: endpoint, note: noteByte, velocity: velocity)
            }
        }
    }

#if os(macOS)
    private var canOpenSelectedVIPlugin: Bool {
        guard selectedVIChannel >= 0 else { return false }
        return virtualChannelManager.selectedVirtualInstrument(for: virtualInstrumentDeviceID, channelIndex: selectedVIChannel) != nil
    }

    private func openSelectedVIPlugin() {
        guard canOpenSelectedVIPlugin else { return }
        VirtualInstrumentHostManager.shared.showInstrumentEditor(
            for: virtualInstrumentDeviceID,
            channelIndex: selectedVIChannel
        )
    }
#endif
}

struct WhiteKey: View {
    let midiNote: Int
    let isPressed: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    // Parametric dimensions
    private let width: CGFloat = 30
    private let height: CGFloat = 120

    var body: some View {
        Rectangle()
            .fill(isPressed ? Color.gray.opacity(0.5) : Color.white)
            .frame(width: width, height: height)
            .border(Color.black.opacity(0.3), width: 1)
            .overlay(
                Text(noteName)
                    .font(.caption2)
                    .foregroundColor(.black.opacity(0.5))
                    .offset(y: 50)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        onPress()
                    }
                    .onEnded { _ in
                        onRelease()
                    }
            )
    }

    private var noteName: String {
        let notes = ["C", "D", "E", "F", "G", "A", "B"]
        let octave = midiNote / 12 - 1
        let offset = midiNote % 12
        let whiteOffsets = [0, 2, 4, 5, 7, 9, 11]
        if let index = whiteOffsets.firstIndex(of: offset) {
            return "\(notes[index])\(octave)"
        }
        return ""
    }
}

struct BlackKey: View {
    let midiNote: Int
    let isPressed: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    // Parametric dimensions
    private let width: CGFloat = 20
    private let height: CGFloat = 75

    var body: some View {
        Rectangle()
            .fill(isPressed ? Color.gray.opacity(0.7) : Color.black)
            .frame(width: width, height: height)
            .cornerRadius(2)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        onPress()
                    }
                    .onEnded { _ in
                        onRelease()
                    }
            )
    }
}

// MARK: - MIDI CC Control View
struct MIDICCControlView: View {
    @EnvironmentObject var manager: AudioDeviceManager
    @EnvironmentObject var virtualChannelManager: VirtualChannelManager
    @EnvironmentObject var midiManager: MIDIStateManager
    @EnvironmentObject var themeManager: ThemeManager

    private let virtualInstrumentDeviceID: AudioDeviceID = 999_999
    private let keyboardVIChannelCount: Int = 8

    // CC Dial values (2 rows of 8 = 16 dials)
    @State private var dialValues: [Double] = Array(repeating: 0.5, count: 16)

    // Grid button states (4x4 = 16 buttons)
    @State private var gridButtonStates: [Bool] = Array(repeating: false, count: 16)

    // Sequencer step states (1 row of 16)
    @State private var sequencerSteps: [Bool] = Array(repeating: false, count: 16)
    @State private var currentStep: Int = 0
    @State private var isPlaying: Bool = false

    // Routing selections
    @State private var selectedVIChannel: Int = -1
    @State private var selectedMIDIOutputIndex: Int = -1

    // Tempo/Clock
    @State private var tempoBPM: Double = 120.0
    @State private var selectedClockSource: String = "Internal"
    @State private var isClockRunning: Bool = false

    // Timer for sequencer (16th notes)
    @State private var timer = Timer.publish(every: 60.0 / (120.0 * 4.0), on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            // Main control area
            VStack(spacing: 16) {
                // Top: 2 rows of 8 dials
                VStack(spacing: 12) {
                    Text("CC Dials")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 12) {
                            ForEach(0..<8, id: \.self) { col in
                                let index = row * 8 + col
                                CCDialView(
                                    value: $dialValues[index],
                                    ccNumber: index,
                                    label: "CC\(index)",
                                    onChange: { newValue in
                                        sendCCMessage(cc: index, value: Int(newValue * 127))
                                    }
                                )
                                .frame(width: 45, height: 60)
                            }
                        }
                    }
                }

                Divider()

                // Middle: 4x4 grid of interactive buttons
                VStack(spacing: 12) {
                    Text("CC Buttons")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    VStack(spacing: 8) {
                        ForEach(0..<4, id: \.self) { row in
                            HStack(spacing: 8) {
                                ForEach(0..<4, id: \.self) { col in
                                    let index = row * 4 + col
                                    CCButtonView(
                                        isActive: $gridButtonStates[index],
                                        label: "\(index + 1)",
                                        onToggle: { isActive in
                                            // Send CC value 127 for ON, 0 for OFF
                                            // Use CC numbers 16-31 for buttons
                                            sendCCMessage(cc: index + 16, value: isActive ? 127 : 0)
                                        }
                                    )
                                    .frame(width: 50, height: 50)
                                }
                            }
                        }
                    }
                }

                Divider()

                // Bottom: 16-step sequencer
                VStack(spacing: 12) {
                    HStack {
                        Text("Sequencer")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button {
                            isPlaying.toggle()
                            if !isPlaying {
                                currentStep = -1 // Reset to before first step
                            }
                        } label: {
                            Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                                .foregroundColor(isPlaying ? .red : .green)
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 4) {
                        ForEach(0..<16, id: \.self) { index in
                            SequencerStepView(
                                isActive: $sequencerSteps[index],
                                isCurrent: currentStep == index && isPlaying
                            )
                            .frame(width: 28, height: 28)
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Right sidebar
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 1)

            VStack(alignment: .leading, spacing: 16) {
                Text("MIDI Routing")
                    .font(.headline)

                // MIDI Output picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("MIDI Output")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("MIDI Output", selection: $selectedMIDIOutputIndex) {
                        Text("None").tag(-1)
                        ForEach(Array(allMIDIOutputEndpoints.enumerated()), id: \.offset) { index, endpoint in
                            Text(midiManager.getEndpointName(endpoint))
                                .tag(index)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 140)
                }

                // VI Channel picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("VI Channel")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("VI Channel", selection: $selectedVIChannel) {
                        Text("None").tag(-1)
                        Text("All Channels").tag(-2)
                        ForEach(0..<keyboardVIChannelCount, id: \.self) { channel in
                            Text("Ch \(channel + 1)").tag(channel)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 140)
                }

                Divider()

                // Tempo/Clock section
                Text("Tempo & Clock")
                    .font(.headline)

                // Tempo field
                VStack(alignment: .leading, spacing: 4) {
                    Text("BPM")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        TextField("BPM", text: Binding(
                            get: { String(Int(tempoBPM)) },
                            set: { newValue in
                                if let bpm = Double(newValue), bpm >= 20, bpm <= 300 {
                                    tempoBPM = bpm
                                }
                            }
                        ))
                            .frame(width: 60)
                        Stepper("", value: $tempoBPM, in: 20...300, step: 1)
                            .labelsHidden()
                    }
                }

                // Clock source picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("Clock Source")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Clock", selection: $selectedClockSource) {
                        Text("Internal").tag("Internal")
                        Text("MIDI In").tag("MIDI In")
                        Text("System").tag("System")
                    }
                    .pickerStyle(MenuPickerStyle())
                    .frame(width: 140)
                }

                // Tempo "red light" indicator
                VStack(alignment: .leading, spacing: 4) {
                    Text("Clock Sync")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isClockRunning ? Color.red : Color.gray)
                            .frame(width: 16, height: 16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                        Text(isPlaying ? "Running" : "Stopped")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .padding(16)
            .frame(width: 180)
        }
        .frame(width: 900, height: 600)
        .background(Color.clear)
        .onReceive(timer) { _ in
            if isPlaying {
                advanceSequencer()
            }
        }
        .onChange(of: tempoBPM) { newBPM in
            updateTimer(bpm: newBPM)
        }
    }

    private var allMIDIOutputEndpoints: [MIDIEndpointRef] {
        midiManager.availableDevices.flatMap { $0.outputEndpoints }
    }

    private func updateTimer(bpm: Double) {
        let interval = 60.0 / (bpm * 4.0)
        timer = Timer.publish(every: interval, on: .main, in: .common).autoconnect()
    }

    private func sendCCMessage(cc: Int, value: Int) {
        guard selectedMIDIOutputIndex >= 0 else { return }
        let endpoints = allMIDIOutputEndpoints
        guard selectedMIDIOutputIndex < endpoints.count else { return }
        let endpoint = endpoints[selectedMIDIOutputIndex]

        let channel = selectedVIChannel >= 0 ? UInt8(selectedVIChannel) : 0
        midiManager.sendCC(to: endpoint, cc: UInt8(cc), value: UInt8(value), channel: channel)
    }

    private func sendNoteMessage(note: Int, velocity: Int, isOn: Bool) {
        let statusByte = isOn ? UInt8(0x90) : UInt8(0x80)
        UtilityInstrumentManager.shared.handleMIDIMessage(status: statusByte, data1: UInt8(note), data2: UInt8(velocity), sourceEndpoint: "Internal CC Controller")

        guard selectedMIDIOutputIndex >= 0 else { return }
        let endpoints = allMIDIOutputEndpoints
        guard selectedMIDIOutputIndex < endpoints.count else { return }
        let endpoint = endpoints[selectedMIDIOutputIndex]

        let channel = selectedVIChannel >= 0 ? UInt8(selectedVIChannel) : 0
        if isOn {
            midiManager.sendNoteOn(to: endpoint, note: UInt8(note), velocity: UInt8(velocity), channel: channel)
        } else {
            midiManager.sendNoteOff(to: endpoint, note: UInt8(note), channel: channel)
        }
    }

    private func advanceSequencer() {
        currentStep = (currentStep + 1) % 16

        // Blink indicator on beats (every 4 steps)
        if currentStep % 4 == 0 {
            isClockRunning = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isClockRunning = false
            }
        }

        if sequencerSteps[currentStep] {
            // Trigger MIDI note 36 (Kick)
            sendNoteMessage(note: 36, velocity: 100, isOn: true)
            // Note off after 50ms
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                sendNoteMessage(note: 36, velocity: 0, isOn: false)
            }
        }
    }
}

// MARK: - CC Dial View
struct CCDialView: View {
    @Binding var value: Double // 0.0 ... 1.0
    let ccNumber: Int
    let label: String
    var onChange: ((Double) -> Void)? = nil

    var body: some View {
        VStack(spacing: 4) {
            // Simple rotary dial representation
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                    .frame(width: 35, height: 35)
                Circle()
                    .trim(from: 0, to: value)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 35, height: 35)
                    .rotationEffect(.degrees(-90))
                Text("\(Int(value * 127))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let delta = gesture.translation.height / -100
                        let newValue = min(1.0, max(0.0, value + delta))
                        if newValue != value {
                            value = newValue
                            onChange?(newValue)
                        }
                    }
            )

            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - CC Button View
struct CCButtonView: View {
    @Binding var isActive: Bool
    let label: String
    var onToggle: ((Bool) -> Void)? = nil

    var body: some View {
        Button {
            isActive.toggle()
            onToggle?(isActive)
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor : Color.gray.opacity(0.3))
                .overlay(
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isActive ? .white : .primary)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sequencer Step View
struct SequencerStepView: View {
    @Binding var isActive: Bool
    let isCurrent: Bool

    var body: some View {
        Button {
            isActive.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(isActive ? Color.green : Color.gray.opacity(0.2))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isCurrent ? Color.red : Color.clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
    }
}

extension ContentView {

    func updateRoutingMatrixMappings() {
        let inputContexts = manager.activeDevices.values.map { $0 }

        let inputMap: [AudioDeviceID: [Int]] = Dictionary(
            uniqueKeysWithValues: inputContexts.map { context in
                let mask = manager.selectedChannelMasks[context.device.deviceID]
                    ?? Array(repeating: true, count: Int(context.device.inputChannels))
                let indices = mask.enumerated().compactMap { $0.element ? $0.offset : nil }
                return (context.device.deviceID, indices)
            }
        )

        let outputMap = MultiOutputStreamManager.shared.getActiveOutputChannels()

        matrixManager.updateInputs(inputMap)
        matrixManager.updateOutputs(outputMap)

        // Rebuild routing structure + refresh labels
        matrixManager.updateRoutingMatrixMappings()

    }
}
// MARK: - Output Channel Selector
private extension ContentView {
    /// Renders a popover for selecting active output channels, capsule theme, channel strip color, and spectrum size for a device.
    /// - Parameter device: The audio output device whose channels are being configured.
    private func outputChannelSelector(for device: AudioDevice) -> some View {
        let channelCount = Int(outputManager.outputContexts[device.deviceID]?.device.outputChannels ?? device.outputChannels)

        // Ensure the mask is initialized correctly before the view is built
        DispatchQueue.main.async {
            if (outputManager.selectedChannelMasks[device.deviceID]?.count ?? 0) != channelCount {
                outputManager.selectedChannelMasks[device.deviceID] = Array(repeating: true, count: channelCount)
            }
        }

        return VStack(alignment: .leading) {
            Text("Select Output Channels")
                .font(.headline)

            let maskCount = min(channelCount, outputManager.selectedChannelMasks[device.deviceID]?.count ?? 0)

            let channelToggle: (Int) -> Toggle<Text> = { index in
                let isOnBinding = Binding<Bool>(
                    get: {
                        let mask = outputManager.selectedChannelMasks[device.deviceID] ?? Array(repeating: true, count: channelCount)
                        return index < mask.count ? mask[index] : false
                    },
                    set: { newValue in
                        var mask = outputManager.selectedChannelMasks[device.deviceID] ?? Array(repeating: true, count: channelCount)
                        if mask.count != channelCount {
                            mask = Array(repeating: true, count: channelCount)
                        }
                        if index < mask.count {
                            mask[index] = newValue
                            outputManager.updateChannelMask(for: device.deviceID, mask: mask)
                        }
                    }
                )
                return Toggle("Output \(index + 1)", isOn: isOnBinding)
            }

            if channelCount > 8 {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(0..<maskCount, id: \.self, content: channelToggle)
                    }
                }
                .frame(height: 220)
            } else {
                ForEach(0..<maskCount, id: \.self, content: channelToggle)
            }

            Divider().padding(.vertical, 6)

            Text("Capsule Theme")
                .font(.subheadline)

            Picker("Capsule Theme", selection: Binding<ThemeMode>(
                get: {
                    themeManager.deviceCapsuleThemes[device.deviceID] ?? themeManager.capsuleThemeMode
                },
                set: { newTheme in
                    themeManager.deviceCapsuleThemes[device.deviceID] = newTheme
                }
            )) {
                Text("Green").tag(ThemeMode.light)
                Text("Blue").tag(ThemeMode.dark)
                Text("Turquoise").tag(ThemeMode.thinMaterial)
                Text("Chilled").tag(ThemeMode.liquidGlass)
                Text("Purple").tag(ThemeMode.purple)
                Text("Mint").tag(ThemeMode.mint)
                Text("Lavender").tag(ThemeMode.lavender)
                Text("Indigo").tag(ThemeMode.indigo)
                Text("Gray").tag(ThemeMode.gray)
                Text("Hollow").tag(ThemeMode.hollow)
            }
            .pickerStyle(PopUpButtonPickerStyle())


            Divider().padding(.vertical, 6)

            Text("Floating Window Size")
                .font(.subheadline)

            Picker("Scale", selection: Binding<Double>(
                get: {
                    themeManager.deviceSpectrumScaleFactors[device.deviceID] ?? 1.0
                },
                set: { newScale in
                    themeManager.deviceSpectrumScaleFactors[device.deviceID] = newScale
                }
            )) {
                Text("1/8x").tag(0.125)
                Text("1/4x").tag(0.25)
                Text("1/2x").tag(0.5)
                Text("1x").tag(1.0)
                Text("2x").tag(2.0)
                Text("4x").tag(4.0)
            }
            .pickerStyle(PopUpButtonPickerStyle())
        }
    }
}
