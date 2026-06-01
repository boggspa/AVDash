//
//  OutputMixerFXView.swift
//  AVCMeter
//
//  Created by Chris Izatt on 06/07/2025.
//

import Foundation
import MetalKit
import SwiftUI
import Combine
import CoreAudio
#if os(macOS)
import AppKit
#endif


private let sharedStreamManager = MultiOutputStreamManager.shared


/// A Metal-based view for rendering a capsule-shaped audio meter for a single audio channel (FX send).
///
/// - discussion: This view draws a high-performance, animated capsule meter using Metal shaders. It maps peak/RMS audio levels to fill heights,
///   applies theme-based gradients, and is optimized for per-frame updates. It is intended to be used as part of a SwiftUI UI for FX send metering.
class MetalFXSendStripView: MTKView, MTKViewDelegate {
    /// The audio metering context providing peak and RMS buffers for this device.
    var context: VirtualMeteringContext!
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
        guard context != nil else {
            return
        }

        // Use VirtualMeteringContext's API for peak buffer access
        let rawPeak = context.peak(for: channelIndex)
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
            if let metallibURL = Bundle(for: MetalFXSendStripView.self).url(forResource: "default", withExtension: "metallib"),
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

private struct FXSendPeakReadout: View {
    let context: VirtualMeteringContext
    let channelIndex: Int

    @State private var currentPeakDB: Double = -100.0
    private let peakTimer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        let (displayDB, color) = peakColorAndLabel(for: currentPeakDB)

        Text(displayDB)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(color)
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .frame(maxWidth: .infinity)
            .onAppear(perform: refreshPeak)
            .onReceive(peakTimer) { _ in refreshPeak() }
    }

    private func refreshPeak() {
        let peak = context.peak(for: channelIndex)
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
}


/// NSViewRepresentable implementation bridging MetalFXSendStripView (AppKit) into SwiftUI.
///
/// - discussion: Responsible for creating and updating the MetalFXSendStripView instance, passing context, channel, theme, and mask.
private struct FXSendStripRepresentableWrapper: NSViewRepresentable {
    /// The audio metering context for the device.
    var context: VirtualMeteringContext
    /// The channel index this strip represents.
    var channelIndex: Int
    /// The current theme mode for strip rendering.
    var themeMode: ThemeMode
    /// Channel mask for this view.
    var channelMask: [Bool]

    /// Creates the MetalFXSendStripView instance.
    /// - param context: The SwiftUI context.
    /// - returns: A configured MetalFXSendStripView.
    func makeNSView(context: Context) -> MetalFXSendStripView {
        let frame = CGRect(x: 0, y: 0, width: 13, height: 270)
        let metalDevice = MTLCreateSystemDefaultDevice()
        let view = MetalFXSendStripView(frame: frame, device: metalDevice)
        view.channelIndex = channelIndex
        view.context = self.context
        view.themeMode = themeMode
        view.channelMask = self.channelMask
        return view
    }

    /// Updates the MetalFXSendStripView when SwiftUI state changes.
    /// - param nsView: The MetalFXSendStripView to update.
    /// - param context: The SwiftUI context.
    func updateNSView(_ nsView: MetalFXSendStripView, context: Context) {
        nsView.themeMode = themeMode
        nsView.channelIndex = self.channelIndex
        nsView.context = self.context
        nsView.channelMask = channelMask
    }
}

/// SwiftUI wrapper that bridges MetalFXSendStripView to SwiftUI views.
///
/// - discussion: This struct provides the necessary context and channel index, and observes theme changes to keep the Metal view in sync.
struct MetalFXSendStripRepresentable: View {
#if os(macOS)
    @State private var showWaveform: Bool = false
    @State private var showSpectrum: Bool = false
    @State private var showSpectrogram: Bool = false
    @StateObject private var waveformBuffer = AudioSampleBuffer()
    private let floatingWindowController = FloatingWindowController.shared
#endif
    @State private var showDelayPopover = false

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
    /// The audio metering context for the device.
    var context: VirtualMeteringContext
    /// The channel index this strip represents.
    var channelIndex: Int

