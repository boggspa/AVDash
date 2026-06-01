import SwiftUI
import Combine
import Accelerate
import AudioToolbox

struct OutputMeteringGroupView: View {
    let deviceID: AudioDeviceID
    var cardWidth: CGFloat? = nil
    var tickMarkYOffset: CGFloat = 0
    var tickMarkYOffsetCPU: CGFloat = 0
    var channelHeaderYOffset: CGFloat = 32
    var channelHeaderYOffsetCPU: CGFloat = 32
    var capsuleYOffset: CGFloat = -14
    var featureControlsTopPadding: CGFloat = 24
    var featureControlsBottomPadding: CGFloat = -85
    var featureControlsLeadingNudge: CGFloat = 2
    var featureControlsYOffset: CGFloat = 0
    var spectrumIconYOffset: CGFloat = 0
    var spectrogramIconYOffset: CGFloat = 0
    var waveformIconYOffset: CGFloat = 0
    var contentYOffset: CGFloat = 0
    @EnvironmentObject var outputManager: OutputDeviceManager
    @EnvironmentObject var themeManager: ThemeManager
    @ObservedObject private var settings = VisualisationSettings.shared
    // Feature toggles for visualizers - per channel
    @State private var showSpectrum: [Int: Bool] = [:]
    @State private var showSpectrogram: [Int: Bool] = [:]
    @State private var showWaveform: [Int: Bool] = [:]
    @State private var rmsDbValues: [Int: Float] = [:]
    @State private var rmsDisplayTexts: [Int: String] = [:]
    @State private var lastRmsTextUpdate: [Int: Date] = [:]
    @State private var spectrogramFeeds: [Int: MixerSpectrogramFeed?] = [:]
    private let floatingWindowController = FloatingWindowController.shared

    private let rmsTextUpdateInterval: TimeInterval = 0.6

    var body: some View {
        Group {
            if let device = outputManager.outputDevices.first(where: { $0.deviceID == deviceID }) {
                outputMeterTile(deviceID: deviceID, device: device)
            } else {
                EmptyView()
            }
        }
    }
}

