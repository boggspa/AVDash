import SwiftUI

// MARK: - Utilities Section

struct UtilityListView: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var midiManager: MIDIStateManager
    @EnvironmentObject var manager: AudioDeviceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                GlassToolbarPill {
                    Text("Utilities")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
                Spacer()
                GlassToolbarPill {
                    Button {
                        // Potential global utility refresh logic here
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.primary.opacity(0.8))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh utilities")
                }
            }

            VStack(spacing: 12) {
                SynthesizerCard()
                PhysicalModelCard()
                SamplerCard()
                DrumMachineCard()
                ToneGeneratorCard()
            }
        }
    }
}

// MARK: - Sampler Card

struct SamplerCard: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var midiManager: MIDIStateManager
    @EnvironmentObject var manager: AudioDeviceManager

    @State private var isOpen: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Sampler Engine")
                        .font(.subheadline)
                    Text("Multi-Bank Sample Playback")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Custom Audio Loader")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                Spacer()

                Button {
                    if isOpen {
                        FloatingWindowController.shared.closeSamplerWindow()
                        UtilityInstrumentManager.shared.stopSampler()
                    } else {
                        UtilityInstrumentManager.shared.startSampler()
                        FloatingWindowController.shared.showSamplerWindow {
                            SamplerWindowView()
                                .environmentObject(themeManager)
                                .environmentObject(midiManager)
                                .environmentObject(manager)
                        }
                    }
                    isOpen.toggle()
                } label: {
                    Image(systemName: isOpen ? "waveform" : "play.circle")
                        .foregroundColor(isOpen ? .red : .green)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Close Sampler Engine" : "Open Sampler Engine")
            }
            .frame(minWidth: 200)
            .padding()
            .background(ThemeRoundedRectangle(cornerRadius: 10, style: .continuous).themed(fill: themeManager.accentFillColor))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSPanel, window == FloatingWindowController.shared.samplerWindow {
                isOpen = false
                UtilityInstrumentManager.shared.stopSampler()
            }
        }
    }
}

// MARK: - Physical Model Synth Card

struct PhysicalModelCard: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var midiManager: MIDIStateManager
    @EnvironmentObject var manager: AudioDeviceManager

    @State private var isOpen: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Physical Model Synth")
                        .font(.subheadline)
                    Text("Plucked String Modeling")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Karplus-Strong Simulation")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                Spacer()

                Button {
                    if isOpen {
                        FloatingWindowController.shared.closePhysicalModelWindow()
                        UtilityInstrumentManager.shared.stopPhysicalModel()
                    } else {
                        UtilityInstrumentManager.shared.startPhysicalModel()
                        FloatingWindowController.shared.showPhysicalModelWindow {
                            PhysicalModelWindowView()
                                .environmentObject(themeManager)
                                .environmentObject(midiManager)
                                .environmentObject(manager)
                        }
                    }
                    isOpen.toggle()
                } label: {
                    Image(systemName: isOpen ? "waveform" : "play.circle")
                        .foregroundColor(isOpen ? .red : .green)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Close Physical Model Synth" : "Open Physical Model Synth")
            }
            .frame(minWidth: 200)
            .padding()
            .background(ThemeRoundedRectangle(cornerRadius: 10, style: .continuous).themed(fill: themeManager.accentFillColor))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSPanel, window == FloatingWindowController.shared.physicalModelWindow {
                isOpen = false
                UtilityInstrumentManager.shared.stopPhysicalModel()
            }
        }
    }
}

// MARK: - Tone Generator Card

