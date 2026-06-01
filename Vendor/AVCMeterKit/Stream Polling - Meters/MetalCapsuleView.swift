//
//  MetalCapsuleView.swift
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
#if os(macOS)
import AppKit
#endif


private let sharedStreamManager = MultiDeviceStreamManager.shared


/// A Metal-based view for rendering a capsule-shaped audio meter for a single audio channel.
///
/// - discussion: This view draws a high-performance, animated capsule meter using Metal shaders. It maps peak/RMS audio levels to fill heights,
///   applies theme-based gradients, and is optimized for per-frame updates. It is intended to be used as part of a SwiftUI UI for channel metering.
class MetalCapsuleView: MTKView, MTKViewDelegate {
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
    private var didReportPipelineFailure = false

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
        self.colorPixelFormat = .bgra8Unorm
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
    private func updateLevels() {
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
        let db = 20 * log10(rawPeakSafe) + 6.0
        guard db.isFinite else {
            fillLevel = 0
            return
        }
        let clampedDb = max(-100.0, min(0.0, db))
        // Use a curved mapping to give more visual headroom near 0 dB.
        let normalized = max(0.0, (clampedDb + 80.0) / 80.0)
        let newFillLevel = pow(normalized, 1.5) // curve favors headroom at the top

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
            case .mint:
                startColor = SIMD4<Float>(0.4, 1.0, 0.7, 1.0)
                endColor = SIMD4<Float>(0.1, 0.7, 0.4, 0.5)
            case .lavender:
                startColor = SIMD4<Float>(0.8, 0.7, 1.0, 1.0)
                endColor = SIMD4<Float>(0.5, 0.4, 0.7, 0.5)
            case .indigo:
                startColor = SIMD4<Float>(0.4, 0.3, 0.9, 1.0)
                endColor = SIMD4<Float>(0.15, 0.15, 0.4, 0.5)
            case .midnight:
                startColor = SIMD4<Float>(0.0, 0.4, 0.8, 1.0)
                endColor = SIMD4<Float>(0.0, 0.1, 0.2, 0.5)
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
        updateLevels()

        // Skip drawing if fillLevel is not finite.
        guard fillLevel.isFinite else {
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
            // Use bar width in points, scaled to pixels for consistent appearance across all resolutions.
            #if os(macOS)
            let scale = Float(self.window?.backingScaleFactor ?? 1.0)
            #else
            let scale = Float(self.contentScaleFactor)
            #endif
            let barWidthPoints: Float = 9.6 // Capsule width in points
            let barWidth = barWidthPoints * scale // Convert to pixels for Metal
            let startX: Float = (Float(drawableSize.width) - barWidth) / 1.0
            let screenWidth = Float(drawableSize.width)

            let x = startX
            // Convert pixel coordinates to normalized device coordinates (NDC) [-1, 1].
            let ndcX = (x / screenWidth) * 2.0 - 1.0
            let ndcRight = ((x + barWidth) / screenWidth) * 2.0 - 1.0
            let ndcBottom: Float = -1.0
            // Render a full-height meter track; fragment shader clips by fill level.
            let ndcTop: Float = 0.8

            // Define quad vertices with positions and texture coordinates for the capsule.
            let quadVertices: [Float] = [
                ndcX, Float(ndcBottom), 0, 1,
                Float(ndcRight), Float(ndcBottom), 1, 1,
                ndcX, ndcTop, 0, 0,
                Float(ndcRight), Float(ndcTop), 1, 0
            ]

            // Set vertex bytes directly from quadVertices.
            quadVertices.withUnsafeBufferPointer { buffer in
                encoder.setVertexBytes(buffer.baseAddress!, length: buffer.count * MemoryLayout<Float>.size, index: 0)
            }

            // Pass fillLevel to fragment shader to control capsule fill height.
            var fill = min(max(fillLevel, 0.0), 0.9)
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
            let frameworkBundle = Bundle(for: MetalCapsuleView.self)
            var candidates: [URL] = []

            if let frameworkURL = frameworkBundle.url(forResource: "default", withExtension: "metallib") {
                candidates.append(frameworkURL)
            }

            if let privateFrameworksURL = Bundle.main.privateFrameworksURL {
                let fallbackURL = privateFrameworksURL
                    .appendingPathComponent("AVCMeterKit.framework")
                    .appendingPathComponent("Resources")
                    .appendingPathComponent("default.metallib")
                candidates.append(fallbackURL)
            }
            if let mainBundleURL = Bundle.main.url(forResource: "default", withExtension: "metallib") {
                candidates.append(mainBundleURL)
            }

            for url in candidates {
                do {
                    return try device.makeLibrary(URL: url)
                } catch {
                    if !didReportPipelineFailure {
                        print("Capsule Metal library load failed at \(url.path): \(error)")
                    }
                }
            }

            do {
                return try device.makeDefaultLibrary(bundle: frameworkBundle)
            } catch {
                if !didReportPipelineFailure {
                    print("Capsule Metal default library from framework bundle failed: \(error)")
                }
            }

            do {
                return try device.makeDefaultLibrary(bundle: .main)
            } catch {
                if !didReportPipelineFailure {
                    print("Capsule Metal default library from main bundle failed: \(error)")
                }
            }

            if let library = device.makeDefaultLibrary() {
                return library
            }

            return nil
        }()
        guard let library = library else {
            if !didReportPipelineFailure {
                print("Capsule pipeline setup failed: no Metal library found.")
                didReportPipelineFailure = true
            }
            return
        }

        guard let vertexFunction = library.makeFunction(name: "vertex_main") else {
            if !didReportPipelineFailure {
                print("Capsule pipeline setup failed: missing vertex_main function.")
                didReportPipelineFailure = true
            }
            return
        }
        guard let fragmentFunction = library.makeFunction(name: "fragment_main") else {
            if !didReportPipelineFailure {
                print("Capsule pipeline setup failed: missing fragment_main function.")
                didReportPipelineFailure = true
            }
            return
        }

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
            if !didReportPipelineFailure {
                print("Failed to create capsule pipeline state: \(error)")
                didReportPipelineFailure = true
            }
        }
    }
}

