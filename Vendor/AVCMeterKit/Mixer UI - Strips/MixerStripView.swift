//
//  MixerStripView.swift
//  AVCMeter
//
//  This view handles per-channel audio metering using Metal for high-performance rendering.
//  It is responsible for:
//   - Drawing capsule-shaped meters using Metal and custom fragment/vertex shaders.
//   - Mapping linear input levels (peak/RMS) to decibel scales and animated fill heights.
//   - Theming logic that adjusts the capsule gradient colors based on UI theme (dark/light/material).
//   - Communicating uniform data (fill level, gradient colors, theme) to Metal shaders.
//   - Displaying live RMS and held Peak values beneath each capsule, with interactive reset support.
//   - Rendering one capsule per audio input channel via SwiftUI layout, efficiently integrated with @EnvironmentObject.
//
//  The SwiftUI wrapper supports per-channel UI layout and keeps the Metal view in sync with app-level settings.
//


import Foundation
import MetalKit
import SwiftUI
import CoreAudio
#if os(macOS)
import AppKit
#endif




private let sharedStreamManager = MultiDeviceStreamManager.shared


/// A Metal-based view for rendering a capsule-shaped audio meter for a single audio channel.
///
/// - discussion: This view draws a high-performance, animated capsule meter using Metal shaders. It maps peak/RMS audio levels to fill heights,
///   applies theme-based gradients, and is optimized for per-frame updates. It is intended to be used as part of a SwiftUI UI for channel metering.
class MetalMixerStripView: MTKView, MTKViewDelegate {
    /// The audio metering context providing peak and RMS buffers for this device.
    var context: DeviceMeteringContext!
    /// Index of the audio channel this view represents.
    var channelIndex: Int = 0
    /// The current theme mode, used to select appropriate capsule colors.
    var themeMode: ThemeMode?

    /// Channel mask for this view, indicating enabled/disabled channels.
    var channelMask: [Bool] = []

    /// Metal command queue used for encoding GPU commands.
    private var commandQueue: MTLCommandQueue?
    /// Render pipeline state encapsulating shader functions and configuration.
    private var pipelineState: MTLRenderPipelineState?

    /// Current fill level of the capsule meter (0.0 to 1.0, animated).
    private var fillLevel: Float = 0.0
    /// Cache for last rendered fillLevel to avoid redundant updates.
    private var lastRenderedFillLevel: Float? = nil
    /// Gradient start color for the capsule bar (SIMD RGBA).
    private var startColor: SIMD4<Float> = SIMD4<Float>(0.1, 0.6, 0.1, 1.0)
    /// Gradient end color for the capsule bar (SIMD RGBA).
    private var endColor: SIMD4<Float> = SIMD4<Float>(0.2, 1.0, 0.2, 1.0)

    /// Last time the fill level was updated (for animation smoothing).
    private var lastUpdate: Date = .distantPast

    /// Initializes the MetalCapsuleView with a given frame and Metal device.
    /// - param frameRect: The frame rectangle for the view.
    /// - param device: The Metal device to use (optional).
    override init(frame frameRect: CGRect, device: MTLDevice?) {
        let metalDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect, device: metalDevice)
        self.device = metalDevice
        self.commandQueue = metalDevice?.makeCommandQueue()
        self.delegate = self
        self.enableSetNeedsDisplay = false
        self.isPaused = false
        self.framebufferOnly = false
        self.preferredFramesPerSecond = 30
        self.layer?.isOpaque = false
        self.layer?.backgroundColor = NSColor.clear.cgColor
        self.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.2)
        // No need to start timer; updates now tied to Metal's refresh loop.
    }

    /// Unimplemented required initializer.
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Updates the fill level and determines capsule gradient colors based on the current dB level.
    /// - discussion: Uses exponential smoothing to animate the fill level, and maps decibel bands to specific theme-based gradients.
    /// - note: This method is called once per frame in the Metal draw loop.
    private func updateMixerLevels() {
        guard let ctx = context else {
            return
        }

        // Use the cached most recent value for the peak buffer, but check bounds to avoid out-of-range access
        let allPeaks = context.peakBuffer.allMostRecent()
        guard channelIndex < allPeaks.count else {
            fillLevel = 0
            return
        }
        let rawPeak = allPeaks[channelIndex]
        let rawPeakSafe: Float
        if rawPeak.isFinite && rawPeak > 0 {
            rawPeakSafe = rawPeak
        } else {
            rawPeakSafe = 0.000_001
        }
        let db = 20 * log10(rawPeakSafe) + 5.0
        guard db.isFinite else {
            fillLevel = 0
            return
        }
        let clampedDb = max(-100.0, min(0.0, db))
        // Use a curved mapping to give more visual headroom near 0 dB.
        let normalized = max(0.0, (clampedDb + 80.0) / 80.0)
        let newFillLevel = pow(normalized, 1.0) // curve favors headroom at the top

        // Exponential smoothing for fillLevel with 25ms time constant
        let now = Date()
        let deltaTime = Float(now.timeIntervalSince(lastUpdate))
        lastUpdate = now

        let decayTime: Float = 0.1  // 25 ms time constant
        let smoothingFactor = 1.0 - exp(-deltaTime / decayTime)
        fillLevel += (newFillLevel - fillLevel) * smoothingFactor

        // Determine gradient colors based on decibel level and theme
        if clampedDb >= -0.9 {
            startColor = SIMD4<Float>(0.8, 0.0, 0.0, 1.0) // red
            endColor = SIMD4<Float>(1.0, 0.4, 0.0, 1.0)
        } else if clampedDb >= -12.0 {
            startColor = SIMD4<Float>(1.0, 0.5, 0.0, 1.0) // orange
            endColor = SIMD4<Float>(1.0, 0.8, 0.0, 1.0)
        } else if clampedDb >= -24.0 {
            startColor = SIMD4<Float>(1.0, 1.0, 0.0, 1.0) // yellow
            endColor = SIMD4<Float>(0.5, 1.0, 0.2, 1.0)
        } else {
            // Apply theme-specific colors for lower levels
            switch themeMode {
            case .light:
                startColor = SIMD4<Float>(0.2, 0.2, 1.0, 1.0)
                endColor = SIMD4<Float>(0.0, 0.0, 0.3, 0.5)     //green
            case .thinMaterial:
                startColor = SIMD4<Float>(0.0, 0.6, 0.7, 0.7)
                endColor = SIMD4<Float>(0.0, 0.2, 0.2, 0.3)     //turquoise
            case .purple:
                startColor = SIMD4<Float>(0.6, 0.2, 1.0, 1.0)  // vivid purple
                endColor = SIMD4<Float>(0.3, 0.0, 0.5, 0.5)    // deep purple
            case .dark, .none:
                startColor = SIMD4<Float>(0.2, 0.6, 1.0, 1.0) // blue in dark mode
                endColor = SIMD4<Float>(0.0, 0.2, 0.4, 0.5)   // dark blue end
            case .midnight:
                startColor = SIMD4<Float>(0.0, 0.4, 0.8, 1.0)
                endColor = SIMD4<Float>(0.0, 0.1, 0.2, 0.5)
            case .mint:
                startColor = SIMD4<Float>(0.4, 1.0, 0.7, 1.0)
                endColor = SIMD4<Float>(0.1, 0.7, 0.4, 0.5)
            case .lavender:
                startColor = SIMD4<Float>(0.8, 0.7, 1.0, 1.0)
                endColor = SIMD4<Float>(0.5, 0.4, 0.7, 0.5)
            case .indigo:
                startColor = SIMD4<Float>(0.4, 0.3, 0.9, 1.0)
                endColor = SIMD4<Float>(0.15, 0.15, 0.4, 0.5)
            case .gray:
                startColor = SIMD4<Float>(0.7, 0.7, 0.7, 1.0)
                endColor = SIMD4<Float>(0.2, 0.2, 0.2, 0.5)
            case .hollow:
                startColor = SIMD4<Float>(0.9, 0.9, 0.9, 0.3)
                endColor = SIMD4<Float>(0.7, 0.7, 0.9, 0.1)
            case .liquidGlass:
                startColor = SIMD4<Float>(0.6, 0.9, 1.0, 0.7)
                endColor = SIMD4<Float>(0.3, 0.7, 0.9, 0.4)
            @unknown default:
                startColor = SIMD4<Float>(0.2, 0.6, 1.0, 1.0)
                endColor = SIMD4<Float>(0.0, 0.2, 0.4, 0.5)
            }
        }
        // (No longer needed; Metal draw loop calls updateLevels)
    }


    /// Handles view resizing events from MTKView.
    /// - param view: The Metal view whose drawable size changed.
    /// - param size: The new drawable size.
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle resizing if needed (currently no-op).
    }

    /// Main rendering function called each frame to draw the capsule meter.
    /// - param view: The Metal view to render into.
    /// - discussion: Prepares the Metal pipeline, updates levels, and encodes the draw commands for the capsule meter.
    func draw(in view: MTKView) {
        // Removed window check to ensure draw() runs even if view is momentarily detached.

        // Set clear color to transparent black
        view.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0) // leave as-is for transparency

        // Prepare Metal pipeline state if not already done.
        preparePipelineIfNeeded()

        // Update levels at the start of every draw call.
        updateMixerLevels()

        // Skip drawing if fillLevel is not finite.
        guard fillLevel.isFinite else {
            return
        }

        // Insert guard to skip drawing if fillLevel is nearly zero
        guard fillLevel > 0.005 else {
            return
        }

        // --- Begin enhanced safety checks and logging ---
        guard let queue = commandQueue else {
            return
        }
        guard let descriptor = currentRenderPassDescriptor else {
            return
        }
        guard let drawable = currentDrawable else {
            return
        }
        guard let commandBuffer = queue.makeCommandBuffer() else {
            return
        }
        // --- End enhanced safety checks and logging ---
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.label = "Metal Capsule Encoder"
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0)
        descriptor.colorAttachments[0].loadAction = .clear

        if let pipelineState = pipelineState {
            encoder.setRenderPipelineState(pipelineState)

            // --- Begin real capsule bar rendering ---
            let barWidth: Float = 4.6
            let startX: Float = 0.0
            // Use fixed width and height for the capsule bar
            let screenWidth: Float = 13.0

            let x = startX + 0.7
            // Convert pixel coordinates to normalized device coordinates (NDC) [-1, 1].
            let ndcX = (x / screenWidth) * Float(2.0) - Float(1.0)
            let ndcRight = ((x + barWidth) / screenWidth) * Float(2.0) - Float(1.0)
            let ndcBottom = Float(-1.0)
            // Render a full-height meter track; fragment shader clips by fill level.
            let ndcTop: Float = 0.85

            // Define quad vertices with positions and texture coordinates for the capsule.
            let quadVertices: [Float] = [
                ndcX, ndcBottom, 0, 1,
                ndcRight, ndcBottom, 1, 1,
                ndcX, ndcTop, 0, 0,
                ndcRight, ndcTop, 1, 0
            ]

            // Create vertex buffer from quad vertices.
            let vertexBuffer = device!.makeBuffer(bytes: quadVertices, length: quadVertices.count * MemoryLayout<Float>.size, options: [])
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

            // Pass fillLevel to fragment shader to control capsule fill height.
            var fill = min(max(fillLevel, Float(0.0)), Float(1.0))
            encoder.setFragmentBytes(&fill, length: MemoryLayout<Float>.size, index: 0)

            // Pass start and end gradient colors to fragment shader.
            encoder.setFragmentBytes(&startColor, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            encoder.setFragmentBytes(&endColor, length: MemoryLayout<SIMD4<Float>>.size, index: 2)

            // Pass theme mode as integer to fragment shader for theme-specific rendering.
            var themeRaw: Int32 = {
                switch themeMode {
                case .light: return 0
                case .dark, .midnight: return 1
                case .thinMaterial: return 2
                case .liquidGlass, .poorMansGlass: return 3
                case .purple: return 4
                case .mint: return 5
                case .lavender: return 6
                case .indigo: return 7
                case .gray: return 8
                case .hollow: return 9
                case .none: return -1
                }
            }()
            encoder.setFragmentBytes(&themeRaw, length: MemoryLayout<Int32>.size, index: 3)

            // Draw the capsule quad as a triangle strip.
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            // --- End real capsule bar rendering ---

        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Sets up the Metal render pipeline state, including vertex descriptor and shader functions.
    /// - discussion: This method is called once to set up the Metal pipeline, vertex descriptor, and shader function references.
    /// - note: Safe to call redundantly; only sets up pipeline if not already initialized.
    private func preparePipelineIfNeeded() {
        // Setup Metal render pipeline only once.
        guard pipelineState == nil, let device = device else { return }

        let library: MTLLibrary? = {
            if let metallibURL = Bundle(for: MetalMixerStripView.self).url(forResource: "default", withExtension: "metallib"),
               let frameworkLibrary = try? device.makeLibrary(URL: metallibURL) {
                return frameworkLibrary
            }
            return device.makeDefaultLibrary()
        }()
        let vertexFunction = library?.makeFunction(name: "vertex_main")
        let fragmentFunction = library?.makeFunction(name: "fragment_main")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()

        // Define vertex layout: position (float2) and texture coords (float2).
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0

        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.size * 2
        vertexDescriptor.attributes[1].bufferIndex = 0

        vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.size * 4
        vertexDescriptor.layouts[0].stepRate = 1
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        pipelineDescriptor.vertexDescriptor = vertexDescriptor

        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            // Error handled silently.
        }
    }
}


/// NSViewRepresentable implementation bridging MetalMixerStripView (AppKit) into SwiftUI.
///
/// - discussion: Responsible for creating and updating the MetalMixerStripView instance, passing context, channel, theme, and mask.
private struct MixerStripRepresentableWrapper: NSViewRepresentable {
    /// The audio metering context for the device.
    var context: DeviceMeteringContext
    /// The channel index this strip represents.
    var channelIndex: Int
    /// The current theme mode for strip rendering.
    var themeMode: ThemeMode
    /// Channel mask for this view.
    var channelMask: [Bool]

    @EnvironmentObject private var themeManager: ThemeManager

    /// Creates the MetalMixerStripView instance.
    /// - param context: The SwiftUI context.
    /// - returns: A configured MetalMixerStripView.
    func makeNSView(context: Context) -> MetalMixerStripView {
        let frame = CGRect(x: 0, y: 0, width: 13, height: 270)
        let metalDevice = MTLCreateSystemDefaultDevice()
        let view = MetalMixerStripView(frame: frame, device: metalDevice)
        view.channelIndex = channelIndex
        view.context = self.context
        view.themeMode = themeMode
        view.channelMask = self.channelMask
        return view
    }

    /// Updates the MetalMixerStripView when SwiftUI state changes.
    /// - param nsView: The MetalMixerStripView to update.
    /// - param context: The SwiftUI context.
    func updateNSView(_ nsView: MetalMixerStripView, context: Context) {
        nsView.themeMode = themeMode
        nsView.channelIndex = self.channelIndex
        nsView.context = self.context
        nsView.channelMask = MultiDeviceStreamManager.shared.channelMaskCache[self.context.device.deviceID] ?? []
    }
}

/// SwiftUI wrapper that bridges MetalMixerStripView to SwiftUI views.
///
/// - discussion: This struct provides the necessary context and channel index, and observes theme changes to keep the Metal view in sync.
struct MetalMixerStripRepresentable: View {
    /// The audio metering context for the device.
    var context: DeviceMeteringContext
    /// The channel index this strip represents.
    var channelIndex: Int
    /// Whether this is a virtual instrument strip (modifies label and insert order)
    var isVirtualInstrument: Bool = false
    // Helper function to map ChannelStripColor to Color for channel strip background
    private func colorForChannelStrip(_ color: ChannelStripColor) -> Color {
        switch color {
        case .standard:
            return Color(.black).opacity(0.75)
        case .red:
            return Color.red.opacity(0.6)
        case .blue:
            return Color.blue.opacity(0.6)
        case .green:
            return Color.green.opacity(0.6)
        case .orange:
            return Color.orange.opacity(0.6)
        case .yellow:
            return Color.yellow.opacity(0.6)
        case .gray:
            return Color.gray.opacity(0.6)
        case .white:
            return Color.white.opacity(0.6)
        case .mint:
            return Color(red: 0.62, green: 0.96, blue: 0.78).opacity(0.6)
        case .pink:
            return Color.pink.opacity(0.6)
        case .purple:
            return Color.purple.opacity(0.6)
        }
    }
    /// The theme manager from the environment, used for dynamic theming.
    @EnvironmentObject var themeManager: ThemeManager

    // Added state for post gain editing UI
    @State private var isEditingPostGain: Bool = false
    @State private var postGainInput: String = ""
    @State private var showRoutingPopover = false
    @State private var showDelayPopover = false
    @State private var showVISelectPopover = false
    @State private var showVIKeyboardPopover = false
    @ObservedObject private var virtualChannelManager = VirtualChannelManager.shared

#if os(macOS)
    @StateObject private var waveformBuffer = AudioSampleBuffer()
    @State private var showSpectrogram = false
    @State private var showSpectrum: Bool = false
    @State private var showWaveform = false
    @State private var showSendPrePostPopover = false
    private let floatingWindowController = FloatingWindowController.shared

    /// Helper to get the AudioObjectID for the current channel's volume control.
    private var volumeControlObjectID: AudioObjectID {
        context.device.deviceID
    }

    /// Reads the current volume for this channel from CoreAudio.
    private func getVolume() -> Double {
        var volumeValue: Float32 = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: AudioObjectPropertyElement(channelIndex + 1)
        )
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let deviceID = context.device.deviceID
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &volumeValue)
        return status == noErr ? Double(volumeValue) : 0.8
    }

    /// Sets the volume for this channel via CoreAudio.
    private func setVolume(to newValue: Float) {
        var value = newValue
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: AudioObjectPropertyElement(channelIndex + 1)
        )
        let deviceID = context.device.deviceID
        AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, UInt32(MemoryLayout<Float>.size), &value)
    }
