/// Ensures the hosting NSWindow is resizable on launch without forcing a fixed size.
/// On legacy macOS we keep the existing window size, but remove accidental min/max locks.
struct MaxWindowOnLaunchConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var didApply = false
    }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = v.window else { return }
            guard context.coordinator.didApply == false else { return }
            context.coordinator.didApply = true

            // Re-enable normal window resizing.
            window.styleMask.insert(.resizable)
            window.standardWindowButton(.zoomButton)?.isEnabled = true

            // Remove any previous fixed-size clamps.
            window.contentMinSize = NSSize(width: 640, height: 720)
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                           height: CGFloat.greatestFiniteMagnitude)
            window.minSize = NSSize(width: 640, height: 720)
            window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                    height: CGFloat.greatestFiniteMagnitude)

            // Persist and restore window position/size across launches.
            // AppKit saves the frame automatically on every move/resize and
            // restores it immediately when setFrameAutosaveName is called.
            window.setFrameAutosaveName("PodcastPreviewMainWindow")
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.styleMask.insert(.resizable)
            window.standardWindowButton(.zoomButton)?.isEnabled = true
        }
    }
}

/// Paints the title bar area (including behind traffic lights) with a solid color.

/// Paints the title bar area (including behind traffic lights) with a solid color.
/// Works with `.windowStyle(.hiddenTitleBar)` and transparent window content.
struct SolidTitlebarColorConfigurator: NSViewRepresentable {
    let color: NSColor

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var didApply = false
        var accessory: NSTitlebarAccessoryViewController?
        var didInstallResizeHook = false
        var resizeObserver: NSObjectProtocol?
    }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = v.window else { return }
            guard context.coordinator.didApply == false else { return }
            context.coordinator.didApply = true

            // Ensure the titlebar isn't composited from the content behind it.
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = false

            // If we already installed an accessory, remove it first.
            if let existing = context.coordinator.accessory,
               let idx = window.titlebarAccessoryViewControllers.firstIndex(of: existing) {
                window.removeTitlebarAccessoryViewController(at: idx)
                context.coordinator.accessory = nil
            }

            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .top

            let barView = NSView(frame: .zero)
            barView.wantsLayer = true
            barView.layer?.backgroundColor = color.cgColor

            // Fill the accessory container using autoresizing (more reliable on first show).
            barView.translatesAutoresizingMaskIntoConstraints = true
            barView.autoresizingMask = [.width, .height]
            accessory.view = barView

            window.addTitlebarAccessoryViewController(accessory)
            context.coordinator.accessory = accessory

            // Ensure it always fills after the window finishes attaching/layout.
            DispatchQueue.main.async {
                barView.frame = accessory.view.bounds
            }

            // Keep it filled on window resizes.
            if context.coordinator.didInstallResizeHook == false {
                context.coordinator.didInstallResizeHook = true
                context.coordinator.resizeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    barView.frame = accessory.view.bounds
                }
            }
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Keep the installed bar view color in sync if the configurator is rebuilt.
        if let barView = context.coordinator.accessory?.view {
            barView.wantsLayer = true
            barView.layer?.backgroundColor = color.cgColor
        }
    }
}
//  MainWindowView.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 07/12/2025.
//



import SwiftUI
import AppKit
import Foundation
import PodcastPreviewShared

enum AppMode: Hashable, CaseIterable {
    case visualiser
    case video
    case audio
    case hardwareStats
    case remoteHardware
}

private extension AppMode {
    var title: String {
        switch self {
        case .video:
            return "Video"
        case .audio:
            return "Audio"
        case .visualiser:
            return "Visualiser"
        case .hardwareStats:
            return "Hardware"
        case .remoteHardware:
            return "Remote"
        }
    }

    var systemImageName: String {
        switch self {
        case .video:
            if #available(macOS 13.0, *) {
                return "camera.metering.partial"
            } else {
                return "video"
            }
        case .audio:
            return "waveform"
        case .visualiser:
            return "waveform.path.ecg.rectangle"
        case .hardwareStats:
            if #available(macOS 13.0, *) {
                return "cpu.fill"
            } else {
                return "cpu"
            }
        case .remoteHardware:
            return "network"
        }
    }
}

// MARK: - Background Layers