    @ObservedObject private var channelState = ChannelStateManager.shared
    @ObservedObject private var virtualChannelManager = VirtualChannelManager.shared
    private var channel: VirtualChannel {
        context.channels[channelIndex]
    }
    private var visualisationDeviceID: UInt32 {
        let base: UInt32
        switch channel.type {
        case .fxSend:
            base = 70_000
        case .auxSend:
            base = 71_000
        case .dca:
            base = 72_000
        case .fxReturn:
            base = 73_000
        case .auxReturn:
            base = 74_000
        case .virtualInstrument:
            base = 75_000
        }
        return base + UInt32(max(channel.index, 0))
    }
    private var visualizerSourceDescriptor: MixerVisualizerSource? {
        switch channel.type {
        case .auxSend:
            return .auxSend(busIndex: channel.index)
        case .fxSend:
            return .fxSend(busIndex: channel.index)
        case .auxReturn:
            return .auxReturn(busIndex: channel.index)
        case .fxReturn:
            return .fxReturn(busIndex: channel.index)
        case .dca, .virtualInstrument:
            return nil
        }
    }
    private func makeVisualizerSource() -> MixerVisualizerAudioSource? {
        guard let descriptor = visualizerSourceDescriptor else { return nil }
        return MixerVisualizerAudioSource(
            source: descriptor,
            visualDeviceID: AudioDeviceID(visualisationDeviceID)
        )
    }
    private var channelKey: ChannelKey {
        return ChannelKey(deviceID: 0, channelIndex: channel.index)
    }
    let scale = 1.0

    // Bindings to ChannelStateManager for mute/solo/link/fader
    private var isMuted: Bool {
        channelState.isOutputMuted(deviceID: channelKey.deviceID, channel: channelKey.channelIndex)
    }
    private var isSoloed: Bool {
        channelState.isOutputSoloed(deviceID: channelKey.deviceID, channel: channelKey.channelIndex)
    }
    private var isLinked: Bool {
        channelState.isOutputLinked(deviceID: channelKey.deviceID, channel: channelKey.channelIndex)
    }
    private var faderBinding: Binding<Double> {
        Binding<Double>(
            get: { Double(channelState.outputFader(for: channelKey.deviceID, channel: channelKey.channelIndex)) },
            set: { channelState.setOutputFader(for: channelKey.deviceID, channel: channelKey.channelIndex, value: Float($0)) }
        )
    }

    private var auxSendBinding: Binding<Double> {
        Binding<Double>(
            get: { Double(channelState.auxSendValue(for: channel.id)) },
            set: { channelState.setAuxSend(for: channel.id, value: Float($0)) }
        )
    }

    private var fxSendBinding: Binding<Double> {
        Binding<Double>(
            get: { Double(channelState.fxSendValue(for: channel.id)) },
            set: { channelState.setFXSend(for: channel.id, value: Float($0)) }
        )
    }

    private var selectedAuxSendLabel: String {
        channelState.auxSendLabel(for: channel.id)
    }

    private var selectedFXSendLabel: String {
        channelState.fxSendLabel(for: channel.id)
    }

    private var eqEnabledBinding: Binding<Bool> {
        Binding(
            get: { channelState.eqSettings(for: channel.id).enabled },
            set: { enabled in
                channelState.updateEQSettings(for: channel.id, type: channel.type, channelIndex: channel.index) { $0.enabled = enabled }
            }
        )
    }

    private var dynamicsEnabledBinding: Binding<Bool> {
        Binding(
            get: { channelState.dynamicsSettings(for: channel.id).enabled },
            set: { enabled in
                channelState.updateDynamicsSettings(for: channel.id, type: channel.type, channelIndex: channel.index) { $0.enabled = enabled }
            }
        )
    }

