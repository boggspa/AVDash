import SwiftUI

struct VisualisationSettingsView: View {
    @ObservedObject private var settings = VisualisationSettings.shared
    @State private var selectedTab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Visualisation Settings")
                .font(.headline)
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 14)

            Picker("Tab", selection: $selectedTab) {
                Text("Spectrum").tag(0)
                Text("Spectrogram").tag(1)
                Text("Waveform").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.bottom, 14)

            // MARK: Rendering backend selector
            VStack(alignment: .leading, spacing: 4) {
                Picker("Rendering", selection: $settings.visualisationPerformanceMode) {
                    Text("Automatic").tag(VisualisationPerformanceMode.automatic)
                    Text("Compatibility").tag(VisualisationPerformanceMode.compatibility)
                }
                .pickerStyle(.segmented)

                Text("Compatibility uses CPU rendering for weaker GPUs.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)

            Divider()

            if selectedTab == 0 {
                spectrumPane
            } else if selectedTab == 1 {
                spectrogramPane
            } else {
                waveformPane
            }
        }
        .frame(width: 320)
    }

    // MARK: - Spectrum

    private var spectrumPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("FFT Size", selection: $settings.spectrumFFTSize) {
                Text("512").tag(512)
                Text("1024").tag(1024)
                Text("2048").tag(2048)
            }
            .help("Applies when opening new spectrum windows")

            Picker("Decay Speed", selection: $settings.spectrumDecaySpeed) {
                Text("Fast").tag("Fast")
                Text("Medium").tag("Medium")
                Text("Slow").tag("Slow")
            }

            labeledSlider(
                label: "Min dB Floor",
                valueLabel: "\(Int(settings.spectrumMinDB)) dB",
                value: Binding(
                    get: { Double(settings.spectrumMinDB) },
                    set: { settings.spectrumMinDB = Float($0) }
                ),
                range: -120 ... -40,
                step: 5
            )

            labeledSlider(
                label: "Gain Trim",
                valueLabel: String(format: "%+.0f dB", settings.spectrumGainTrimDB),
                value: Binding(
                    get: { Double(settings.spectrumGainTrimDB) },
                    set: { settings.spectrumGainTrimDB = Float($0) }
                ),
                range: -24 ... 24,
                step: 1
            )
        }
        .padding(24)
    }

    // MARK: - Spectrogram

    private var spectrogramPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            labeledSlider(
                label: "Display Duration",
                valueLabel: "\(settings.spectrogramDisplaySeconds) s",
                value: Binding(
                    get: { Double(settings.spectrogramDisplaySeconds) },
                    set: { settings.spectrogramDisplaySeconds = Int($0) }
                ),
                range: 5 ... 300,
                step: 5
            )
            .help("Applies when opening new spectrogram windows")

            Divider()

            labeledSlider(
                label: "Threshold",
                valueLabel: "\(Int(settings.spectrogramThresholdDB)) dB",
                value: Binding(
                    get: { Double(settings.spectrogramThresholdDB) },
                    set: { settings.spectrogramThresholdDB = Float($0) }
                ),
                range: -120 ... -60,
                step: 5
            )

            labeledSlider(
                label: "Noise Gate",
                valueLabel: String(format: "%.2f", settings.spectrogramGate),
                value: Binding(
                    get: { Double(settings.spectrogramGate) },
                    set: { settings.spectrogramGate = Float($0) }
                ),
                range: 0 ... 0.3,
                step: 0.01
            )

            labeledSlider(
                label: "Power Curve",
                valueLabel: String(format: "%.2f", settings.spectrogramPowerCurve),
                value: Binding(
                    get: { Double(settings.spectrogramPowerCurve) },
                    set: { settings.spectrogramPowerCurve = Float($0) }
                ),
                range: 0.2 ... 1.0,
                step: 0.05
            )

            labeledSlider(
                label: "Gain Trim",
                valueLabel: String(format: "%+.0f dB", settings.spectrogramGainTrimDB),
                value: Binding(
                    get: { Double(settings.spectrogramGainTrimDB) },
                    set: { settings.spectrogramGainTrimDB = Float($0) }
                ),
                range: -24 ... 24,
                step: 1
            )

        }
        .padding(24)
    }

    // MARK: - Waveform

    private var waveformPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Display Duration", selection: $settings.waveformDurationSeconds) {
                Text("1 s").tag(1)
                Text("2 s").tag(2)
                Text("3 s").tag(3)
                Text("4 s").tag(4)
                Text("5 s").tag(5)
            }
            .help("Applies to waveform window history")
        }
        .padding(24)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func labeledSlider(
        label: String,
        valueLabel: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(valueLabel)
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