extension OutputMeteringGroupView {
    private func outputMeterTile(deviceID: AudioDeviceID, device: AudioDevice) -> AnyView {
        let selectedIndices: [Int]
        if let mask = outputManager.selectedChannelMasks[deviceID], mask.count == Int(device.outputChannels) {
            selectedIndices = mask.enumerated().compactMap { $0.element ? $0.offset : nil }
        } else {
            selectedIndices = Array(0..<Int(device.outputChannels))
        }
        let grouped: [[Int]] = stride(from: 0, to: selectedIndices.count, by: 64).map {
            Array(selectedIndices[$0..<min($0 + 64, selectedIndices.count)])
        }

        return AnyView(
            ZStack(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(themeManager.accentFillColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                VStack(alignment: .center, spacing: 8) {
                    ForEach(grouped, id: \.self) { group in
                        outputCapsuleRow(
                            deviceID: deviceID,
                            group: group,
                            channelHeaderYOffset: channelHeaderYOffset,
                            channelHeaderYOffsetCPU: channelHeaderYOffsetCPU,
                            capsuleYOffset: capsuleYOffset,
                            tickMarkYOffset: tickMarkYOffset,
                            tickMarkYOffsetCPU: tickMarkYOffsetCPU
                        )
                    }
                }
                .padding()
                .offset(y: -32)
            }
            .frame(
                width: cardWidth ?? (CGFloat(selectedIndices.count) * 15.2 * 1.05 + 24),
                height: 415
            )
            .onAppear {
                MeterUpdateCoordinator.shared.start()
                for channelIndex in selectedIndices {
                    refreshPeakDisplay(channelIndex: channelIndex)
                }
            }
            .onReceive(MeterUpdateCoordinator.shared.publisher) { _ in
                for channelIndex in selectedIndices {
                    refreshPeakDisplay(channelIndex: channelIndex)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .floatingSpectrumWindowDidClose)) { notification in
                if let channelIndex = notification.floatingWindowChannelIndex(deviceID: deviceID, suffix: "spectrum") {
                    showSpectrum[channelIndex] = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .floatingWaveformWindowDidClose)) { notification in
                if let channelIndex = notification.floatingWindowChannelIndex(deviceID: deviceID, suffix: "waveform") {
                    showWaveform[channelIndex] = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .floatingSpectrogramWindowDidClose)) { notification in
                if let channelIndex = notification.floatingWindowChannelIndex(deviceID: deviceID, suffix: "spectrogram") {
                    showSpectrogram[channelIndex] = false
                    spectrogramFeeds[channelIndex]??.stop()
                    spectrogramFeeds[channelIndex] = nil
                }
            }
        )
    }

    private func outputCapsuleRow(deviceID: AudioDeviceID, group: [Int], channelHeaderYOffset: CGFloat = 18, channelHeaderYOffsetCPU: CGFloat = 42, capsuleYOffset: CGFloat = 0, tickMarkYOffset: CGFloat = 0, tickMarkYOffsetCPU: CGFloat = -8) -> some View {
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
            -100: ("-∞",   0.96)
        ]

        let isCPUBackend = RenderBackendResolver.resolveMeterBackend() == .cpu
        let effectiveTickMarkYOffset = isCPUBackend ? tickMarkYOffsetCPU : tickMarkYOffset

        return HStack(alignment: .bottom, spacing: 4.5) {
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

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(group, id: \.self) { channelIndex in
                    if let ctx = outputManager.outputContexts[deviceID] {
                        MetalOutputCapsuleWithText(
                            channelIndex: channelIndex,
                            deviceID: deviceID,
                            handler: ctx.handler,
                            channelHeaderYOffset: channelHeaderYOffset,
                            channelHeaderYOffsetCPU: channelHeaderYOffsetCPU,
                            capsuleYOffset: capsuleYOffset,
                            showDbLabel: false,
                            rmsText: rmsDisplayTexts[channelIndex] ?? "−∞",
                            rmsDb: rmsDbValues[channelIndex] ?? -100.0,
                            showsRmsText: true,
                            showsFeatureIcons: true,
                            spectrumIconOn: showSpectrum[channelIndex] ?? false,
                            spectrogramIconOn: showSpectrogram[channelIndex] ?? false,
                            waveformIconOn: showWaveform[channelIndex] ?? false,
                            onToggleSpectrum: {
                                toggleSpectrum(channelIndex: channelIndex, channelCount: group.count)
                            },
                            onToggleSpectrogram: {
                                toggleSpectrogram(channelIndex: channelIndex, channelCount: group.count)
                            },
                            onToggleWaveform: {
                                toggleWaveform(channelIndex: channelIndex)
                            }
                        )
                        .frame(width: 12.8, height: 280)
                    }
                }
            }
        }
        .offset(x: -6.4, y: 2.4 + contentYOffset)
    }

    // MARK: - Toggle Functions

    private func toggleSpectrum(channelIndex: Int, channelCount: Int) {
        showSpectrum[channelIndex, default: false].toggle()
        let scale = themeManager.deviceSpectrumScaleFactors[deviceID] ?? 1.0

        if showSpectrum[channelIndex] ?? false {
            let fftSize = settings.spectrumFFTSize
            let source = MixerVisualizerAudioSource(
                source: .output(deviceID: deviceID, channelIndex: channelIndex)
            )
            let processor = SafeFFTSpectrumProcessor(
                streamManager: source,
                channelIndex: channelIndex,
                channelCount: channelCount,
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
        showSpectrogram[channelIndex, default: false].toggle()
        if showSpectrogram[channelIndex] ?? false {
            let pickedTheme = themeManager.deviceCapsuleThemes[deviceID] ?? themeManager.capsuleThemeMode
            let simdTheme = simdColor(from: spectrumLineColor(for: SpectrumThemeMode(from: pickedTheme)))
            let uDeviceID = UInt32(deviceID)

            guard SpectroManager.shared.acquireExternalSpectrogramSession(
                deviceID: uDeviceID,
                channelCount: UInt32(max(1, channelCount)),
                channel: Int32(channelIndex)
            ) else {
                showSpectrogram[channelIndex] = false
                return
            }

            let source = MixerVisualizerAudioSource(
                source: .output(deviceID: deviceID, channelIndex: channelIndex)
            )
            let feed = MixerSpectrogramFeed(source: source, deviceID: Int32(deviceID), channelIndex: Int32(channelIndex))
            feed.start()
            spectrogramFeeds[channelIndex] = feed

            let scale = themeManager.deviceSpectrumScaleFactors[deviceID] ?? 1.0
            floatingWindowController.showSpectrogramWindow(
                deviceID: deviceID,
                channelIndex: channelIndex,
                scale: scale
            ) {
                SpectroBackendView(
                    deviceID: Int32(deviceID),
                    channelIndex: Int32(channelIndex),
                    fftSize: Int32(settings.spectrumFFTSize),
                    themeColor: simdTheme,
                    themeMode: Int32(pickedTheme.rawValue),
                    deviceName: outputManager.outputDevices.first(where: { $0.deviceID == deviceID })?.name ?? "Output",
                    scale: scale,
                    externalAudioSource: source
                )
            }
        } else {
            spectrogramFeeds[channelIndex]??.stop()
            spectrogramFeeds[channelIndex] = nil
            floatingWindowController.closeSpectrogramWindow(for: deviceID, channelIndex: channelIndex)
        }
    }

    private func toggleWaveform(channelIndex: Int) {
        showWaveform[channelIndex, default: false].toggle()
        let scale = themeManager.deviceSpectrumScaleFactors[deviceID] ?? 1.0

        if showWaveform[channelIndex] ?? false {
            let source = MixerVisualizerAudioSource(
                source: .output(deviceID: deviceID, channelIndex: channelIndex)
            )
            floatingWindowController.showWaveformWindow(
                deviceID: deviceID,
                channelIndex: channelIndex,
                scale: scale
            ) {
                WaveformView(
                    buffer: AudioSampleBuffer(),
                    deviceID: deviceID,
                    channelIndex: channelIndex,
                    themeMode: WaveformThemeMode(rawValue: themeManager.deviceCapsuleThemes[deviceID]?.rawValue ?? themeManager.capsuleThemeMode.rawValue) ?? .light,
                    deviceName: outputManager.outputDevices.first(where: { $0.deviceID == deviceID })?.name ?? "Output",
                    mixerAudioSource: source,
                    scale: scale
                )
            }
        } else {
            floatingWindowController.closeWaveformWindow(for: deviceID, channelIndex: channelIndex)
        }
    }

    // MARK: - Peak Display

    private func refreshPeakDisplay(channelIndex: Int) {
        guard let ctx = outputManager.outputContexts[deviceID],
              channelIndex < ctx.device.outputChannels else { return }

        let rmsDb = dbFromLinear(ctx.rmsBuffer.readMostRecent(fromChannel: channelIndex))
        let now = Date()

        rmsDbValues[channelIndex] = rmsDb
        if shouldUpdateRmsText(channelIndex: channelIndex, now: now) {
            let rmsDisplayDb = rmsDb + 4.0
            rmsDisplayTexts[channelIndex] = formatDb(rmsDisplayDb)
            lastRmsTextUpdate[channelIndex] = now
        }
    }

    private func dbFromLinear(_ linearValue: Float) -> Float {
        let safe = max(0.000_001, linearValue)
        let db = 20 * log10(safe)
        return db.isFinite ? db : -100.0
    }

    private func formatDb(_ db: Float) -> String {
        if db < -99.0 { return "−∞" }
        return String(format: "%.0f", db)
    }

    private func shouldUpdateRmsText(channelIndex: Int, now: Date) -> Bool {
        guard let lastUpdate = lastRmsTextUpdate[channelIndex] else { return true }
        return now.timeIntervalSince(lastUpdate) >= rmsTextUpdateInterval
    }
}