    var body: some View {
        ZStack {
            backgroundStripes
            ZStack(alignment: .bottom) {
                HStack(spacing: 4) {
                    yAxisLabelsColumn
                    meterStripSection
                    faderAndControlsSection
                    Spacer(minLength: 10)
                }
                .frame(width: 80, height: 412)
                .overlay(overlayIconsSection, alignment: .top)
                .overlay(channelNameOverlay)
                .offset(x: -18, y: -34)
                highlightOverlay
            }
        }
        .id("\(context.name)-\(channelIndex)")
    }

    // MARK: - Private View Components

    private var backgroundStripes: some View {
        ZStack {
            Rectangle()
                .fill(themeManager.accentFillColor)
                .opacity(1.0)
                .frame(width: 45, height: 266)
                .offset(x: -38, y: 120)
            Rectangle()
                .fill(themeManager.accentFillColor)
                .opacity(1.0)
                .frame(width: 80, height: 124)
                .offset(x: -17, y: -109)
            Rectangle()
                .fill(themeManager.accentFillColor)
                .opacity(1.0)
                .frame(width: 80, height: 34)
                .offset(x: -17, y: -276)
        }
    }

    private var yAxisLabelsColumn: some View {
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
        .offset(x: 24, y: 36)
    }

    private var meterStripSection: some View {
        // Use mock equivalents for theme and mask
        return ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(.sRGB, red: 0.08, green: 0.08, blue: 0.08, opacity: 1.0))
                .frame(width: 12, height: 260)
                .offset(x: 10, y: 36)
            FXSendStripRepresentableWrapper(
                context: context,
                channelIndex: channelIndex,
                themeMode: themeManager.capsuleThemeMode,
                channelMask: Array(repeating: true, count: context.channels.count)
            )
            .frame(width: 26, height: 280)
            .offset(x: 17, y: 26)
        }
    }

    private var faderAndControlsSection: some View {
        VStack {
#if os(macOS)
            FaderView(
                value: faderBinding,
                minValue: 0.0,
                maxValue: 1.2,
                trackHeight : 260,
                trackWidth: 2,
                thumbHeight: 42,
                thumbWidth: 45,
                capStyle: context.channels[channelIndex].type == .fxSend ? .fxSend : .auxSend,
                deviceID: context.deviceID,
                channelIndex: channelIndex,
                role: .output
            )
            .frame(width: 28, height: 270)
            .offset(y: 66)
#else
            Slider(value: .constant(0.8), in: 0...1)
                .rotationEffect(.degrees(-90))
                .frame(height: 280)
                .padding(.leading, 6)
#endif
            // Mute/Solo/Link buttons
            linkButton
                .offset(x: -48, y: 62)
            muteButton
                .offset(x: -23, y: 43)
            soloButton
                .offset(x: -2, y: 24)
        }
        .frame(width: 36)
    }

    private var linkButton: some View {
        VStack {
            Button(action: {
                channelState.toggleOutputLink(deviceID: channelKey.deviceID, channel: channelKey.channelIndex)
            }) {
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .bold))
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
    }

    private var muteButton: some View {
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
                    channelState.toggleOutputMute(deviceID: channelKey.deviceID, channel: channelKey.channelIndex)
                }
        }
    }

    private var soloButton: some View {
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
                    channelState.toggleOutputSolo(deviceID: channelKey.deviceID, channel: channelKey.channelIndex)
                }
        }
    }

    private var overlayIconsSection: some View {
        VStack {
            // The entire overlay icons, dials, and controls section
            overlayIconsMain
        }
        .padding(.top, 10)
        .offset(x: -30, y: 0)
    }

