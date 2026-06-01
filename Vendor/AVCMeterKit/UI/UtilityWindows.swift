import SwiftUI
import CoreAudio
import AVFoundation

// MARK: - Utility Window Shared Components

struct UtilityModuleView<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 4)

            content
                .padding(8)
        }
        .background(Color.black.opacity(0.2))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

struct UtilityKnob: View {
    @Binding var value: Double
    let label: String
    var range: ClosedRange<Double> = 0...1

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                        .frame(width: 40, height: 40)

                    Circle()
                        .trim(from: 0, to: CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound) * 0.75))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 40, height: 40)
                        .rotationEffect(.degrees(135))

                    // Dial marker
                    Rectangle()
                        .fill(Color.primary.opacity(0.8))
                        .frame(width: 2, height: 10)
                        .offset(y: -12)
                        .rotationEffect(.degrees((value - range.lowerBound) / (range.upperBound - range.lowerBound) * 270 - 135))
                }
                .position(center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let dx = gesture.location.x - center.x
                            let dy = gesture.location.y - center.y
                            var angle = atan2(dy, dx) * 180 / .pi + 90
                            if angle < -180 { angle += 360 }
                            if angle > 180 { angle -= 360 }

                            if angle > 135 && angle < 180 { angle = 135 }
                            if angle < -135 && angle > -180 { angle = -135 }

                            let clampedAngle = min(135.0, max(-135.0, angle))
                            let normalizedValue = (clampedAngle + 135.0) / 270.0
                            value = range.lowerBound + normalizedValue * (range.upperBound - range.lowerBound)
                        }
                )
            }
            .frame(width: 40, height: 40)

            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.secondary)
        }
    }
}

struct XYPad: View {
    @Binding var x: Double
    @Binding var y: Double
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack {
                    // Background
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )

                    // Grid lines
                    Path { path in
                        path.move(to: CGPoint(x: geo.size.width / 2, y: 0))
                        path.addLine(to: CGPoint(x: geo.size.width / 2, y: geo.size.height))
                        path.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                        path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                    }
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)

                    // Corner labels
                    Group {
                        Text("Wood").font(.system(size: 8, weight: .bold)).position(x: 25, y: 10)
                        Text("Metal").font(.system(size: 8, weight: .bold)).position(x: geo.size.width - 25, y: 10)
                        Text("Glass").font(.system(size: 8, weight: .bold)).position(x: 25, y: geo.size.height - 10)
                        Text("String").font(.system(size: 8, weight: .bold)).position(x: geo.size.width - 25, y: geo.size.height - 10)
                    }
                    .foregroundColor(.secondary)

                    // Draggable node
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 12, height: 12)
                        .shadow(radius: 2)
                        .position(x: geo.size.width * x, y: geo.size.height * (1.0 - y))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            x = min(1.0, max(0.0, val.location.x / geo.size.width))
                            y = min(1.0, max(0.0, 1.0 - (val.location.y / geo.size.height)))
                        }
                )
            }
            .frame(width: 140, height: 140)

            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Sampler Engine Window