#endif
    @EnvironmentObject var channelStateManager: ChannelStateManager
    let scale = 1.0

    private var isMuted: Bool {
        channelStateManager.isMuted(deviceID: context.device.deviceID, channel: channelIndex)
    }

    private var isSoloed: Bool {
        channelStateManager.isSoloed(deviceID: context.device.deviceID, channel: channelIndex)
    }

    // Link state is now based on adjacent pairs (odd-even pairs)
    private var isLinked: Bool {
        ChannelStateManager.shared.isLinked(deviceID: context.device.deviceID, channel: channelIndex)
    }

    private var inputGlobalChannelID: Int {
        (Int(context.device.deviceID) << 8) | channelIndex
    }

    private var selectedAuxSendLabel: String {
        channelStateManager.auxSendLabel(for: context.device.deviceID, channel: channelIndex)
    }

    private var selectedFXSendLabel: String {
        channelStateManager.fxSendLabel(for: context.device.deviceID, channel: channelIndex)
    }

    // Binding to fader value routed through ChannelStateManager for linked channels
    private var faderBinding: Binding<Double> {
        Binding<Double>(
            get: {
                Double(channelStateManager.fader(for: context.device.deviceID, channel: channelIndex))
            },
            set: { newValue in
                channelStateManager.setFader(for: context.device.deviceID, channel: channelIndex, value: Float(newValue))
            }
        )
    }

    // Binding to aux send value routed through ChannelStateManager
    private var auxSendBinding: Binding<Double> {
        // Updated to call getter function instead of property access
        Binding<Double>(
            get: {
                Double(channelStateManager.auxSendValue(for: context.device.deviceID, channel: channelIndex))
            },
            set: { newValue in
                channelStateManager.setAuxSend(for: context.device.deviceID, channel: channelIndex, value: Float(newValue))
            }
        )
    }

    // Binding to FX send value routed through ChannelStateManager
    private var fxSendBinding: Binding<Double> {
        // Updated to call getter function instead of property access
        Binding<Double>(
            get: {
                Double(channelStateManager.fxSendValue(for: context.device.deviceID, channel: channelIndex))
            },
            set: { newValue in
                channelStateManager.setFXSend(for: context.device.deviceID, channel: channelIndex, value: Float(newValue))
            }
        )
    }

    // Binding to Post Gain value routed through ChannelStateManager
    private var postGainBinding: Binding<Double> {
        Binding<Double>(
            get: {
                // Convert stored dB value (0...28) to dial range (0...127)
                let dbValue = channelStateManager.postGainValue(for: context.device.deviceID, channel: channelIndex)
                return Double((dbValue / 28.0) * 127.0)
            },
            set: { newValue in
                // Convert dial value (0...127) back to dB (0...28)
                let dialValue = Float(newValue)
                let dbValue = (dialValue / 127.0) * 28.0
                channelStateManager.setPostGain(for: context.device.deviceID, channel: channelIndex, value: dbValue)
            }
        )
    }

    /// Tick marks and labels for the y-axis of the meter (dB scale).
    private let yAxisLabels: [Double: (label: String, position: CGFloat)] = [
        0:    (label: "0", position: 0.04),
        -6:   (label: "-6", position: 0.15),
        -12:  (label: "-12", position: 0.28),
        -18:  (label: "-18", position: 0.40),
        -24:  (label: "-24", position: 0.52),
        -40:  (label: "-40", position: 0.74),
        -60:  (label: "-60", position: 0.93),
        -100: (label: "∞", position: 0.99)
    ]

    // This allows yAxisLabelsView to reference yAxisLabels and provides reasonable tick marks for a dB meter.

    private var yAxisLabelsView: some View {
        VStack {
            GeometryReader { geo in
                ForEach(yAxisLabels.keys.sorted(by: >), id: \.self) { db in
                    if let label = yAxisLabels[db] {
                        Text(label.label)
                            .font(.system(size: 7.5, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                            .position(
                                x: geo.size.width - 12,
                                y: geo.size.height * label.position
                            )
                    }
                }
            }
        }
        .frame(width: 26, height: 270)
        .offset(x: 24, y: 142)
    }

    private var meteringCapsuleView: some View {
        let streamManager = MultiDeviceStreamManager.shared
        let themeMode = themeManager.deviceCapsuleThemes[context.device.deviceID] ?? themeManager.capsuleThemeMode
        let channelMask = streamManager.channelMaskCache[context.device.deviceID] ?? []
        return ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(.sRGB, red: 0.08, green: 0.08, blue: 0.08, opacity: 1.0))
                .frame(width: 12, height: 260)
                .offset(x: 10, y: 140)
            MixerStripRepresentableWrapper(
                context: context,
                channelIndex: channelIndex,
                themeMode: themeMode,
                channelMask: channelMask
            )
            .frame(width: 26, height: 280)
            .offset(x: 17, y: 130)
        }
    }

    private var faderAndButtonsView: some View {
        VStack {
    #if os(macOS)
            // Fader bound directly to ChannelStateManager for linking support
            FaderView(
                value: faderBinding,
                minValue: 0.0,
                maxValue: 1.2,
                trackHeight : 260,
                trackWidth: 2,
                thumbHeight: 42,
                thumbWidth: 45,
                capStyle: .standard,
                deviceID: context.device.deviceID,
                channelIndex: channelIndex,
                role: .input
            )
            .frame(width: 28, height: 270)
            .offset(x: 45, y: 145)
    #else
            Slider(value: .constant(0.5), in: 0...1)
                .rotationEffect(.degrees(-90))
                .frame(height: 280)
                .padding(.leading, 6)
    #endif
            // Mute/Solo/Link buttons
            VStack {
                // Note: ChannelStateManager.toggleLink always links odd/even pairs as a unit.
                // Both buttons in the pair will show the toggled effect when linked.
                Button(action: {
                    ChannelStateManager.shared.toggleLink(deviceID: context.device.deviceID, channel: channelIndex)
                }) {
                    Image(systemName: "link")
                        .font(.system(size: 14, weight: .bold))
                        // Use the shared ChannelStateManager to check linked state, reflecting adjacent pairing logic
                        .foregroundColor(isLinked ? .white : .blue)
                        .padding(.horizontal, 2)
                        .background(
                            ZStack {
                                isLinked ? Color.blue : Color.black.opacity(0.6)
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
                            }
                        )
                        .cornerRadius(6)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .offset(x: 0, y: 145)

            VStack {
                Text("M")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(isMuted ? .white : .red)
                    .padding(.horizontal, 2)
                    .background(
                        ZStack {
                            isMuted ? Color.red : Color.black.opacity(0.6)
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.6), lineWidth: 1)
                        }
                    )
                    .cornerRadius(6)
                    .onTapGesture {
                        channelStateManager.toggleMute(deviceID: context.device.deviceID, channel: channelIndex)
                    }
            }
            .offset(x: 25, y: 127)

            VStack {
                Text("S")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(isSoloed ? .white : .yellow)
                    .padding(.horizontal, 6)
                    .background(
                        ZStack {
                            isSoloed ? Color.yellow : Color.black.opacity(0.6)
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.6), lineWidth: 1)
                        }
                    )
                    .cornerRadius(6)
                    .onTapGesture {
                        channelStateManager.toggleSolo(deviceID: context.device.deviceID, channel: channelIndex)
                    }
            }
            .offset(x: 50, y: 108)
        }
        .frame(width: 36)
    }

    // MARK: - Overlay Rows for Modular Layout

    private var iconButtonRow: some View {
        HStack(spacing: 2) {
            Button(action: {
                showWaveform.toggle()
                let controller = floatingWindowController
                if showWaveform {
                    controller.showWaveformWindow(deviceID: context.device.deviceID, channelIndex: channelIndex) {
                        WaveformView(
                            buffer: waveformBuffer,
                            deviceID: context.device.deviceID,
                            channelIndex: channelIndex,
                            themeMode: WaveformThemeMode(rawValue: themeManager.deviceCapsuleThemes[context.device.deviceID]?.rawValue ?? themeManager.capsuleThemeMode.rawValue) ?? .light,
                            deviceName: context.device.name,
                            scale: scale
                        )
                        .environmentObject(themeManager)
                        .frame(width: 750, height: 180)
                        .background(Color.clear)
                    }
                } else {
                    controller.closeWaveformWindow(for: context.device.deviceID, channelIndex: channelIndex)
                }
            }) {
                Image(systemName: "waveform")
                    .resizable()
                    .frame(width: 10, height: 10)
                    .foregroundColor(.primary)
                    .padding(6)
            }
            .buttonStyle(PlainButtonStyle())
            .background(
                ZStack {
                    Color(.sRGB, red: 0.6, green: 0.6, blue: 0.85, opacity: 0.6)
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
                }
            )
            .cornerRadius(6)

            Button(action: {
                showSpectrum.toggle()
                let deviceID = context.device.deviceID
                let scale = themeManager.deviceSpectrumScaleFactors[deviceID] ?? 1.0
                let channelCount = UInt32(context.device.inputChannels)

                let controller = floatingWindowController
                if showSpectrum {
                    let fftSize = VisualisationSettings.shared.spectrumFFTSize
                    let manager = FFTStreamManager(
                        deviceID: deviceID,
                        channelCount: channelCount,
                        sampleRate: 48000,
                        bufferSize: UInt32(fftSize)
                    )
                    if let manager = manager {
                        try? manager.start()
                        let processor = SafeFFTSpectrumProcessor(
                            streamManager: manager,
                            channelIndex: channelIndex,
                            channelCount: Int(channelCount),
                            fftSize: fftSize
                        )
                        processor.start()
                        let pickedTheme = themeManager.deviceCapsuleThemes[deviceID] ?? themeManager.capsuleThemeMode
                        controller.showSpectrumWindow(deviceID: deviceID, channelIndex: channelIndex, scale: scale) {
                            SpectrumContainer(
                                processor: processor,
                                themeMode: pickedTheme,
                                scale: scale
                            )
                            .environmentObject(themeManager)
                            .frame(width: 750 * scale, height: 380 * scale)
                            .background(Color.clear)
                        }
                    }
                } else {
                    controller.closeSpectrumWindow(for: deviceID, channelIndex: channelIndex)
                }
            }) {
                Image(systemName: "waveform.path.ecg")
                    .resizable()
                    .frame(width: 10, height: 10)
                    .foregroundColor(.primary)
                    .padding(6)
            }
            .buttonStyle(PlainButtonStyle())
            .background(
                ZStack {
                    Color(.sRGB, red: 0.6, green: 0.6, blue: 0.85, opacity: 0.6)
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
                }
            )
            .cornerRadius(6)

            Button(action: {
                showSpectrogram.toggle()
            }) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .resizable()
                    .frame(width: 10, height: 10)
                    .foregroundColor(.primary)
                    .padding(6)
            }
            .buttonStyle(PlainButtonStyle())
            .background(
                ZStack {
                    Color(.sRGB, red: 0.6, green: 0.6, blue: 0.85, opacity: 0.6)
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
                }
            )
            .cornerRadius(6)
            .onChange(of: showSpectrogram) { newValue in
                DispatchQueue.main.async {
                    if newValue {
                        let pickedTheme = themeManager.deviceCapsuleThemes[context.device.deviceID] ?? themeManager.capsuleThemeMode
                        let simdTheme = simdColor(from: spectrumLineColor(for: SpectrumThemeMode(from: pickedTheme)))
                        let deviceID = UInt32(context.device.deviceID)
                        let channelCount = UInt32(context.device.inputChannels)
                        guard SpectroManager.shared.acquireSpectrogramSession(
                            deviceID: deviceID,
                            channelCount: channelCount,
                            channel: Int32(channelIndex)
                        ) else {
                            showSpectrogram = false
                            return
                        }
                        let scale = themeManager.deviceSpectrumScaleFactors[context.device.deviceID] ?? 1.0
                        floatingWindowController.showSpectrogramWindow(
                            deviceID: context.device.deviceID,
                            channelIndex: channelIndex,
                            scale: scale
                        ) {
                            SpectroBackendView(
                                deviceID: Int32(context.device.deviceID),
                                channelIndex: Int32(channelIndex),
                                fftSize: 512,
                                themeColor: simdTheme,
                                themeMode: Int32(pickedTheme.rawValue),
                                deviceName: context.device.name,
                                scale: scale
                            )
                            .environmentObject(themeManager)
                            .frame(width: 750 * scale, height: 380 * scale)
                            .background(Color.clear)
                        }
                    } else {
                        floatingWindowController.closeSpectrogramWindow(for: context.device.deviceID, channelIndex: channelIndex)
                    }
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .onReceive(NotificationCenter.default.publisher(for: .floatingSpectrumWindowDidClose)) { notification in
            if notification.matchesFloatingWindow(deviceID: context.device.deviceID, channelIndex: channelIndex, suffix: "spectrum") {
                showSpectrum = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .floatingWaveformWindowDidClose)) { notification in
            if notification.matchesFloatingWindow(deviceID: context.device.deviceID, channelIndex: channelIndex, suffix: "waveform") {
                showWaveform = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .floatingSpectrogramWindowDidClose)) { notification in
            if notification.matchesFloatingWindow(deviceID: context.device.deviceID, channelIndex: channelIndex, suffix: "spectrogram") {
                showSpectrogram = false
            }
        }
        .offset(x: 2, y: -182)
    }

    private var routingRow: some View {
        HStack(spacing: 2) {
            Button(action: {
                showRoutingPopover = true
            }) {
                Image(systemName: "arrow.triangle.branch")
                    .resizable()
                    .frame(width: 10, height: 10)
                    .foregroundColor(.primary)
                    .padding(6)
            }
            .buttonStyle(PlainButtonStyle())
            .background(
                ZStack {
                    Color(.sRGB, red: 0.2, green: 0.8, blue: 0.1, opacity: 0.6)
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
                }
            )
            .cornerRadius(6)
            .popover(isPresented: $showRoutingPopover) {
                RoutingPopover(inputGlobalChannelID: inputGlobalChannelID)
            }

            if isVirtualInstrument {
                Button(action: {
                    showVIKeyboardPopover.toggle()
                }) {
                    Image(systemName: "pianokeys")
                        .resizable()
                        .frame(width: 12, height: 10)
                        .foregroundColor(showVIKeyboardPopover ? .white : .primary)
                        .padding(6)
                }
                .buttonStyle(PlainButtonStyle())
                .background(
                    ZStack {
                        showVIKeyboardPopover
                            ? Color(.sRGB, red: 0.08, green: 0.75, blue: 0.42, opacity: 0.9)
                            : Color(.sRGB, red: 0.1, green: 0.55, blue: 0.35, opacity: 0.6)
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.6), lineWidth: 1)
                    }
                )
                .cornerRadius(6)
                .popover(isPresented: $showVIKeyboardPopover) {
                    viKeyboardPopover
                }
            } else {
                // Polarity flip toggle — brightens to solid orange when active
                Button(action: {
                    channelStateManager.togglePolarity(deviceID: context.device.deviceID, channel: channelIndex)
                }) {
                    Image(systemName: "arrow.2.squarepath")
                        .resizable()
                        .frame(width: 10, height: 10)
                        .foregroundColor(channelStateManager.isPolarityFlipped(deviceID: context.device.deviceID, channel: channelIndex) ? .white : .primary)
                        .padding(6)
                }
                .buttonStyle(PlainButtonStyle())
                .background(
                    ZStack {
                        channelStateManager.isPolarityFlipped(deviceID: context.device.deviceID, channel: channelIndex)
                            ? Color(.sRGB, red: 1.0, green: 0.55, blue: 0.05, opacity: 0.9)
                            : Color(.sRGB, red: 0.8, green: 0.4, blue: 0.3, opacity: 0.6)
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.6), lineWidth: 1)
                    }
                )
                .cornerRadius(6)
            }

            // Delay — brightens to solid blue when a delay is active
            Button(action: { showDelayPopover.toggle() }) {
                Image(systemName: "timer")
                    .resizable()
                    .frame(width: 10, height: 10)
                    .foregroundColor(channelStateManager.delayMs(for: context.device.deviceID, channel: channelIndex) > 0 ? .white : .primary)
                    .padding(6)
            }
            .buttonStyle(PlainButtonStyle())
            .background(
                ZStack {
                    channelStateManager.delayMs(for: context.device.deviceID, channel: channelIndex) > 0
                        ? Color(.sRGB, red: 0.1, green: 0.3, blue: 1.0, opacity: 0.9)
                        : Color(.sRGB, red: 0.2, green: 0.4, blue: 0.9, opacity: 0.6)
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
                }
            )
            .cornerRadius(6)
            .popover(isPresented: $showDelayPopover) {
                ChannelDelayPopover(deviceID: context.device.deviceID, channelIndex: channelIndex)
                    .environmentObject(channelStateManager)
            }
        }
        .offset(x: 2, y: -180)
    }

    private var divider1: some View {
        Rectangle()
            .fill(Color.white.opacity(0.4))
            .frame(width: 80, height: 1)
            .offset(x: 2, y: -4)
    }

    private var eqEnabledBinding: Binding<Bool> {
        Binding(
            get: { channelStateManager.eqSettings(for: context.device.deviceID, channel: channelIndex).enabled },
            set: { newValue in
                channelStateManager.updateEQSettings(for: context.device.deviceID, channel: channelIndex) { $0.enabled = newValue }
            }
        )
    }

    private var dynamicsEnabledBinding: Binding<Bool> {
        Binding(
            get: { channelStateManager.dynamicsSettings(for: context.device.deviceID, channel: channelIndex).enabled },
            set: { newValue in
                channelStateManager.updateDynamicsSettings(for: context.device.deviceID, channel: channelIndex) { $0.enabled = newValue }
            }
        )
    }

    private var insertsView: some View {
        VStack(spacing: 6) {
            if isVirtualInstrument {
                // VI Select at top (replaces EQ position)
                viSelectInsertTile

                // EQ moved down (replaces Dynamics position)
                insertTile(title: "EQ", accent: Color(red: 0.0, green: 0.75, blue: 0.8), isEnabled: eqEnabledBinding) {
                    FloatingWindowController.shared.showInputEQWindow(
                        deviceID: context.device.deviceID,
                        channelIndex: channelIndex
                    ) {
                        InputChannelEQWindowView(device: context.device, channelIndex: channelIndex)
                            .environmentObject(channelStateManager)
                            .environmentObject(themeManager)
                    }
                }

                // Dynamics moved down (replaces Insert 3 position)
                insertTile(title: "Dynamics", accent: .green, isEnabled: dynamicsEnabledBinding) {
                    FloatingWindowController.shared.showInputDynamicsWindow(
                        deviceID: context.device.deviceID,
                        channelIndex: channelIndex
                    ) {
                        InputChannelDynamicsWindowView(device: context.device, channelIndex: channelIndex)
                            .environmentObject(channelStateManager)
                            .environmentObject(themeManager)
                    }
                }
            } else {
                // Standard input mixer layout
                insertTile(title: "EQ", accent: Color(red: 0.0, green: 0.75, blue: 0.8), isEnabled: eqEnabledBinding) {
                    FloatingWindowController.shared.showInputEQWindow(
                        deviceID: context.device.deviceID,
                        channelIndex: channelIndex
                    ) {
                        InputChannelEQWindowView(device: context.device, channelIndex: channelIndex)
                            .environmentObject(channelStateManager)
                            .environmentObject(themeManager)
                    }
                }

                insertTile(title: "Dynamics", accent: .green, isEnabled: dynamicsEnabledBinding) {
                    FloatingWindowController.shared.showInputDynamicsWindow(
                        deviceID: context.device.deviceID,
                        channelIndex: channelIndex
                    ) {
                        InputChannelDynamicsWindowView(device: context.device, channelIndex: channelIndex)
                            .environmentObject(channelStateManager)
                            .environmentObject(themeManager)
                    }
                }

                insertTile(title: "Insert 3")
            }
        }
        .offset(x: 2, y: -140)
    }

    private var viSelectTileTitle: String {
        guard let selectedName = virtualChannelManager.selectedVirtualInstrumentDisplayName(
            for: context.device.deviceID,
            channelIndex: channelIndex
        ) else {
            return "VI Select"
        }

        let trimmedName = selectedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return "VI Select"
        }

        if trimmedName.count <= 10 {
            return trimmedName
        }
        return "\(trimmedName.prefix(9))…"
    }

    private var viSelectInsertTile: some View {
        insertTile(title: viSelectTileTitle, accent: Color(red: 0.8, green: 0.4, blue: 1.0)) {
            showVISelectPopover = true
        }
        .popover(isPresented: $showVISelectPopover) {
            viInstrumentSelectionPopover
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
                                for: context.device.deviceID,
                                channelIndex: channelIndex
                            )
                            let isSelected = selectedID == instrument.id

                            Button {
                                virtualChannelManager.selectVirtualInstrument(
                                    instrument,
                                    for: context.device.deviceID,
                                    channelIndex: channelIndex
                                )
                                showVISelectPopover = false
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
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isSelected ? Color.purple.opacity(0.18) : Color.white.opacity(0.05))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if virtualChannelManager.selectedVirtualInstrumentID(
                for: context.device.deviceID,
                channelIndex: channelIndex
            ) != nil {
                HStack {
                    Button("Clear Selection") {
                        virtualChannelManager.clearVirtualInstrumentSelection(
                            for: context.device.deviceID,
                            channelIndex: channelIndex
                        )
                    }
                    .buttonStyle(.plain)

#if os(macOS)
                    Button("Open Plugin UI") {
                        VirtualInstrumentHostManager.shared.showInstrumentEditor(
                            for: context.device.deviceID,
                            channelIndex: channelIndex
                        )
                    }
                    .buttonStyle(.plain)
#endif

                    Spacer()

                    if let selectedName = virtualChannelManager.selectedVirtualInstrumentDisplayName(
                        for: context.device.deviceID,
                        channelIndex: channelIndex
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

    private var viKeyboardPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On-Screen Keyboard")
                .font(.headline)

            HStack(spacing: 6) {
                ForEach(Array([48, 50, 52, 53, 55, 57, 59, 60].enumerated()), id: \.offset) { _, midiNote in
                    Button(action: {
                        VirtualInstrumentHostManager.shared.triggerPreviewNote(
                            for: context.device.deviceID,
                            channelIndex: channelIndex,
                            note: UInt8(midiNote),
                            velocity: 100,
                            duration: 0.35
                        )
                    }) {
                        VStack(spacing: 3) {
                            Text(noteName(for: midiNote))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundColor(.black.opacity(0.75))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white)
                                .frame(width: 22, height: 56)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(Color.black.opacity(0.35), lineWidth: 1)
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Preview notes are sent to the selected VI on this strip.")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(width: 260)
    }

    private func noteName(for midiNote: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = (midiNote / 12) - 1
        return "\(names[midiNote % 12])\(octave)"
    }

    private func insertTile(title: String,
                            accent: Color = .white,
                            isEnabled: Binding<Bool>? = nil,
                            action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 0) {
            if let binding = isEnabled {
                Circle()
                    .fill(binding.wrappedValue ? accent : Color.gray.opacity(0.5))
                    .frame(width: 7, height: 7)
                    .padding(.horizontal, 4)
                    .onTapGesture { binding.wrappedValue.toggle() }
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 1, height: 20)
            }
            Button(action: { action?() }) {
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black.opacity(0.4))
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(accent.opacity(0.5), lineWidth: 1)
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(accent)
                }
                .frame(width: isEnabled != nil ? 57 : 72, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(action == nil)
            .saturation(isEnabled?.wrappedValue == false ? 0 : 1)
        }
        .frame(width: 72, height: 20)
    }

    private var divider2: some View {
        Rectangle()
            .fill(Color.white.opacity(0.4))
            .frame(width: 80, height: 1)
            .offset(x: 2, y: -22)
    }

    private func sendDestinationTile(label: String, isPreFade: Bool, onToggle: @escaping () -> Void) -> some View {
        Button(action: {
            onToggle()
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.4))
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                VStack(spacing: 1) {
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.white)
                    Text(isPreFade ? "Pre" : "Post")
                        .font(.system(size: 6, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .frame(width: 42, height: 18)
        }
        .buttonStyle(PlainButtonStyle())
        .popover(isPresented: $showSendPrePostPopover) {
            VStack(spacing: 8) {
                Text("Send Position")
                    .font(.headline)
                Toggle("Pre-Fade", isOn: Binding(
                    get: { isPreFade },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(SwitchToggleStyle())
                Text("Pre-Fade: Send level is independent of fader")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Post-Fade: Send level follows fader")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(width: 200)
        }
    }

    private func sendMenuTile(label: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(0.3))
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.white.opacity(0.4), lineWidth: 1)
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .frame(width: 72, height: 20)
    }

    private var auxSendDestinationMenu: some View {
        Menu {
            if virtualChannelManager.auxSendChannels.isEmpty {
                Text("No Aux Sends")
            } else {
                ForEach(Array(virtualChannelManager.auxSendChannels.enumerated()), id: \.offset) { index, channel in
                    Button {
                        channelStateManager.setSelectedAuxSendIndex(for: context.device.deviceID, channel: channelIndex, value: index)
                    } label: {
                        Text(index == channelStateManager.selectedAuxSendIndex(for: context.device.deviceID, channel: channelIndex)
                             ? "✓ \(channel.name)"
                             : channel.name)
                    }
                }
            }
        } label: {
            sendMenuTile(label: "Aux Sends")
        }
        .menuStyle(BorderlessButtonMenuStyle())
    }

    private var fxSendDestinationMenu: some View {
        Menu {
            if virtualChannelManager.fxSendChannels.isEmpty {
                Text("No FX Sends")
            } else {
                ForEach(Array(virtualChannelManager.fxSendChannels.enumerated()), id: \.offset) { index, channel in
                    Button {
                        channelStateManager.setSelectedFXSendIndex(for: context.device.deviceID, channel: channelIndex, value: index)
                    } label: {
                        Text(index == channelStateManager.selectedFXSendIndex(for: context.device.deviceID, channel: channelIndex)
                             ? "✓ \(channel.name)"
                             : channel.name)
                    }
                }
            }
        } label: {
            sendMenuTile(label: "FX Sends")
        }
        .menuStyle(BorderlessButtonMenuStyle())
    }

    private var dialsView: some View {
        VStack(spacing: 4) {
            HStack(spacing: 13) {
                AuxSendDialView(
                    themeMode: themeManager.deviceCapsuleThemes[context.device.deviceID] ?? themeManager.capsuleThemeMode,
                    value: auxSendBinding
                )
                .frame(width: 14, height: 14)
                .help("Aux Send Dial\n270° range\n0 = dry, 127 = max send")

                sendDestinationTile(
                    label: selectedAuxSendLabel,
                    isPreFade: channelStateManager.auxSendPreFade(for: context.device.deviceID, channel: channelIndex),
                    onToggle: {
                        channelStateManager.setAuxSendPreFade(
                            for: context.device.deviceID,
                            channel: channelIndex,
                            value: !channelStateManager.auxSendPreFade(for: context.device.deviceID, channel: channelIndex)
                        )
                    }
                )
            }
            .offset(x: 28, y: -10)

            auxSendDestinationMenu
                .frame(width: 72, height: 20)
                .offset(x: 30, y: -6)

            Rectangle()
                .fill(Color.white.opacity(0.4))
                .frame(width: 80, height: 1)
                .offset(x: 30, y: -62)

            HStack(spacing: 13) {
                FXSendDialView(
                    themeMode: themeManager.deviceCapsuleThemes[context.device.deviceID] ?? themeManager.capsuleThemeMode,
                    value: fxSendBinding
                )
                .frame(width: 14, height: 14)
                .help("FX Send Dial\n270° range\n0 = dry, 127 = max send")

                sendDestinationTile(
                    label: selectedFXSendLabel,
                    isPreFade: channelStateManager.fxSendPreFade(for: context.device.deviceID, channel: channelIndex),
                    onToggle: {
                        channelStateManager.setFXSendPreFade(
                            for: context.device.deviceID,
                            channel: channelIndex,
                            value: !channelStateManager.fxSendPreFade(for: context.device.deviceID, channel: channelIndex)
                        )
                    }
                )
            }
            .offset(x: 30, y: -4)

            fxSendDestinationMenu
                .frame(width: 72, height: 20)
                .offset(x: 28, y: 0)

            Rectangle()
                .fill(Color.white.opacity(0.4))
                .frame(width: 80, height: 1)
                .offset(x: 30, y: -226)

            HStack(spacing: 13) {
                PostGainDialView(
                    themeMode: themeManager.deviceCapsuleThemes[context.device.deviceID] ?? themeManager.capsuleThemeMode,
                    value: postGainBinding
                )
                .frame(width: 14, height: 14)
                .help("Post Gain Dial\n270° range\n0 = min, 127 = max")

                postGainValueTile
            }
            .offset(x: 28, y: -226)

            Rectangle()
                .fill(Color.white.opacity(0.4))
                .frame(width: 80, height: 1)
                .offset(x: 30, y: -224)
        }
        .offset(x: -28, y: -120)
    }

    private var postGainValueTile: some View {
        Group {
            if isEditingPostGain {
                TextField(
                    "",
                    text: $postGainInput,
                    onCommit: {
                        applyPostGainEditing()
                    }
                )
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 42, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black.opacity(0.4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                        )
                )
                .onExitCommand(perform: {
                    applyPostGainEditing()
                })
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black.opacity(0.4))
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.white.opacity(0.4), lineWidth: 1)
                    Text(channelStateManager.postGainDisplayString(for: context.device.deviceID, channel: channelIndex))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                }
                .frame(width: 42, height: 18)
                .onTapGesture(count: 2) {
                    postGainInput = extractNumericPostGain(from: channelStateManager.postGainDisplayString(for: context.device.deviceID, channel: channelIndex))
                    isEditingPostGain = true
                }
            }
        }
    }

    // Focus state for TextField
    @State private var isNameFieldFocused: Bool = false

    /// Applies the editing results: parses input, clamps, updates channel state, and exits editing mode.
    private func applyPostGainEditing() {
        let trimmed = postGainInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let inputValue = Float(trimmed) {
            // Clamp between 0.0 and 28.0 dB
            let clampedDB = min(max(inputValue, 0.0), 28.0)
            channelStateManager.setPostGain(for: context.device.deviceID, channel: channelIndex, value: clampedDB)
        }
        isEditingPostGain = false
    }

    /// Extracts numeric value from post gain display string, returns as string for editing field.
    private func extractNumericPostGain(from displayString: String) -> String {
        // Attempt to extract numeric component from string, e.g. "12.3 dB" -> "12.3"
        let pattern = #"([0-9]+(\.[0-9]+)?)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: displayString, options: [], range: NSRange(location: 0, length: displayString.utf16.count)) {
            if let range = Range(match.range(at: 1), in: displayString) {
                return String(displayString[range])
            }
        }
        return ""
    }

    private var panPeakRow: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.6))
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
                MixerStripPeakReadout(
                    context: context,
                    channelIndex: channelIndex,
                    isVirtualInstrument: isVirtualInstrument
                )
            }
            .frame(width: 35, height: 20)
            .offset(x: 2)

            // Updated PanDialView with deviceID and channelIndex, binding to ChannelStateManager
            PanDialView(
                value: Binding(
                    get: {
                        Double(channelStateManager.pan(for: context.device.deviceID, channel: channelIndex))
                    },
                    set: { newValue in
                        channelStateManager.setPan(for: context.device.deviceID, channel: channelIndex, value: Float(newValue))
                    }
                ),
                themeMode: themeManager.deviceCapsuleThemes[context.device.deviceID] ?? themeManager.capsuleThemeMode,
                deviceID: context.device.deviceID,
                channelIndex: channelIndex
            )
            .frame(width: 32, height: 32)
            .offset(x: 2)
            .help("Pan Dial\n270° range\n0 = hard left, 127 = hard right\n63 = center")
        }
        .offset(x: 0, y: -135)
    }

    /*
     Note: Overlays and gestures should use ChannelStateManager.shared.bubbleStates and showBubble
     to support consistent bubble UI behavior across channel views, following the pattern in FaderView.swift.
    */

    private var channelLabelOverlayView: some View {
        ZStack {
            Rectangle()
                .fill(themeManager.accentFillColor)
                .frame(width: 80, height: 22)
            Rectangle()
                .stroke(colorForChannelStrip(isVirtualInstrument ? .purple : (themeManager.deviceChannelStripColors[context.device.deviceID] ?? .standard)), lineWidth: 2)
                .frame(width: 80, height: 22)

            Text(isVirtualInstrument ? "VI \(channelIndex + 1)" : "Input \(channelIndex + 1)")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.primary)
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
                .offset(y: -1)
        }
        .offset(x: 2, y: 440)
    }

    private var highlightRectangle: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(Color.accentColor.opacity(0.65), lineWidth: 4)
            .frame(width: 80, height: 22)
            .offset(x: 2, y: 444)
    }


    var body: some View {
        ZStack(alignment: .topLeading) {
            meteringCapsuleView
            yAxisLabelsView
            faderAndButtonsView

            // Overlay rows stacked vertically with modular offsets, no nested ZStacks
            VStack(spacing: 0) {
                iconButtonRow
                routingRow
                divider1
                insertsView
                divider2
                dialsView
                panPeakRow
            }
            .frame(width: 120, alignment: .leading)

            highlightRectangle
            channelLabelOverlayView
        }
        .frame(width: 120, height: 320)
        .background(Color.clear)
    }
}