struct BackgroundLayers: View {
    let cornerRadius: CGFloat
    @Environment(\.poorMansGlassTuningOverride) private var poorMansGlassTuningOverride

    private var backdropStrength: Double {
        let tuning = poorMansGlassTuningOverride ?? .releaseBigSurFallback
        return min(max(Double(tuning.intensity * tuning.haze), 0.05), 2.20)
    }

    var body: some View {
        ZStack {
            TransparentWindowConfigurator(
                cornerRadius: cornerRadius,
                titlebarOverlayColor: NSColor.black.withAlphaComponent(0.06 * backdropStrength)
            )
                .ignoresSafeArea()

            MaxWindowOnLaunchConfigurator()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

            GlassBackground(.hud,
                            cornerRadius: cornerRadius,
                            shape: ThemeRoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .ignoresSafeArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            GraphiteSlateWindowOverlay(backdropStrength: backdropStrength)
        }
    }
}

struct LegacyBackgroundLayers: View {
    let cornerRadius: CGFloat
    @Environment(\.poorMansGlassTuningOverride) private var poorMansGlassTuningOverride

    private var backdropStrength: Double {
        let tuning = poorMansGlassTuningOverride ?? .releaseBigSurFallback
        return min(max(Double(tuning.intensity * tuning.haze), 0.05), 2.20)
    }

    var body: some View {
        ZStack {
            TransparentWindowConfigurator(
                cornerRadius: cornerRadius,
                titlebarOverlayColor: NSColor.black.withAlphaComponent(0.06 * backdropStrength)
            )
                .ignoresSafeArea()

            MaxWindowOnLaunchConfigurator()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)

            GlassBackground(.hud,
                            cornerRadius: cornerRadius,
                            shape: ThemeRoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .ignoresSafeArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            GraphiteSlateWindowOverlay(backdropStrength: backdropStrength)
        }
    }
}

// MARK: - Mode Selector

struct ModeSelector: View {
    @Binding var mode: AppMode
    let topPadding: CGFloat
    let innerPadding: CGFloat
    private let tabChipHeight: CGFloat = 28

    var body: some View {
        HStack {
            Spacer()

            HStack(spacing: 4) {
                ForEach(AppMode.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            mode = tab
                        }
                    } label: {
                        ZStack {
                            if mode == tab {
                                GraphiteSlatePillBackground(isActive: true)
                            }
                            HStack(spacing: 6) {
                                Image(systemName: tab.systemImageName)
                                Text(tab.title)
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundColor(
                            mode == tab ? Color.white.opacity(0.96) : Color.white.opacity(0.72)
                        )
                        .padding(.vertical, 5)
                        .padding(.horizontal, 11)
                        .frame(height: tabChipHeight)
                        .fixedSize(horizontal: true, vertical: true)
                        .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(tab.title))
                }

                ThemeMenuButton(chipHeight: tabChipHeight)
            }
            .fixedSize(horizontal: true, vertical: true)
            .padding(innerPadding)
            .background(GraphiteSlatePillBackground())
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(GraphiteSlateTheme.separator, lineWidth: 1)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5)
                    .blendMode(.overlay)
            )
            .shadow(color: GraphiteSlateTheme.shadow, radius: 12, x: 0, y: 5)

            Spacer()
        }
        .padding(.top, topPadding)
        .fixedSize(horizontal: false, vertical: true)
        .zIndex(1000)
    }
}

// MARK: - Spectrum Container

