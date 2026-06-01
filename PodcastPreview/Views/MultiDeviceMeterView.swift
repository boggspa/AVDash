//
//  MultiDeviceMeterView.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 17/03/2026.
//
//  Displays peak meters for multiple simultaneously monitored devices
//

import SwiftUI
import PodcastPreviewShared

struct MultiDeviceMeterView: View {
    @ObservedObject var manager: MultiDeviceAudioManager

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(Array(manager.deviceMeteringStates.values.sorted(by: { $0.device.name < $1.device.name })), id: \.device.id) { state in
                    DeviceMeterCard(state: state, manager: manager)
                }
            }
            .padding()
        }
    }
}

struct DeviceMeterCard: View {
    @ObservedObject var state: DeviceMeteringState
    let manager: MultiDeviceAudioManager
    @State private var showColorPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with device name, color picker, and close button
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.device.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)

                    Text("Inputs: 1 - \(state.channelCount)")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Color picker button
                Button(action: {
                    showColorPicker.toggle()
                }) {
                    Circle()
                        .fill(state.device.themeColor)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.3), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Change Meter Color")
                .popover(isPresented: $showColorPicker) {
                    DeviceColorPickerView(device: state.device)
                }

                // Close button
                Button(action: {
                    manager.stopPeakMonitoring(for: state.device)
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop Monitoring")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Meters with scale (matches FFT meter style)
            HStack(alignment: .bottom, spacing: 8) {
                let meterWidth: CGFloat = 12
                let meterSpacing: CGFloat = 8
                let stripWidth = CGFloat(state.channelCount) * meterWidth +
                    CGFloat(max(Int(state.channelCount) - 1, 0)) * meterSpacing

                // dB scale on the left
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach([0, -10, -20, -30, -40, -50], id: \.self) { db in
                        Text("\(db)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(height: 46.67, alignment: .bottom) // 280 / 6 intervals
                        if db != -50 {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(width: 24, height: 280)

                VStack(alignment: .leading, spacing: 4) {
                    MetalMeterStripView(
                        metering: state.channelMetering,
                        themeColor: state.device.themeColor,
                        calibrationDB: 0.0,
                        meterWidth: meterWidth,
                        meterSpacing: meterSpacing
                    )
                    .frame(width: stripWidth, height: 280)

                    HStack(spacing: meterSpacing) {
                        ForEach(0..<Int(state.channelCount), id: \.self) { index in
                            Text("\(index + 1)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: meterWidth)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(
            ThemeRoundedRectangle(cornerRadius: 16).themed()
        )
    }
}

// MARK: - Refined Meter Column (Metal-accelerated)

struct RefinedMeterColumn: View {
    let channelNumber: Int
    let channelData: MeteringResult
    let color: Color
    @ObservedObject var state: DeviceMeteringState

    var body: some View {
        VStack(spacing: 4) {
            // Metal-accelerated meter bar (same as FFT meters)
            MetalMeterColumnWrapper(
                metering: channelData,
                themeColor: color
            )
            .frame(width: 12, height: 280)

            // Channel number at bottom
            Text("\(channelNumber)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}

// Wrapper to adapt Metal meter for multi-device use
struct MetalMeterColumnWrapper: NSViewRepresentable {
    let metering: MeteringResult
    let themeColor: Color

    // Peak hold state (per instance)
    @State private var heldLevel: Float = 0
    @State private var lastPeakTime: Date = Date()
    private let holdDuration: TimeInterval = 1.0

    func makeNSView(context: Context) -> MetalHostingView {
        MetalHostingView()
    }

    func updateNSView(_ nsView: MetalHostingView, context: Context) {
        let now = Date()
        let linearPeak = metering.peak

        // Convert to dBFS and normalize
        let db = MeterScale.dbFS(fromLinear: linearPeak,
                                 minDB: MeterScale.defaultMinDB)
        let level = MeterScale.normalized(fromDB: db,
                                          minDB: MeterScale.defaultMinDB,
                                          maxDB: MeterScale.defaultMaxDB)

        // Update peak hold
        var held = context.coordinator.heldLevel
        var lastTime = context.coordinator.lastPeakTime

        if level > held {
            held = level
            lastTime = now
        } else {
            let elapsed = now.timeIntervalSince(lastTime)
            if elapsed > holdDuration {
                held = level
                lastTime = now
            }
        }

        context.coordinator.heldLevel = held
        context.coordinator.lastPeakTime = lastTime

        // Update Metal view
        nsView.updateLevels(level: level, peakHold: held)
        nsView.baseColor = simdColor(from: themeColor)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var heldLevel: Float = 0
        var lastPeakTime: Date = Date()
    }

    private func simdColor(from color: Color) -> SIMD3<Float> {
        let nsColor = NSColor(color)
        let rgb = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(Float(r), Float(g), Float(b))
    }
}

// MARK: - Professional Meter Column (legacy with scale labels)

struct ProfessionalMeterColumn: View {
    let channelNumber: Int
    let channelData: MeteringResult
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            // Channel number at top
            Text("\(channelNumber)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)

            // Scale markings and meter
            HStack(spacing: 4) {
                // Scale labels on the left (positioned absolutely)
                GeometryReader { geo in
                    let height = geo.size.height
                    ForEach([0, -3, -6, -9, -12, -18, -24, -30, -36, -42, -48, -54, -60], id: \.self) { db in
                        let position = dbToVerticalPosition(db: db, height: height)
                        Text("\(db)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 24, alignment: .trailing)
                            .position(x: 12, y: position)
                    }
                }
                .frame(width: 24, height: 280)

                // Meter bar
                ProfessionalMeterBar(level: channelData.peak, color: color)
                    .frame(width: 32, height: 280)
            }

            // Peak dB value at bottom
            let peakDB = 20 * log10(max(channelData.peak, 0.00001))
            Text(String(format: "%.0f", peakDB))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(meterColor(for: Double(peakDB)))
        }
    }

    // Convert dB to vertical position (0 dB = top, -60 dB = bottom)
    private func dbToVerticalPosition(db: Int, height: CGFloat) -> CGFloat {
        let positions: [Int: CGFloat] = [
            0: 0.0,
            -3: 0.05,
            -6: 0.10,
            -9: 0.15,
            -12: 0.20,
            -18: 0.30,
            -24: 0.40,
            -30: 0.50,
            -36: 0.60,
            -42: 0.70,
            -48: 0.80,
            -54: 0.90,
            -60: 1.0
        ]
        let normalizedPos = positions[db] ?? 0.0
        return height * normalizedPos
    }
}

struct ProfessionalMeterBar: View {
    let level: Float
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Background (dark)
                ThemeRoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.6))

                // Level bar with gradient
                let levelHeight = geometry.size.height * CGFloat(min(max(level, 0), 1))

                ThemeRoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            stops: gradientStops(for: level, height: geometry.size.height),
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(height: levelHeight)

                // Scale tick marks at correct positions
                ForEach([0.0, 0.05, 0.10, 0.15, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.0], id: \.self) { position in
                    Rectangle()
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 1)
                        .offset(y: -(geometry.size.height * (1.0 - position)))
                }
            }
        }
    }

    private func gradientStops(for level: Float, height: CGFloat) -> [Gradient.Stop] {
        let levelDB = 20 * log10(max(level, 0.00001))

        // Create gradient based on dB ranges
        var stops: [Gradient.Stop] = []

        // Red zone (0 to -3 dB) - top ~5%
        if levelDB > -3 {
            stops.append(Gradient.Stop(color: .red, location: 0.95))
        }

        // Yellow zone (-3 to -6 dB) - ~5-10%
        if levelDB > -6 {
            stops.append(Gradient.Stop(color: .yellow, location: 0.9))
        }

        // Green to yellow transition (-6 to -18 dB) - ~10-30%
        stops.append(Gradient.Stop(color: color.opacity(0.9), location: 0.7))
        stops.append(Gradient.Stop(color: color.opacity(0.8), location: 0.5))
        stops.append(Gradient.Stop(color: color.opacity(0.7), location: 0.3))
        stops.append(Gradient.Stop(color: color.opacity(0.6), location: 0.0))

        return stops
    }
}

// MARK: - Meter Display Components (legacy, keeping for compatibility)

struct MonoMeterDisplay: View {
    @ObservedObject var state: DeviceMeteringState

    var body: some View {
        if let channelData = state.channelMetering.first {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Peak:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    let peakDB = 20 * log10(max(channelData.peak, 0.00001))
                    Text(String(format: "%.1f dB", peakDB))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(meterColor(for: Double(peakDB)))
                }

                SimplePeakMeterBar(
                    level: channelData.peak,
                    color: state.device.themeColor
                )
                .frame(height: 24)
            }
        }
    }
}

struct StereoMeterDisplay: View {
    @ObservedObject var state: DeviceMeteringState

    var body: some View {
        HStack(spacing: 8) {
            // Left channel
            if state.channelMetering.indices.contains(0) {
                ChannelMeterColumn(
                    label: "L",
                    channelData: state.channelMetering[0],
                    color: state.device.themeColor
                )
            }

            // Right channel
            if state.channelMetering.indices.contains(1) {
                ChannelMeterColumn(
                    label: "R",
                    channelData: state.channelMetering[1],
                    color: state.device.themeColor
                )
            }
        }
    }
}

struct MultiChannelMeterDisplay: View {
    @ObservedObject var state: DeviceMeteringState

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 8) {
            ForEach(0..<Int(state.channelCount), id: \.self) { index in
                if state.channelMetering.indices.contains(index) {
                    ChannelMeterColumn(
                        label: "Ch \(index + 1)",
                        channelData: state.channelMetering[index],
                        color: state.device.themeColor
                    )
                }
            }
        }
    }
}

struct ChannelMeterColumn: View {
    let label: String
    let channelData: MeteringResult
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer()

                let peakDB = 20 * log10(max(channelData.peak, 0.00001))
                Text(String(format: "%.1f", peakDB))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(meterColor(for: Double(peakDB)))
            }

            SimplePeakMeterBar(level: channelData.peak, color: color)
                .frame(height: 16)
        }
    }
}