private struct MixerStripPeakReadout: View {
    let context: DeviceMeteringContext
    let channelIndex: Int
    let isVirtualInstrument: Bool

    @State private var currentPeakDB: Double = -100.0
    private let peakTimer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        let (displayDB, color) = isVirtualInstrument
            ? virtualInstrumentPeakLabelAndColor(for: currentPeakDB)
            : peakColorAndLabel(for: currentPeakDB)

        Text(displayDB)
            .font(.system(size: isVirtualInstrument ? 9 : 10, weight: .medium, design: .monospaced))
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .frame(maxWidth: .infinity)
            .onAppear(perform: refreshPeak)
            .onReceive(peakTimer) { _ in refreshPeak() }
    }

    private func refreshPeak() {
        let peaks = context.peakBuffer.allMostRecent()
        let peak = channelIndex < peaks.count ? peaks[channelIndex] : 0.0
        let nextPeakDB = Double(peak.isFinite && peak > 0 ? 20 * log10(peak) : -100.0)

        if abs(nextPeakDB - currentPeakDB) >= 0.1 || (nextPeakDB <= -99.5) != (currentPeakDB <= -99.5) {
            currentPeakDB = nextPeakDB
        }
    }

    private func peakColorAndLabel(for db: Double) -> (String, Color) {
        if db <= -99.5 {
            return ("-∞", .white)
        }

        let value = String(format: "%5.1f", db + 5.0)
        let color: Color
        switch db {
        case ..<(-44): color = .white
        case -44 ... -32: color = Color(.sRGB, red: 0.0, green: 0.6, blue: 0.6)
        case -32 ... -22: color = .green
        case -22 ... -16: color = .yellow
        case -16 ... -8: color = .orange
        case -8 ... 6: color = .red
        default: color = .white
        }
        return (value, color)
    }

    private func virtualInstrumentPeakLabelAndColor(for db: Double) -> (String, Color) {
        if db <= -99.5 {
            return ("-∞", .white.opacity(0.85))
        }

        let color: Color
        switch db {
        case ..<(-44): color = .white
        case -44 ... -32: color = Color(.sRGB, red: 0.0, green: 0.6, blue: 0.6)
        case -32 ... -22: color = .green
        case -22 ... -16: color = .yellow
        case -16 ... -8: color = .orange
        case -8 ... 6: color = .red
        default: color = .white
        }

        return (String(format: "%+.1f", db), color)
    }
}

struct RoutingPopover: View {
    let inputGlobalChannelID: Int
    @ObservedObject private var routingManager = AudioRoutingMatrixManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Output Routing")
                    .font(.headline)
                Spacer()
                Button("All") {
                    routingManager.setAllRoutes(forInput: inputGlobalChannelID, enabled: true)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

                Button("None") {
                    routingManager.setAllRoutes(forInput: inputGlobalChannelID, enabled: false)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            }

            if routingManager.outputChannels.isEmpty {
                Text("No active output channels")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(routingManager.outputChannels, id: \.self) { outputChannelID in
                            let isEnabled = routingManager.isRouteEnabled(input: inputGlobalChannelID, output: outputChannelID)
                            Button {
                                routingManager.setRoute(
                                    input: inputGlobalChannelID,
                                    output: outputChannelID,
                                    enabled: !isEnabled
                                )
                            } label: {
                                HStack(spacing: 10) {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(isEnabled ? Color.green.opacity(0.85) : Color.white.opacity(0.12))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                .stroke(isEnabled ? Color.green.opacity(0.95) : Color.white.opacity(0.18), lineWidth: 1)
                                        )
                                        .frame(width: 18, height: 18)
                                        .overlay(
                                            Image(systemName: isEnabled ? "checkmark" : "xmark")
                                                .font(.system(size: 8, weight: .bold))
                                                .foregroundColor(.white.opacity(isEnabled ? 0.95 : 0.45))
                                        )

                                    Text(routingManager.outputLabels[outputChannelID] ?? "Out \(outputChannelID)")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.white.opacity(0.05))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 280, minHeight: 120)
        .onAppear {
            routingManager.updateRoutingMatrixMappings()
        }
    }
}

final class MixerInputChannelFFTAnalyzer: ObservableObject {
    /// Pre-EQ spectrum processor (reads from device input directly)
    let processor: SafeFFTSpectrumProcessor?
    /// Post-EQ spectrum processor (reads from mixer's post-EQ ring buffer)
    let postEQProcessor: SafeFFTSpectrumProcessor?
    private let streamManager: FFTStreamManager?
    private let postEQReader: PostEQStreamReader?

    init(device: AudioDevice, channelIndex: Int, role: ChannelRole = .input) {
        let channelCount: UInt32
        switch role {
        case .input:
            channelCount = max(device.inputChannels, 1)
        case .output:
            channelCount = max(device.outputChannels, 1)
        }
        let sampleRate = UInt32(max(1.0, device.sampleRate.rounded()))

        let fftSize = VisualisationSettings.shared.spectrumFFTSize

        // Pre-EQ source by role.
        switch role {
        case .input:
            if let streamManager = FFTStreamManager(
                deviceID: device.deviceID,
                channelCount: channelCount,
                sampleRate: sampleRate,
                bufferSize: UInt32(fftSize)
            ) {
                self.streamManager = streamManager
                try? streamManager.start()
                self.processor = SafeFFTSpectrumProcessor(
                    streamManager: streamManager,
                    channelIndex: channelIndex,
                    channelCount: Int(channelCount),
                    sampleRate: Float(device.sampleRate),
                    fftSize: fftSize
                )
            } else {
                self.streamManager = nil
                self.processor = nil
            }
        case .output:
            self.streamManager = nil
            let source = MixerVisualizerAudioSource(source: .output(deviceID: device.deviceID, channelIndex: channelIndex))
            self.processor = SafeFFTSpectrumProcessor(
                streamManager: source,
                channelIndex: channelIndex,
                channelCount: Int(channelCount),
                sampleRate: Float(device.sampleRate),
                fftSize: fftSize
            )
            self.processor?.start()
        }

        // Post-EQ: reads from mixer's post-EQ ring buffer
        let channelType = role == .input ? MIXER_CHANNEL_INPUT : MIXER_CHANNEL_OUTPUT
        if let reader = PostEQStreamReader(deviceID: device.deviceID, channelIndex: channelIndex, channelType: channelType) {
            self.postEQReader = reader
            let postProcessor = SafeFFTSpectrumProcessor(
                streamManager: reader,
                channelIndex: 0, // PostEQStreamReader reads a single channel already
                channelCount: 1,
                sampleRate: Float(device.sampleRate),
                fftSize: fftSize
            )
            postProcessor.start()
            self.postEQProcessor = postProcessor
        } else {
            self.postEQReader = nil
            self.postEQProcessor = nil
        }
    }

    deinit {
        if let streamManager {
            try? streamManager.stop()
        }
        processor?.stop()
        postEQProcessor?.stop()
    }
}

private struct InputProcessingCard<Content: View>: View {
    let accent: Color
    let content: Content

    init(accent: Color, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(accent.opacity(0.25), lineWidth: 0.5)
        )
    }
}

private struct ProcessingStatusBadge: View {
    let title: String
    let detail: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(accent)
            Text(detail)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accent.opacity(0.16))
        )
    }
}

private struct ProcessingSliderRow: View {
    let title: String
    let detail: String
    let valueText: String
    let range: ClosedRange<Double>
    let tint: Color
    @Binding var value: Double
    var onEditingChanged: ((Bool) -> Void)? = nil
    var onValueChanged: ((Double) -> Void)? = nil

    @State private var localValue: Double = 0
    @State private var isDragging: Bool = false

    // Throttling state
    @State private var lastValueUpdateTime: Date = Date.distantPast
    private let valueThrottleInterval: TimeInterval = 0.016 // ~60Hz max