struct SamplerWindowView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var midiManager: MIDIStateManager
    @StateObject var utilityManager = UtilityInstrumentManager.shared
    @ObservedObject var manager = AudioDeviceManager.shared

    private let banks = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11"]

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Sampler Engine")
                        .font(.title2.bold())
                    Text("Multi-Bank Sample Playback & Trimming")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MIDI Input")
                            .font(.system(size: 9, weight: .bold))
                        Picker("", selection: $utilityManager.samplerMIDISource) {
                            Text("Omni").tag(nil as String?)
                            Text("Internal Keyboard").tag("Internal Keyboard" as String?)
                            Text("Internal CC Controller").tag("Internal CC Controller" as String?)
                            ForEach(midiManager.availableDevices, id: \.name) { device in
                                Text(device.name).tag(device.name as String?)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .frame(width: 140)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top)

            // Body
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 16) {
                    // Bank Selector
                    UtilityModuleView(title: "Sample Banks") {
                        HStack(spacing: 8) {
                            ForEach(0..<11, id: \.self) { index in
                                Button(action: {
                                    utilityManager.selectedSamplerBankIndex = index
                                }) {
                                    Text(banks[index])
                                        .font(.system(size: 10, weight: .bold))
                                        .frame(width: 30, height: 30)
                                        .background(utilityManager.selectedSamplerBankIndex == index ? Color.accentColor : Color.gray.opacity(0.2))
                                        .foregroundColor(utilityManager.selectedSamplerBankIndex == index ? .white : .primary)
                                        .cornerRadius(4)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }

                    // Selected Bank Controls
                    let activeIndex = utilityManager.selectedSamplerBankIndex
                    let activeBank = utilityManager.samplerBanks[activeIndex]

                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 12) {
                            UtilityModuleView(title: "File") {
                                VStack(spacing: 8) {
                                    Button(action: {
                                        loadSample(for: activeIndex)
                                    }) {
                                        Label("LOAD", systemImage: "doc.badge.plus")
                                            .font(.system(size: 10, weight: .bold))
                                            .padding(6)
                                            .frame(width: 80)
                                            .background(Color.accentColor)
                                            .foregroundColor(.white)
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(PlainButtonStyle())

                                    Text(activeBank.fileName ?? "Empty")
                                        .font(.system(size: 8))
                                        .foregroundColor(.secondary)
                                        .frame(width: 80)
                                        .lineLimit(1)
                                }
                            }

                            UtilityModuleView(title: "Level") {
                                UtilityKnob(value: Binding(
                                    get: { utilityManager.samplerBanks[activeIndex].level },
                                    set: { utilityManager.samplerBanks[activeIndex].level = $0 }
                                ), label: "Bank Vol")
                            }
                        }

                        // Waveform Viewport
                        UtilityModuleView(title: "Waveform / Trim") {
                            VStack(spacing: 8) {
                                SamplerWaveformView(
                                    data: activeBank.sampleData,
                                    trimStart: Binding(
                                        get: { activeBank.trimStart },
                                        set: { utilityManager.samplerBanks[activeIndex].trimStart = $0 }
                                    ),
                                    trimEnd: Binding(
                                        get: { activeBank.trimEnd },
                                        set: { utilityManager.samplerBanks[activeIndex].trimEnd = $0 }
                                    )
                                )
                                .frame(width: 400, height: 120)
                                .background(Color.black.opacity(0.3))
                                .cornerRadius(4)

                                HStack {
                                    Text(String(format: "Start: %.2f", activeBank.trimStart))
                                    Spacer()
                                    Text(String(format: "End: %.2f", activeBank.trimEnd))
                                }
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(.secondary)
                            }
                        }

                        // Filter & ADSR
                        VStack(spacing: 12) {
                            UtilityModuleView(title: "Filter") {
                                HStack(spacing: 12) {
                                    UtilityKnob(value: $utilityManager.samplerCutoff, label: "Cutoff")
                                    UtilityKnob(value: $utilityManager.samplerResonance, label: "Res")
                                }
                            }

                            UtilityModuleView(title: "ADSR") {
                                HStack(spacing: 8) {
                                    UtilityKnob(value: $utilityManager.samplerAttack, label: "A")
                                    UtilityKnob(value: $utilityManager.samplerDecay, label: "D")
                                    UtilityKnob(value: $utilityManager.samplerSustain, label: "S")
                                    UtilityKnob(value: $utilityManager.samplerRelease, label: "R")
                                }
                            }
                        }
                    }

                    UtilityModuleView(title: "Master") {
                        UtilityKnob(value: $utilityManager.samplerMasterVolume, label: "Master")
                    }
                }
                .padding(.horizontal)

                Spacer()

                // Metering
                if manager.activeDevices[utilityManager.samplerDeviceID] != nil {
                    ZStack {
                        ThemeRoundedRectangle(cornerRadius: MeteringCardLayout.cardCornerRadius, style: .continuous)
                            .fill(themeManager.accentFillColor)
                            .overlay(
                                ThemeRoundedRectangle(cornerRadius: MeteringCardLayout.cardCornerRadius, style: .continuous)
                                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                            )
                        VStack(alignment: .center, spacing: MeteringCardLayout.cardContentSpacing) {
                            meteringCardHeader(
                                title: "Master:",
                                subtitle: "Outputs: L - R",
                                headerYOffset: MeteringCardLayout.inputCardHeaderYOffset,
                                headerSubtitleYOffset: MeteringCardLayout.inputCardHeaderSubtitleYOffset
                            )
                            ChannelMeteringGroupView(
                                deviceID: utilityManager.samplerDeviceID,
                                channelIndices: [0, 1],
                                showsPerChannelFeatureIcons: false,
                                showsPerChannelLevelTexts: true,
                                channelHeaderYOffset: MeteringCardLayout.inputChannelHeaderYOffset,
                                channelHeaderYOffsetCPU: MeteringCardLayout.inputChannelHeaderYOffsetCPU,
                                capsuleYOffset: MeteringCardLayout.inputCapsuleYOffset,
                                tickMarkYOffset: MeteringCardLayout.inputTickMarkYOffset,
                                tickMarkYOffsetCPU: MeteringCardLayout.inputTickMarkYOffsetCPU
                            )
                        }
                        .padding(MeteringCardLayout.cardContentPadding)
                        .offset(y: MeteringCardLayout.cardContentOffsetY)
                    }
                    .frame(width: 140, height: 415)
                    .padding(.trailing, 20)
                }
            }
            .padding(.horizontal)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.1))
    }

    private func loadSample(for index: Int) {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.audio]
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false

        if openPanel.runModal() == .OK, let url = openPanel.url {
            do {
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                let frameCount = AVAudioFrameCount(file.length)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
                try file.read(into: buffer)

                let floatArray = Array(UnsafeBufferPointer(start: buffer.floatChannelData?[0], count: Int(frameCount)))

                DispatchQueue.main.async {
                    utilityManager.samplerBanks[index].sampleData = floatArray
                    utilityManager.samplerBanks[index].sampleRate = format.sampleRate
                    utilityManager.samplerBanks[index].fileName = url.lastPathComponent
                    utilityManager.samplerBanks[index].trimStart = 0.0
                    utilityManager.samplerBanks[index].trimEnd = 1.0
                }
            } catch {
                print("[Sampler] Error loading sample: \(error)")
            }
        }
    }
}

