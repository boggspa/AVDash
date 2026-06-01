//
//  FocusPeakingControlsView.swift
//  PodcastPreview
//
//  SwiftUI interface for focus peaking settings
//

import SwiftUI
import PodcastPreviewShared

@available(macOS 14.0, *)
struct FocusPeakingControlsView: View {
    @Bindable var engine: FocusPeakingEngine
    @State private var showColorPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Enable toggle
            HStack {
                Toggle("Focus Peaking", isOn: $engine.isEnabled)
                    .toggleStyle(.switch)
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                // Reset button (for troubleshooting)
                Button(action: {
                    engine.reset()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Reset Focus Peaking (fixes issues)")
                .foregroundColor(.secondary)
                .padding(.trailing, 8)

                if engine.isEnabled {
                    Button(action: { showColorPicker.toggle() }) {
                        Circle()
                            .fill(Color(
                                red: Double(engine.settings.peakColor.x),
                                green: Double(engine.settings.peakColor.y),
                                blue: Double(engine.settings.peakColor.z)
                            ))
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Change Peak Color")
                    .popover(isPresented: $showColorPicker) {
                        FocusPeakingColorPicker(settings: $engine.settings)
                    }
                }
            }

            if engine.isEnabled {
                Divider()
                    .padding(.vertical, 4)

                // Sensitivity slider
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Sensitivity")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Spacer()

                        Text(String(format: "%.0f%%", (1.0 - engine.settings.edgeThreshold) * 100))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Slider(value: Binding(
                        get: { 1.0 - Double(engine.settings.edgeThreshold) },
                        set: { engine.settings.edgeThreshold = Float(1.0 - $0) }
                    ), in: 0...1)
                    .help("Lower = more edges detected")
                }

                // Opacity slider
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Opacity")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Spacer()

                        Text(String(format: "%.0f%%", engine.settings.opacity * 100))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Slider(value: Binding(
                        get: { Double(engine.settings.opacity) },
                        set: { engine.settings.opacity = Float($0) }
                    ), in: 0...1)
                }

                // Thickness picker
                HStack {
                    Text("Thickness")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Spacer()

                    Picker("", selection: $engine.settings.thickness) {
                        Text("Thin").tag(1)
                        Text("Medium").tag(2)
                        Text("Thick").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                // Pre-blur toggle
                Toggle("Noise Reduction", isOn: $engine.settings.enablePreBlur)
                    .font(.system(size: 11))
                    .help("Blur before edge detection (reduces false positives)")
            }
        }
        .padding(12)
        .background(
            ThemeRoundedRectangle(cornerRadius: 16).themed(fill: Color.black.opacity(0.05), stroke: Color.white.opacity(0.1))
        )
    }
}

// MARK: - Color Picker

@available(macOS 14.0, *)
struct FocusPeakingColorPicker: View {
    @Binding var settings: FocusPeakingSettings
    @State private var hue: Double = 0.0
    @State private var saturation: Double = 1.0
    @State private var brightness: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Peak Color")
                .font(.headline)

            // Color preview
            ThemeRoundedRectangle(cornerRadius: 16).themed(
                fill: Color(
                    red: Double(settings.peakColor.x),
                    green: Double(settings.peakColor.y),
                    blue: Double(settings.peakColor.z)
                ),
                stroke: Color.white.opacity(0.2)
            )
            .frame(height: 40)

            // HSB sliders
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Hue")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.0f°", hue * 360))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $hue, in: 0...1)
                        .accentColor(Color(hue: hue, saturation: 1.0, brightness: 1.0))
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Saturation")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.0f%%", saturation * 100))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $saturation, in: 0...1)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Brightness")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(String(format: "%.0f%%", brightness * 100))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $brightness, in: 0...1)
                }
            }

            Divider()

            // Quick presets
            Text("Presets")
                .font(.caption)
                .foregroundColor(.secondary)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                ColorPreset(name: "Red", hue: 0.0, sat: 1.0, bright: 1.0, current: $hue, currentSat: $saturation, currentBright: $brightness)
                ColorPreset(name: "Green", hue: 0.33, sat: 1.0, bright: 1.0, current: $hue, currentSat: $saturation, currentBright: $brightness)
                ColorPreset(name: "Blue", hue: 0.6, sat: 1.0, bright: 1.0, current: $hue, currentSat: $saturation, currentBright: $brightness)
                ColorPreset(name: "Yellow", hue: 0.16, sat: 1.0, bright: 1.0, current: $hue, currentSat: $saturation, currentBright: $brightness)
                ColorPreset(name: "Cyan", hue: 0.5, sat: 1.0, bright: 1.0, current: $hue, currentSat: $saturation, currentBright: $brightness)
                ColorPreset(name: "Magenta", hue: 0.83, sat: 1.0, bright: 1.0, current: $hue, currentSat: $saturation, currentBright: $brightness)
                ColorPreset(name: "Orange", hue: 0.08, sat: 1.0, bright: 1.0, current: $hue, currentSat: $saturation, currentBright: $brightness)
                ColorPreset(name: "White", hue: 0.0, sat: 0.0, bright: 1.0, current: $hue, currentSat: $saturation, currentBright: $brightness)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            // Initialize from current color
            let color = Color(
                red: Double(settings.peakColor.x),
                green: Double(settings.peakColor.y),
                blue: Double(settings.peakColor.z)
            )
            let nsColor = NSColor(color)
            if let rgb = nsColor.usingColorSpace(.deviceRGB) {
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                hue = Double(h)
                saturation = Double(s)
                brightness = Double(b)
            }
        }
        .onChange(of: hue) { updateColor() }
        .onChange(of: saturation) { updateColor() }
        .onChange(of: brightness) { updateColor() }
    }

    private func updateColor() {
        let color = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1.0)
        if let rgb = color.usingColorSpace(.deviceRGB) {
            settings.peakColor = SIMD3(
                Float(rgb.redComponent),
                Float(rgb.greenComponent),
                Float(rgb.blueComponent)
            )
        }
    }
}

@available(macOS 14.0, *)
struct ColorPreset: View {
    let name: String
    let hue: Double
    let sat: Double
    let bright: Double
    @Binding var current: Double
    @Binding var currentSat: Double
    @Binding var currentBright: Double

    var body: some View {
        Button(action: {
            current = hue
            currentSat = sat
            currentBright = bright
        }) {
            VStack(spacing: 4) {
                ThemeRoundedRectangle(cornerRadius: 16).themed(fill: Color(hue: hue, saturation: sat, brightness: bright), stroke: Color.white.opacity(0.2))
                    .frame(height: 24)

                Text(name)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