    init(
        title: String,
        detail: String,
        valueText: String,
        range: ClosedRange<Double>,
        tint: Color,
        value: Binding<Double>,
        onEditingChanged: ((Bool) -> Void)? = nil,
        onValueChanged: ((Double) -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.valueText = valueText
        self.range = range
        self.tint = tint
        self._value = value
        self.onEditingChanged = onEditingChanged
        self.onValueChanged = onValueChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(valueText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
            }
            Slider(value: $localValue, in: range) { editing in
                isDragging = editing
                onEditingChanged?(editing)
                if !editing {
                    value = localValue
                }
            }
            .accentColor(tint)
            .onAppear { localValue = value }
            .onChange(of: value) { newValue in
                if !isDragging {
                    localValue = newValue
                }
            }
            .onChange(of: localValue) { newLocalValue in
                if isDragging {
                    let now = Date()
                    guard now.timeIntervalSince(lastValueUpdateTime) >= valueThrottleInterval else { return }
                    lastValueUpdateTime = now
                    onValueChanged?(newLocalValue)
                }
            }
        }
        .frame(minWidth: 140)
    }
}

/// A text field that supports both direct text editing and vertical drag to adjust values (DAW/NLE style)
private struct DragAdjustableField: View {
    let title: String
    let unit: String // "dB", "Hz", "", etc.
    let range: ClosedRange<Double>
    let step: Double
    let tint: Color
    @Binding var value: Double
    var onEditingChanged: ((Bool) -> Void)? = nil
    var onValueChanged: ((Double) -> Void)? = nil

    @State private var textValue: String = ""
    @State private var isEditing: Bool = false
    @State private var dragStartValue: Double = 0
    @State private var lastDragLocation: CGPoint? = nil

    private var displayValue: String {
        switch unit {
        case "dB":
            return String(format: "%+.1f", value)
        case "Hz":
            if value >= 1000 {
                return String(format: "%.1fk", value / 1000.0)
            } else {
                return String(format: "%.0f", value)
            }
        default:
            return String(format: "%.2f", value)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)

            Spacer()

            TextField("", text: $textValue, onEditingChanged: { editing in
                isEditing = editing
                if !editing {
                    commitTextValue()
                }
                onEditingChanged?(editing)
            }, onCommit: {
                commitTextValue()
            })
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(tint)
            .multilineTextAlignment(.trailing)
            .frame(width: unit == "Hz" ? 50 : 40)
            .onAppear { textValue = displayValue }
            .onChange(of: value) { _ in
                if !isEditing {
                    textValue = displayValue
                }
            }
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { gesture in
                        if !isEditing {
                            if lastDragLocation == nil {
                                dragStartValue = value
                                lastDragLocation = gesture.location
                            }

                            let deltaY = lastDragLocation!.y - gesture.location.y
                            let sensitivity: Double = unit == "Hz" ? 2.0 : (unit == "dB" ? 0.5 : 0.02)
                            let newValue = dragStartValue + (Double(deltaY) * sensitivity)

                            let clamped = min(max(newValue, range.lowerBound), range.upperBound)
                            if clamped != value {
                                value = clamped
                                textValue = displayValue
                                onValueChanged?(clamped)
                            }
                        }
                    }
                    .onEnded { _ in
                        lastDragLocation = nil
                        if !isEditing {
                            onEditingChanged?(false)
                        }
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }

            Text(unit)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: unit.isEmpty ? 0 : 16, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func commitTextValue() {
        let cleaned = textValue.replacingOccurrences(of: "[^0-9.-]", with: "", options: .regularExpression)
        if let newValue = Double(cleaned) {
            let adjustedValue: Double
            if unit == "Hz" && textValue.contains("k") {
                adjustedValue = newValue * 1000
            } else {
                adjustedValue = newValue
            }
            let clamped = min(max(adjustedValue, range.lowerBound), range.upperBound)
            value = clamped
        }
        textValue = displayValue
    }
}

private struct EQBandCard: View {
    let title: String
    let accent: Color
    let frequencyRange: ClosedRange<Double>
    @Binding var isEnabled: Bool
    @Binding var filterType: EQFilterFamily
    @Binding var slope: EQFilterSlope
    @Binding var gain: Double
    @Binding var frequency: Double
    @Binding var q: Double
    let onReset: () -> Void
    var onEditingChanged: ((Bool) -> Void)? = nil
    var onGainChanged: ((Double) -> Void)? = nil
    var onFrequencyChanged: ((Double) -> Void)? = nil
    var onQChanged: ((Double) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(accent)

                Spacer(minLength: 0)

                Button("Reset") {
                    onReset()
                }
                .buttonStyle(.plain)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(accent.opacity(0.9))

                Toggle("", isOn: $isEnabled)
                    .scaleEffect(0.6)
                    .labelsHidden()
            }

            HStack(spacing: 4) {
                Picker("Type", selection: $filterType) {
                    ForEach(EQFilterFamily.allCases, id: \.self) { family in
                        Text(eqFilterFamilyLabel(family)).tag(family)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Picker("Slope", selection: $slope) {
                    ForEach(EQFilterSlope.allCases, id: \.self) { selectedSlope in
                        Text(eqFilterSlopeLabel(selectedSlope)).tag(selectedSlope)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .font(.system(size: 9, weight: .semibold))
            .opacity(isEnabled ? 1 : 0.55)

            DragAdjustableField(
                title: "Gain",
                unit: "dB",
                range: -24...24,
                step: 0.1,
                tint: accent,
                value: $gain,
                onEditingChanged: onEditingChanged,
                onValueChanged: onGainChanged
            )
            DragAdjustableField(
                title: "Freq",
                unit: "Hz",
                range: frequencyRange,
                step: 1.0,
                tint: accent.opacity(0.9),
                value: $frequency,
                onEditingChanged: onEditingChanged,
                onValueChanged: onFrequencyChanged
            )
            DragAdjustableField(
                title: "Q",
                unit: "",
                range: 0.3...6.0,
                step: 0.01,
                tint: accent.opacity(0.8),
                value: $q,
                onEditingChanged: onEditingChanged,
                onValueChanged: onQChanged
            )
        }
        .opacity(isEnabled ? 1 : 0.58)
        .padding(8)
        .frame(width: 115)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(accent.opacity(0.28), lineWidth: 0.5)
        )
    }
}

private struct FilterCutCardView: View {
    let title: String
    let accent: Color
    let range: ClosedRange<Double>
    @Binding var isEnabled: Bool
    @Binding var filterType: EQFilterFamily
    @Binding var slope: EQFilterSlope
    @Binding var frequency: Double
    let onReset: () -> Void
    var onEditingChanged: ((Bool) -> Void)? = nil
    var onFrequencyChanged: ((Double) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(accent)
                Spacer()

                Button("Reset") {
                    onReset()
                }
                .buttonStyle(.plain)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(accent.opacity(0.9))

                Toggle("", isOn: $isEnabled)
                    .scaleEffect(0.6)
                    .labelsHidden()
            }

            HStack(spacing: 4) {
                Picker("Type", selection: $filterType) {
                    ForEach(EQFilterFamily.allCases, id: \.self) { family in
                        Text(eqFilterFamilyLabel(family)).tag(family)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                Picker("Slope", selection: $slope) {
                    ForEach(EQFilterSlope.allCases, id: \.self) { selectedSlope in
                        Text(eqFilterSlopeLabel(selectedSlope)).tag(selectedSlope)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .font(.system(size: 9, weight: .semibold))
            .opacity(isEnabled ? 1 : 0.55)

            DragAdjustableField(
                title: "Freq",
                unit: "Hz",
                range: range,
                step: 1.0,
                tint: accent,
                value: $frequency,
                onEditingChanged: onEditingChanged,
                onValueChanged: onFrequencyChanged
            )
            .opacity(isEnabled ? 1 : 0.55)
        }
        .padding(8)
        .frame(width: 100)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(accent.opacity(0.28), lineWidth: 0.5)
        )
    }
}

private struct DynamicsTransferGraphView: View {
    let settings: InputChannelDynamicsSettings

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.18))

                Path { path in
                    for step in 0...160 {
                        let t = Double(step) / 160.0
                        let inputDB = -60.0 + (t * 60.0)
                        let outputDB = compressedOutput(for: inputDB)
                        let x = geo.size.width * t
                        let normalizedY = 1.0 - CGFloat((outputDB + 60.0) / 60.0)
                        let y = normalizedY * geo.size.height

                        if step == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(Color.green.opacity(0.9), lineWidth: 2)

                Path { path in
                    let thresholdX = geo.size.width * CGFloat((settings.thresholdDB + 60.0) / 60.0)
                    path.move(to: CGPoint(x: thresholdX, y: 0))
                    path.addLine(to: CGPoint(x: thresholdX, y: geo.size.height))
                }
                .stroke(Color.green.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            }
        }
    }

    private func compressedOutput(for inputDB: Double) -> Double {
        guard settings.enabled else { return inputDB }
        let threshold = settings.thresholdDB
        let ratio = max(settings.ratio, 1.0)
        guard inputDB > threshold else { return inputDB + settings.makeupGainDB }
        let compressedOver = (inputDB - threshold) / ratio
        return threshold + compressedOver + settings.makeupGainDB
    }
}

private struct GainReductionMeterView: View {
    let gainReductionDB: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gain Reduction")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondary)

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 26, height: 150)

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.green.opacity(0.8))
                    .frame(width: 26, height: max(6, min(150, gainReductionDB / 18.0 * 150.0)))
            }

            Text(String(format: "%.1f dB", gainReductionDB))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
        }
    }
}

// MARK: - Dynamics Live Waveform

private final class DynamicsWaveformModel: ObservableObject {
    @Published var inputLevelHistory: [Float]
    @Published var inputWaveformHistory: [Float]
    @Published var outputWaveformHistory: [Float]
    @Published var gainReductionHistory: [Float]
    @Published var gainReductionDB: Float = 0.0

    private let historyCount = 200
    private var timer: Timer?
    private let globalChannelIndex: Int32
    private var readBlock: [Float]
    private var inputReadBlock: [Float]

    init(deviceID: AudioDeviceID, channelIndex: Int, channelType: UInt32 = MIXER_CHANNEL_INPUT) {
        inputLevelHistory = Array(repeating: -60, count: 200)
        inputWaveformHistory = Array(repeating: 0, count: 200)
        outputWaveformHistory = Array(repeating: 0, count: 200)
        gainReductionHistory = Array(repeating: 0, count: 200)
        readBlock = Array(repeating: 0, count: 512)
        inputReadBlock = Array(repeating: 0, count: 512)
        globalChannelIndex = Mixer_GetGlobalChannelIndex(UInt32(deviceID), channelType, UInt32(channelIndex))
        let newTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func tick() {
        let idx = globalChannelIndex
        guard idx >= 0 else { return }

        // Read both buffers with the same count to ensure temporal alignment
        let readCount = min(Int32(readBlock.count), Int32(inputReadBlock.count))

        // Read post-dynamics (compressed) buffer
        let read = Mixer_ReadPostDynamicsBuffer(UInt32(idx), &readBlock, readCount)
        let rmsDB: Float
        var outputWaveformSample: Float = 0

        if read > 0 {
            let sumSq = readBlock.prefix(Int(read)).reduce(0 as Float) { $0 + $1 * $1 }
            let rms = sqrt(sumSq / Float(read))
            rmsDB = rms > 1e-10 ? 20 * log10(rms) : -60

            // Take a representative sample from the same position in both buffers
            let midIndex = Int(read) / 2
            outputWaveformSample = readBlock[midIndex]
        } else {
            rmsDB = -60
            outputWaveformSample = 0
        }

        // Read pre-dynamics (input) buffer for comparison
        let inputRead = Mixer_ReadPostEQBuffer(UInt32(idx), &inputReadBlock, readCount)
        var inputWaveformSample: Float = 0

        if inputRead > 0 {
            // Use the input buffer's own read count for the midIndex
            let midIndex = Int(inputRead) / 2
            inputWaveformSample = inputReadBlock[midIndex]
        } else {
            inputWaveformSample = 0
        }

        let gr = Mixer_GetChannelGainReduction(UInt32(idx))

        DispatchQueue.main.async {
            self.inputLevelHistory.removeFirst()
            self.inputLevelHistory.append(rmsDB)
            self.inputWaveformHistory.removeFirst()
            self.inputWaveformHistory.append(inputWaveformSample)
            self.outputWaveformHistory.removeFirst()
            self.outputWaveformHistory.append(outputWaveformSample)
            self.gainReductionHistory.removeFirst()
            self.gainReductionHistory.append(gr)
            self.gainReductionDB = gr
        }
    }

    deinit {
        timer?.invalidate()
    }
}

private struct DynamicsLiveWaveformView: View {
    @ObservedObject var model: DynamicsWaveformModel

    private let inputWaveformOffset: Int = 0  // Shift input waveform to align with output

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let count = model.outputWaveformHistory.count
            let w = count > 1 ? size.width / CGFloat(count - 1) : 0
            let minDB: Float = -60
            let maxDB: Float = 0

            // Draw input level (faint green background)
            let inputPoints: [CGPoint] = (0..<count).map { i in
                let x = CGFloat(i) * w
                let norm = CGFloat(max(0, min(1, (model.inputLevelHistory[i] - minDB) / (maxDB - minDB))))
                let y = size.height * 0.5 - size.height * 0.5 * norm
                return CGPoint(x: x, y: y)
            }

            let inputLowerPoints: [CGPoint] = (0..<count).reversed().map { i in
                let x = CGFloat(i) * w
                let norm = CGFloat(max(0, min(1, (model.inputLevelHistory[i] - minDB) / (maxDB - minDB))))
                let y = size.height * 0.5 + size.height * 0.5 * norm
                return CGPoint(x: x, y: y)
            }

            // Draw compressed output waveform (actual signal after dynamics)
            let outputPoints: [CGPoint] = (0..<count).map { i in
                let x = CGFloat(i) * w
                // Convert linear sample to dB for visualization
                let sample = abs(model.outputWaveformHistory[i])
                let sampleDB = sample > 1e-10 ? 20 * log10(sample) : -60
                let norm = CGFloat(max(0, min(1, (sampleDB - minDB) / (maxDB - minDB))))
                let y = size.height * 0.5 - size.height * 0.5 * norm
                return CGPoint(x: x, y: y)
            }

            let outputLowerPoints: [CGPoint] = (0..<count).reversed().map { i in
                let x = CGFloat(i) * w
                let sample = abs(model.outputWaveformHistory[i])
                let sampleDB = sample > 1e-10 ? 20 * log10(sample) : -60
                let norm = CGFloat(max(0, min(1, (sampleDB - minDB) / (maxDB - minDB))))
                let y = size.height * 0.5 + size.height * 0.5 * norm
                return CGPoint(x: x, y: y)
            }

            // Draw uncompressed input waveform (red for comparison) with offset
            let inputWaveformPoints: [CGPoint] = (0..<count).map { i in
                let x = CGFloat(i) * w
                let sampleIndex = max(0, min(count - 1, i + inputWaveformOffset))
                let sample = abs(model.inputWaveformHistory[sampleIndex])
                let sampleDB = sample > 1e-10 ? 20 * log10(sample) : -60
                let norm = CGFloat(max(0, min(1, (sampleDB - minDB) / (maxDB - minDB))))
                let y = size.height * 0.5 - size.height * 0.5 * norm
                return CGPoint(x: x, y: y)
            }

            let inputWaveformLowerPoints: [CGPoint] = (0..<count).reversed().map { i in
                let x = CGFloat(i) * w
                let sampleIndex = max(0, min(count - 1, i + inputWaveformOffset))
                let sample = abs(model.inputWaveformHistory[sampleIndex])
                let sampleDB = sample > 1e-10 ? 20 * log10(sample) : -60
                let norm = CGFloat(max(0, min(1, (sampleDB - minDB) / (maxDB - minDB))))
                let y = size.height * 0.5 + size.height * 0.5 * norm
                return CGPoint(x: x, y: y)
            }