private var overlayIconsMain: some View {
    let channelType = context.channels[channelIndex].type
    var overlaySections: [(view: AnyView, offsetX: CGFloat, offsetY: CGFloat)] = [
        (AnyView(overlayIconButtons), 30, -10),
        (AnyView(overlayRoutingPhaseDelayRow), 30, 0),
        (AnyView(overlayDivider), 30, 10),
        (AnyView(overlayInsertSection), 30, 14),
        (AnyView(overlayDivider), 30, 18)
    ]

    if channelType == .auxSend {
        overlaySections.append((AnyView(overlayDCA), 30, 24))
    }

    if channelType == .fxSend {
        overlaySections.append((AnyView(overlayAuxSection), 0, 34))
    }

    if channelType == .auxSend {
        overlaySections.append((AnyView(overlayDivider), 30, 28))
    }

    if channelType == .fxSend {
        overlaySections.append((AnyView(overlayDivider), 30, 34))
    }

    if channelType == .auxSend {
        overlaySections.append((view: AnyView(overlayDivider), offsetX: 30, offsetY: 106))
    }

    if channelType == .fxSend {
        overlaySections.append((view: AnyView(overlayDivider), offsetX: 30, offsetY: 84))
    }

    if channelType == .auxSend {
        overlaySections.append((view: AnyView(overlayPanPeakSection), offsetX: 0, offsetY: 106))
    }

    if channelType == .fxSend {
        overlaySections.append((view: AnyView(overlayPanPeakSection), offsetX: 0, offsetY: 84))
    }

    return VStack(spacing: 0) {
        ForEach(0..<overlaySections.count, id: \.self) { index in
            overlaySections[index].view
                .offset(x: overlaySections[index].offsetX, y: overlaySections[index].offsetY)
        }
    }
    .zIndex(1)
    .id("cosmetic-dials")
    .accessibility(hidden: true)
    .frame(maxWidth: .infinity)
    .fixedSize(horizontal: false, vertical: true)
    .layoutPriority(1)
    .transition(.identity)
    .animation(nil, value: 0)
    .background(Color.clear)
}

    private var overlayIconButtons: some View {
        HStack(spacing: 1) {
            #if os(macOS)
            waveformButton
                .offset(x: -2, y: -228)
            spectrumButton
                .offset(y: -228)
            spectrogramButton
                .offset(x: 2, y: -228)
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .floatingSpectrumWindowDidClose)) { notification in
            #if os(macOS)
            if notification.matchesFloatingWindow(deviceID: visualisationDeviceID, channelIndex: channelIndex, suffix: "spectrum") {
                showSpectrum = false
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .floatingWaveformWindowDidClose)) { notification in
            #if os(macOS)
            if notification.matchesFloatingWindow(deviceID: visualisationDeviceID, channelIndex: channelIndex, suffix: "waveform") {
                showWaveform = false
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .floatingSpectrogramWindowDidClose)) { notification in
            #if os(macOS)
            if notification.matchesFloatingWindow(deviceID: visualisationDeviceID, channelIndex: channelIndex, suffix: "spectrogram") {
                showSpectrogram = false
            }
            #endif
        }
    }

    #if os(macOS)
    private var waveformButton: some View {
        Button(action: {
            showWaveform.toggle()
            let controller = floatingWindowController
            if showWaveform {
                guard let source = makeVisualizerSource() else {
                    showWaveform = false
                    return
                }
                controller.showWaveformWindow(deviceID: visualisationDeviceID, channelIndex: channelIndex) {
                    WaveformView(
                        buffer: waveformBuffer,
                        deviceID: visualisationDeviceID,
                        channelIndex: channelIndex,
                        themeMode: WaveformThemeMode(rawValue: themeManager.deviceCapsuleThemes[AudioDeviceID(visualisationDeviceID)]?.rawValue ?? themeManager.capsuleThemeMode.rawValue) ?? .light,
                        deviceName: context.name,
                        mixerAudioSource: source,
                        scale: scale
                    )
                    .environmentObject(themeManager)
                    .frame(width: 750, height: 180)
                        .background(Color.clear)
                }
            } else {
                controller.closeWaveformWindow(for: visualisationDeviceID, channelIndex: channelIndex)
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
    }

    private var spectrumButton: some View {
        Button(action: {
            showSpectrum.toggle()
            let deviceID = visualisationDeviceID
            let scale = themeManager.deviceSpectrumScaleFactors[AudioDeviceID(visualisationDeviceID)] ?? 1.0
            let channelCount = UInt32(context.channels.count)

            let controller = floatingWindowController
            if showSpectrum {
                let fftSize = VisualisationSettings.shared.spectrumFFTSize
                guard let source = makeVisualizerSource() else {
                    showSpectrum = false
                    return
                }
                let processor = SafeFFTSpectrumProcessor(
                    streamManager: source,
                    channelIndex: channelIndex,
                    channelCount: Int(channelCount),
                    fftSize: fftSize
                )
                processor.start()
                let pickedTheme = themeManager.deviceCapsuleThemes[AudioDeviceID(visualisationDeviceID)] ?? themeManager.capsuleThemeMode
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
    }

    private var spectrogramButton: some View {
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
        .padding(.leading, 1)
        .padding(.trailing, 1)
        .padding(.top, 1)
        .onChange(of: showSpectrogram) { newValue in
            DispatchQueue.main.async {
                if newValue {
                    let pickedTheme = themeManager.deviceCapsuleThemes[AudioDeviceID(visualisationDeviceID)] ?? themeManager.capsuleThemeMode
                    let simdTheme = simdColor(from: spectrumLineColor(for: SpectrumThemeMode(from: pickedTheme)))
                    let deviceID = visualisationDeviceID
                    let channelCount = UInt32(context.channels.count)
                    guard SpectroManager.shared.acquireExternalSpectrogramSession(
                        deviceID: deviceID,
                        channelCount: channelCount,
                        channel: Int32(channelIndex)
                    ) else {
                        showSpectrogram = false
                        return
                    }
                    guard let source = makeVisualizerSource() else {
                        showSpectrogram = false
                        return
                    }
                    let scale = themeManager.deviceSpectrumScaleFactors[AudioDeviceID(visualisationDeviceID)] ?? 1.0
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
                            deviceName: context.name,
                            scale: scale,
                            externalAudioSource: source
                        )
                            .environmentObject(themeManager)
                            .frame(width: 750 * scale, height: 380 * scale)
                            .background(Color.clear)
                    }
                } else {
                    floatingWindowController.closeSpectrogramWindow(for: visualisationDeviceID, channelIndex: channelIndex)
                }
            }
        }
    }
    #endif

    private var overlayRoutingPhaseDelayRow: some View {
        HStack(spacing: 1) {
            // Routing is intentionally unavailable on send/output strips.
            Button(action: {}) {
                Image(systemName: "arrow.triangle.branch")
                    .resizable()
                    .frame(width: 10, height: 10)
                    .foregroundColor(.primary)
                    .padding(6)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(true)
            .background(
                ZStack {
                    Color.gray.opacity(0.45)
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
                }
            )
            .cornerRadius(6)
            .offset(x: -2, y: -235)
            // Phase flip toggle.
            Button(action: {
                channelState.toggleOutputPolarity(deviceID: channelKey.deviceID, channel: channelKey.channelIndex)
            }) {
                Image(systemName: "arrow.2.squarepath")
                    .resizable()
                    .frame(width: 10, height: 10)
                    .foregroundColor(channelState.isOutputPolarityFlipped(deviceID: channelKey.deviceID, channel: channelKey.channelIndex) ? .white : .primary)
                    .padding(6)
            }
            .buttonStyle(PlainButtonStyle())
            .background(
                ZStack {
                    channelState.isOutputPolarityFlipped(deviceID: channelKey.deviceID, channel: channelKey.channelIndex)
                        ? Color(.sRGB, red: 1.0, green: 0.55, blue: 0.05, opacity: 0.9)
                        : Color(.sRGB, red: 0.8, green: 0.4, blue: 0.3, opacity: 0.6)
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
                }
            )
            .cornerRadius(6)
            .offset(y: -235)
            // Delay control.
            Button(action: { showDelayPopover.toggle() }) {
                Image(systemName: "timer")
                    .resizable()
                    .frame(width: 10, height: 10)
                    .foregroundColor(channelState.outputDelayMs(for: channelKey.deviceID, channel: channelKey.channelIndex) > 0 ? .white : .primary)
                    .padding(6)
            }
            .buttonStyle(PlainButtonStyle())
            .background(
                ZStack {
                    channelState.outputDelayMs(for: channelKey.deviceID, channel: channelKey.channelIndex) > 0
                        ? Color(.sRGB, red: 0.1, green: 0.3, blue: 1.0, opacity: 0.9)
                        : Color(.sRGB, red: 0.2, green: 0.4, blue: 0.9, opacity: 0.6)
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
                }
            )
            .cornerRadius(6)
            .popover(isPresented: $showDelayPopover) {
                ChannelDelayPopover(deviceID: channelKey.deviceID, channelIndex: channelKey.channelIndex, role: .output)
                    .environmentObject(channelState)
            }
            .padding(.leading, 1)
            .padding(.trailing, 1)
            .padding(.top, 1)
            .offset(x: 2, y: -235)
        }
    }

    private var overlayDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.4))
            .frame(width: 80, height: 1)
            .offset(x: 0, y: -235)
    }

    private var overlayPostGainRow: some View {
        return HStack(spacing: 13) {
            PostGainDialView(themeMode: themeManager.capsuleThemeMode, value: .constant(0.0))
                .frame(width: 14, height: 14)
                .offset(x: 1, y: -2)
                .help("Post Gain Dial\n270° range\n0 = min, 127 = max")
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.4))
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                Text("+0.0 dB")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
            }
            .frame(width: 42, height: 18)
        }
        .offset(x: -2, y: -235)
    }

    private var overlayInsertSection: some View {
        VStack(spacing: 6) {
            insertTile(title: "EQ", accent: Color(red: 0.0, green: 0.75, blue: 0.8), isEnabled: eqEnabledBinding) {
                FloatingWindowController.shared.showVirtualEQWindow(channelID: channel.id) {
                    VirtualChannelEQWindowView(channel: channel)
                        .environmentObject(channelState)
                        .environmentObject(themeManager)
                }
            }
            insertTile(title: "Dynamics", accent: .green, isEnabled: dynamicsEnabledBinding) {
                FloatingWindowController.shared.showVirtualDynamicsWindow(channelID: channel.id) {
                    VirtualChannelDynamicsWindowView(channel: channel)
                        .environmentObject(channelState)
                        .environmentObject(themeManager)
                }
            }
            ForEach(2..<5) { index in
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black.opacity(0.4))
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.white.opacity(0.4), lineWidth: 1)
                    Text("Insert \(index + 1)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                }
                .frame(width: 72, height: 20)
            }
        }
        .offset(x: 0, y: -235)
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

    private var overlayDCA: some View {
        VStack {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.4))
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                Text("DCA")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
            }
                .frame(width: 72, height: 20)
        }
        .offset(x: 0, y: -235)
    }


    private var overlayAuxSection: some View {
        VStack(spacing: 4) {
            HStack(spacing: 13) {
                AuxSendDialView(themeMode: themeManager.capsuleThemeMode, value: auxSendBinding)
                    .frame(width: 14, height: 14)
                    .offset(x: 1, y: -2)
                    .help("Aux Send Dial\n270° range\n0 = dry, 127 = max send")
                sendDestinationTile(label: selectedAuxSendLabel)
            }
            .offset(x: 28, y: -245)
            auxSendDestinationMenu
            .frame(width: 72, height: 20)
            .offset(x: 30, y: -240)
        }
    }

    private var overlayFXSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                FXSendDialView(themeMode: themeManager.capsuleThemeMode, value: fxSendBinding)
                    .frame(width: 14, height: 14)
                    .offset(x: 1, y: -2)
                    .help("FX Send Dial\n270° range\n0 = dry, 127 = max send")
                sendDestinationTile(label: selectedFXSendLabel)
            }
            .offset(x: 30, y: -237)
            fxSendDestinationMenu
            .frame(width: 72, height: 20)
            .offset(x: 28, y: -232)
        }
    }

    private func sendDestinationTile(label: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(0.4))
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.white.opacity(0.4), lineWidth: 1)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)
        }
        .frame(width: 42, height: 18)
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
                ForEach(Array(virtualChannelManager.auxSendChannels.enumerated()), id: \.offset) { index, virtualChannel in
                    Button {
                        channelState.setSelectedAuxSendIndex(for: channel.id, value: index)
                    } label: {
                        Text(
                            index == channelState.selectedAuxSendIndex(for: channel.id)
                            ? "✓ \(virtualChannel.name)"
                            : virtualChannel.name
                        )
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
                ForEach(Array(virtualChannelManager.fxSendChannels.enumerated()), id: \.offset) { index, virtualChannel in
                    Button {
                        channelState.setSelectedFXSendIndex(for: channel.id, value: index)
                    } label: {
                        Text(
                            index == channelState.selectedFXSendIndex(for: channel.id)
                            ? "✓ \(virtualChannel.name)"
                            : virtualChannel.name
                        )
                    }
                }
            }
        } label: {
            sendMenuTile(label: "FX Sends")
        }
        .menuStyle(BorderlessButtonMenuStyle())
    }

    private var overlayPanPeakSection: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.6))
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
                FXSendPeakReadout(context: context, channelIndex: channelIndex)
            }
            .frame(width: 35, height: 20)
            .offset(x: 2)
            // Use shared ChannelStateManager's pan binding and bubble state for this channel.
            PanDialView(
                value: Binding(
                    get: { Double(channelState.outputPan(for: channelKey.deviceID, channel: channelKey.channelIndex)) },
                    set: { newValue in
                        channelState.setOutputPan(for: channelKey.deviceID, channel: channelKey.channelIndex, value: Float(newValue))
                    }
                ),
                themeMode: themeManager.capsuleThemeMode,
                deviceID: channelKey.deviceID,
                channelIndex: channelKey.channelIndex
            )
            .frame(width: 32, height: 32)
            .offset(x: -2)
            .help("Pan Dial\n270° range\n0 = hard left, 127 = hard right\n63 = center")
            // Bubble overlays and gesture handling use shared ChannelStateManager bubbleStates and showBubble mechanism.
        }
        .offset(x: 32, y: 4)
        .offset(y: -235)
    }

    private var channelNameOverlay: some View {
        let channel = context.channels[channelIndex]
        let prefix: String = {
            switch channel.type {
            case .fxSend:
                return "FX Send"
            case .auxSend:
                return "Aux Send"
            case .dca:
                return "DCA"
            default:
                return "Output"
            }
        }()

        return ZStack {
            Rectangle()
                .fill(themeManager.accentFillColor)
                .frame(width: 80, height: 22)
            Rectangle()
                .stroke(colorForChannelStrip(.standard), lineWidth: 2)
                .frame(width: 80, height: 22)
            Text("\(prefix) \(channel.index + 1)")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.primary)
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
                .offset(y: -1)
        }
        .offset(y: 204)
    }

    private var highlightOverlay: some View {
        Rectangle()
            .stroke(Color.white.opacity(0.2), lineWidth: 2)
            .offset(x: -18, y: -24)
            .onChange(of: themeManager.deviceThemeVersion) { _ in
                // Force view to update by refreshing the bound channel state.
                channelState.setOutputFader(for: channelKey.deviceID, channel: channelKey.channelIndex, value: channelState.outputFader(for: channelKey.deviceID, channel: channelKey.channelIndex))
            }
    }

    // Volume control not supported for VirtualMeteringContext; methods removed.
}