struct SpectrumContainerView: View {
    @ObservedObject var monitoring: MonitoringState
    @Binding var fftSize: Int
    @Binding var decay: SpectrumView.DecayOption
    @Binding var freqRange: SpectrumView.FrequencyRangePreset
    @Binding var waveformHistoryDuration: TimeInterval
    let minHeight: CGFloat
    let topPadding: CGFloat
    let horizontalPadding: CGFloat
    let bottomPadding: CGFloat
    let appUIScale: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // Waveform history card
            ZStack {
                ThemeRoundedRectangle(cornerRadius: 16).themed(fill: Color.black.opacity(0.12), stroke: Color.white.opacity(0.12))

                WaveformHistoryView(
                    monitoring: monitoring,
                    historyDuration: $waveformHistoryDuration
                )
            }
            .frame(height: max(minHeight, 80))  // min height for waveform
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)

            Spacer()
                .frame(height: 10)  // Fixed spacer

            // Spectrum analyzer card
            ZStack {
                ThemeRoundedRectangle(cornerRadius: 16).themed(fill: Color.black.opacity(0.12), stroke: Color.white.opacity(0.12))

                SpectrumView(monitoring: monitoring,
                            fftSize: $fftSize,
                            decay: $decay,
                            selectedFreqRange: $freqRange)
                    .padding(12)
            }
            .frame(height: max(minHeight, 260))  // Ensure minimum height
            .padding(.horizontal, horizontalPadding)
            .contentShape(ThemeRoundedRectangle(cornerRadius: 16))
            .floatingMonitorContextMenu(cardKind: .spectrum, source: .local)

            Spacer()
                .frame(height: 10)  // Fixed spacer

        }
        .padding(.bottom, (bottomPadding / 2))
    }
}




// MARK: - Audio Sidebar

struct AudioSidebarView: View {
    @ObservedObject var monitoring: MonitoringState
    @Binding var showColorPicker: Bool
    @Binding var showPeakHoldPicker: Bool
    @Binding var showCalibrationPicker: Bool
    @Binding var hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double
    @Binding var selectedHold: TimeInterval

    // Spectrum controls
    @Binding var fftSize: Int
    @Binding var spectrumDecay: SpectrumView.DecayOption
    @Binding var spectrumFreqRange: SpectrumView.FrequencyRangePreset

    let includeBufferSizePicker: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio Input Device")
                .font(.headline)

            DevicePickerView(monitoring: monitoring)

            if includeBufferSizePicker {
                BufferSizePickerView(monitoring: monitoring)
            }

            if let device = monitoring.selectedDevice {
                DeviceInfoCard(monitoring: monitoring)

                MeterColorButton(
                    showColorPicker: $showColorPicker,
                    device: device,
                    hue: $hue,
                    saturation: $saturation,
                    brightness: $brightness
                )

                PeakHoldButton(
                    showPeakHoldPicker: $showPeakHoldPicker,
                    selectedHold: $selectedHold
                )

                if includeBufferSizePicker {
                    CalibrationButton(
                        showCalibrationPicker: $showCalibrationPicker,
                        monitoring: monitoring
                    )
                }

                Text("Spectrum")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 6)

                // Channel selector (only show if multi-channel)
                if monitoring.channelCount > 1 {
                    SpectrumChannelButton(monitoring: monitoring)
                }

                SpectrumFrequencyRangeButton(
                    selectedRange: $spectrumFreqRange,
                    monitoring: monitoring
                )

                SpectrumFFTSizeButton(fftSize: $fftSize)

                SpectrumDecayButton(decay: $spectrumDecay)
            }
        }
    }
}

// MARK: - Buffer Size Picker