            ZStack {
                // Input level (faint green background)
                Path { path in
                    guard let first = inputPoints.first else { return }
                    path.move(to: first)
                    for point in inputPoints.dropFirst() {
                        path.addLine(to: point)
                    }
                    for point in inputLowerPoints {
                        path.addLine(to: point)
                    }
                    path.closeSubpath()
                }
                .fill(Color.green.opacity(0.08))

                Path { path in
                    guard let first = inputPoints.first else { return }
                    path.move(to: first)
                    for point in inputPoints.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(Color.green.opacity(0.25), lineWidth: 1.0)

                // Uncompressed input waveform (red)
                Path { path in
                    guard let first = inputWaveformPoints.first else { return }
                    path.move(to: first)
                    for point in inputWaveformPoints.dropFirst() {
                        path.addLine(to: point)
                    }
                    for point in inputWaveformLowerPoints {
                        path.addLine(to: point)
                    }
                    path.closeSubpath()
                }
                .fill(Color(red: 0.8, green: 0.2, blue: 0.2).opacity(0.2))

                Path { path in
                    guard let first = inputWaveformPoints.first else { return }
                    path.move(to: first)
                    for point in inputWaveformPoints.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(Color(red: 0.8, green: 0.2, blue: 0.2).opacity(0.5), lineWidth: 1.2)

                // Compressed output waveform (brighter green)
                Path { path in
                    guard let first = outputPoints.first else { return }
                    path.move(to: first)
                    for point in outputPoints.dropFirst() {
                        path.addLine(to: point)
                    }
                    for point in outputLowerPoints {
                        path.addLine(to: point)
                    }
                    path.closeSubpath()
                }
                .fill(Color.green.opacity(0.15))

                Path { path in
                    guard let first = outputPoints.first else { return }
                    path.move(to: first)
                    for point in outputPoints.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(Color.green.opacity(0.6), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct EQBiquadCoefficients {
    let b0: Double
    let b1: Double
    let b2: Double
    let a1: Double
    let a2: Double

    func magnitude(at omega: Double) -> Double {
        let cos1 = cos(omega)
        let sin1 = sin(omega)
        let cos2 = cos(omega * 2.0)
        let sin2 = sin(omega * 2.0)

        let numeratorReal = b0 + (b1 * cos1) + (b2 * cos2)
        let numeratorImag = -(b1 * sin1) - (b2 * sin2)
        let denominatorReal = 1.0 + (a1 * cos1) + (a2 * cos2)
        let denominatorImag = -(a1 * sin1) - (a2 * sin2)

        let numeratorMagnitude = sqrt((numeratorReal * numeratorReal) + (numeratorImag * numeratorImag))
        let denominatorMagnitude = sqrt((denominatorReal * denominatorReal) + (denominatorImag * denominatorImag))
        return denominatorMagnitude > 0.000_000_1 ? numeratorMagnitude / denominatorMagnitude : 1.0
    }
}

private func normalizedBiquadCoefficients(b0: Double,
                                          b1: Double,
                                          b2: Double,
                                          a0: Double,
                                          a1: Double,
                                          a2: Double) -> EQBiquadCoefficients {
    EQBiquadCoefficients(
        b0: b0 / a0,
        b1: b1 / a0,
        b2: b2 / a0,
        a1: a1 / a0,
        a2: a2 / a0
    )
}

private func highPassCoefficients(sampleRate: Double, frequency: Double, q: Double) -> EQBiquadCoefficients? {
    guard sampleRate > 0, frequency > 0 else { return nil }
    let omega = 2.0 * Double.pi * frequency / sampleRate
    let alpha = sin(omega) / (2.0 * max(q, 0.0001))
    let cosine = cos(omega)
    return normalizedBiquadCoefficients(
        b0: (1.0 + cosine) / 2.0,
        b1: -(1.0 + cosine),
        b2: (1.0 + cosine) / 2.0,
        a0: 1.0 + alpha,
        a1: -2.0 * cosine,
        a2: 1.0 - alpha
    )
}

private func lowPassCoefficients(sampleRate: Double, frequency: Double, q: Double) -> EQBiquadCoefficients? {
    guard sampleRate > 0, frequency > 0 else { return nil }
    let omega = 2.0 * Double.pi * frequency / sampleRate
    let alpha = sin(omega) / (2.0 * max(q, 0.0001))
    let cosine = cos(omega)
    return normalizedBiquadCoefficients(
        b0: (1.0 - cosine) / 2.0,
        b1: 1.0 - cosine,
        b2: (1.0 - cosine) / 2.0,
        a0: 1.0 + alpha,
        a1: -2.0 * cosine,
        a2: 1.0 - alpha
    )
}

private func peakingCoefficients(sampleRate: Double,
                                 frequency: Double,
                                 q: Double,
                                 gainDB: Double) -> EQBiquadCoefficients? {
    guard sampleRate > 0, frequency > 0, abs(gainDB) > 0.05 else { return nil }
    let omega = 2.0 * Double.pi * frequency / sampleRate
    let alpha = sin(omega) / (2.0 * max(q, 0.0001))
    let cosine = cos(omega)
    let amplitude = pow(10.0, gainDB / 40.0)
    return normalizedBiquadCoefficients(
        b0: 1.0 + (alpha * amplitude),
        b1: -2.0 * cosine,
        b2: 1.0 - (alpha * amplitude),
        a0: 1.0 + (alpha / amplitude),
        a1: -2.0 * cosine,
        a2: 1.0 - (alpha / amplitude)
    )
}

private func eqStageCount(for slope: EQFilterSlope) -> Int {
    switch slope {
    case .db24:
        return 2
    case .db48:
        return 4
    case .db6, .db12:
        return 1
    }
}

private func eqSlopeGainScale(for slope: EQFilterSlope) -> Double {
    switch slope {
    case .db6:
        return 0.5
    case .db12, .db24, .db48:
        return 1.0
    }
}

private func eqFamilyQScale(for family: EQFilterFamily) -> Double {
    switch family {
    case .butterworth:
        return 1.0
    case .chebyshev:
        return 1.18
    case .bessel:
        return 0.82
    case .linkwitzRiley:
        return 0.707
    }
}

private func eqSlopeQScale(for slope: EQFilterSlope) -> Double {
    switch slope {
    case .db6:
        return 0.78
    case .db12:
        return 1.0
    case .db24:
        return 1.15
    case .db48:
        return 1.3
    }
}

private func eqCoefficients(for settings: InputChannelEQSettings, sampleRate: Double) -> [EQBiquadCoefficients] {
    guard settings.enabled, sampleRate > 0 else { return [] }

    var coefficients: [EQBiquadCoefficients] = []

    if settings.highPassEnabled {
        let q = min(max(0.707 * eqFamilyQScale(for: settings.highPassFilterType) * eqSlopeQScale(for: settings.highPassSlope), 0.35), 2.5)
        let stageCount = eqStageCount(for: settings.highPassSlope)
        if let base = highPassCoefficients(sampleRate: sampleRate, frequency: settings.highPassFrequencyHz, q: q) {
            for _ in 0..<stageCount { coefficients.append(base) }
        }
    }

    func appendPeaking(enabled: Bool,
                       frequency: Double,
                       q: Double,
                       gainDB: Double,
                       filterType: EQFilterFamily,
                       slope: EQFilterSlope) {
        guard enabled else { return }
        let stageCount = eqStageCount(for: slope)
        let scaledQ = min(max(q * eqFamilyQScale(for: filterType) * eqSlopeQScale(for: slope), 0.3), 8.0)
        let perStageGain = (gainDB * eqSlopeGainScale(for: slope)) / Double(stageCount)
        if let base = peakingCoefficients(sampleRate: sampleRate, frequency: frequency, q: scaledQ, gainDB: perStageGain) {
            for _ in 0..<stageCount { coefficients.append(base) }
        }
    }

    appendPeaking(enabled: settings.lowEnabled,
                  frequency: settings.lowCenterFrequencyHz,
                  q: settings.lowQ,
                  gainDB: settings.lowGainDB,
                  filterType: settings.lowFilterType,
                  slope: settings.lowSlope)
    appendPeaking(enabled: settings.lowMidEnabled,
                  frequency: settings.lowMidCenterFrequencyHz,
                  q: settings.lowMidQ,
                  gainDB: settings.lowMidGainDB,
                  filterType: settings.lowMidFilterType,
                  slope: settings.lowMidSlope)
    appendPeaking(enabled: settings.midEnabled,
                  frequency: settings.midCenterFrequencyHz,
                  q: settings.midQ,
                  gainDB: settings.midGainDB,
                  filterType: settings.midFilterType,
                  slope: settings.midSlope)
    appendPeaking(enabled: settings.presenceEnabled,
                  frequency: settings.presenceCenterFrequencyHz,
                  q: settings.presenceQ,
                  gainDB: settings.presenceGainDB,
                  filterType: settings.presenceFilterType,
                  slope: settings.presenceSlope)
    appendPeaking(enabled: settings.highEnabled,
                  frequency: settings.highCenterFrequencyHz,
                  q: settings.highQ,
                  gainDB: settings.highGainDB,
                  filterType: settings.highFilterType,
                  slope: settings.highSlope)

    if settings.lowPassEnabled {
        let q = min(max(0.707 * eqFamilyQScale(for: settings.lowPassFilterType) * eqSlopeQScale(for: settings.lowPassSlope), 0.35), 2.5)
        let stageCount = eqStageCount(for: settings.lowPassSlope)
        if let base = lowPassCoefficients(sampleRate: sampleRate, frequency: settings.lowPassFrequencyHz, q: q) {
            for _ in 0..<stageCount { coefficients.append(base) }
        }
    }

    return coefficients
}

private func totalEQResponseDB(settings: InputChannelEQSettings, sampleRate: Double, frequency: Double) -> Double {
    let coefficients = eqCoefficients(for: settings, sampleRate: sampleRate)
    guard !coefficients.isEmpty, frequency > 0 else { return 0.0 }
    let omega = 2.0 * Double.pi * frequency / sampleRate
    let magnitude = coefficients.reduce(1.0) { partial, coefficient in
        partial * coefficient.magnitude(at: omega)
    }
    return 20.0 * log10(max(magnitude, 0.000_000_1))
}

private enum EQEditableNode: String, CaseIterable, Identifiable {
    case highPass
    case low
    case lowMid
    case mid
    case presence
    case high
    case lowPass

    var id: String { rawValue }

    var supportsGain: Bool {
        switch self {
        case .highPass, .lowPass:
            return false
        case .low, .lowMid, .mid, .presence, .high:
            return true
        }
    }

    var tint: Color {
        switch self {
        case .highPass:
            return Color(red: 0.0, green: 0.75, blue: 0.8)
        case .low:
            return Color(red: 0.24, green: 0.82, blue: 0.88)
        case .lowMid:
            return Color(red: 0.24, green: 0.88, blue: 0.78)
        case .mid:
            return Color(red: 0.34, green: 0.92, blue: 0.78)
        case .presence:
            return Color(red: 0.54, green: 0.78, blue: 1.0)
        case .high:
            return Color(red: 0.46, green: 0.84, blue: 1.0)
        case .lowPass:
            return Color(red: 0.48, green: 0.72, blue: 1.0)
        }
    }

    var frequencyRange: ClosedRange<Double> {
        switch self {
        case .highPass:
            return 20...20_000
        case .low:
            return 20...20_000
        case .lowMid:
            return 20...20_000
        case .mid:
            return 20...20_000
        case .presence:
            return 20...20_000
        case .high:
            return 20...20_000
        case .lowPass:
            return 20...20_000
        }
    }
}

// Observable object for EQ preview state that isolates updates from parent view
private final class EQPreviewState: ObservableObject {
    @Published var settings: InputChannelEQSettings?
}

private final class DynamicsPreviewState: ObservableObject {
    @Published var settings: InputChannelDynamicsSettings?
}

private struct EQAnalyzerOverlayView: View {
    let baseSettings: InputChannelEQSettings
    @ObservedObject var processor: SafeFFTSpectrumProcessor
    @ObservedObject var previewState: EQPreviewState
    var showPostEQ: Bool = false
    var postEQProcessor: SafeFFTSpectrumProcessor? = nil
    var onNodeDrag: ((EQEditableNode, Double, Double?) -> Void)? = nil
    var onCommit: (() -> Void)? = nil
    @State private var activeNode: EQEditableNode? = nil

    // Throttling state for drag gestures
    @State private var lastDragUpdateTime: Date = Date.distantPast
    private let dragThrottleInterval: TimeInterval = 0.016 // ~60Hz max

    private let controlResponseRange = -24.0...24.0
    private let curveAttenuationFloorDB = -96.0
    private let minDisplayFrequency = 20.0
    private var maxDisplayFrequency: Double {
        min(Double(processor.sampleRate) / 2.0, 20_000.0)
    }

    private var settings: InputChannelEQSettings {
        previewState.settings ?? baseSettings
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach([-24.0, -12.0, 0.0, 12.0, 24.0], id: \.self) { value in
                    Path { path in
                        let y = yForControlResponse(value, height: geo.size.height)
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(value == 0 ? Color.white.opacity(0.22) : Color.white.opacity(0.08),
                            style: StrokeStyle(lineWidth: value == 0 ? 1.2 : 1, dash: [5, 5]))
                }

                // EQ response curve
                Path { path in
                    let points = responsePoints(width: geo.size.width, height: geo.size.height)
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(Color(red: 0.0, green: 0.75, blue: 0.8).opacity(0.95), lineWidth: 2.2)

                ForEach(EQEditableNode.allCases) { node in
                    let nodeFrequency = displayFrequency(for: node)
                    let nodeGain = displayGain(for: node)
                    let x = xForFrequency(nodeFrequency, width: geo.size.width)
                    let y = yForControlResponse(nodeGain, height: geo.size.height)
                    let isActive = activeNode == node
                    let isEnabled = isNodeEnabled(node)

                    ZStack {
                        Circle()
                            .fill(Color.clear)
                            .frame(width: 32, height: 32)
                        Circle()
                            .fill(node.tint.opacity(isEnabled ? (isActive ? 0.35 : 0.22) : 0.08))
                            .frame(width: isActive ? 20 : 18, height: isActive ? 20 : 18)
                        Circle()
                            .stroke(Color.white.opacity(isEnabled ? 0.9 : 0.45), lineWidth: 1)
                            .frame(width: isActive ? 12 : 10, height: isActive ? 12 : 10)
                        Circle()
                            .fill(node.tint.opacity(isEnabled ? 0.95 : 0.35))
                            .frame(width: isActive ? 8 : 7, height: isActive ? 8 : 7)
                    }
                    .position(x: x, y: y)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("eq-overlay-space"))
                            .onChanged { drag in
                                let now = Date()
                                guard now.timeIntervalSince(lastDragUpdateTime) >= dragThrottleInterval else { return }
                                lastDragUpdateTime = now
                                activeNode = node
                                applyDrag(for: node, at: drag.location, size: geo.size)
                            }
                            .onEnded { _ in
                                activeNode = nil
                                onCommit?()
                            }
                    )
                    .accessibilityLabel(Text(node.rawValue))
                }
            }
            .coordinateSpace(name: "eq-overlay-space")
        }
        .allowsHitTesting(onNodeDrag != nil)
    }

    private func responsePoints(width: CGFloat, height: CGFloat) -> [CGPoint] {
        let sampleRate = Double(processor.sampleRate)
        return (0..<240).map { index in
            let t = Double(index) / 239.0
            let frequency = exp(log(minDisplayFrequency) + t * (log(maxDisplayFrequency) - log(minDisplayFrequency)))
            let responseDB = totalEQResponseDB(settings: settings, sampleRate: sampleRate, frequency: frequency)
            return CGPoint(
                x: xForFrequency(frequency, width: width),
                y: yForCurveResponse(responseDB, height: height)
            )
        }
    }

    private func xForFrequency(_ frequency: Double, width: CGFloat) -> CGFloat {
        let magnitudeCount = max(processor.magnitudes.count, Int(processor.fftSize / 2))
        if let x = SpectrumMeshBuilder.xPositionForFrequency(
            frequency,
            width: width,
            sampleRate: processor.sampleRate,
            fftSize: processor.fftSize,
            magnitudeCount: magnitudeCount,
            minFrequency: Float(minDisplayFrequency),
            maxFrequency: Float(maxDisplayFrequency)
        ) {
            return x
        }
        return 0
    }

    private func frequencyForX(_ x: CGFloat, width: CGFloat) -> Double {
        let magnitudeCount = max(processor.magnitudes.count, Int(processor.fftSize / 2))
        if let frequency = SpectrumMeshBuilder.frequencyForXPosition(
            x,
            width: width,
            sampleRate: processor.sampleRate,
            fftSize: processor.fftSize,
            magnitudeCount: magnitudeCount,
            minFrequency: Float(minDisplayFrequency),
            maxFrequency: Float(maxDisplayFrequency)
        ) {
            return frequency
        }
        return minDisplayFrequency
    }

    private func yForControlResponse(_ responseDB: Double, height: CGFloat) -> CGFloat {
        let clamped = min(max(responseDB, controlResponseRange.lowerBound), controlResponseRange.upperBound)
        let normalized = (clamped - controlResponseRange.lowerBound) / (controlResponseRange.upperBound - controlResponseRange.lowerBound)
        return height - (CGFloat(normalized) * height)
    }

    private func yForCurveResponse(_ responseDB: Double, height: CGFloat) -> CGFloat {
        let clamped = min(max(responseDB, curveAttenuationFloorDB), controlResponseRange.upperBound)
        let centerY = height * 0.5

        if clamped >= 0 {
            let normalized = clamped / controlResponseRange.upperBound
            return centerY - (CGFloat(normalized) * centerY)
        }

        let normalized = clamped / curveAttenuationFloorDB
        return centerY + (CGFloat(normalized) * centerY)
    }

    private func responseForY(_ y: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0.0 }
        let clampedY = max(0, min(y, height))
        let normalized = 1.0 - Double(clampedY / height)
        let value = controlResponseRange.lowerBound + normalized * (controlResponseRange.upperBound - controlResponseRange.lowerBound)
        return min(max(value, controlResponseRange.lowerBound), controlResponseRange.upperBound)
    }

    private func displayFrequency(for node: EQEditableNode) -> Double {
        switch node {
        case .highPass:
            return settings.highPassFrequencyHz
        case .low:
            return settings.lowCenterFrequencyHz
        case .lowMid:
            return settings.lowMidCenterFrequencyHz
        case .mid:
            return settings.midCenterFrequencyHz
        case .presence:
            return settings.presenceCenterFrequencyHz
        case .high:
            return settings.highCenterFrequencyHz
        case .lowPass:
            return settings.lowPassFrequencyHz
        }
    }

    private func displayGain(for node: EQEditableNode) -> Double {
        switch node {
        case .highPass, .lowPass:
            return 0.0
        case .low:
            return settings.lowEnabled ? settings.lowGainDB : 0.0
        case .lowMid:
            return settings.lowMidEnabled ? settings.lowMidGainDB : 0.0
        case .mid:
            return settings.midEnabled ? settings.midGainDB : 0.0
        case .presence:
            return settings.presenceEnabled ? settings.presenceGainDB : 0.0
        case .high:
            return settings.highEnabled ? settings.highGainDB : 0.0
        }
    }

    private func isNodeEnabled(_ node: EQEditableNode) -> Bool {
        switch node {
        case .highPass:
            return settings.highPassEnabled
        case .low:
            return settings.lowEnabled
        case .lowMid:
            return settings.lowMidEnabled
        case .mid:
            return settings.midEnabled
        case .presence:
            return settings.presenceEnabled
        case .high:
            return settings.highEnabled
        case .lowPass:
            return settings.lowPassEnabled
        }
    }

    private func applyDrag(for node: EQEditableNode, at location: CGPoint, size: CGSize) {
        let rawFrequency = frequencyForX(location.x, width: size.width)
        let clampedFrequency = min(max(rawFrequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
        let gain = node.supportsGain ? responseForY(location.y, height: size.height) : nil

        var newSettings = previewState.settings ?? baseSettings
        newSettings.enabled = true
        switch node {
        case .highPass:
            newSettings.highPassEnabled = true
            newSettings.highPassFrequencyHz = min(max(clampedFrequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
        case .low:
            newSettings.lowEnabled = true
            newSettings.lowCenterFrequencyHz = min(max(clampedFrequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
            if let gain {
                newSettings.lowGainDB = min(max(gain, -24.0), 24.0)
            }
        case .lowMid:
            newSettings.lowMidEnabled = true
            newSettings.lowMidCenterFrequencyHz = min(max(clampedFrequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
            if let gain {
                newSettings.lowMidGainDB = min(max(gain, -24.0), 24.0)
            }
        case .mid:
            newSettings.midEnabled = true
            newSettings.midCenterFrequencyHz = min(max(clampedFrequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
            if let gain {
                newSettings.midGainDB = min(max(gain, -24.0), 24.0)
            }
        case .presence:
            newSettings.presenceEnabled = true
            newSettings.presenceCenterFrequencyHz = min(max(clampedFrequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
            if let gain {
                newSettings.presenceGainDB = min(max(gain, -24.0), 24.0)
            }
        case .high:
            newSettings.highEnabled = true
            newSettings.highCenterFrequencyHz = min(max(clampedFrequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
            if let gain {
                newSettings.highGainDB = min(max(gain, -24.0), 24.0)
            }
        case .lowPass:
            newSettings.lowPassEnabled = true
            newSettings.lowPassFrequencyHz = min(max(clampedFrequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
        }
        previewState.settings = newSettings
        onNodeDrag?(node, clampedFrequency, gain)
    }
}

// Container that isolates Metal spectrum renderer from parent view updates
private struct SpectrumRendererContainer: View, Equatable {
    let processor: SafeFFTSpectrumProcessor
    let channelIndex: Int
    let themeMode: ThemeMode

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Only re-render if identity changes, not when parent state changes
        lhs.processor === rhs.processor &&
        lhs.channelIndex == rhs.channelIndex &&
        lhs.themeMode == rhs.themeMode
    }

    var body: some View {
        MetalSpectrumRenderer(
            spectrumProcessor: processor,
            channelIndex: channelIndex,
            themeMode: themeMode
        )
    }
}

struct InputChannelEQWindowView: View {
    let device: AudioDevice
    let channelIndex: Int
    let role: ChannelRole

    @EnvironmentObject private var channelStateManager: ChannelStateManager
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var analyzer: MixerInputChannelFFTAnalyzer
    @State private var showPostEQ: Bool = false
    @StateObject private var previewState = EQPreviewState()

    init(device: AudioDevice, channelIndex: Int, role: ChannelRole = .input) {
        self.device = device
        self.channelIndex = channelIndex
        self.role = role
        _analyzer = StateObject(wrappedValue: MixerInputChannelFFTAnalyzer(device: device, channelIndex: channelIndex, role: role))
    }

    private var globalSettings: InputChannelEQSettings {
        switch role {
        case .input:
            return channelStateManager.eqSettings(for: device.deviceID, channel: channelIndex)
        case .output:
            return channelStateManager.outputEQSettings(for: device.deviceID, channel: channelIndex)
        }
    }

    private var settings: InputChannelEQSettings {
        previewState.settings ?? globalSettings
    }

    private var theme: ThemeMode {
        themeManager.deviceCapsuleThemes[device.deviceID] ?? themeManager.capsuleThemeMode
    }

    private var channelRoleLabel: String {
        role == .input ? "Input" : "Output"
    }

    private var activeProcessor: SafeFFTSpectrumProcessor? {
        showPostEQ ? (analyzer.postEQProcessor ?? analyzer.processor) : analyzer.processor
    }

    private var prePostToggleChip: some View {
        Button {
            showPostEQ.toggle()
        } label: {
            HStack(spacing: 2) {
                Circle()
                    .fill(showPostEQ ? Color.yellow : Color(red: 0.0, green: 0.75, blue: 0.8))
                    .frame(width: 3, height: 3)
                Text(showPostEQ ? "POST" : "PRE")
                    .font(.system(size: 5, weight: .bold, design: .monospaced))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke((showPostEQ ? Color.yellow : Color(red: 0.0, green: 0.75, blue: 0.8)).opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                InputProcessingCard(accent: Color(red: 0.0, green: 0.75, blue: 0.8)) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Parametric EQ")
                                .font(.system(size: 14, weight: .bold))
                            Text("\(device.name) • \(channelRoleLabel) \(channelIndex + 1)")
                                .font(.system(size: 7, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Button("Reset") {
                                resetAllBands()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 6, weight: .bold))
                            .foregroundColor(Color(red: 0.0, green: 0.75, blue: 0.8))

                            Toggle("EQ", isOn: eqEnabledBinding)
                                .toggleStyle(.switch)
                                .scaleEffect(0.5)
                        }
                    }

                    if let processor = activeProcessor {
                        ZStack(alignment: .topLeading) {
                            EquatableView(content: SpectrumRendererContainer(
                                processor: processor,
                                channelIndex: showPostEQ ? 0 : channelIndex,
                                themeMode: theme
                            ))

                            EQAnalyzerOverlayView(
                                baseSettings: globalSettings,
                                processor: processor,
                                previewState: previewState,
                                showPostEQ: showPostEQ,
                                postEQProcessor: analyzer.postEQProcessor,
                                onNodeDrag: { node, freq, gain in
                                    updateOverlayState(node: node, frequency: freq, gain: gain)
                                },
                                onCommit: {
                                    commitOverlaySettings()
                                }
                            )
                            .padding(.vertical, 7)
                            .drawingGroup(opaque: false)

                            prePostToggleChip
                                .padding(6)
                        }
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke((showPostEQ ? Color.yellow : Color(red: 0.0, green: 0.75, blue: 0.8)).opacity(0.22), lineWidth: 0.5)
                        )
                    } else {
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                                .overlay(
                                    Text("FFT unavailable")
                                        .font(.system(size: 7, weight: .medium))
                                        .foregroundColor(.secondary)
                                )

                            prePostToggleChip
                                .padding(6)
                        }
                        .frame(height: 160)
                    }
                }

                InputProcessingCard(accent: Color(red: 0.0, green: 0.75, blue: 0.8)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Filter Stack")
                                .font(.system(size: 10, weight: .bold))
                        }
                        Spacer()
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 6) {
                            FilterCutCardView(
                                title: "HPF",
                                accent: Color(red: 0.0, green: 0.75, blue: 0.8),
                                range: 20...20_000,
                                isEnabled: highPassEnabledBinding,
                                filterType: eqFilterFamilyBinding(\.highPassFilterType),
                                slope: eqFilterSlopeBinding(\.highPassSlope),
                                frequency: highPassBinding,
                                onReset: { resetBand(.highPass) },
                                onEditingChanged: { editing in
                                    if !editing { commitEQSettings() }
                                },
                                onFrequencyChanged: { updatePendingEQFrequency(for: .highPass, value: $0) }
                            )

                            EQBandCard(
                                title: "Low",
                                accent: Color(red: 0.24, green: 0.82, blue: 0.88),
                                frequencyRange: 20...20_000,
                                isEnabled: eqBoolBinding(\.lowEnabled),
                                filterType: eqFilterFamilyBinding(\.lowFilterType),
                                slope: eqFilterSlopeBinding(\.lowSlope),
                                gain: eqBinding(\.lowGainDB),
                                frequency: eqBinding(\.lowCenterFrequencyHz),
                                q: eqBinding(\.lowQ),
                                onReset: { resetBand(.low) },
                                onEditingChanged: { editing in
                                    if !editing { commitEQSettings() }
                                },
                                onGainChanged: { updatePendingEQGain(for: .low, value: $0) },
                                onFrequencyChanged: { updatePendingEQFrequency(for: .low, value: $0) },
                                onQChanged: { updatePendingEQQ(for: .low, value: $0) }
                            )

                            EQBandCard(
                                title: "Low Mid",
                                accent: Color(red: 0.24, green: 0.88, blue: 0.78),
                                frequencyRange: 20...20_000,
                                isEnabled: eqBoolBinding(\.lowMidEnabled),
                                filterType: eqFilterFamilyBinding(\.lowMidFilterType),
                                slope: eqFilterSlopeBinding(\.lowMidSlope),
                                gain: eqBinding(\.lowMidGainDB),
                                frequency: eqBinding(\.lowMidCenterFrequencyHz),
                                q: eqBinding(\.lowMidQ),
                                onReset: { resetBand(.lowMid) },
                                onEditingChanged: { editing in
                                    if !editing { commitEQSettings() }
                                },
                                onGainChanged: { updatePendingEQGain(for: .lowMid, value: $0) },
                                onFrequencyChanged: { updatePendingEQFrequency(for: .lowMid, value: $0) },
                                onQChanged: { updatePendingEQQ(for: .lowMid, value: $0) }
                            )

                            EQBandCard(
                                title: "Mid",
                                accent: Color(red: 0.34, green: 0.92, blue: 0.78),
                                frequencyRange: 20...20_000,
                                isEnabled: eqBoolBinding(\.midEnabled),
                                filterType: eqFilterFamilyBinding(\.midFilterType),
                                slope: eqFilterSlopeBinding(\.midSlope),
                                gain: eqBinding(\.midGainDB),
                                frequency: eqBinding(\.midCenterFrequencyHz),
                                q: eqBinding(\.midQ),
                                onReset: { resetBand(.mid) },
                                onEditingChanged: { editing in
                                    if !editing { commitEQSettings() }
                                },
                                onGainChanged: { updatePendingEQGain(for: .mid, value: $0) },
                                onFrequencyChanged: { updatePendingEQFrequency(for: .mid, value: $0) },
                                onQChanged: { updatePendingEQQ(for: .mid, value: $0) }
                            )

                            EQBandCard(
                                title: "Presence",
                                accent: Color(red: 0.54, green: 0.78, blue: 1.0),
                                frequencyRange: 20...20_000,
                                isEnabled: eqBoolBinding(\.presenceEnabled),
                                filterType: eqFilterFamilyBinding(\.presenceFilterType),
                                slope: eqFilterSlopeBinding(\.presenceSlope),
                                gain: eqBinding(\.presenceGainDB),
                                frequency: eqBinding(\.presenceCenterFrequencyHz),
                                q: eqBinding(\.presenceQ),
                                onReset: { resetBand(.presence) },
                                onEditingChanged: { editing in
                                    if !editing { commitEQSettings() }
                                },
                                onGainChanged: { updatePendingEQGain(for: .presence, value: $0) },
                                onFrequencyChanged: { updatePendingEQFrequency(for: .presence, value: $0) },
                                onQChanged: { updatePendingEQQ(for: .presence, value: $0) }
                            )

                            EQBandCard(
                                title: "High",
                                accent: Color(red: 0.46, green: 0.84, blue: 1.0),
                                frequencyRange: 20...20_000,
                                isEnabled: eqBoolBinding(\.highEnabled),
                                filterType: eqFilterFamilyBinding(\.highFilterType),
                                slope: eqFilterSlopeBinding(\.highSlope),
                                gain: eqBinding(\.highGainDB),
                                frequency: eqBinding(\.highCenterFrequencyHz),
                                q: eqBinding(\.highQ),
                                onReset: { resetBand(.high) },
                                onEditingChanged: { editing in
                                    if !editing { commitEQSettings() }
                                },
                                onGainChanged: { updatePendingEQGain(for: .high, value: $0) },
                                onFrequencyChanged: { updatePendingEQFrequency(for: .high, value: $0) },
                                onQChanged: { updatePendingEQQ(for: .high, value: $0) }
                            )

                            FilterCutCardView(
                                title: "LPF",
                                accent: Color(red: 0.48, green: 0.72, blue: 1.0),
                                range: 20...20_000,
                                isEnabled: lowPassEnabledBinding,
                                filterType: eqFilterFamilyBinding(\.lowPassFilterType),
                                slope: eqFilterSlopeBinding(\.lowPassSlope),
                                frequency: lowPassBinding,
                                onReset: { resetBand(.lowPass) },
                                onEditingChanged: { editing in
                                    if !editing { commitEQSettings() }
                                },
                                onFrequencyChanged: { updatePendingEQFrequency(for: .lowPass, value: $0) }
                            )
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private var eqEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.enabled },
            set: { enabled in
                updateEQSettings { $0.enabled = enabled }
            }
        )
    }

    private var highPassEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.highPassEnabled },
            set: { enabled in
                updateEQSettings { settings in
                    settings.enabled = true
                    settings.highPassEnabled = enabled
                }
            }
        )
    }

    private var lowPassEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.lowPassEnabled },
            set: { enabled in
                updateEQSettings { settings in
                    settings.enabled = true
                    settings.lowPassEnabled = enabled
                }
            }
        )
    }

    private var highPassBinding: Binding<Double> {
        Binding(
            get: { settings.highPassFrequencyHz },
            set: { newValue in
                var newSettings = previewState.settings ?? globalSettings
                newSettings.enabled = true
                newSettings.highPassEnabled = true
                newSettings.highPassFrequencyHz = min(max(newValue, 20), 20_000)
                previewState.settings = newSettings
                applyPreviewEQSettings(newSettings)
            }
        )
    }

    private var lowPassBinding: Binding<Double> {
        Binding(
            get: { settings.lowPassFrequencyHz },
            set: { newValue in
                var newSettings = previewState.settings ?? globalSettings
                newSettings.enabled = true
                newSettings.lowPassEnabled = true
                newSettings.lowPassFrequencyHz = min(max(newValue, 20), 20_000)
                previewState.settings = newSettings
                applyPreviewEQSettings(newSettings)
            }
        )
    }

    private func eqBoolBinding(_ keyPath: WritableKeyPath<InputChannelEQSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                updateEQSettings { settings in
                    settings.enabled = true
                    settings[keyPath: keyPath] = value
                }
            }
        )
    }

    private func eqFilterFamilyBinding(_ keyPath: WritableKeyPath<InputChannelEQSettings, EQFilterFamily>) -> Binding<EQFilterFamily> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                updateEQSettings { settings in
                    settings.enabled = true
                    settings[keyPath: keyPath] = value
                }
            }
        )
    }

    private func eqFilterSlopeBinding(_ keyPath: WritableKeyPath<InputChannelEQSettings, EQFilterSlope>) -> Binding<EQFilterSlope> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                updateEQSettings { settings in
                    settings.enabled = true
                    settings[keyPath: keyPath] = value
                }
            }
        )
    }

    private func eqBinding(_ keyPath: WritableKeyPath<InputChannelEQSettings, Double>) -> Binding<Double> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                var newSettings = previewState.settings ?? globalSettings
                newSettings.enabled = true
                newSettings[keyPath: keyPath] = newValue
                previewState.settings = newSettings
                applyPreviewEQSettings(newSettings)
            }
        )
    }

    private func commitEQSettings() {
        guard let pending = previewState.settings else { return }
        updateEQSettings { settings in
            settings = pending
        }
        previewState.settings = nil
    }

    private func updatePendingEQGain(for band: EQBandKind, value: Double) {
        var newSettings = previewState.settings ?? globalSettings
        newSettings.enabled = true
        switch band {
        case .low:
            newSettings.lowEnabled = true
            newSettings.lowGainDB = value
        case .lowMid:
            newSettings.lowMidEnabled = true
            newSettings.lowMidGainDB = value
        case .mid:
            newSettings.midEnabled = true
            newSettings.midGainDB = value
        case .presence:
            newSettings.presenceEnabled = true
            newSettings.presenceGainDB = value
        case .high:
            newSettings.highEnabled = true
            newSettings.highGainDB = value
        default: break
        }
        previewState.settings = newSettings
        applyPreviewEQSettings(newSettings)
    }

    private func updatePendingEQFrequency(for band: EQBandKind, value: Double) {
        var newSettings = previewState.settings ?? globalSettings
        newSettings.enabled = true
        switch band {
        case .highPass:
            newSettings.highPassEnabled = true
            newSettings.highPassFrequencyHz = min(max(value, 20), 20_000)
        case .low:
            newSettings.lowEnabled = true
            newSettings.lowCenterFrequencyHz = min(max(value, 20), 20_000)
        case .lowMid:
            newSettings.lowMidEnabled = true
            newSettings.lowMidCenterFrequencyHz = min(max(value, 20), 20_000)
        case .mid:
            newSettings.midEnabled = true
            newSettings.midCenterFrequencyHz = min(max(value, 20), 20_000)
        case .presence:
            newSettings.presenceEnabled = true
            newSettings.presenceCenterFrequencyHz = min(max(value, 20), 20_000)
        case .high:
            newSettings.highEnabled = true
            newSettings.highCenterFrequencyHz = min(max(value, 20), 20_000)
        case .lowPass:
            newSettings.lowPassEnabled = true
            newSettings.lowPassFrequencyHz = min(max(value, 20), 20_000)
        }
        previewState.settings = newSettings
        applyPreviewEQSettings(newSettings)
    }

    private func updatePendingEQQ(for band: EQBandKind, value: Double) {
        var newSettings = previewState.settings ?? globalSettings
        newSettings.enabled = true
        switch band {
        case .low:
            newSettings.lowEnabled = true
            newSettings.lowQ = value
        case .lowMid:
            newSettings.lowMidEnabled = true
            newSettings.lowMidQ = value
        case .mid:
            newSettings.midEnabled = true
            newSettings.midQ = value
        case .presence:
            newSettings.presenceEnabled = true
            newSettings.presenceQ = value
        case .high:
            newSettings.highEnabled = true
            newSettings.highQ = value
        default: break
        }
        previewState.settings = newSettings
        applyPreviewEQSettings(newSettings)
    }

    private func updateOverlayState(node: EQEditableNode, frequency: Double, gain: Double?) {
        var newSettings = previewState.settings ?? globalSettings
        newSettings.enabled = true
        switch node {
        case .highPass:
            newSettings.highPassEnabled = true
            newSettings.highPassFrequencyHz = min(max(frequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
        case .low:
            newSettings.lowEnabled = true
            newSettings.lowCenterFrequencyHz = min(max(frequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
            if let gain { newSettings.lowGainDB = min(max(gain, -24.0), 24.0) }
        case .lowMid:
            newSettings.lowMidEnabled = true
            newSettings.lowMidCenterFrequencyHz = min(max(frequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
            if let gain { newSettings.lowMidGainDB = min(max(gain, -24.0), 24.0) }
        case .mid:
            newSettings.midEnabled = true
            newSettings.midCenterFrequencyHz = min(max(frequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
            if let gain { newSettings.midGainDB = min(max(gain, -24.0), 24.0) }
        case .presence:
            newSettings.presenceEnabled = true
            newSettings.presenceCenterFrequencyHz = min(max(frequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
            if let gain { newSettings.presenceGainDB = min(max(gain, -24.0), 24.0) }
        case .high:
            newSettings.highEnabled = true
            newSettings.highCenterFrequencyHz = min(max(frequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
            if let gain { newSettings.highGainDB = min(max(gain, -24.0), 24.0) }
        case .lowPass:
            newSettings.lowPassEnabled = true
            newSettings.lowPassFrequencyHz = min(max(frequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
        }
        previewState.settings = newSettings
        applyPreviewEQSettings(newSettings)
    }

    private func commitOverlaySettings() {
        guard let pending = previewState.settings else { return }
        updateEQSettings { settings in
            settings = pending
        }
        previewState.settings = nil
    }

    private func resetBand(_ band: EQBandKind) {
        updateEQSettings { settings in
            settings.resetBand(band)
        }
        // Update preview state if active
        var newSettings = previewState.settings ?? globalSettings
        newSettings.resetBand(band)
        previewState.settings = newSettings
    }

    private func resetAllBands() {
        updateEQSettings { settings in
            settings.resetAllBands()
        }
        previewState.settings = nil
    }

    private func applyPreviewEQSettings(_ settings: InputChannelEQSettings) {
        channelStateManager.applyPreviewEQSettings(
            for: device.deviceID,
            channelType: role == .input ? MIXER_CHANNEL_INPUT : MIXER_CHANNEL_OUTPUT,
            channel: channelIndex,
            settings: settings
        )
    }

    private func updateEQSettings(_ mutate: (inout InputChannelEQSettings) -> Void) {
        switch role {
        case .input:
            channelStateManager.updateEQSettings(for: device.deviceID, channel: channelIndex, mutate: mutate)
        case .output:
            channelStateManager.updateOutputEQSettings(for: device.deviceID, channel: channelIndex, mutate: mutate)
        }
    }
}

// MARK: - Dynamics Compact Components

struct CompactGainReductionMeterView: View {
    let gainReductionDB: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(Color.black.opacity(0.04))
                    .frame(width: 16, height: 140)

                Rectangle()
                    .fill(Color(red: 0.8, green: 0.2, blue: 0.2))
                    .frame(width: 16, height: max(2, min(140, gainReductionDB / 20.0 * 140.0)))
            }
            .clipShape(Rectangle())

            Text(String(format: "%.1f", gainReductionDB))
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(red: 0.8, green: 0.2, blue: 0.2))
                .frame(width: 16, alignment: .center)
        }
    }
}

struct DraggableThresholdNode: View {
    @Binding var threshold: Double
    let range: ClosedRange<Double>
    let accent: Color
    var onEditingChanged: ((Bool) -> Void)? = nil

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            Circle()
                .fill(accent)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: 2)
                )
                .position(
                    x: geometry.size.width * ((threshold - range.lowerBound) / (range.upperBound - range.lowerBound)),
                    y: geometry.size.height * 0.5
                )
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                onEditingChanged?(true)
                            }
                            let width = geometry.size.width
                            let normalizedX = value.location.x / width
                            let newValue = range.lowerBound + normalizedX * (range.upperBound - range.lowerBound)
                            threshold = max(range.lowerBound, min(range.upperBound, newValue))
                        }
                        .onEnded { _ in
                            isDragging = false
                            onEditingChanged?(false)
                        }
                )
        }
    }
}

struct DynamicsMiniCard: View {
    let title: String
    let accent: Color
    @Binding var value1: Double
    @Binding var value2: Double
    let range1: ClosedRange<Double>
    let range2: ClosedRange<Double>
    let label1: String
    let label2: String
    let format1: String
    let format2: String
    var isPercent2: Bool = false
    var onEditingChanged: ((Bool) -> Void)? = nil
    var onValue1Changed: ((Double) -> Void)? = nil
    var onValue2Changed: ((Double) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.secondary)

            HStack(spacing: 6) {
                DraggableValueField(
                    value: $value1,
                    range: range1,
                    label: label1,
                    format: format1,
                    accent: accent,
                    onEditingChanged: onEditingChanged,
                    onValueChanged: onValue1Changed
                )

                DraggableValueField(
                    value: $value2,
                    range: range2,
                    label: label2,
                    format: format2,
                    accent: accent,
                    isPercent: isPercent2,
                    onEditingChanged: onEditingChanged,
                    onValueChanged: onValue2Changed
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(accent.opacity(0.3), lineWidth: 0.5)
        )
    }
}

struct DynamicsLimiterCard: View {
    let title: String
    let accent: Color
    @Binding var ceiling: Double
    let range: ClosedRange<Double>
    @Binding var isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Toggle("", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .scaleEffect(0.6)
            }

            DraggableValueField(
                value: $ceiling,
                range: range,
                label: "dBFS",
                format: "%.1f",
                accent: accent
            )
        }
        .padding(8)
        .frame(width: 90)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isEnabled ? accent.opacity(0.1) : Color.gray.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isEnabled ? accent.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 0.5)
        )
        .opacity(isEnabled ? 1.0 : 0.5)
    }
}