/// SwiftUI wrapper that bridges MetalCapsuleView to SwiftUI views.
///
/// - discussion: This struct provides the necessary context and channel index, and observes theme changes to keep the Metal view in sync.
struct MetalCapsuleRepresentable: View {
    /// The theme manager from the environment, used for dynamic theming.
    @EnvironmentObject var themeManager: ThemeManager
    /// The audio metering context for the device.
    var context: DeviceMeteringContext
    /// The channel index this capsule represents.
    var channelIndex: Int

    var body: some View {
        let streamManager = MultiDeviceStreamManager.shared
        ViewRepresentableWrapper(
            context: context,
            channelIndex: channelIndex,
            themeMode: themeManager.deviceCapsuleThemes[context.device.deviceID] ?? themeManager.capsuleThemeMode,
            channelMask: streamManager.channelMaskCache[context.device.deviceID] ?? []
        )
    }
}

/// NSViewRepresentable implementation bridging MetalCapsuleView (AppKit) into SwiftUI.
///
/// - discussion: Responsible for creating and updating the MetalCapsuleView instance, passing context, channel, theme, and mask.
private struct ViewRepresentableWrapper: NSViewRepresentable {
    /// The audio metering context for the device.
    var context: DeviceMeteringContext
    /// The channel index this capsule represents.
    var channelIndex: Int
    /// The current theme mode for capsule rendering.
    var themeMode: ThemeMode
    /// Channel mask for this view.
    var channelMask: [Bool]