struct SamplerWaveformView: View {
    let data: [Float]?
    @Binding var trimStart: Double
    @Binding var trimEnd: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background Waveform
                if let data = data, !data.isEmpty {
                    Path { path in
                        let width = geo.size.width
                        let height = geo.size.height
                        let midY = height / 2
                        let step = max(1, data.count / Int(width))

                        path.move(to: CGPoint(x: 0, y: midY))

                        for x in stride(from: 0, to: Int(width), by: 1) {
                            let sampleIdx = x * step
                            if sampleIdx < data.count {
                                let sample = CGFloat(data[sampleIdx])
                                let y = midY - (sample * midY * 0.8)
                                path.addLine(to: CGPoint(x: CGFloat(x), y: y))
                            }
                        }
                    }
                    .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                } else {
                    Text("No Sample Loaded")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }

                // Trim Overlay
                Rectangle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: geo.size.width * (trimEnd - trimStart))
                    .offset(x: geo.size.width * trimStart)

                // Trim Handles
                Group {
                    // Start Handle
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 4, height: geo.size.height)
                        .offset(x: geo.size.width * trimStart)
                        .gesture(DragGesture().onChanged { val in
                            let normalized = val.location.x / geo.size.width
                            trimStart = min(trimEnd - 0.01, max(0.0, Double(normalized)))
                        })

                    // End Handle
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 4, height: geo.size.height)
                        .offset(x: geo.size.width * trimEnd - 4)
                        .gesture(DragGesture().onChanged { val in
                            let normalized = val.location.x / geo.size.width
                            trimEnd = max(trimStart + 0.01, min(1.0, Double(normalized)))
                        })
                }
            }
        }
    }
}

// MARK: - Physical Model Synth Window

struct PhysicalModelWindowView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var midiManager: MIDIStateManager
    @StateObject var utilityManager = UtilityInstrumentManager.shared
    @ObservedObject var manager = AudioDeviceManager.shared

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Physical Model Synth")
                        .font(.title2.bold())
                    Text("Karplus-Strong Plucked String Modeling")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MIDI Input")
                            .font(.system(size: 9, weight: .bold))
                        Picker("", selection: $utilityManager.physicalMIDISource) {
                            Text("Omni").tag(nil as String?)
                            Text("Internal Keyboard").tag("Internal Keyboard" as String?)
                            Text("Internal CC Controller").tag("Internal CC Controller" as String?)
                            ForEach(midiManager.availableDevices, id: \.name) { device in
                                Text(device.name).tag(device.name as String?)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .frame(width: 140)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top)

            // Body
            HStack(alignment: .top, spacing: 16) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        // Character XY Pad
                        UtilityModuleView(title: "Character") {
                            XYPad(x: $utilityManager.pmX, y: $utilityManager.pmY, label: "Material")
                        }

                        // Model
                        UtilityModuleView(title: "String Model") {
                            HStack(spacing: 12) {
                                UtilityKnob(value: $utilityManager.pmDamping, label: "Damping")
                                UtilityKnob(value: $utilityManager.pmDecay, label: "Decay")
                                UtilityKnob(value: $utilityManager.pmExcitation, label: "Pluck")
                                UtilityKnob(value: $utilityManager.pmBrightness, label: "Tone")
                            }
                        }

                        // Filter & ADSR
                        VStack(spacing: 12) {
                            UtilityModuleView(title: "Filter") {
                                HStack(spacing: 12) {
                                    UtilityKnob(value: $utilityManager.pmCutoff, label: "Cutoff")
                                    UtilityKnob(value: $utilityManager.pmResonance, label: "Res")
                                }
                            }

                            UtilityModuleView(title: "Envelope") {
                                HStack(spacing: 8) {
                                    UtilityKnob(value: $utilityManager.pmAttack, label: "Attack")
                                    UtilityKnob(value: $utilityManager.pmRelease, label: "Release")
                                }
                            }
                        }

                        // FX & Output
                        UtilityModuleView(title: "FX / Output") {
                            HStack(spacing: 12) {
                                UtilityKnob(value: $utilityManager.pmDistortion, label: "Drive")
                                UtilityKnob(value: $utilityManager.pmMasterVolume, label: "Master")
                            }
                        }

                        Spacer().frame(width: 160)
                    }
                    .padding(.horizontal)
                }

                Spacer()

                // Metering
                if manager.activeDevices[utilityManager.physicalModelDeviceID] != nil {
                    ZStack {
                        ThemeRoundedRectangle(cornerRadius: MeteringCardLayout.cardCornerRadius, style: .continuous)
                            .fill(themeManager.accentFillColor)
                            .overlay(
                                ThemeRoundedRectangle(cornerRadius: MeteringCardLayout.cardCornerRadius, style: .continuous)
                                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                            )
                        VStack(alignment: .center, spacing: MeteringCardLayout.cardContentSpacing) {
                            meteringCardHeader(
                                title: "Output:",
                                subtitle: "L - R",
                                headerYOffset: MeteringCardLayout.inputCardHeaderYOffset,
                                headerSubtitleYOffset: MeteringCardLayout.inputCardHeaderSubtitleYOffset
                            )
                            ChannelMeteringGroupView(
                                deviceID: utilityManager.physicalModelDeviceID,
                                channelIndices: [0, 1],
                                showsPerChannelFeatureIcons: false,
                                showsPerChannelLevelTexts: true,
                                channelHeaderYOffset: MeteringCardLayout.inputChannelHeaderYOffset,
                                channelHeaderYOffsetCPU: MeteringCardLayout.inputChannelHeaderYOffsetCPU,
                                capsuleYOffset: MeteringCardLayout.inputCapsuleYOffset,
                                tickMarkYOffset: MeteringCardLayout.inputTickMarkYOffset,
                                tickMarkYOffsetCPU: MeteringCardLayout.inputTickMarkYOffsetCPU
                            )
                        }
                        .padding(MeteringCardLayout.cardContentPadding)
                        .offset(y: MeteringCardLayout.cardContentOffsetY)
                    }
                    .frame(width: 140, height: 415)
                    .padding(.trailing, 20)
                }
            }
            .padding(.horizontal)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.1))
    }
}