struct DynamicsMakeupMixLimiterCard: View {
    let accent: Color
    @Binding var makeup: Double
    @Binding var mix: Double
    @Binding var ceiling: Double
    @Binding var limiterEnabled: Bool
    let makeupRange: ClosedRange<Double>
    let mixRange: ClosedRange<Double>
    let ceilingRange: ClosedRange<Double>
    var onEditingChanged: ((Bool) -> Void)? = nil
    var onMakeupChanged: ((Double) -> Void)? = nil
    var onMixChanged: ((Double) -> Void)? = nil
    var onCeilingChanged: ((Double) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    Text("Makeup")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.secondary)

                    DraggableValueField(
                        value: $makeup,
                        range: makeupRange,
                        label: "dB",
                        format: "%+.1f",
                        accent: accent,
                        onEditingChanged: onEditingChanged,
                        onValueChanged: onMakeupChanged
                    )
                }

                VStack(spacing: 4) {
                    HStack {
                        Text("Limiter")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Toggle("", isOn: $limiterEnabled)
                            .toggleStyle(.switch)
                            .scaleEffect(0.6)
                    }

                    DraggableValueField(
                        value: $ceiling,
                        range: ceilingRange,
                        label: "dBFS",
                        format: "%.1f",
                        accent: accent,
                        onEditingChanged: onEditingChanged,
                        onValueChanged: onCeilingChanged
                    )
                    .opacity(limiterEnabled ? 1.0 : 0.4)
                }

                VStack(spacing: 4) {
                    Text("Mix")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.secondary)

                    DraggableValueField(
                        value: $mix,
                        range: mixRange,
                        label: "%",
                        format: "%.0f",
                        accent: accent,
                        isPercent: true,
                        onEditingChanged: onEditingChanged,
                        onValueChanged: onMixChanged
                    )
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(limiterEnabled ? accent.opacity(0.1) : accent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(limiterEnabled ? accent.opacity(0.3) : accent.opacity(0.2), lineWidth: 0.5)
        )
        .opacity(limiterEnabled ? 1.0 : 0.7)
    }
}