    /// Creates the MetalCapsuleView instance.
    /// - param context: The SwiftUI context.
    /// - returns: A configured MetalCapsuleView.
    func makeNSView(context: Context) -> MetalCapsuleView {
        let frame = CGRect(x: 0, y: 0, width: 12.8, height: 270 / 18)
        let metalDevice = MTLCreateSystemDefaultDevice()
        let view = MetalCapsuleView(frame: frame, device: metalDevice)
        view.channelIndex = channelIndex
        view.context = self.context
        view.themeMode = themeMode
        view.channelMask = self.channelMask
        return view
    }

    /// Updates the MetalCapsuleView when SwiftUI state changes.
    /// - param nsView: The MetalCapsuleView to update.
    /// - param context: The SwiftUI context.
    func updateNSView(_ nsView: MetalCapsuleView, context: Context) {
        // Update theme mode when SwiftUI environment changes.
        nsView.themeMode = themeMode
        // The following line is removed to avoid forcing a reset on every update:
        // nsView.channelMask = MultiDeviceStreamManager.shared.channelMaskCache[self.context.device.deviceID] ?? []
    }
}


/// SwiftUI view combining the Metal capsule meter with textual RMS and peak value displays.
///
/// - discussion: Includes live updating via a timer and user interaction to reset held peak value.
struct MetalCapsuleWithText: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var manager: AudioDeviceManager
    var context: DeviceMeteringContext
    var channelIndex: Int
    var showsFeatureIcons: Bool = true
    var showsLevelTexts: Bool = true
    var channelHeaderYOffset: CGFloat = 42
    var channelHeaderYOffsetCPU: CGFloat = 42
    var capsuleYOffset: CGFloat = 0

    /// Current RMS value in dB, updated live.
    @State private var currentRMS: Float = -100.0
    /// Current peak value in dB, updated live.
    @State private var currentPeak: Float = -100.0
    /// Held peak value in dB, which persists until reset by user tap.
    @State private var heldPeakValue: Float = -100.0
    /// Color used to display the held peak value text.
    @State private var heldPeakColor: Color = .secondary
    /// Instantaneous peak value in dB for quick updates.
    @State private var instantPeak: Float = -100.0
    /// Formatted string for RMS dB display.
    @State private var formattedRMSDbText: String = "−∞"
    /// Formatted string for peak dB display.
    @State private var formattedPeakDbText: String = "−∞"
    /// Track last time heldPeakValue was updated in the clip range.
    @State private var lastHeldPeakUpdate: Date = .distantPast
    /// Throttle text updates: track last update time and minimum interval.
    @State private var lastTextUpdate: Date = .distantPast
    /// Minimum interval between text updates (seconds).
    let updateInterval: TimeInterval = 0.6

#if os(macOS)
    @StateObject private var waveformBuffer = AudioSampleBuffer()
    @State private var showSpectrogram = false
    @State private var showSpectrum: Bool = false
    @State private var showWaveform = false
    private let floatingWindowController = FloatingWindowController.shared