// MARK: - Synthesizer Engine Window

struct SynthesizerWindowView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var midiManager: MIDIStateManager
    @StateObject var utilityManager = UtilityInstrumentManager.shared
    @ObservedObject var manager = AudioDeviceManager.shared

    // Routing state
    @State private var selectedAudioOutputID: AudioDeviceID = 0

    var body: some View {
        VStack(spacing: 20) {
            // Header & Routing
            HStack {
                VStack(alignment: .leading) {
                    Text("Synthesizer Engine")
                        .font(.title2.bold())
                    Text("Moog Grandmother Inspired Architecture")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MIDI Input")
                            .font(.system(size: 9, weight: .bold))
                        Picker("", selection: $utilityManager.synthMIDISource) {
                            Text("Omni").tag(nil as String?)
                            Text("Internal Keyboard").tag("Internal Keyboard" as String?)
                            Text("Internal CC Controller").tag("Internal CC Controller" as String?)
                            ForEach(midiManager.availableDevices, id: \.name) { device in
                                Text(device.name).tag(device.name as String?)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .frame(width: 140)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Audio Output")
                            .font(.system(size: 9, weight: .bold))
                        Picker("", selection: $selectedAudioOutputID) {
                            Text("Default").tag(AudioDeviceID(0))
                            ForEach(OutputDeviceManager.shared.outputDevices) { device in
                                Text(device.name).tag(device.deviceID)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .frame(width: 140)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top)

            // Body
            HStack(alignment: .top, spacing: 0) {
                // Modules
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        // Arp / Sequencer
                        UtilityModuleView(title: "Arp / Seq") {
                            HStack(spacing: 12) {
                                UtilityKnob(value: $utilityManager.synthArpRate, label: "Rate")
                                VStack(spacing: 8) {
                                    Button(action: {
                                        utilityManager.synthArpActive.toggle()
                                    }) {
                                        Text("ARP")
                                            .font(.system(size: 8, weight: .bold))
                                            .padding(4)
                                            .frame(width: 40)
                                            .background(utilityManager.synthArpActive ? Color.accentColor : Color.gray.opacity(0.3))
                                            .foregroundColor(.white)
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                        }

                        // Modulation
                        UtilityModuleView(title: "Modulation") {
                            VStack(spacing: 12) {
                                HStack(spacing: 12) {
                                    UtilityKnob(value: $utilityManager.synthLFORate, label: "LFO Rate")
                                    UtilityKnob(value: $utilityManager.synthGlide, label: "Glide")
                                }
                                HStack(spacing: 12) {
                                    UtilityKnob(value: $utilityManager.synthLFOPitchAmount, label: "LFO Pitch")
                                    UtilityKnob(value: $utilityManager.synthLFOFilterAmount, label: "LFO Filt")
                                }
                            }
                        }

                        // Oscillators
                        UtilityModuleView(title: "Oscillators") {
                            VStack(spacing: 16) {
                                HStack(spacing: 12) {
                                    UtilityKnob(value: $utilityManager.synthOsc1Wave, label: "OSC 1 Wave", range: 0...2)
                                    UtilityKnob(value: $utilityManager.synthOsc1Pitch, label: "OSC 1 Pitch")
                                }
                                HStack(spacing: 12) {
                                    UtilityKnob(value: $utilityManager.synthOsc2Wave, label: "OSC 2 Wave", range: 0...2)
                                    UtilityKnob(value: $utilityManager.synthOsc2Pitch, label: "OSC 2 Pitch")
                                }
                            }
                        }

                        // Mixer
                        UtilityModuleView(title: "Mixer") {
                            HStack(spacing: 12) {
                                UtilityKnob(value: $utilityManager.synthOsc1Level, label: "OSC 1")
                                UtilityKnob(value: $utilityManager.synthOsc2Level, label: "OSC 2")
                                UtilityKnob(value: $utilityManager.synthNoiseLevel, label: "Noise")
                            }
                        }

                        // Filter
                        UtilityModuleView(title: "Filter") {
                            HStack(spacing: 12) {
                                UtilityKnob(value: $utilityManager.synthCutoff, label: "Cutoff")
                                UtilityKnob(value: $utilityManager.synthResonance, label: "Res")
                            }
                        }

                        // Envelope
                        UtilityModuleView(title: "Envelope (ADSR)") {
                            HStack(spacing: 8) {
                                UtilityKnob(value: $utilityManager.synthAttack, label: "A")
                                UtilityKnob(value: $utilityManager.synthDecay, label: "D")
                                UtilityKnob(value: $utilityManager.synthSustain, label: "S")
                                UtilityKnob(value: $utilityManager.synthRelease, label: "R")
                            }
                        }

                        // Output / FX
                        UtilityModuleView(title: "Output / FX") {
                            HStack(spacing: 12) {
                                UtilityKnob(value: $utilityManager.synthReverbLevel, label: "Reverb")
                                UtilityKnob(value: $utilityManager.synthMasterVolume, label: "Master")
                            }
                        }

                        // Spacer to prevent the last module from being covered by the fixed meter
                        Spacer()
                            .frame(width: 160)
                    }
                    .padding(.horizontal)
                }

                Spacer()

                // Metering
                if manager.activeDevices[utilityManager.synthesizerDeviceID] != nil {
                    ZStack {
                        ThemeRoundedRectangle(cornerRadius: MeteringCardLayout.cardCornerRadius, style: .continuous)
                            .fill(themeManager.accentFillColor)
                            .overlay(
                                ThemeRoundedRectangle(cornerRadius: MeteringCardLayout.cardCornerRadius, style: .continuous)
                                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                            )
                        VStack(alignment: .center, spacing: MeteringCardLayout.cardContentSpacing) {
                            meteringCardHeader(
                                title: "Master:",
                                subtitle: "Outputs: L - R",
                                headerYOffset: MeteringCardLayout.inputCardHeaderYOffset,
                                headerSubtitleYOffset: MeteringCardLayout.inputCardHeaderSubtitleYOffset
                            )
                            ChannelMeteringGroupView(
                                deviceID: utilityManager.synthesizerDeviceID,
                                channelIndices: [0, 1],
                                showsPerChannelFeatureIcons: false,
                                showsPerChannelLevelTexts: true,
                                channelHeaderYOffset: MeteringCardLayout.inputChannelHeaderYOffset,
                                channelHeaderYOffsetCPU: MeteringCardLayout.inputChannelHeaderYOffsetCPU,
                                capsuleYOffset: MeteringCardLayout.inputCapsuleYOffset,
                                tickMarkYOffset: MeteringCardLayout.inputTickMarkYOffset,
                                tickMarkYOffsetCPU: MeteringCardLayout.inputTickMarkYOffsetCPU
                            )
                        }
                        .padding(MeteringCardLayout.cardContentPadding)
                        .offset(y: MeteringCardLayout.cardContentOffsetY)
                    }
                    .frame(width: 140, height: 415)
                    .padding(.trailing, 20)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.1))
    }
}

// MARK: - 808 Drum Machine Window

struct DrumMachineWindowView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var midiManager: MIDIStateManager
    @StateObject var utilityManager = UtilityInstrumentManager.shared
    @ObservedObject var manager = AudioDeviceManager.shared

    // Routing
    @State private var selectedAudioOutputID: AudioDeviceID = 0

    @State private var currentStep: Int = 0
    @State private var isPlaying: Bool = false
    @State private var timer: Timer? = nil

    // Drum modules
    private let instruments = [
        "BD", "SD", "LT", "MT", "HT", "RS", "CP", "CB", "CY", "OH", "CH"
    ]
    @State private var selectedInstrument = "BD"

    var body: some View {
        VStack(spacing: 20) {
            // Header & Routing
            HStack {
                VStack(alignment: .leading) {
                    Text("808 Drum Machine")
                        .font(.title2.bold())
                    Text("Classic Analog Style Rhythm Composer")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MIDI Input")
                            .font(.system(size: 9, weight: .bold))
                        Picker("", selection: $utilityManager.drumMIDISource) {
                            Text("Omni").tag(nil as String?)
                            ForEach(midiManager.availableDevices, id: \.name) { device in
                                Text(device.name).tag(device.name as String?)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .frame(width: 140)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Audio Output")
                            .font(.system(size: 9, weight: .bold))
                        Picker("", selection: $selectedAudioOutputID) {
                            Text("Default").tag(AudioDeviceID(0))
                            ForEach(OutputDeviceManager.shared.outputDevices) { device in
                                Text(device.name).tag(device.deviceID)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .frame(width: 140)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top)

            // Drum Controls
            HStack(alignment: .top, spacing: 20) {
                // Left Column: Transport and Global FX
                VStack(spacing: 16) {
                    UtilityModuleView(title: "Transport") {
                        HStack(spacing: 12) {
                            Button { isPlaying.toggle() } label: {
                                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                                    .foregroundColor(isPlaying ? .red : .green)
                                    .frame(width: 40, height: 40)
                                    .background(Color.black.opacity(0.3))
                                    .cornerRadius(8)
                            }.buttonStyle(.plain)

                            UtilityKnob(value: $utilityManager.drumTempo, label: "Tempo", range: 0.1...1.0)
                        }
                    }

                    UtilityModuleView(title: "Global FX") {
                        VStack(spacing: 12) {
                            HStack(spacing: 12) {
                                UtilityKnob(value: $utilityManager.drumAccent, label: "Accent")
                                UtilityKnob(value: $utilityManager.drumSwing, label: "Swing")
                            }
                            HStack(spacing: 12) {
                                UtilityKnob(value: $utilityManager.drumGlobalCutoff, label: "Filt")
                                UtilityKnob(value: $utilityManager.drumGlobalResonance, label: "Res")
                            }
                        }
                    }
                }
                .frame(width: 140)

                // Center Column: Sequencer and Per-Instrument Controls
                VStack(spacing: 20) {
                    // Pattern Selector & Sequencer
                    UtilityModuleView(title: "Step Sequencer") {
                        VStack(spacing: 12) {
                            HStack {
                                Picker("", selection: $utilityManager.drumSelectedPatternIndex) {
                                    Text("Pattern A").tag(0)
                                    Text("Pattern B").tag(1)
                                    Text("Pattern C").tag(2)
                                    Text("Pattern D").tag(3)
                                }
                                .pickerStyle(SegmentedPickerStyle())
                                .frame(width: 300)
                                Spacer()
                            }
                            .padding(.bottom, 4)

                            HStack(spacing: 6) {
                                ForEach(0..<16, id: \.self) { index in
                                    VStack(spacing: 8) {
                                        Rectangle()
                                            .fill((utilityManager.drumPatterns[utilityManager.drumSelectedPatternIndex][selectedInstrument]?[index] ?? false) ? colorForStep(index) : Color.gray.opacity(0.2))
                                            .frame(width: 35, height: 50)
                                            .cornerRadius(4)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .stroke(currentStep == index ? Color.white : Color.clear, lineWidth: 2)
                                            )
                                            .onTapGesture {
                                                utilityManager.drumPatterns[utilityManager.drumSelectedPatternIndex][selectedInstrument]?[index].toggle()
                                            }

                                        Text("\(index + 1)")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundColor(.secondary)
                                            .frame(height: 10)
                                    }
                                }
                            }
                        }
                    }

                    HStack(alignment: .top, spacing: 16) {
                        UtilityModuleView(title: "Instrument") {
                            Picker("", selection: $selectedInstrument) {
                                ForEach(instruments, id: \.self) { inst in
                                    Text(inst).tag(inst)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 100)
                        }

                        UtilityModuleView(title: "\(selectedInstrument) Controls") {
                            HStack(spacing: 16) {
                                UtilityKnob(value: Binding(
                                    get: { utilityManager.drumParams[selectedInstrument]?["Level"] ?? 0.5 },
                                    set: { utilityManager.drumParams[selectedInstrument]?["Level"] = $0 }
                                ), label: "Level")

                                UtilityKnob(value: Binding(
                                    get: { utilityManager.drumParams[selectedInstrument]?["Tune"] ?? 0.5 },
                                    set: { utilityManager.drumParams[selectedInstrument]?["Tune"] = $0 }
                                ), label: "Tune")

                                UtilityKnob(value: Binding(
                                    get: { utilityManager.drumParams[selectedInstrument]?["Mod"] ?? 0.5 },
                                    set: { utilityManager.drumParams[selectedInstrument]?["Mod"] = $0 }
                                ), label: "Mod")

                                UtilityKnob(value: Binding(
                                    get: { utilityManager.drumParams[selectedInstrument]?["Decay"] ?? 0.5 },
                                    set: { utilityManager.drumParams[selectedInstrument]?["Decay"] = $0 }
                                ), label: "Decay")

                                UtilityKnob(value: Binding(
                                    get: { utilityManager.drumParams[selectedInstrument]?["Filter"] ?? 1.0 },
                                    set: { utilityManager.drumParams[selectedInstrument]?["Filter"] = $0 }
                                ), label: "Filter")

                                UtilityKnob(value: Binding(
                                    get: { utilityManager.drumParams[selectedInstrument]?["Res"] ?? 0.0 },
                                    set: { utilityManager.drumParams[selectedInstrument]?["Res"] = $0 }
                                ), label: "Res")

                                if selectedInstrument == "SD" {
                                    UtilityKnob(value: Binding(
                                        get: { utilityManager.drumParams[selectedInstrument]?["Snappy"] ?? 0.5 },
                                        set: { utilityManager.drumParams[selectedInstrument]?["Snappy"] = $0 }
                                    ), label: "Snappy")
                                }
                            }
                        }
                    }
                }

                Spacer()

                // Metering
                if manager.activeDevices[utilityManager.drumMachineDeviceID] != nil {
                    ZStack(alignment: .trailing) {
                        ThemeRoundedRectangle(cornerRadius: MeteringCardLayout.cardCornerRadius, style: .continuous)
                            .fill(themeManager.accentFillColor)
                            .overlay(
                                ThemeRoundedRectangle(cornerRadius: MeteringCardLayout.cardCornerRadius, style: .continuous)
                                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                            )
                        VStack(alignment: .center, spacing: MeteringCardLayout.cardContentSpacing) {
                            meteringCardHeader(
                                title: "Master:",
                                subtitle: "Outputs: L - R",
                                headerYOffset: MeteringCardLayout.inputCardHeaderYOffset,
                                headerSubtitleYOffset: MeteringCardLayout.inputCardHeaderSubtitleYOffset
                            )
                            ChannelMeteringGroupView(
                                deviceID: utilityManager.drumMachineDeviceID,
                                channelIndices: [0, 1],
                                showsPerChannelFeatureIcons: false,
                                showsPerChannelLevelTexts: true,
                                channelHeaderYOffset: MeteringCardLayout.inputChannelHeaderYOffset,
                                channelHeaderYOffsetCPU: MeteringCardLayout.inputChannelHeaderYOffsetCPU,
                                capsuleYOffset: MeteringCardLayout.inputCapsuleYOffset,
                                tickMarkYOffset: MeteringCardLayout.inputTickMarkYOffset,
                                tickMarkYOffsetCPU: MeteringCardLayout.inputTickMarkYOffsetCPU
                            )
                        }
                        .padding(MeteringCardLayout.cardContentPadding)
                        .offset(y: MeteringCardLayout.cardContentOffsetY)
                    }
                    .frame(width: 140, height: 415)
                }
            }
            .padding(.horizontal)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.1))
        .onChange(of: isPlaying) { _ in updateTimer() }
        .onChange(of: utilityManager.drumTempo) { _ in updateTimer() }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil

        if isPlaying {
            // Tempo 0.1...1.0 -> ~60...300 BPM
            let bpm = 60.0 + (utilityManager.drumTempo - 0.1) * (240.0 / 0.9)
            let interval = 60.0 / (bpm * 4.0) // 16th notes
            let newTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                advanceStep()
            }
            RunLoop.main.add(newTimer, forMode: .common)
            timer = newTimer
        }
    }

    private func advanceStep() {
        currentStep = (currentStep + 1) % 16

        // Basic swing logic: Delay even steps
        let isEvenStep = currentStep % 2 == 1
        let swingDelay = isEvenStep ? (utilityManager.drumSwing * 0.1) : 0.0

        if swingDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + swingDelay) {
                self.triggerCurrentStep()
            }
        } else {
            triggerCurrentStep()
        }
    }

    private func triggerCurrentStep() {
        let pattern = utilityManager.drumPatterns[utilityManager.drumSelectedPatternIndex]
        for (inst, instSteps) in pattern {
            if instSteps[currentStep] {
                var midiNote: UInt8 = 0
                switch inst {
                case "BD": midiNote = 36
                case "SD": midiNote = 38
                case "CH": midiNote = 42
                case "OH": midiNote = 46
                case "LT": midiNote = 41
                case "MT": midiNote = 43
                case "HT": midiNote = 45
                case "CP": midiNote = 39
                case "CB": midiNote = 56
                case "RS": midiNote = 37
                case "CY": midiNote = 49
                default: break
                }
                if midiNote > 0 {
                    let velocity = UInt8(100.0 * (1.0 + utilityManager.drumAccent * 0.27))
                    utilityManager.handleMIDIMessage(status: 0x90, data1: midiNote, data2: velocity, sourceEndpoint: "Internal Sequencer")
                }
            }
        }
    }

    private func colorForStep(_ index: Int) -> Color {
        // 808 step colors: Red, Orange, Yellow, White
        let colors: [Color] = [.red, .orange, .yellow, .white]
        return colors[(index / 4) % colors.count]
    }
}

// MARK: - Tone Generator Window

struct ToneGeneratorWindowView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @StateObject var utilityManager = UtilityInstrumentManager.shared
    @ObservedObject var manager = AudioDeviceManager.shared

    @State private var frequencyString: String = "1000"

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Tone Generator")
                        .font(.title2.bold())
                    Text("Reference Signal & Noise Generator")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top)

            // Main Controls
            HStack(alignment: .top, spacing: 0) {
                HStack(spacing: 24) {
                    // Bypass
                    VStack(spacing: 8) {
                        Text("BYPASS")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                        Toggle("", isOn: $utilityManager.toneBypass)
                            .toggleStyle(SwitchToggleStyle(tint: .red))
                            .labelsHidden()
                    }
                    .padding(.leading)

                    // Waveform Picker
                    UtilityModuleView(title: "Waveform") {
                        Picker("", selection: $utilityManager.toneWaveform) {
                            Text("Sine").tag(0)
                            Text("Triangle").tag(1)
                            Text("Sawtooth").tag(2)
                            Text("Square").tag(3)
                            Text("Pink").tag(4)
                            Text("White").tag(5)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 450)
                    }

                    // Frequency
                    UtilityModuleView(title: "Frequency") {
                        VStack(spacing: 8) {
                            TextField("", text: $frequencyString, onCommit: {
                                if let val = Double(frequencyString) {
                                    utilityManager.toneFrequency = min(20000.0, max(20.0, val))
                                }
                                frequencyString = String(format: "%.0f", utilityManager.toneFrequency)
                            })
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .frame(width: 80)
                            .padding(4)
                            .background(Color.black.opacity(0.3))
                            .cornerRadius(4)

                            UtilityKnob(value: $utilityManager.toneFrequency, label: "Hz", range: 20...20000)
                                .disabled(utilityManager.toneWaveform >= 4)
                                .opacity(utilityManager.toneWaveform >= 4 ? 0.3 : 1.0)
                                .onChange(of: utilityManager.toneFrequency) { newValue in
                                    frequencyString = String(format: "%.0f", newValue)
                                }
                        }
                    }

                    // Gain
                    UtilityModuleView(title: "Output") {
                        VStack(spacing: 8) {
                            Text("\(Int(utilityManager.toneGain)) dB")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.secondary)
                            UtilityKnob(value: $utilityManager.toneGain, label: "Gain", range: -120...20)
                        }
                    }

                    Spacer()
                }

                Spacer()

                // Metering
                if manager.activeDevices[utilityManager.toneGeneratorDeviceID] != nil {
                    ZStack {
                        ThemeRoundedRectangle(cornerRadius: MeteringCardLayout.cardCornerRadius, style: .continuous)
                            .fill(themeManager.accentFillColor)
                            .overlay(
                                ThemeRoundedRectangle(cornerRadius: MeteringCardLayout.cardCornerRadius, style: .continuous)
                                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                            )
                        VStack(alignment: .center, spacing: MeteringCardLayout.cardContentSpacing) {
                            meteringCardHeader(
                                title: "Output:",
                                subtitle: "L - R",
                                headerYOffset: MeteringCardLayout.inputCardHeaderYOffset,
                                headerSubtitleYOffset: MeteringCardLayout.inputCardHeaderSubtitleYOffset
                            )
                            ChannelMeteringGroupView(
                                deviceID: utilityManager.toneGeneratorDeviceID,
                                channelIndices: [0, 1],
                                showsPerChannelFeatureIcons: false,
                                showsPerChannelLevelTexts: true,
                                channelHeaderYOffset: MeteringCardLayout.inputChannelHeaderYOffset,
                                channelHeaderYOffsetCPU: MeteringCardLayout.inputChannelHeaderYOffsetCPU,
                                capsuleYOffset: MeteringCardLayout.inputCapsuleYOffset,
                                tickMarkYOffset: MeteringCardLayout.inputTickMarkYOffset,
                                tickMarkYOffsetCPU: MeteringCardLayout.inputTickMarkYOffsetCPU
                            )
                        }
                        .padding(MeteringCardLayout.cardContentPadding)
                        .offset(y: MeteringCardLayout.cardContentOffsetY)
                    }
                    .frame(width: 140, height: 415)
                    .padding(.trailing, 20)
                }
            }
            .padding(.horizontal)

            Spacer()
        }
        .background(Color.black.opacity(0.1))
        .onAppear {
            frequencyString = String(format: "%.0f", utilityManager.toneFrequency)
        }
    }
}