struct DraggableValueField: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    let format: String
    let accent: Color
    var isPercent: Bool = false
    var onEditingChanged: ((Bool) -> Void)? = nil
    var onValueChanged: ((Double) -> Void)? = nil

    @State private var isDragging = false
    @State private var dragStartValue: Double = 0

    var displayValue: String {
        if isPercent {
            return String(format: format, value * 100)
        }
        return String(format: format, value)
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(accent.opacity(0.15))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(accent.opacity(isDragging ? 0.6 : 0.3), lineWidth: isDragging ? 1 : 0.5)

                Text(displayValue)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
            }
            .frame(height: 28)
            .gesture(
                DragGesture()
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            dragStartValue = value
                            onEditingChanged?(true)
                        }
                        let delta = gesture.translation.height
                        let rangeSpan = range.upperBound - range.lowerBound
                        let sensitivity: CGFloat = 200
                        let normalizedDelta = -delta / sensitivity
                        let newValue = dragStartValue + Double(normalizedDelta) * rangeSpan
                        let clampedValue = max(range.lowerBound, min(range.upperBound, newValue))
                        value = clampedValue
                        onValueChanged?(clampedValue)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged?(false)
                    }
            )

            Text(label)
                .font(.system(size: 6, weight: .medium))
                .foregroundColor(.secondary)
        }
    }
}

private struct DynamicsAnalyzerSection: View {
    let baseSettings: InputChannelDynamicsSettings
    @ObservedObject var previewState: DynamicsPreviewState
    let thresholdBinding: Binding<Double>
    var onThresholdEditingChanged: ((Bool) -> Void)? = nil

    @StateObject private var scopeModel: DynamicsWaveformModel

    init(deviceID: AudioDeviceID,
         channelIndex: Int,
         channelType: UInt32,
         baseSettings: InputChannelDynamicsSettings,
         previewState: DynamicsPreviewState,
         thresholdBinding: Binding<Double>,
         onThresholdEditingChanged: ((Bool) -> Void)? = nil) {
        self.baseSettings = baseSettings
        self.previewState = previewState
        self.thresholdBinding = thresholdBinding
        self.onThresholdEditingChanged = onThresholdEditingChanged
        _scopeModel = StateObject(wrappedValue: DynamicsWaveformModel(
            deviceID: deviceID,
            channelIndex: channelIndex,
            channelType: channelType
        ))
    }

    private var settings: InputChannelDynamicsSettings {
        previewState.settings ?? baseSettings
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack(alignment: .topLeading) {
                DynamicsLiveWaveformView(model: scopeModel)
                DynamicsTransferGraphView(settings: settings)
                    .overlay(
                        DraggableThresholdNode(
                            threshold: thresholdBinding,
                            range: -60...0,
                            accent: .green,
                            onEditingChanged: onThresholdEditingChanged
                        )
                    )
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.green.opacity(0.22), lineWidth: 0.5)
            )

            CompactGainReductionMeterView(gainReductionDB: Double(scopeModel.gainReductionDB))
        }
    }
}

struct InputChannelDynamicsWindowView: View {
    let device: AudioDevice
    let channelIndex: Int
    let role: ChannelRole

    @EnvironmentObject private var channelStateManager: ChannelStateManager
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var previewState = DynamicsPreviewState()

    init(device: AudioDevice, channelIndex: Int, role: ChannelRole = .input) {
        self.device = device
        self.channelIndex = channelIndex
        self.role = role
    }

    private var channelType: UInt32 {
        role == .input ? MIXER_CHANNEL_INPUT : MIXER_CHANNEL_OUTPUT
    }

    private var globalSettings: InputChannelDynamicsSettings {
        switch role {
        case .input:
            return channelStateManager.dynamicsSettings(for: device.deviceID, channel: channelIndex)
        case .output:
            return channelStateManager.outputDynamicsSettings(for: device.deviceID, channel: channelIndex)
        }
    }

    private var settings: InputChannelDynamicsSettings {
        previewState.settings ?? globalSettings
    }

    private var channelRoleLabel: String {
        role == .input ? "Input" : "Output"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                InputProcessingCard(accent: .green) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dynamics")
                                .font(.system(size: 14, weight: .bold))
                            Text("\(device.name) • \(channelRoleLabel) \(channelIndex + 1)")
                                .font(.system(size: 7, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Button("Reset") {
                                resetDynamics()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 6, weight: .bold))
                            .foregroundColor(.green)

                            Toggle("Dyn", isOn: dynamicsEnabledBinding)
                                .toggleStyle(.switch)
                                .scaleEffect(0.5)
                        }
                    }

                    DynamicsAnalyzerSection(
                        deviceID: device.deviceID,
                        channelIndex: channelIndex,
                        channelType: channelType,
                        baseSettings: globalSettings,
                        previewState: previewState,
                        thresholdBinding: dynamicsBinding(\.thresholdDB),
                        onThresholdEditingChanged: handleDynamicsEditingChanged
                    )
                }

                InputProcessingCard(accent: .green) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dynamics Stack")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 8) {
                        DynamicsMiniCard(
                            title: "Thresh / Ratio",
                            accent: .green,
                            value1: dynamicsBinding(\.thresholdDB),
                            value2: dynamicsBinding(\.ratio),
                            range1: -60...0,
                            range2: 1...20,
                            label1: "dB",
                            label2: ":1",
                            format1: "%.1f",
                            format2: "%.1f",
                            onEditingChanged: handleDynamicsEditingChanged,
                            onValue1Changed: { updatePendingDynamicsValue(\.thresholdDB, value: $0) },
                            onValue2Changed: { updatePendingDynamicsValue(\.ratio, value: $0) }
                        )

                        DynamicsMiniCard(
                            title: "Attack / Release",
                            accent: Color(red: 0.0, green: 0.5, blue: 0.5),
                            value1: dynamicsBinding(\.attackMilliseconds),
                            value2: dynamicsBinding(\.releaseMilliseconds),
                            range1: 0.01...500,
                            range2: 1...1500,
                            label1: "ms",
                            label2: "ms",
                            format1: "%.1f",
                            format2: "%.0f",
                            onEditingChanged: handleDynamicsEditingChanged,
                            onValue1Changed: { updatePendingDynamicsValue(\.attackMilliseconds, value: $0) },
                            onValue2Changed: { updatePendingDynamicsValue(\.releaseMilliseconds, value: $0) }
                        )

                        DynamicsMakeupMixLimiterCard(
                            accent: Color(red: 0.62, green: 0.96, blue: 0.78),
                            makeup: dynamicsBinding(\.makeupGainDB),
                            mix: dynamicsBinding(\.mix),
                            ceiling: dynamicsBinding(\.limiterCeilingDB),
                            limiterEnabled: dynamicsBoolBinding(\.limiterEnabled),
                            makeupRange: 0...24,
                            mixRange: 0...1,
                            ceilingRange: -24...0,
                            onEditingChanged: handleDynamicsEditingChanged,
                            onMakeupChanged: { updatePendingDynamicsValue(\.makeupGainDB, value: $0) },
                            onMixChanged: { updatePendingDynamicsValue(\.mix, value: $0) },
                            onCeilingChanged: { updatePendingDynamicsValue(\.limiterCeilingDB, value: $0) }
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
    }

    private var dynamicsEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.enabled },
            set: { enabled in
                commitDynamicsChange { $0.enabled = enabled }
            }
        )
    }

    private func dynamicsBinding(_ keyPath: WritableKeyPath<InputChannelDynamicsSettings, Double>) -> Binding<Double> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                updatePendingDynamicsValue(keyPath, value: value)
            }
        )
    }

    private func dynamicsBoolBinding(_ keyPath: WritableKeyPath<InputChannelDynamicsSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                commitDynamicsChange { settings in
                    settings.enabled = true
                    settings[keyPath: keyPath] = value
                }
            }
        )
    }

    private func handleDynamicsEditingChanged(_ editing: Bool) {
        if !editing {
            commitDynamicsSettings()
        }
    }

    private func updatePendingDynamicsValue(_ keyPath: WritableKeyPath<InputChannelDynamicsSettings, Double>, value: Double) {
        var newSettings = previewState.settings ?? globalSettings
        newSettings.enabled = true
        newSettings[keyPath: keyPath] = value
        previewState.settings = newSettings
        applyPreviewDynamicsSettings(newSettings)
    }

    private func applyPreviewDynamicsSettings(_ settings: InputChannelDynamicsSettings) {
        channelStateManager.applyPreviewDynamicsSettings(
            for: device.deviceID,
            channelType: channelType,
            channel: channelIndex,
            settings: settings
        )
    }

    private func commitDynamicsChange(_ mutate: (inout InputChannelDynamicsSettings) -> Void) {
        var newSettings = previewState.settings ?? globalSettings
        mutate(&newSettings)
        updateDynamicsSettings { settings in
            settings = newSettings
        }
        previewState.settings = nil
    }

    private func commitDynamicsSettings() {
        guard let pending = previewState.settings else { return }
        updateDynamicsSettings { settings in
            settings = pending
        }
        previewState.settings = nil
    }

    private func updateDynamicsSettings(_ mutate: (inout InputChannelDynamicsSettings) -> Void) {
        switch role {
        case .input:
            channelStateManager.updateDynamicsSettings(for: device.deviceID, channel: channelIndex, mutate: mutate)
        case .output:
            channelStateManager.updateOutputDynamicsSettings(for: device.deviceID, channel: channelIndex, mutate: mutate)
        }
    }

    private func resetDynamics() {
        commitDynamicsChange { settings in
            settings.thresholdDB = -20.0
            settings.ratio = 4.0
            settings.attackMilliseconds = 10.0
            settings.releaseMilliseconds = 250.0
            settings.makeupGainDB = 0.0
            settings.mix = 1.0
            settings.limiterEnabled = false
            settings.limiterCeilingDB = -0.1
        }
    }
}

private final class VirtualChannelFFTAnalyzer: ObservableObject {
    let processor: SafeFFTSpectrumProcessor?

    init(channel: VirtualChannel) {
        let descriptor: MixerVisualizerSource?
        switch channel.type {
        case .auxSend:
            descriptor = .auxSend(busIndex: channel.index)
        case .fxSend:
            descriptor = .fxSend(busIndex: channel.index)
        case .auxReturn:
            descriptor = .auxReturn(busIndex: channel.index)
        case .fxReturn:
            descriptor = .fxReturn(busIndex: channel.index)
        case .dca, .virtualInstrument:
            descriptor = nil
        }

        guard let descriptor else {
            self.processor = nil
            return
        }

        let fftSize = VisualisationSettings.shared.spectrumFFTSize
        let source = MixerVisualizerAudioSource(source: descriptor)
        let processor = SafeFFTSpectrumProcessor(
            streamManager: source,
            channelIndex: 0,
            channelCount: 1,
            fftSize: fftSize
        )
        processor.start()
        self.processor = processor
    }

    deinit {
        processor?.stop()
    }
}

struct VirtualChannelEQWindowView: View {
    let channel: VirtualChannel

    @EnvironmentObject private var channelStateManager: ChannelStateManager
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var analyzer: VirtualChannelFFTAnalyzer
    @StateObject private var previewState = EQPreviewState()

    init(channel: VirtualChannel) {
        self.channel = channel
        _analyzer = StateObject(wrappedValue: VirtualChannelFFTAnalyzer(channel: channel))
    }

    private var globalSettings: InputChannelEQSettings {
        channelStateManager.eqSettings(for: channel.id)
    }

    private var settings: InputChannelEQSettings {
        previewState.settings ?? globalSettings
    }

    private var channelLabel: String {
        "\(channel.name) • \(channel.type.rawValue.uppercased())"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                InputProcessingCard(accent: Color(red: 0.0, green: 0.75, blue: 0.8)) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Parametric EQ")
                                .font(.system(size: 14, weight: .bold))
                            Text(channelLabel)
                                .font(.system(size: 7, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Button("Reset") {
                                resetAllBands()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 6, weight: .bold))
                            .foregroundColor(Color(red: 0.0, green: 0.75, blue: 0.8))

                            Toggle("EQ", isOn: eqEnabledBinding)
                                .toggleStyle(.switch)
                                .scaleEffect(0.5)
                        }
                    }