#endif



    /// SwiftUI body rendering a single metering capsule stack (per device -> per channel).
    ///
    /// @discussion
    /// This view includes:
    /// - A channel number label.
    /// - A Metal-rendered capsule showing current peak and RMS levels.
    /// - Peak and RMS decibel text overlays.
    /// - Interactive tap gestures for resetting held peak values.
    /// - Icons for toggling spectrum, spectrogram, and waveform floating windows.
    ///
    /// The capsule and text visuals are dynamically themed and updated in real-time using Metal.
    ///
    /// @returns A fully stacked metering capsule UI, conditionally shown based on active channel masks.
    var body: some View {
        let channelMask = manager.selectedChannelMasks[context.device.deviceID] ?? []
        let isChannelEnabled = (channelIndex < channelMask.count) ? channelMask[channelIndex] : false
        let isCPUBackend = RenderBackendResolver.resolveMeterBackend() == .cpu
        if isChannelEnabled {
            VStack(spacing: 4) {
                /// ▸ Channel label: Shows the channel number above the meter.
                /// - Font: Monospaced, small, semibold
                /// - Behavior: Triggers metering updates on appear.
                Text("\(channelIndex + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .offset(y: isCPUBackend ? channelHeaderYOffsetCPU : channelHeaderYOffset) /// ADJUST HERE IF CHANNEL INDEX SHIFTS
                    .onAppear {
                        // User action: Start metering refresh for visible channels.
                        MeterUpdateCoordinator.shared.start()
                    }

                /// ▸ Capsule meter view (Metal or CPU compatibility backend).
                /// - Uses resolver output so only renderer changes, not surrounding UI.
                let themeMode = themeManager.deviceCapsuleThemes[context.device.deviceID] ?? themeManager.capsuleThemeMode
                Group {
                    if RenderBackendResolver.resolveMeterBackend() == .cpu {
                        CPUCapsuleBarView(context: context, channelIndex: channelIndex, themeMode: themeMode)
                    } else {
                        MetalCapsuleRepresentable(context: context, channelIndex: channelIndex)
                    }
                }
                .frame(width: 12.8, height: 280)
                .background(Color.clear)
                .offset(y: 14 + capsuleYOffset)
                VStack(spacing: 2) {
                    if showsLevelTexts {
                        /// ▸ Peak value label.
                        /// - Updated on metering refresh notifications.
                        /// - Tap gesture clears held peak to −∞.
                        Text(formattedPeakDbText)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(peakColor(for: heldPeakValue))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: true, vertical: false)
                            .onTapGesture {
                                // User action: Reset held peak value to −∞ on tap.
                                heldPeakValue = -100.0
                                formattedPeakDbText = "−∞"
                            }

                        /// ▸ RMS value label.
                        /// - Updated in sync with peak display refresh.
                        Text(formattedRMSDbText)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(rmsColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .onAppear {
                    refreshLevelTexts(force: true)
                }
                .onReceive(MeterUpdateCoordinator.shared.publisher) { _ in
                    refreshLevelTexts()
                }
                if showsFeatureIcons {
                    /// ▸ Icon: Spectrum analyzer
                    /// - Toggles floating spectrum window (macOS) or popover (iOS).
                    /// - Uses theme-derived color for consistency.
                    #if os(macOS)
                    Image(systemName: "waveform")
                        .font(.system(size: 10, weight: .medium, design: .default))
                        .foregroundColor(
                            showSpectrum
                            ? .white
                            : waveformIconColor(
                                for: themeManager.deviceCapsuleThemes[context.device.deviceID] ?? themeManager.capsuleThemeMode
                            )
                        )
                        .onTapGesture {
                            // User action: Toggle spectrum window.
                            showSpectrum.toggle()
                        }
                        .onChange(of: showSpectrum) { newValue in
                                // User action: Show/close floating spectrum window.
                                if newValue {
                                    DispatchQueue.main.async {
                                        // Filter out virtual instrument device ID (999_999) which has its own pipeline
                                        guard context.device.deviceID != 999_999 else {
                                            showSpectrum = false
                                            return
                                        }

                                        let pickedTheme = themeManager.deviceCapsuleThemes[context.device.deviceID] ?? themeManager.capsuleThemeMode
                                        let simdTheme = simdColor(from: spectrumLineColor(for: SpectrumThemeMode(from: pickedTheme)))
                                        let deviceID = context.device.deviceID

                                        // Special handling for System Audio (888_888) - use SystemAudioSource
                                        if deviceID == 888_888 {
                                            let fftSize = VisualisationSettings.shared.spectrumFFTSize
                                            let processor = SafeFFTSpectrumProcessor(
                                                streamManager: SystemAudioSource.shared,
                                                channelIndex: channelIndex,
                                                channelCount: Int(context.device.inputChannels),
                                                fftSize: fftSize
                                            )
                                            processor.start()
                                            let baseWidth: CGFloat = 750
                                            let baseHeight: CGFloat = 380
                                            let scale = themeManager.deviceSpectrumScaleFactors[deviceID] ?? 1.0
                                            let scaledWidth = baseWidth * scale
                                            let scaledHeight = baseHeight * scale
                                            floatingWindowController.showSpectrumWindow(
                                                deviceID: deviceID,
                                                channelIndex: channelIndex,
                                                scale: scale,
                                                title: "\(SystemAudioSource.shared.name) Spectrum"
                                            ) {
                                                SpectrumContainer(
                                                    processor: processor,
                                                    themeMode: pickedTheme,
                                                    scale: scale
                                                )
                                                .environmentObject(themeManager)
                                                .frame(width: scaledWidth, height: scaledHeight)
                                                .background(Color.clear)
                                            }
                                            return
                                        }

                                        let fftSize = VisualisationSettings.shared.spectrumFFTSize
                                        guard let streamManager = FFTStreamManager(
                                            deviceID: deviceID,
                                            channelCount: UInt32(context.device.inputChannels),
                                            sampleRate: UInt32(48000),
                                            bufferSize: UInt32(fftSize)
                                        ) else {
                                            return
                                        }

                                        let isUtilityInstrument = (context.device.deviceID >= 1_000_000 && context.device.deviceID <= 1_000_004)
                                        if !isUtilityInstrument {
                                            try? streamManager.start()
                                        }

                                        let audioSource: FFTAudioSource
                                        if isUtilityInstrument {
                                            audioSource = PostEQStreamReader(deviceID: context.device.deviceID, channelIndex: channelIndex, channelType: 0)!
                                        } else {
                                            audioSource = streamManager
                                        }

                                        let processor = SafeFFTSpectrumProcessor(
                                            streamManager: audioSource,
                                            channelIndex: channelIndex,
                                            channelCount: Int(context.device.inputChannels),
                                            fftSize: fftSize
                                        )
                                        processor.start()
                                        let baseWidth: CGFloat = 750
                                        let baseHeight: CGFloat = 380
                                        let scale = themeManager.deviceSpectrumScaleFactors[deviceID] ?? 1.0
                                        let scaledWidth = baseWidth * scale
                                        let scaledHeight = baseHeight * scale
                                        floatingWindowController.showSpectrumWindow(
                                            deviceID: context.device.deviceID,
                                            channelIndex: channelIndex,
                                            scale: scale,
                                            title: "\(audioSource.name) Spectrum"
                                        ) {
                                            SpectrumContainer(
                                                processor: processor,
                                                themeMode: pickedTheme,
                                                scale: scale
                                            )
                                            .environmentObject(themeManager)
                                            .frame(width: scaledWidth, height: scaledHeight)
                                            .background(Color.clear)
                                        }
                                    }
                                } else {
                                    DispatchQueue.main.async {
                                        floatingWindowController.closeSpectrumWindow(for: context.device.deviceID, channelIndex: channelIndex)
                                    }
                                }
                            }
    #else
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .medium, design: .default))
                            .padding(.top, 4)
                            .foregroundColor(
                                showSpectrum
                                ? .white
                                : waveformIconColor(
                                    for: themeManager.deviceCapsuleThemes[context.device.deviceID] ?? themeManager.capsuleThemeMode
                                )
                            )
                            .onTapGesture {
                                // User action: Toggle spectrum popover.
                                showSpectrum.toggle()
                            }
                            .popover(isPresented: $showSpectrum) {
                                let wrapper = ChannelFFTSpectrumWrapper(channelIndex: channelIndex, fftSize: 1024, device: context.device, totalChannels: Int(context.device.inputChannels))
                                wrapper.start()
                                SpectrumContainer(wrapper: wrapper)
                                    .environmentObject(themeManager)
                                    .frame(width: 750, height: 380)
                                    .background(Color.clear)
                                    .offset(y: 6)
                            }
    #endif

                        /// ▸ Icon: Spectrogram
                        /// - Toggles floating spectrogram window (macOS).
                        /// - Uses theme-derived color for consistency.
                        Image(systemName: "chart.bar.doc.horizontal")
                            .padding(.top, 6)
                            .font(.system(size: 10, weight: .medium, design: .default))
                            .foregroundColor(
                                showSpectrogram
                                ? .white
                                : waveformIconColor(
                                    for: themeManager.deviceCapsuleThemes[context.device.deviceID] ?? themeManager.capsuleThemeMode
                                )
                            )
                            .onTapGesture {
                                // User action: Toggle spectrogram window.
                                showSpectrogram.toggle()
                            }
                            .onChange(of: showSpectrogram) { newValue in
                                // User action: Show/close floating spectrogram window.
                                DispatchQueue.main.async {
                                    if newValue {
                                        // Filter out virtual instrument device ID (999_999) which has its own pipeline
                                        guard context.device.deviceID != 999_999 else {
                                            showSpectrogram = false
                                            return
                                        }

                                        let pickedTheme = themeManager.deviceCapsuleThemes[context.device.deviceID] ?? themeManager.capsuleThemeMode
                                        let simdTheme = simdColor(from: spectrumLineColor(for: SpectrumThemeMode(from: pickedTheme)))
                                        let deviceID = context.device.deviceID

                                        // Special handling for System Audio (888_888) - use SystemAudioSpectroProcessor
                                        if deviceID == 888_888 {
                                            let scale = themeManager.deviceSpectrumScaleFactors[deviceID] ?? 1.0
                                            floatingWindowController.showSpectrogramWindow(
                                                deviceID: deviceID,
                                                channelIndex: channelIndex,
                                                scale: scale,
                                                title: "System Audio Spectrogram"
                                            ) {
                                                SystemAudioSpectrogramView(
                                                    deviceID: deviceID,
                                                    channelIndex: channelIndex,
                                                    themeMode: WaveformThemeMode(rawValue: themeManager.deviceCapsuleThemes[deviceID]?.rawValue ?? themeManager.capsuleThemeMode.rawValue) ?? .light,
                                                    deviceName: "System Audio",
                                                    scale: scale,
                                                    themeColor: simdTheme
                                                )
                                            }
                                            return
                                        }

                                        let uDeviceID = UInt32(deviceID)
                                        let channelCount = UInt32(context.device.inputChannels)
                                        guard SpectroManager.shared.acquireSpectrogramSession(
                                            deviceID: uDeviceID,
                                            channelCount: channelCount,
                                            channel: Int32(channelIndex)
                                        ) else {
                                            showSpectrogram = false
                                            return
                                        }
                                        let isUtilityInstrument = (deviceID >= 1_000_000 && deviceID <= 1_000_004)
                                        let scale = themeManager.deviceSpectrumScaleFactors[deviceID] ?? 1.0

                                        var mixerAudioSource: PostEQStreamReader? = nil
                                        if isUtilityInstrument {
                                            mixerAudioSource = PostEQStreamReader(deviceID: deviceID, channelIndex: channelIndex, channelType: 0)
                                        }

                                        floatingWindowController.showSpectrogramWindow(
                                            deviceID: deviceID,
                                            channelIndex: channelIndex,
                                            scale: scale,
                                            title: "\(mixerAudioSource?.name ?? context.device.name) Spectrogram"
                                        ) {
                                            SpectroBackendView(
                                                deviceID: Int32(deviceID),
                                                channelIndex: Int32(channelIndex),
                                                fftSize: 512,
                                                themeColor: simdTheme,
                                                themeMode: Int32(pickedTheme.rawValue),
                                                deviceName: context.device.name,
                                                scale: scale,
                                                externalAudioSource: mixerAudioSource
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

                        /// ▸ Icon: Waveform
                        /// - Toggles floating waveform window (macOS) or popover (iOS).
                        /// - Uses theme-derived color for consistency.
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 10, weight: .medium, design: .default))
                            .foregroundColor(
                                showWaveform
                                ? .white
                                : waveformIconColor(
                                    for: themeManager.deviceCapsuleThemes[context.device.deviceID] ?? themeManager.capsuleThemeMode
                                )
                            )
                            .onTapGesture {
                                // User action: Toggle waveform window.
                                showWaveform.toggle()
                            }
                        #if os(macOS)
                            .onChange(of: showWaveform) { newValue in
                                // User action: Show/close floating waveform window.
                                if newValue {
                                    // Filter out virtual instrument device ID (999_999) which has its own pipeline
                                    guard context.device.deviceID != 999_999 else {
                                        showWaveform = false
                                        return
                                    }

                                    let deviceID = context.device.deviceID

                                    // Special handling for System Audio (888_888) - use SystemAudioWaveformView
                                    if deviceID == 888_888 {
                                        let scale = themeManager.deviceSpectrumScaleFactors[deviceID] ?? 1.0
                                        floatingWindowController.showWaveformWindow(
                                            deviceID: deviceID,
                                            channelIndex: channelIndex,
                                            scale: scale,
                                            title: "System Audio Waveform"
                                        ) {
                                            SystemAudioWaveformView(
                                                deviceID: deviceID,
                                                channelIndex: channelIndex,
                                                themeMode: WaveformThemeMode(rawValue: themeManager.deviceCapsuleThemes[deviceID]?.rawValue ?? themeManager.capsuleThemeMode.rawValue) ?? .light,
                                                deviceName: "System Audio",
                                                scale: scale
                                            )
                                        }
                                        return
                                    }

                                    let isUtilityInstrument = (deviceID >= 1_000_000 && deviceID <= 1_000_004)
                                    let scale = themeManager.deviceSpectrumScaleFactors[context.device.deviceID] ?? 1.0

                                    var mixerAudioSource: PostEQStreamReader? = nil
                                    if isUtilityInstrument {
                                        mixerAudioSource = PostEQStreamReader(deviceID: deviceID, channelIndex: channelIndex, channelType: 0)
                                    }

                                    floatingWindowController.showWaveformWindow(
                                        deviceID: context.device.deviceID,
                                        channelIndex: channelIndex,
                                        scale: scale,
                                        title: "\(mixerAudioSource?.name ?? context.device.name) Waveform"
                                    ) {
                                        WaveformView(
                                            buffer: waveformBuffer,
                                            deviceID: context.device.deviceID,
                                            channelIndex: channelIndex,
                                            themeMode: WaveformThemeMode(rawValue: themeManager.deviceCapsuleThemes[context.device.deviceID]?.rawValue ?? themeManager.capsuleThemeMode.rawValue) ?? .light,
                                            deviceName: context.device.name,
                                            mixerAudioSource: mixerAudioSource,
                                            scale: scale
                                        )
                                        .frame(width: 750 * scale, height: 180 * scale)
                                        .background(Color.clear)
                                    }
                                } else {
                                    floatingWindowController.closeWaveformWindow(for: context.device.deviceID, channelIndex: channelIndex)
                                }
                            }

    #else
                            .popover(isPresented: $showWaveform) {
                                WaveformView(
                                    buffer: waveformBuffer,
                                    deviceID: context.device.deviceID,
                                    channelIndex: channelIndex,
                                    themeMode: WaveformThemeMode(rawValue: themeManager.deviceCapsuleThemes[context.device.deviceID]?.rawValue ?? themeManager.capsuleThemeMode.rawValue) ?? .light
                                )
                                .frame(width: 750, height: 180)
                                .background(Color.clear)
                            }
    #endif
                            .offset(y: 6)
                    }
                }
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
                .offset(y: 12)
            }
        }
    }

private extension MetalCapsuleWithText {
    func refreshLevelTexts(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastTextUpdate) >= updateInterval else { return }
        lastTextUpdate = now

        let rawPeak = context.peakBuffer.mostRecent(for: channelIndex)
        let peakDb = linearToDb(rawPeak)
        currentPeak = peakDb

        if peakDb > heldPeakValue || force {
            heldPeakValue = max(heldPeakValue, peakDb)
            let displayDb = heldPeakValue + 4.0
            if !displayDb.isFinite || displayDb <= -99.5 {
                formattedPeakDbText = "−∞"
            } else {
                formattedPeakDbText = String(format: "%d", Int(displayDb))
            }
            lastHeldPeakUpdate = now
        }

        let rms = context.rmsBuffer.mostRecent(for: channelIndex)
        let rmsValue = linearToDb(rms)
        currentRMS = rmsValue
        let displayRms = rmsValue + 4.0
        if !displayRms.isFinite || displayRms <= -99.5 {
            formattedRMSDbText = "−∞"
        } else {
            let newRmsText = String(format: "%d", Int(displayRms))
            if formattedRMSDbText != newRmsText {
                formattedRMSDbText = newRmsText
            }
        }
    }

    /// Converts a linear audio amplitude value to decibels (dB).
    /// - param linear: The linear amplitude value.
    /// - returns: The corresponding value in decibels (dB).
    func linearToDb(_ linear: Float) -> Float {
        linear <= 0.000_01 ? -100.0 : 20.0 * log10(linear)
    }

    /// Determines the color to use for the peak text based on the clamped peak dB value.
    /// - param clampedPeakDb: The clamped peak value in dB.
    /// - returns: The color to use for the peak text.
    func peakColor(for clampedPeakDb: Float) -> Color {
        if clampedPeakDb >= -6.0 {
            return .red
        } else if clampedPeakDb >= -18.0 {
            return .orange
        } else if clampedPeakDb >= -24.0 {
            return Color(red: 0.4, green: 1.0, blue: 0.4)
        } else if clampedPeakDb >= -40.0 {
            return .green
        } else if clampedPeakDb >= -64.0 {
            return Color(red: 0.1, green: 0.6, blue: 0.1)
        } else {
            return .secondary
        }
    }

    /// Determines the color to use for the RMS text based on the current RMS dB value.
    var rmsColor: Color {
        if currentRMS >= -6.0 {
            return .red
        } else if currentRMS >= -18.0 {
            return .orange
        } else if currentRMS >= -24.0 {
            return Color(red: 0.4, green: 1.0, blue: 0.4)
        } else if currentRMS >= -40.0 {
            return .green
        } else if currentRMS >= -64.0 {
            return Color(red: 0.1, green: 0.6, blue: 0.1)
        } else {
            return .secondary
        }
    }

    /// Determines the base color for the capsule based on dB and theme.
    /// - param db: The decibel value.
    /// - returns: The Color to use for the capsule fill.
    func capsuleColor(for db: Float) -> Color {
        if db >= -0.9 {
            return Color(red: 0.8, green: 0.0, blue: 0.0)
        } else if db >= -12.0 {
            return Color(red: 1.0, green: 0.5, blue: 0.0)
        } else if db >= -24.0 {
            return Color(red: 1.0, green: 1.0, blue: 0.0)
        } else {
            return Color(red: 0.2, green: 0.6, blue: 1.0)
        }
    }

    /// Determines the color for the waveform icon based on the theme.
    /// - param theme: The current ThemeMode.
    /// - returns: The Color to use for the waveform icon.
    func waveformIconColor(for theme: ThemeMode) -> Color {
        switch theme {
        case .light:
            return Color(red: 0.2, green: 0.6, blue: 0.2)
        case .thinMaterial:
            return Color(red: 0.0, green: 0.6, blue: 0.7)
        case .purple:
            return Color(red: 0.6, green: 0.2, blue: 1.0)
        case .mint:
            return Color(red: 0.62, green: 0.96, blue: 0.78)
        case .lavender:
            return Color.purple.opacity(0.6)
        case .indigo:
            return Color(red: 0.29, green: 0.0, blue: 0.51)
        case .gray:
            return Color.gray
        case .hollow:
            return Color.clear
        case .dark:
            return Color(red: 0.2, green: 0.6, blue: 1.0)
        case .midnight:
            return Color(red: 0.4, green: 0.8, blue: 1.0)
        case .poorMansGlass, .liquidGlass:
            return Color.white.opacity(0.5)
        }
    }
}