struct ToneGeneratorCard: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var midiManager: MIDIStateManager
    @EnvironmentObject var manager: AudioDeviceManager

    @State private var isOpen: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Tone Generator")
                        .font(.subheadline)
                    Text("Reference Signal & Noise Generator")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Utility Reference Tool")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                Spacer()

                Button {
                    if isOpen {
                        FloatingWindowController.shared.closeToneGeneratorWindow()
                        UtilityInstrumentManager.shared.stopToneGenerator()
                    } else {
                        UtilityInstrumentManager.shared.startToneGenerator()
                        FloatingWindowController.shared.showToneGeneratorWindow {
                            ToneGeneratorWindowView()
                                .environmentObject(themeManager)
                                .environmentObject(midiManager)
                                .environmentObject(manager)
                        }
                    }
                    isOpen.toggle()
                } label: {
                    Image(systemName: isOpen ? "waveform" : "play.circle")
                        .foregroundColor(isOpen ? .red : .green)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Close Tone Generator" : "Open Tone Generator")
            }
            .frame(minWidth: 200)
            .padding()
            .background(ThemeRoundedRectangle(cornerRadius: 10, style: .continuous).themed(fill: themeManager.accentFillColor))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSPanel, window == FloatingWindowController.shared.toneGeneratorWindow {
                isOpen = false
                UtilityInstrumentManager.shared.stopToneGenerator()
            }
        }
    }
}

// MARK: - Synthesizer Card

struct SynthesizerCard: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var midiManager: MIDIStateManager
    @EnvironmentObject var manager: AudioDeviceManager

    @State private var isOpen: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Synthesizer Engine")
                        .font(.subheadline)
                    Text("Multi-Oscillator Subtractive Synth")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Logic Style In-App Plugin")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                Spacer()

                Button {
                    if isOpen {
                        FloatingWindowController.shared.closeSynthesizerWindow()
                        UtilityInstrumentManager.shared.stopSynthesizer()
                    } else {
                        UtilityInstrumentManager.shared.startSynthesizer()
                        FloatingWindowController.shared.showSynthesizerWindow {
                            SynthesizerWindowView()
                                .environmentObject(themeManager)
                                .environmentObject(midiManager)
                                .environmentObject(manager)
                        }
                    }
                    isOpen.toggle()
                } label: {
                    Image(systemName: isOpen ? "waveform" : "play.circle")
                        .foregroundColor(isOpen ? .red : .green)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Close Synthesizer" : "Open Synthesizer")
            }
            .frame(minWidth: 200)
            .padding()
            .background(ThemeRoundedRectangle(cornerRadius: 10, style: .continuous).themed(fill: themeManager.accentFillColor))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSPanel, window == FloatingWindowController.shared.synthesizerWindow {
                isOpen = false
                UtilityInstrumentManager.shared.stopSynthesizer()
            }
        }
    }
}

// MARK: - Drum Machine Card

struct DrumMachineCard: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var midiManager: MIDIStateManager
    @EnvironmentObject var manager: AudioDeviceManager

    @State private var isOpen: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("808 Drum Machine")
                        .font(.subheadline)
                    Text("Analog Style Rhythm Composer")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Logic Style In-App Plugin")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }

                Spacer()

                Button {
                    if isOpen {
                        FloatingWindowController.shared.closeDrumMachineWindow()
                        UtilityInstrumentManager.shared.stopDrumMachine()
                    } else {
                        UtilityInstrumentManager.shared.startDrumMachine()
                        FloatingWindowController.shared.showDrumMachineWindow {
                            DrumMachineWindowView()
                                .environmentObject(themeManager)
                                .environmentObject(midiManager)
                                .environmentObject(manager)
                        }
                    }
                    isOpen.toggle()
                } label: {
                    Image(systemName: isOpen ? "waveform" : "play.circle")
                        .foregroundColor(isOpen ? .red : .green)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .help(isOpen ? "Close Drum Machine" : "Open Drum Machine")
            }
            .frame(minWidth: 200)
            .padding()
            .background(ThemeRoundedRectangle(cornerRadius: 10, style: .continuous).themed(fill: themeManager.accentFillColor))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSPanel, window == FloatingWindowController.shared.drumMachineWindow {
                isOpen = false
                UtilityInstrumentManager.shared.stopDrumMachine()
            }
        }
    }
}