                    if let processor = analyzer.processor {
                        ZStack {
                            EquatableView(content: SpectrumRendererContainer(
                                processor: processor,
                                channelIndex: 0,
                                themeMode: themeManager.capsuleThemeMode
                            ))

                            EQAnalyzerOverlayView(
                                baseSettings: globalSettings,
                                processor: processor,
                                previewState: previewState,
                                showPostEQ: false,
                                postEQProcessor: nil,
                                onNodeDrag: { node, freq, gain in
                                    updateOverlayState(node: node, frequency: freq, gain: gain)
                                },
                                onCommit: {
                                    commitOverlaySettings()
                                }
                            )
                            .padding(.vertical, 7)
                            .drawingGroup(opaque: false)
                        }
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(red: 0.0, green: 0.75, blue: 0.8).opacity(0.22), lineWidth: 0.5)
                        )
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
                            .frame(height: 160)
                            .overlay(
                                Text("FFT unavailable")
                                    .font(.system(size: 7, weight: .medium))
                                    .foregroundColor(.secondary)
                            )
                    }
                }

                InputProcessingCard(accent: Color(red: 0.0, green: 0.75, blue: 0.8)) {
                    Text("Filter Stack")
                        .font(.system(size: 10, weight: .bold))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 6) {
                            FilterCutCardView(
                                title: "HPF",
                                accent: Color(red: 0.0, green: 0.75, blue: 0.8),
                                range: 20...20_000,
                                isEnabled: highPassEnabledBinding,
                                filterType: eqFilterFamilyBinding(\.highPassFilterType),
                                slope: eqFilterSlopeBinding(\.highPassSlope),
                                frequency: highPassBinding,
                                onReset: { resetBand(.highPass) },
                                onEditingChanged: { editing in
                                    if !editing { commitEQSettings() }
                                },
                                onFrequencyChanged: { updatePendingEQFrequency(for: .highPass, value: $0) }
                            )

                            EQBandCard(
                                title: "Low",
                                accent: Color(red: 0.24, green: 0.82, blue: 0.88),
                                frequencyRange: 20...20_000,
                                isEnabled: eqBoolBinding(\.lowEnabled),
                                filterType: eqFilterFamilyBinding(\.lowFilterType),
                                slope: eqFilterSlopeBinding(\.lowSlope),
                                gain: eqBinding(\.lowGainDB),
                                frequency: eqBinding(\.lowCenterFrequencyHz),
                                q: eqBinding(\.lowQ),
                                onReset: { resetBand(.low) },
                                onEditingChanged: { editing in
                                    if !editing { commitEQSettings() }
                                },
                                onGainChanged: { updatePendingEQGain(for: .low, value: $0) },
                                onFrequencyChanged: { updatePendingEQFrequency(for: .low, value: $0) },
                                onQChanged: { updatePendingEQQ(for: .low, value: $0) }
                            )

                            EQBandCard(
                                title: "Low Mid",
                                accent: Color(red: 0.24, green: 0.88, blue: 0.78),
                                frequencyRange: 20...20_000,
                                isEnabled: eqBoolBinding(\.lowMidEnabled),
                                filterType: eqFilterFamilyBinding(\.lowMidFilterType),
                                slope: eqFilterSlopeBinding(\.lowMidSlope),
                                gain: eqBinding(\.lowMidGainDB),
                                frequency: eqBinding(\.lowMidCenterFrequencyHz),
                                q: eqBinding(\.lowMidQ),
                                onReset: { resetBand(.lowMid) },
                                onEditingChanged: { editing in
                                    if !editing { commitEQSettings() }
                                },
                                onGainChanged: { updatePendingEQGain(for: .lowMid, value: $0) },
                                onFrequencyChanged: { updatePendingEQFrequency(for: .lowMid, value: $0) },
                                onQChanged: { updatePendingEQQ(for: .lowMid, value: $0) }
                            )

                            EQBandCard(
                                title: "Mid",
                                accent: Color(red: 0.34, green: 0.92, blue: 0.78),
                                frequencyRange: 20...20_000,
                                isEnabled: eqBoolBinding(\.midEnabled),
                                filterType: eqFilterFamilyBinding(\.midFilterType),
                                slope: eqFilterSlopeBinding(\.midSlope),
                                gain: eqBinding(\.midGainDB),
                                frequency: eqBinding(\.midCenterFrequencyHz),
                                q: eqBinding(\.midQ),
                                onReset: { resetBand(.mid) },
                                onEditingChanged: { editing in
                                    if !editing { commitEQSettings() }
                                },
                                onGainChanged: { updatePendingEQGain(for: .mid, value: $0) },
                                onFrequencyChanged: { updatePendingEQFrequency(for: .mid, value: $0) },
                                onQChanged: { updatePendingEQQ(for: .mid, value: $0) }
                            )

                            EQBandCard(
                                title: "Presence",
                                accent: Color(red: 0.54, green: 0.78, blue: 1.0),
                                frequencyRange: 20...20_000,
                                isEnabled: eqBoolBinding(\.presenceEnabled),
                                filterType: eqFilterFamilyBinding(\.presenceFilterType),
                                slope: eqFilterSlopeBinding(\.presenceSlope),
                                gain: eqBinding(\.presenceGainDB),
                                frequency: eqBinding(\.presenceCenterFrequencyHz),
                                q: eqBinding(\.presenceQ),
                                onReset: { resetBand(.presence) },
                                onEditingChanged: { editing in
                                    if !editing { commitEQSettings() }
                                },
                                onGainChanged: { updatePendingEQGain(for: .presence, value: $0) },
                                onFrequencyChanged: { updatePendingEQFrequency(for: .presence, value: $0) },
                                onQChanged: { updatePendingEQQ(for: .presence, value: $0) }
                            )

                            EQBandCard(
                                title: "High",
                                accent: Color(red: 0.46, green: 0.84, blue: 1.0),
                                frequencyRange: 20...20_000,
                                isEnabled: eqBoolBinding(\.highEnabled),
                                filterType: eqFilterFamilyBinding(\.highFilterType),
                                slope: eqFilterSlopeBinding(\.highSlope),
                                gain: eqBinding(\.highGainDB),
                                frequency: eqBinding(\.highCenterFrequencyHz),
                                q: eqBinding(\.highQ),
                                onReset: { resetBand(.high) },
                                onEditingChanged: { editing in
                                    if !editing { commitEQSettings() }
                                },
                                onGainChanged: { updatePendingEQGain(for: .high, value: $0) },
                                onFrequencyChanged: { updatePendingEQFrequency(for: .high, value: $0) },
                                onQChanged: { updatePendingEQQ(for: .high, value: $0) }
                            )

                            FilterCutCardView(
                                title: "LPF",
                                accent: Color(red: 0.48, green: 0.72, blue: 1.0),
                                range: 20...20_000,
                                isEnabled: lowPassEnabledBinding,
                                filterType: eqFilterFamilyBinding(\.lowPassFilterType),
                                slope: eqFilterSlopeBinding(\.lowPassSlope),
                                frequency: lowPassBinding,
                                onReset: { resetBand(.lowPass) },
                                onEditingChanged: { editing in
                                    if !editing { commitEQSettings() }
                                },
                                onFrequencyChanged: { updatePendingEQFrequency(for: .lowPass, value: $0) }
                            )
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private var eqEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.enabled },
            set: { enabled in
                channelStateManager.updateEQSettings(for: channel.id, type: channel.type, channelIndex: channel.index) { $0.enabled = enabled }
            }
        )
    }

    private var highPassEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.highPassEnabled },
            set: { enabled in
                channelStateManager.updateEQSettings(for: channel.id, type: channel.type, channelIndex: channel.index) { settings in
                    settings.enabled = true
                    settings.highPassEnabled = enabled
                }
            }
        )
    }

    private var lowPassEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.lowPassEnabled },
            set: { enabled in
                channelStateManager.updateEQSettings(for: channel.id, type: channel.type, channelIndex: channel.index) { settings in
                    settings.enabled = true
                    settings.lowPassEnabled = enabled
                }
            }
        )
    }

    private var highPassBinding: Binding<Double> {
        Binding(
            get: { settings.highPassFrequencyHz },
            set: { newValue in
                var newSettings = previewState.settings ?? globalSettings
                newSettings.enabled = true
                newSettings.highPassEnabled = true
                newSettings.highPassFrequencyHz = min(max(newValue, 20), 20_000)
                previewState.settings = newSettings
                applyPreviewEQSettings(newSettings)
            }
        )
    }

    private var lowPassBinding: Binding<Double> {
        Binding(
            get: { settings.lowPassFrequencyHz },
            set: { newValue in
                var newSettings = previewState.settings ?? globalSettings
                newSettings.enabled = true
                newSettings.lowPassEnabled = true
                newSettings.lowPassFrequencyHz = min(max(newValue, 20), 20_000)
                previewState.settings = newSettings
                applyPreviewEQSettings(newSettings)
            }
        )
    }

    private func eqBoolBinding(_ keyPath: WritableKeyPath<InputChannelEQSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                channelStateManager.updateEQSettings(for: channel.id, type: channel.type, channelIndex: channel.index) { settings in
                    settings.enabled = true
                    settings[keyPath: keyPath] = value
                }
            }
        )
    }

    private func eqFilterFamilyBinding(_ keyPath: WritableKeyPath<InputChannelEQSettings, EQFilterFamily>) -> Binding<EQFilterFamily> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                channelStateManager.updateEQSettings(for: channel.id, type: channel.type, channelIndex: channel.index) { settings in
                    settings.enabled = true
                    settings[keyPath: keyPath] = value
                }
            }
        )
    }

    private func eqFilterSlopeBinding(_ keyPath: WritableKeyPath<InputChannelEQSettings, EQFilterSlope>) -> Binding<EQFilterSlope> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                channelStateManager.updateEQSettings(for: channel.id, type: channel.type, channelIndex: channel.index) { settings in
                    settings.enabled = true
                    settings[keyPath: keyPath] = value
                }
            }
        )
    }

    private func eqBinding(_ keyPath: WritableKeyPath<InputChannelEQSettings, Double>) -> Binding<Double> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                var newSettings = previewState.settings ?? globalSettings
                newSettings.enabled = true
                newSettings[keyPath: keyPath] = newValue
                previewState.settings = newSettings
                applyPreviewEQSettings(newSettings)
            }
        )
    }

    private func updateOverlayState(node: EQEditableNode, frequency: Double, gain: Double?) {
        var newSettings = previewState.settings ?? globalSettings
        newSettings.enabled = true
        switch node {
        case .highPass:
            newSettings.highPassEnabled = true
            newSettings.highPassFrequencyHz = min(max(frequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
        case .low:
            newSettings.lowEnabled = true
            newSettings.lowCenterFrequencyHz = min(max(frequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
            if let gain { newSettings.lowGainDB = min(max(gain, -24.0), 24.0) }
        case .lowMid:
            newSettings.lowMidEnabled = true
            newSettings.lowMidCenterFrequencyHz = min(max(frequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
            if let gain { newSettings.lowMidGainDB = min(max(gain, -24.0), 24.0) }
        case .mid:
            newSettings.midEnabled = true
            newSettings.midCenterFrequencyHz = min(max(frequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
            if let gain { newSettings.midGainDB = min(max(gain, -24.0), 24.0) }
        case .presence:
            newSettings.presenceEnabled = true
            newSettings.presenceCenterFrequencyHz = min(max(frequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
            if let gain { newSettings.presenceGainDB = min(max(gain, -24.0), 24.0) }
        case .high:
            newSettings.highEnabled = true
            newSettings.highCenterFrequencyHz = min(max(frequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
            if let gain { newSettings.highGainDB = min(max(gain, -24.0), 24.0) }
        case .lowPass:
            newSettings.lowPassEnabled = true
            newSettings.lowPassFrequencyHz = min(max(frequency, node.frequencyRange.lowerBound), node.frequencyRange.upperBound)
        }
        previewState.settings = newSettings
        applyPreviewEQSettings(newSettings)
    }

    private func commitOverlaySettings() {
        guard let pending = previewState.settings else { return }
        channelStateManager.updateEQSettings(for: channel.id, type: channel.type, channelIndex: channel.index) { settings in
            settings = pending
        }
        previewState.settings = nil
    }

    private func resetBand(_ band: EQBandKind) {
        channelStateManager.updateEQSettings(for: channel.id, type: channel.type, channelIndex: channel.index) { settings in
            settings.resetBand(band)
        }
        // Update preview state if active
        var newSettings = previewState.settings ?? globalSettings
        newSettings.resetBand(band)
        previewState.settings = newSettings
    }

    private func resetAllBands() {
        channelStateManager.updateEQSettings(for: channel.id, type: channel.type, channelIndex: channel.index) { settings in
            settings.resetAllBands()
        }
        previewState.settings = nil
    }

    private func applyPreviewEQSettings(_ settings: InputChannelEQSettings) {
        channelStateManager.applyPreviewEQSettings(
            for: channel.id,
            type: channel.type,
            channelIndex: channel.index,
            settings: settings
        )
    }

    private func commitEQSettings() {
        guard let pending = previewState.settings else { return }
        channelStateManager.updateEQSettings(for: channel.id, type: channel.type, channelIndex: channel.index) { settings in
            settings = pending
        }
        previewState.settings = nil
    }

    private func updatePendingEQGain(for band: EQBandKind, value: Double) {
        var newSettings = previewState.settings ?? globalSettings
        newSettings.enabled = true
        switch band {
        case .low:
            newSettings.lowEnabled = true
            newSettings.lowGainDB = value
        case .lowMid:
            newSettings.lowMidEnabled = true
            newSettings.lowMidGainDB = value
        case .mid:
            newSettings.midEnabled = true
            newSettings.midGainDB = value
        case .presence:
            newSettings.presenceEnabled = true
            newSettings.presenceGainDB = value
        case .high:
            newSettings.highEnabled = true
            newSettings.highGainDB = value
        default: break
        }
        previewState.settings = newSettings
        applyPreviewEQSettings(newSettings)
    }

    private func updatePendingEQFrequency(for band: EQBandKind, value: Double) {
        var newSettings = previewState.settings ?? globalSettings
        newSettings.enabled = true
        switch band {
        case .highPass:
            newSettings.highPassEnabled = true
            newSettings.highPassFrequencyHz = min(max(value, 20), 20_000)
        case .low:
            newSettings.lowEnabled = true
            newSettings.lowCenterFrequencyHz = min(max(value, 20), 20_000)
        case .lowMid:
            newSettings.lowMidEnabled = true
            newSettings.lowMidCenterFrequencyHz = min(max(value, 20), 20_000)
        case .mid:
            newSettings.midEnabled = true
            newSettings.midCenterFrequencyHz = min(max(value, 20), 20_000)
        case .presence:
            newSettings.presenceEnabled = true
            newSettings.presenceCenterFrequencyHz = min(max(value, 20), 20_000)
        case .high:
            newSettings.highEnabled = true
            newSettings.highCenterFrequencyHz = min(max(value, 20), 20_000)
        case .lowPass:
            newSettings.lowPassEnabled = true
            newSettings.lowPassFrequencyHz = min(max(value, 20), 20_000)
        }
        previewState.settings = newSettings
        applyPreviewEQSettings(newSettings)
    }

    private func updatePendingEQQ(for band: EQBandKind, value: Double) {
        var newSettings = previewState.settings ?? globalSettings
        newSettings.enabled = true
        switch band {
        case .low:
            newSettings.lowEnabled = true
            newSettings.lowQ = value
        case .lowMid:
            newSettings.lowMidEnabled = true
            newSettings.lowMidQ = value
        case .mid:
            newSettings.midEnabled = true
            newSettings.midQ = value
        case .presence:
            newSettings.presenceEnabled = true
            newSettings.presenceQ = value
        case .high:
            newSettings.highEnabled = true
            newSettings.highQ = value
        default: break
        }
        previewState.settings = newSettings
        applyPreviewEQSettings(newSettings)
    }
}

struct VirtualChannelDynamicsWindowView: View {
    let channel: VirtualChannel

    @EnvironmentObject private var channelStateManager: ChannelStateManager
    @EnvironmentObject private var themeManager: ThemeManager
    @StateObject private var previewState = DynamicsPreviewState()

    private var globalSettings: InputChannelDynamicsSettings {
        channelStateManager.dynamicsSettings(for: channel.id)
    }

    private var settings: InputChannelDynamicsSettings {
        previewState.settings ?? globalSettings
    }

    private var gainReduction: Double {
        Double(channelStateManager.gainReductionDB(for: channel.id, type: channel.type, channelIndex: channel.index))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                InputProcessingCard(accent: .green) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dynamics")
                                .font(.system(size: 14, weight: .bold))
                            Text("\(channel.name) • \(channel.type.rawValue.uppercased())")
                                .font(.system(size: 7, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Button("Reset") {
                                resetDynamics()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 6, weight: .bold))
                            .foregroundColor(.green)

                            Toggle("Dyn", isOn: dynamicsEnabledBinding)
                                .toggleStyle(.switch)
                                .scaleEffect(0.5)
                        }
                    }

                    HStack(alignment: .top, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        DynamicsTransferGraphView(settings: settings)
                            .overlay(
                                DraggableThresholdNode(
                                    threshold: dynamicsBinding(\.thresholdDB),
                                    range: -60...0,
                                    accent: .green,
                                    onEditingChanged: handleDynamicsEditingChanged
                                )
                            )
                    }
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.green.opacity(0.22), lineWidth: 0.5)
                    )

                    CompactGainReductionMeterView(gainReductionDB: gainReduction)
                    }
                }

                InputProcessingCard(accent: .green) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dynamics Stack")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 8) {
                        DynamicsMiniCard(
                            title: "Thresh / Ratio",
                            accent: .green,
                            value1: dynamicsBinding(\.thresholdDB),
                            value2: dynamicsBinding(\.ratio),
                            range1: -60...0,
                            range2: 1...20,
                            label1: "dB",
                            label2: ":1",
                            format1: "%.1f",
                            format2: "%.1f",
                            onEditingChanged: handleDynamicsEditingChanged,
                            onValue1Changed: { updatePendingDynamicsValue(\.thresholdDB, value: $0) },
                            onValue2Changed: { updatePendingDynamicsValue(\.ratio, value: $0) }
                        )

                        DynamicsMiniCard(
                            title: "Attack / Release",
                            accent: Color(red: 0.0, green: 0.5, blue: 0.5),
                            value1: dynamicsBinding(\.attackMilliseconds),
                            value2: dynamicsBinding(\.releaseMilliseconds),
                            range1: 0.01...500,
                            range2: 1...1500,
                            label1: "ms",
                            label2: "ms",
                            format1: "%.1f",
                            format2: "%.0f",
                            onEditingChanged: handleDynamicsEditingChanged,
                            onValue1Changed: { updatePendingDynamicsValue(\.attackMilliseconds, value: $0) },
                            onValue2Changed: { updatePendingDynamicsValue(\.releaseMilliseconds, value: $0) }
                        )

                        DynamicsMakeupMixLimiterCard(
                            accent: Color(red: 0.62, green: 0.96, blue: 0.78),
                            makeup: dynamicsBinding(\.makeupGainDB),
                            mix: dynamicsBinding(\.mix),
                            ceiling: dynamicsBinding(\.limiterCeilingDB),
                            limiterEnabled: dynamicsBoolBinding(\.limiterEnabled),
                            makeupRange: 0...24,
                            mixRange: 0...1,
                            ceilingRange: -24...0,
                            onEditingChanged: handleDynamicsEditingChanged,
                            onMakeupChanged: { updatePendingDynamicsValue(\.makeupGainDB, value: $0) },
                            onMixChanged: { updatePendingDynamicsValue(\.mix, value: $0) },
                            onCeilingChanged: { updatePendingDynamicsValue(\.limiterCeilingDB, value: $0) }
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
    }

    private var dynamicsEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.enabled },
            set: { enabled in
                commitDynamicsChange { $0.enabled = enabled }
            }
        )
    }

    private func dynamicsBinding(_ keyPath: WritableKeyPath<InputChannelDynamicsSettings, Double>) -> Binding<Double> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                updatePendingDynamicsValue(keyPath, value: value)
            }
        )
    }

    private func dynamicsBoolBinding(_ keyPath: WritableKeyPath<InputChannelDynamicsSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                commitDynamicsChange { settings in
                    settings.enabled = true
                    settings[keyPath: keyPath] = value
                }
            }
        )
    }

    private func handleDynamicsEditingChanged(_ editing: Bool) {
        if !editing {
            commitDynamicsSettings()
        }
    }

    private func updatePendingDynamicsValue(_ keyPath: WritableKeyPath<InputChannelDynamicsSettings, Double>, value: Double) {
        var newSettings = previewState.settings ?? globalSettings
        newSettings.enabled = true
        newSettings[keyPath: keyPath] = value
        previewState.settings = newSettings
        channelStateManager.applyPreviewDynamicsSettings(
            for: channel.id,
            type: channel.type,
            channelIndex: channel.index,
            settings: newSettings
        )
    }

    private func commitDynamicsChange(_ mutate: (inout InputChannelDynamicsSettings) -> Void) {
        var newSettings = previewState.settings ?? globalSettings
        mutate(&newSettings)
        channelStateManager.updateDynamicsSettings(for: channel.id, type: channel.type, channelIndex: channel.index) { settings in
            settings = newSettings
        }
        previewState.settings = nil
    }

    private func commitDynamicsSettings() {
        guard let pending = previewState.settings else { return }
        channelStateManager.updateDynamicsSettings(for: channel.id, type: channel.type, channelIndex: channel.index) { settings in
            settings = pending
        }
        previewState.settings = nil
    }

    private func resetDynamics() {
        commitDynamicsChange { settings in
            settings.thresholdDB = -20.0
            settings.ratio = 4.0
            settings.attackMilliseconds = 10.0
            settings.releaseMilliseconds = 250.0
            settings.makeupGainDB = 0.0
            settings.mix = 1.0
            settings.limiterEnabled = false
            settings.limiterCeilingDB = -0.1
        }
    }
}

private func formatHertz(_ value: Double) -> String {
    if value >= 1000 {
        return String(format: "%.1f kHz", value / 1000.0)
    }
    return String(format: "%.0f Hz", value)
}

private func eqFilterFamilyLabel(_ family: EQFilterFamily) -> String {
    switch family {
    case .butterworth:
        return "Butterworth"
    case .chebyshev:
        return "Chebyshev"
    case .bessel:
        return "Bessel"
    case .linkwitzRiley:
        return "Linkwitz-Riley"
    }
}

private func eqFilterSlopeLabel(_ slope: EQFilterSlope) -> String {
    "\(slope.dbPerOctave) dB/oct"
}

// MARK: - Channel Delay Popover

/// Popover shown when the blue delay button is tapped.
/// The three distance/time fields are linked: editing any one updates the other two.
/// Speed of sound: 343 m/s = 1125.33 ft/s.
struct ChannelDelayPopover: View {
    let deviceID: AudioDeviceID
    let channelIndex: Int
    var role: ChannelRole = .input
    @EnvironmentObject var channelStateManager: ChannelStateManager

    private static let metersPerMs: Double = 0.343     // 343 m/s ÷ 1000
    private static let feetPerMs: Double   = 1.12533   // 1125.33 ft/s ÷ 1000

    @State private var msText: String     = ""
    @State private var metersText: String = ""
    @State private var feetText: String   = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Channel Delay")
                .font(.headline)
                .padding(.bottom, 2)

            delayField(label: "ms", text: $msText, onCommit: applyMs)
            delayField(label: "feet", text: $feetText, onCommit: applyFeet)
            delayField(label: "meters", text: $metersText, onCommit: applyMeters)

            Button("Clear") {
                msText = ""; feetText = ""; metersText = ""
                setDelay(0)
            }
            .font(.subheadline)
        }
        .padding(20)
        .frame(width: 200)
        .onAppear(perform: syncFromState)
    }

    private func delayField(label: String, text: Binding<String>, onCommit: @escaping () -> Void) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .frame(width: 52, alignment: .leading)
            TextField("0.00", text: text, onCommit: onCommit)
                .font(.subheadline.monospacedDigit())
                .textFieldStyle(.roundedBorder)
        }
    }

    private func syncFromState() {
        let ms = currentDelayMs()
        if ms <= 0 { return }
        msText     = String(format: "%.3f", ms)
        metersText = String(format: "%.3f", ms * Self.metersPerMs)
        feetText   = String(format: "%.3f", ms * Self.feetPerMs)
    }

    private func applyMs() {
        guard let ms = Double(msText), ms >= 0 else { return }
        metersText = String(format: "%.3f", ms * Self.metersPerMs)
        feetText   = String(format: "%.3f", ms * Self.feetPerMs)
        setDelay(ms)
    }

    private func applyFeet() {
        guard let feet = Double(feetText), feet >= 0 else { return }
        let ms = feet / Self.feetPerMs
        msText     = String(format: "%.3f", ms)
        metersText = String(format: "%.3f", ms * Self.metersPerMs)
        setDelay(ms)
    }

    private func applyMeters() {
        guard let meters = Double(metersText), meters >= 0 else { return }
        let ms = meters / Self.metersPerMs
        msText   = String(format: "%.3f", ms)
        feetText = String(format: "%.3f", ms * Self.feetPerMs)
        setDelay(ms)
    }

    private func currentDelayMs() -> Double {
        switch role {
        case .input:
            return channelStateManager.delayMs(for: deviceID, channel: channelIndex)
        case .output:
            return channelStateManager.outputDelayMs(for: deviceID, channel: channelIndex)
        }
    }

    private func setDelay(_ ms: Double) {
        switch role {
        case .input:
            channelStateManager.setDelayMs(ms, for: deviceID, channel: channelIndex)
        case .output:
            channelStateManager.setOutputDelayMs(ms, for: deviceID, channel: channelIndex)
        }
    }
}
