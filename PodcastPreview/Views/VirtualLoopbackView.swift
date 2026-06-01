//
//  VirtualLoopbackView.swift
//  PodcastPreview
//
//  Controls and meters for the app-routed AudioServerPlugIn loopback path.
//

import SwiftUI
import PodcastPreviewShared

struct VirtualLoopbackControlPanel: View {
    @ObservedObject var model: VirtualLoopbackModel

    private var includeInputBinding: Binding<Bool> {
        Binding(
            get: { model.includeSelectedInput },
            set: { model.updateIncludeSelectedInput(to: $0) }
        )
    }

    private var includeSystemBinding: Binding<Bool> {
        Binding(
            get: { model.includeSystemAudio },
            set: { model.updateIncludeSystemAudio(to: $0) }
        )
    }

    private var inputBinding: Binding<UInt32> {
        Binding(
            get: { model.selectedInputDeviceID },
            set: { model.updateInputSelection(to: $0) }
        )
    }

    private var outputBinding: Binding<UInt32> {
        Binding(
            get: { model.selectedOutputDeviceID },
            set: { model.updateOutputSelection(to: $0) }
        )
    }

    private var bufferBinding: Binding<UInt32> {
        Binding(
            get: { model.bufferFrames },
            set: { model.updateBufferFrames(to: $0) }
        )
    }

    private var sampleRateBinding: Binding<Double> {
        Binding(
            get: { model.routeSampleRate },
            set: { model.updateSampleRate(to: $0) }
        )
    }

    private var inputGainBinding: Binding<Double> {
        Binding(
            get: { model.selectedInputGain },
            set: { model.updateSelectedInputGain(to: $0) }
        )
    }

    private var systemGainBinding: Binding<Double> {
        Binding(
            get: { model.systemAudioGain },
            set: { model.updateSystemAudioGain(to: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("System Loopback")
                    .font(.headline)

                Spacer()

                Button {
                    model.refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh output devices")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("AudioServerPlugIn")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(model.pluginDisplayName)
                    .font(.subheadline)

                Text("If the system output is set to this virtual device, the AudioServerPlugIn feeds the app mixer. The selected input below can also run at the same time, so local input and system audio can be mixed before routing to the destination.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Sources")
                    .font(.caption)
                    .foregroundColor(.secondary)

                SourceLaneCard(
                    title: "Selected Input",
                    subtitle: model.inputSummary,
                    isEnabled: includeInputBinding,
                    gain: inputGainBinding,
                    level: model.selectedInputLevel,
                    accentColor: .blue
                )

                SourceLaneCard(
                    title: "System Audio",
                    subtitle: model.pluginDisplayName,
                    isEnabled: includeSystemBinding,
                    gain: systemGainBinding,
                    level: model.systemAudioLevel,
                    accentColor: model.tapThemeColor
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Input")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Input", selection: inputBinding) {
                    ForEach(model.availableInputs) { input in
                        Text(input.name).tag(input.deviceID)
                    }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Route To")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Route To", selection: outputBinding) {
                    ForEach(model.availableOutputs) { output in
                        Text(output.name).tag(output.deviceID)
                    }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Router Buffer")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Router Buffer", selection: bufferBinding) {
                    Text("128 frames").tag(UInt32(128))
                    Text("256 frames").tag(UInt32(256))
                    Text("512 frames").tag(UInt32(512))
                    Text("1024 frames").tag(UInt32(1024))
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Virtual Device Rate")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Virtual Device Rate", selection: sampleRateBinding) {
                    Text("44.1").tag(44_100.0)
                    Text("48").tag(48_000.0)
                    Text("88.2").tag(88_200.0)
                    Text("96").tag(96_000.0)
                }
                .pickerStyle(.segmented)
            }

            HStack(spacing: 10) {
                StatusDot(color: model.busFed ? model.tapThemeColor : .secondary)

                Text(model.statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button(model.isRouterRunning ? "Stop Route" : "Start Route") {
                    if model.isRouterRunning {
                        model.stopRouting()
                    } else {
                        model.startRouting()
                    }
                }
                .buttonStyle(.bordered)
            }

            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 12) {
                    MetricPill(label: "Captured", value: "\(model.framesCaptured)")
                    MetricPill(label: "Queued", value: "\(model.framesAvailable)")
                    MetricPill(label: "Overruns", value: "\(model.overruns)")
                    MetricPill(label: "Underruns", value: "\(model.underruns)")
                }

                Spacer(minLength: 0)

                Button("Reset Counters") {
                    model.resetRouteCounters()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            if let error = model.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding(12)
        .background(
            ThemeRoundedRectangle(cornerRadius: 16).themed()
        )
    }
}

struct VirtualLoopbackTapMeterCard: View {
    @ObservedObject var model: VirtualLoopbackModel
    let isSpectrumSelected: Bool
    let onActivateSpectrum: () -> Void
    let onToggleAnalysis: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Program Tap")
                        .font(.headline)
                    Text("\(model.sourceSummary) -> \(model.outputSummary)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    onToggleAnalysis()
                } label: {
                    Label(model.isTapAnalysisEnabled ? "Analysis On" : "Analysis Off",
                          systemImage: model.isTapAnalysisEnabled ? "waveform.badge.magnifyingglass" : "waveform.slash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if model.isTapSpectrumAvailable {
                    Button {
                        onActivateSpectrum()
                    } label: {
                        Label(isSpectrumSelected ? "FFT Active" : "Use For FFT",
                              systemImage: isSpectrumSelected ? "waveform.path.ecg.rectangle.fill" : "waveform.path.ecg.rectangle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                StatusDot(color: model.busFed ? model.tapThemeColor : .secondary)
                Text(model.busFed ? "Program bus active" : "Waiting for source")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if model.isTapAnalysisEnabled {
                MeterView(monitoring: model.tapMonitoring)
                    .frame(minHeight: 280, maxHeight: 360)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("Program tap analysis is disabled.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Enable it to resume the meter, waveform, and spectrum.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 360)
                .background(
                    ThemeRoundedRectangle(cornerRadius: 18).themed()
                )
            }
        }
        .padding(12)
        .background(
            ThemeRoundedRectangle(cornerRadius: 24).themed()
        )
    }
}

private struct MetricPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.18))
        )
    }
}

private struct SourceLaneCard: View {
    let title: String
    let subtitle: String
    let isEnabled: Binding<Bool>
    let gain: Binding<Double>
    let level: Double
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle(isOn: isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Spacer()

                Text(String(format: "%.2fx", gain.wrappedValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Text("Gain")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if #available(macOS 13.0, *) {
                    Slider(value: gain, in: 0...2)
                        .tint(accentColor)
                } else {
                    Slider(value: gain, in: 0...2)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Level")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(level * 100))%")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                        Capsule()
                            .fill(accentColor.opacity(isEnabled.wrappedValue ? 0.85 : 0.25))
                            .frame(width: max(6, geometry.size.width * level))
                    }
                }
                .frame(height: 8)
            }
        }
        .padding(10)
        .background(
            ThemeRoundedRectangle(cornerRadius: 14).themed()
        )
    }
}

private struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}