struct SimplePeakMeterBar: View {
    let level: Float
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                ThemeRoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.3))

                // Level bar
                ThemeRoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: gradientColors(for: level),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
    }

    private func gradientColors(for level: Float) -> [Color] {
        let levelDB = 20 * log10(max(level, 0.00001))

        if levelDB > -3 {
            // Hot - red zone
            return [color.opacity(0.8), .red]
        } else if levelDB > -12 {
            // Warm - yellow to color
            return [color.opacity(0.6), color]
        } else {
            // Safe - green-ish
            return [color.opacity(0.3), color.opacity(0.7)]
        }
    }
}

// MARK: - Helpers

private func meterColor(for db: Double) -> Color {
    if db > -3 {
        return .red
    } else if db > -12 {
        return .orange
    } else {
        return .green
    }
}
// MARK: - Device Color Picker

struct DeviceColorPickerView: View {
    @ObservedObject var device: AudioDeviceModel
    @State private var hue: Double = 0.33
    @State private var saturation: Double = 0.9
    @State private var brightness: Double = 0.9

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Meter Color")
                .font(.headline)

            // Color preview
            let currentColor = Color(
                hue: hue,
                saturation: saturation,
                brightness: brightness
            )

            ThemeRoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [
                            currentColor.opacity(0.5),
                            currentColor.opacity(0.8),
                            currentColor,
                            .orange,
                            .red
                        ],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .frame(height: 48)
                .overlay(
                    ThemeRoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )

            // Color sliders
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
                        .accentColor(currentColor)
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
                        .accentColor(currentColor)
                }
            }

            Divider()

            // Quick color presets
            Text("Presets")
                .font(.caption)
                .foregroundColor(.secondary)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                ColorPresetButton(name: "Green", hue: 0.33, saturation: 0.8, brightness: 0.85, currentHue: $hue, currentSat: $saturation, currentBright: $brightness)
                ColorPresetButton(name: "Blue", hue: 0.55, saturation: 0.7, brightness: 0.85, currentHue: $hue, currentSat: $saturation, currentBright: $brightness)
                ColorPresetButton(name: "Purple", hue: 0.75, saturation: 0.75, brightness: 0.85, currentHue: $hue, currentSat: $saturation, currentBright: $brightness)
                ColorPresetButton(name: "Orange", hue: 0.08, saturation: 0.85, brightness: 0.9, currentHue: $hue, currentSat: $saturation, currentBright: $brightness)
                ColorPresetButton(name: "Pink", hue: 0.95, saturation: 0.65, brightness: 0.85, currentHue: $hue, currentSat: $saturation, currentBright: $brightness)
                ColorPresetButton(name: "Cyan", hue: 0.5, saturation: 0.8, brightness: 0.9, currentHue: $hue, currentSat: $saturation, currentBright: $brightness)
                ColorPresetButton(name: "Yellow", hue: 0.15, saturation: 0.7, brightness: 0.9, currentHue: $hue, currentSat: $saturation, currentBright: $brightness)
                ColorPresetButton(name: "Red", hue: 0.0, saturation: 0.85, brightness: 0.9, currentHue: $hue, currentSat: $saturation, currentBright: $brightness)
            }

            Text("Colors apply to both peak meters and spectrum")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            syncFromDeviceColor()
        }
        .onChange(of: hue) { _ in updateDeviceColor() }
        .onChange(of: saturation) { _ in updateDeviceColor() }
        .onChange(of: brightness) { _ in updateDeviceColor() }
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

struct ColorPresetButton: View {
    let name: String
    let hue: Double
    let saturation: Double
    let brightness: Double
    @Binding var currentHue: Double
    @Binding var currentSat: Double
    @Binding var currentBright: Double

    var body: some View {
        Button(action: {
            currentHue = hue
            currentSat = saturation
            currentBright = brightness
        }) {
            VStack(spacing: 4) {
                ThemeRoundedRectangle(cornerRadius: 16).themed(fill: Color(hue: hue, saturation: saturation, brightness: brightness), stroke: Color.white.opacity(0.2))
                    .frame(height: 32)

                Text(name)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