struct BufferSizePickerView: View {
    @ObservedObject var monitoring: MonitoringState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Buffer size")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("Buffer size", selection: $monitoring.bufferSizeFrames) {
                Text("128 frames (low latency)").tag(UInt32(128))
                Text("256 frames").tag(UInt32(256))
                Text("512 frames (default)").tag(UInt32(512))
                Text("1024 frames (stable)").tag(UInt32(1024))
                Text("2048 frames (very stable)").tag(UInt32(2048))
            }
            .pickerStyle(.menu)
        }
        .onChange(of: monitoring.bufferSizeFrames) { _ in
            if monitoring.selectedDevice != nil {
                monitoring.applyBufferSizeChange()
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Device Info Card

struct DeviceInfoCard: View {
    @ObservedObject var monitoring: MonitoringState

    var body: some View {
        let peakDB = Double(MeterScale.dbFS(fromLinear: monitoring.uiMeteringResult.peak,
                                            minDB: MeterScale.defaultMinDB)) + Double(monitoring.meterCalibrationDB)
        let rmsDB = Double(MeterScale.dbFS(fromLinear: monitoring.uiMeteringResult.rms,
                                           minDB: MeterScale.defaultMinDB)) + Double(monitoring.meterCalibrationDB)

        VStack(alignment: .leading, spacing: 4) {
            Text("Source: \(monitoring.displayName)")
            Text("Channels: \(monitoring.channelMetering.count)")

            if monitoring.displaySampleRate > 0 {
                let rateKHz = monitoring.displaySampleRate / 1000.0
                Text(String(format: "Sample rate: %.1f kHz", rateKHz))
            }

            if !monitoring.displayManufacturer.isEmpty {
                Text("Manufacturer: \(monitoring.displayManufacturer)")
            }

            Text("Connection: \(monitoring.displayConnection)")

            Text("Peak: \(peakDB, specifier: "%.0f") dB")
                .foregroundColor(peakDB > -3 ? .red : (peakDB > -12 ? .orange : .primary))
            Text("RMS: \(rmsDB, specifier: "%.0f") dB")
                .foregroundColor(rmsDB > -3 ? .red : (rmsDB > -12 ? .orange : .primary))
        }
        .font(.caption2)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .graphiteSurface(.panel, cornerRadius: 16)
    }
}

// MARK: - Meter Color Button

struct MeterColorButton: View {
    @Binding var showColorPicker: Bool
    let device: AudioDeviceModel
    @Binding var hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double

    var body: some View {
        Button {
            showColorPicker.toggle()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(device.themeColor)
                    .frame(width: 14, height: 14)
                Text("Meter colour")
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .popover(isPresented: $showColorPicker) {
            ColorPickerPopover(
                device: device,
                hue: $hue,
                saturation: $saturation,
                brightness: $brightness
            )
        }
    }
}

// MARK: - Color Picker Popover

struct ColorPickerPopover: View {
    let device: AudioDeviceModel
    @Binding var hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meter colour")
                .font(.headline)

            let currentColor = Color(
                hue: hue,
                saturation: saturation,
                brightness: brightness
            )

            ThemeRoundedRectangle(cornerRadius: 16).themed(fill: currentColor, stroke: Color.white.opacity(0.2))
                .frame(height: 32)

            VStack(alignment: .leading, spacing: 6) {
                Text("Hue")
                    .font(.caption)
                Slider(value: $hue, in: 0...1)

                Text("Saturation")
                    .font(.caption)
                Slider(value: $saturation, in: 0...1)

                Text("Brightness")
                    .font(.caption)
                Slider(value: $brightness, in: 0...1)
            }
            .onChange(of: hue) { _ in updateDeviceColor() }
            .onChange(of: saturation) { _ in updateDeviceColor() }
            .onChange(of: brightness) { _ in updateDeviceColor() }
        }
        .padding()
        .frame(width: 260)
        .onAppear {
            syncFromDeviceColor()
        }
    }

    private func updateDeviceColor() {
        device.themeColor = Color(
            hue: hue,
            saturation: saturation,
            brightness: brightness
        )
    }

    private func syncFromDeviceColor() {
        let nsColor = NSColor(device.themeColor)
        if let rgb = nsColor.usingColorSpace(.deviceRGB) {
            var h: CGFloat = 0
            var s: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            hue = Double(h)
            saturation = Double(s)
            brightness = Double(b)
        }
    }
}

// MARK: - Peak Hold Button

struct PeakHoldButton: View {
    @Binding var showPeakHoldPicker: Bool
    @Binding var selectedHold: TimeInterval

    var body: some View {
        Button {
            showPeakHoldPicker.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                Text("Peak hold")
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .popover(isPresented: $showPeakHoldPicker) {
            PeakHoldPopover(selectedHold: $selectedHold)
        }
    }
}

// MARK: - Peak Hold Popover

struct PeakHoldPopover: View {
    @Binding var selectedHold: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Peak hold duration")
                .font(.headline)

            Picker("", selection: $selectedHold) {
                Text("0.5s").tag(0.5 as TimeInterval)
                Text("1s").tag(1.0 as TimeInterval)
                Text("2s").tag(2.0 as TimeInterval)
            }
            .pickerStyle(.radioGroup)

            Text("Controls how long the white peak bar is held before dropping.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 260)
        .onAppear {
            selectedHold = MetalMeterView.holdDuration
        }
        .onChange(of: selectedHold) { newValue in
            MetalMeterView.holdDuration = newValue
        }
    }
}

// MARK: - Calibration Button

struct CalibrationButton: View {
    @Binding var showCalibrationPicker: Bool
    @ObservedObject var monitoring: MonitoringState

    var body: some View {
        Button {
            showCalibrationPicker.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                Text("Calibration")
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .popover(isPresented: $showCalibrationPicker) {
            CalibrationPopover(monitoring: monitoring)
        }
    }
}

// MARK: - Calibration Popover

struct CalibrationPopover: View {
    @ObservedObject var monitoring: MonitoringState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meter Calibration")
                .font(.headline)

            HStack {
                Text("Gain:")
                    .frame(width: 50, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(monitoring.meterCalibrationDB) },
                    set: { monitoring.meterCalibrationDB = Float($0) }
                ),
                       in: -20...20,
                       step: 0.5)

                if #available(macOS 12.0, *) {
                    Text(String(format: "%+.1f dB", monitoring.meterCalibrationDB))
                        .frame(width: 60, alignment: .trailing)
                        .monospacedDigit()
                } else {
                    Text(String(format: "%+.1f dB", monitoring.meterCalibrationDB))
                        .frame(width: 60, alignment: .trailing)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Button("Reset to 0 dB") {
                monitoring.meterCalibrationDB = 0.0
            }
            .buttonStyle(.bordered)

            Text("Adjusts input gain for all meters. Use positive values if your signal is consistently quiet.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 300)
    }
}

// MARK: - Audio Content View

struct AudioContentView: View {
    @Environment(\.appUIScale) private var appUIScale
    @ObservedObject var monitoring: MonitoringState
    @Binding var showColorPicker: Bool
    @Binding var showPeakHoldPicker: Bool
    @Binding var showCalibrationPicker: Bool
    @Binding var hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double
    @Binding var selectedHold: TimeInterval

    // Spectrum controls
    @Binding var fftSize: Int
    @Binding var spectrumDecay: SpectrumView.DecayOption
    @Binding var spectrumFreqRange: SpectrumView.FrequencyRangePreset

    let sidebarWidth: CGFloat
    let meterSpacing: CGFloat
    let includeBufferSizePicker: Bool

    var body: some View {
        HStack(spacing: meterSpacing) {
            AudioSidebarView(
                monitoring: monitoring,
                showColorPicker: $showColorPicker,
                showPeakHoldPicker: $showPeakHoldPicker,
                showCalibrationPicker: $showCalibrationPicker,
                hue: $hue,
                saturation: $saturation,
                brightness: $brightness,
                selectedHold: $selectedHold,
                fftSize: $fftSize,
                spectrumDecay: $spectrumDecay,
                spectrumFreqRange: $spectrumFreqRange,
                includeBufferSizePicker: includeBufferSizePicker
            )
            .frame(width: sidebarWidth, alignment: .leading)
            .padding(16 * appUIScale)
            .graphiteSidebarChrome(separatorEdge: .trailing)

            if monitoring.selectedDevice != nil {
                MeterView(monitoring: monitoring)
            }
        }
    }
}

struct LocalRemoteConsentSheetPresenter: View {
    @ObservedObject private var manager = RemoteHardwareManager.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .sheet(item: Binding(
                get: { manager.localPendingAuthRequest },
                set: { _ in }
            )) { request in
                LocalRemoteConsentDialog(request: request, manager: manager)
            }
    }
}

struct MainWindowView: View {
     @Environment(\.appUIScale) private var appUIScale

     @State private var mode: AppMode = .hardwareStats

     #if DEBUG
    @AppStorage("theme.visualEffectOverride") private var effectOverrideRaw: String = VisualEffectOverride.auto.rawValue
    #endif

    @AppStorage("graph.showGridlines") private var graphShowGridlines: Bool = true

    var body: some View {
        let usesEdgeToEdgeContent: Bool = mode == .hardwareStats || mode == .visualiser
        let contentPadding: CGFloat = usesEdgeToEdgeContent ? 0 : 20 * appUIScale
        let modeBubbleTopPadding: CGFloat = 36
        let modeBubbleInnerPadding = 8 * appUIScale

        Group {
            if #available(macOS 13.0, *) {
                NavigationStack {
                    ZStack(alignment: .top) {
                        let windowCornerRadius: CGFloat = 16

                        BackgroundLayers(cornerRadius: windowCornerRadius)

                        VStack(spacing: 0) {
                            mainContent(
                                contentPadding: contentPadding
                            )
                            .padding(.vertical, usesEdgeToEdgeContent ? 0 : 4)
                        }
                        .padding(.bottom, usesEdgeToEdgeContent ? 0 : 16 * appUIScale)

                        GraphiteSlateWindowRim(cornerRadius: windowCornerRadius)
                            .zIndex(900)

                        ModeSelector(
                            mode: $mode,
                            topPadding: modeBubbleTopPadding,
                            innerPadding: modeBubbleInnerPadding
                        )
                    }
                    .ignoresSafeArea(.all)
                    .hideScrollIndicators()
                    .navigationTitle("AVDash")
                }
                .environment(\.graphShowGridlines, graphShowGridlines)
                .background(Color.clear)
#if DEBUG
                .applyDevVisualEffectEnvironment()
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        let selection = Binding<VisualEffectOverride>(
                            get: { VisualEffectOverride(rawValue: effectOverrideRaw) ?? .auto },
                            set: { effectOverrideRaw = $0.rawValue }
                        )
                        Picker("Visual Theme", selection: selection) {
                            ForEach(VisualEffectOverride.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    ToolbarItem(placement: .automatic) {
                        DevPoorMansGlassTuningMenu()
                    }
                }
#endif
            } else {
                ZStack(alignment: .top) {
                        let windowCornerRadius: CGFloat = 16

                        LegacyBackgroundLayers(cornerRadius: windowCornerRadius)

                        VStack {
                            mainContent(
                                contentPadding: contentPadding
                            )

                            Spacer()
                        }
                        .padding(.bottom, usesEdgeToEdgeContent ? 0 : 16 * appUIScale)

                        GraphiteSlateWindowRim(cornerRadius: windowCornerRadius)
                            .zIndex(900)

                        ModeSelector(
                            mode: $mode,
                            topPadding: modeBubbleTopPadding,
                            innerPadding: modeBubbleInnerPadding
                        )
                    }
                //.background(Color.black.opacity(0.1))
#if DEBUG
                .applyDevVisualEffectEnvironment()
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        let selection = Binding<VisualEffectOverride>(
                            get: { VisualEffectOverride(rawValue: effectOverrideRaw) ?? .auto },
                            set: { effectOverrideRaw = $0.rawValue }
                        )
                        Picker("Visual Theme", selection: selection) {
                            ForEach(VisualEffectOverride.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    ToolbarItem(placement: .automatic) {
                        DevPoorMansGlassTuningMenu()
                    }
                }
            #endif
            }
        }
        .ignoresSafeArea(.all)
        .applyThemeEnvironment()
        .background(LocalRemoteConsentSheetPresenter())
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func mainContent(
        contentPadding: CGFloat
    ) -> some View {
        switch mode {
        case .video:
            VideoView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .audio:
            PodcastPreviewAudioTabView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .visualiser:
            EmbeddedVisualiserTabView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .hardwareStats:
            HardwareStatsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .remoteHardware:
            RemoteHardwareTab()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(contentPadding)
        }
    }
}

// MARK: - Spectrum Control Buttons

struct SpectrumChannelButton: View {
    @ObservedObject var monitoring: MonitoringState

    var body: some View {
        Button {
            guard monitoring.channelCount > 0 else { return }
            let nextChannel = (monitoring.selectedSpectrumChannel + 1) % monitoring.channelCount
            monitoring.selectedSpectrumChannel = nextChannel
        } label: {
            HStack {
                Image(systemName: "waveform.circle")
                Text("Channel")
                Spacer()
                Text("Ch \(monitoring.selectedSpectrumChannel + 1)")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SpectrumFrequencyRangeButton: View {
    @Binding var selectedRange: SpectrumView.FrequencyRangePreset
    @ObservedObject var monitoring: MonitoringState

    private var rangeBinding: Binding<SpectrumView.FrequencyRangePreset> {
        Binding(
            get: { selectedRange },
            set: { preset in
                selectedRange = preset
                monitoring.spectrumMinFreqHz = preset.minHz
                monitoring.spectrumMaxFreqHz = preset.maxHz
            }
        )
    }

    var body: some View {
        HStack {
            Image(systemName: "waveform.path")
            Text("Range")
            Spacer()

            Picker("Range", selection: rangeBinding) {
                ForEach(SpectrumView.FrequencyRangePreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SpectrumFFTSizeButton: View {
    @Binding var fftSize: Int
    private let fftSizeOptions: [Int] = [512, 1024, 2048, 4096]

    var body: some View {
        HStack {
            Image(systemName: "chart.bar")
            Text("FFT Size")
            Spacer()

            Picker("FFT Size", selection: $fftSize) {
                ForEach(fftSizeOptions, id: \.self) { size in
                    Text("\(size)").tag(size)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SpectrumDecayButton: View {
    @Binding var decay: SpectrumView.DecayOption

    var body: some View {
        HStack {
            Image(systemName: "timer")
            Text("Decay")
            Spacer()

            Picker("Decay", selection: $decay) {
                ForEach(SpectrumView.DecayOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Scroll Indicators Extension

private struct ScrollIndicatorsHider: NSViewRepresentable {
    func makeNSView(context: Context) -> HiderView {
        let view = HiderView()
        view.scheduleApply(resetMissingScrollViewRetries: true)
        return view
    }

    func updateNSView(_ nsView: HiderView, context: Context) {
        nsView.scheduleApply(resetMissingScrollViewRetries: false)
    }

    final class HiderView: NSView {
        private static let missingScrollViewRetryLimit = 12
        private static let missingScrollViewRetryDelay: TimeInterval = 0.05

        private var didScheduleApply = false
        private var missingScrollViewRetryCount = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleApply(resetMissingScrollViewRetries: true)
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleApply(resetMissingScrollViewRetries: true)
        }

        override func layout() {
            super.layout()
            scheduleApply(resetMissingScrollViewRetries: false)
        }

        private func applyScrollIndicatorHiding() {
            guard let scrollView = enclosingScrollView(from: self) else {
                scheduleMissingScrollViewRetry()
                return
            }

            missingScrollViewRetryCount = 0
            guard scrollView.hasVerticalScroller ||
                    scrollView.hasHorizontalScroller ||
                    scrollView.verticalScroller?.isHidden == false ||
                    scrollView.horizontalScroller?.isHidden == false ||
                    (scrollView.verticalScroller?.alphaValue ?? 0) > 0 ||
                    (scrollView.horizontalScroller?.alphaValue ?? 0) > 0 else {
                return
            }

            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            scrollView.verticalScroller?.isHidden = true
            scrollView.horizontalScroller?.isHidden = true
            scrollView.verticalScroller?.alphaValue = 0
            scrollView.horizontalScroller?.alphaValue = 0
        }

        func scheduleApply(resetMissingScrollViewRetries: Bool) {
            if resetMissingScrollViewRetries {
                missingScrollViewRetryCount = 0
            }
            scheduleApply(after: 0)
        }

        private func scheduleMissingScrollViewRetry() {
            guard missingScrollViewRetryCount < Self.missingScrollViewRetryLimit else { return }
            missingScrollViewRetryCount += 1
            scheduleApply(after: Self.missingScrollViewRetryDelay)
        }

        private func scheduleApply(after delay: TimeInterval) {
            guard didScheduleApply == false else { return }
            didScheduleApply = true
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.didScheduleApply = false
                self.applyScrollIndicatorHiding()
            }
        }

        private func enclosingScrollView(from view: NSView) -> NSScrollView? {
            var current: NSView? = view
            var found: NSScrollView?
            while let candidate = current {
                if let scrollView = candidate.enclosingScrollView {
                    found = scrollView
                }
                current = candidate.superview
            }
            return found
        }
    }
}

extension View {
    func hideScrollIndicators() -> some View {
        #if os(macOS)
        if #available(macOS 13.0, *) {
            return AnyView(
                self
                    .scrollIndicators(.hidden)
            )
        } else {
            return AnyView(
                self.background(ScrollIndicatorsHider().frame(width: 0, height: 0))
            )
        }
        #else
        return AnyView(self.scrollIndicators(.hidden))
        #endif
    }
}

#Preview {
    MainWindowView()
}

#if DEBUG
#Preview("Video View") {
    VideoView()
        .frame(width: 980, height: 620)
}
#endif
