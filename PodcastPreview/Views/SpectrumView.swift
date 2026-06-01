//
//  SpectrumView.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 07/12/2025.
//

import SwiftUI
import Combine
import AppKit
import Metal
import QuartzCore
import simd

// Helper to convert SwiftUI Color into SIMD3<Float> for Metal usage.
// This mirrors the behaviour used by the meter Metal pipeline.
private func simdColor(from color: Color) -> SIMD3<Float> {
    #if os(macOS)
    let nsColor = NSColor(color)
    let rgbColor = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
    return SIMD3(Float(rgbColor.redComponent),
                 Float(rgbColor.greenComponent),
                 Float(rgbColor.blueComponent))
    #else
    return SIMD3(0, 1, 0)
    #endif
}

struct SpectrumView: View {
    @Environment(\.appUIScale) private var appUIScale
    @ObservedObject var monitoring: MonitoringState
    
    // Accept bindings from parent so sidebar can control these
    @Binding var fftSize: Int
    @Binding var decay: DecayOption
    @Binding var selectedFreqRange: FrequencyRangePreset

    private var scaledStackSpacing: CGFloat { 8 * appUIScale }
    private var scaledHeadlineFontSize: CGFloat { 13 * appUIScale }
    private var scaledPadding: CGFloat { 8 * appUIScale }
    private var scaledSpectrumMinHeight: CGFloat { 140 * appUIScale }

    // Number of visual bands (capsules) in the spectrum display
    private let visualBinCount = 127
    private let minDB: CGFloat = -120
    private let maxDB: CGFloat = 0

    private let fftSizeMultiplier: Int = 1  // Could be made configurable later
    
    // Predefined frequency range presets (moved to top-level for reuse)
    enum FrequencyRangePreset: String, CaseIterable, Identifiable {
        case fullRange = "20-20k Hz"
        case subBass = "10-20k Hz"
        case bass = "5-20k Hz"
        case ultraLow = "1-20k Hz"
        case custom = "Custom"
        
        var id: String { rawValue }
        
        var minHz: Double {
            switch self {
            case .fullRange: return 20.0
            case .subBass: return 10.0
            case .bass: return 5.0
            case .ultraLow: return 1.0
            case .custom: return 20.0 // default, user will adjust
            }
        }
        
        var maxHz: Double {
            return 20000.0 // All presets use 20 kHz max
        }
    }

    enum DecayOption: String, CaseIterable, Identifiable {
        case fast = "Fast"
        case medium = "Medium"
        case slow = "Slow"

        var id: String { rawValue }

        /// 1.0 = no smoothing, closer to 0 = heavier smoothing / slower decay
        var smoothingFactor: CGFloat {
            switch self {
            case .fast:   return 0.4
            case .medium: return 0.7
            case .slow:   return 0.9
            }
        }
    }

    private let fftSizeOptions: [Int] = [512, 1024, 2048, 4096]

    var body: some View {
        VStack(alignment: .leading, spacing: scaledStackSpacing) {
            // Just the "Spectrum" title, no controls
            HStack {
                Text("Spectrum")
                    .font(.system(size: scaledHeadlineFontSize, weight: .semibold))
                Spacer()
            }

            ZStack(alignment: .bottom) {
                // Use Metal on macOS 11+ for best performance, Core Graphics on older versions
                if #available(macOS 11.0, *), MTLCreateSystemDefaultDevice() != nil {
                    MetalSpectrumView(monitoring: monitoring,
                                      appUIScale: appUIScale,
                                      fftSize: fftSize,
                                      fftSizeMultiplier: fftSizeMultiplier,
                                      decay: decay)
                        .frame(minHeight: scaledSpectrumMinHeight)
                } else {
                    LegacySpectrumView(monitoring: monitoring,
                                       appUIScale: appUIScale,
                                       fftSize: fftSize,
                                       fftSizeMultiplier: fftSizeMultiplier,
                                       decay: decay)
                        .frame(minHeight: scaledSpectrumMinHeight)
                }
                
                // Frequency labels disabled - spectrum is now perfectly accurate
                // and we don't want to risk breaking it with label positioning
                // FrequencyLabelsView(
                //     minFreq: monitoring.spectrumMinFreqHz,
                //     maxFreq: monitoring.spectrumMaxFreqHz
                // )
            }
        }
        .padding(scaledPadding)
        .onAppear {
            #if DEBUG
            print("SpectrumView appeared")
            print("   Monitoring state: \(monitoring)")
            print("   Selected source: \(monitoring.selectedSourceName ?? monitoring.selectedDevice?.name ?? "nil")")
            #endif
        }
    }
}

// Frequency labels overlay for spectrum
struct FrequencyLabelsView: View {
    let minFreq: Double
    let maxFreq: Double
    
    var body: some View {
        HStack(spacing: 0) {
            // Calculate frequency markers using log2 spacing to match the spectrum
            let markers = calculateFrequencyMarkers()
            
            ForEach(markers, id: \.frequency) { marker in
                Text(marker.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
    
    private func calculateFrequencyMarkers() -> [FrequencyMarker] {
        // Common frequency markers for audio spectrum (DAW-style)
        let frequencies: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
        
        return frequencies.compactMap { freq in
            guard freq >= minFreq && freq <= maxFreq else { return nil }
            
            let label: String
            if freq >= 1000 {
                label = "\(Int(freq / 1000))k"
            } else {
                label = "\(Int(freq))"
            }
            
            return FrequencyMarker(frequency: freq, label: label)
        }
    }
    
    struct FrequencyMarker {
        let frequency: Double
        let label: String
    }
}


struct MetalSpectrumView: NSViewRepresentable {
    @ObservedObject var monitoring: MonitoringState
    var appUIScale: CGFloat
    var fftSize: Int
    var fftSizeMultiplier: Int
    var decay: SpectrumView.DecayOption

    func makeNSView(context: Context) -> MetalSpectrumHostingView {
        let view = MetalSpectrumHostingView(
            monitoring: monitoring,
            fftSize: fftSize,
            fftSizeMultiplier: fftSizeMultiplier,
            decay: decay,
            appUIScale: appUIScale
        )
        
        // Print debug info on creation
        #if DEBUG
        print("Success: MetalSpectrumView created")
        print("   Metal device: \(view.metalLayer.device?.name ?? "none")")
        print("   Renderer: \(view.renderer != nil ? "initialized" : "nil")")
        #endif
        
        return view
    }

    func updateNSView(_ nsView: MetalSpectrumHostingView, context: Context) {
        let theme = monitoring.displaySpectrumThemeColor
        nsView.baseColor = simdColor(from: theme)
        nsView.fftSize = fftSize
        nsView.fftSizeMultiplier = fftSizeMultiplier
        nsView.decay = decay
        nsView.appUIScale = appUIScale
    }
}

// MARK: - Legacy Spectrum View for older macOS versions

/// Legacy spectrum view using Core Graphics instead of Metal
/// Compatible with macOS 10.15+ (Catalina and later)
struct LegacySpectrumView: NSViewRepresentable {
    @ObservedObject var monitoring: MonitoringState
    var appUIScale: CGFloat
    var fftSize: Int
    var fftSizeMultiplier: Int
    var decay: SpectrumView.DecayOption

    func makeNSView(context: Context) -> LegacySpectrumHostingView {
        let view = LegacySpectrumHostingView(
            monitoring: monitoring,
            fftSize: fftSize,
            fftSizeMultiplier: fftSizeMultiplier,
            decay: decay,
            appUIScale: appUIScale
        )
        
        // Print debug info on creation
        #if DEBUG
        print("Success: LegacySpectrumView created (Core Graphics mode)")
        print("   Timer: \(view.displayTimer != nil ? "active" : "nil")")
        #endif
        
        return view
    }

    func updateNSView(_ nsView: LegacySpectrumHostingView, context: Context) {
        let theme = monitoring.displaySpectrumThemeColor
        nsView.themeColor = NSColor(theme)
        nsView.fftSize = fftSize
        nsView.fftSizeMultiplier = fftSizeMultiplier
        nsView.decay = decay
        nsView.appUIScale = appUIScale
    }
}

final class MetalSpectrumHostingView: NSView {
    private let visualBinCount = 127
    private let minDB: Float = -120.0
    private let maxDB: Float = 0.0

    var metalLayer: CAMetalLayer!
    var renderer: MetalSpectrumRenderer!
    var displayLink: CVDisplayLink?
    var baseColor: SIMD3<Float> = SIMD3(0, 1, 0)

    private var monitoring: MonitoringState
    var appUIScale: CGFloat {
        didSet {
            if oldValue != appUIScale {
                invalidateIntrinsicContentSize()
            }
        }
    }
    var fftSize: Int
    var fftSizeMultiplier: Int
    var decay: SpectrumView.DecayOption

    // Smoothed spectrum in dB space
    private var spectrumDB: [Float]
    
    // Throttle spectrum analysis to avoid duplicate work
    private var lastAnalysisTime: Date?
    private var lastDrawTime: CFTimeInterval = 0
    private let targetFPS: CFTimeInterval = 20.0
    
    // Debug flags
    private var hasLoggedSpectrum = false
    private var hasLoggedDraw = false
    private var warnedAboutRenderer = false
    private var warnedAboutDrawable = false
    private var fftErrorCount = 0

    init(monitoring: MonitoringState, fftSize: Int, fftSizeMultiplier: Int, decay: SpectrumView.DecayOption, appUIScale: CGFloat) {
        self.monitoring = monitoring
        self.appUIScale = appUIScale
        self.fftSize = fftSize
        self.fftSizeMultiplier = fftSizeMultiplier
        self.decay = decay
        self.spectrumDB = Array(repeating: minDB, count: visualBinCount)

        super.init(frame: .zero)

        // Spectrum sensitivity is applied in Swift (analyseSpectrum) as a simple dB offset.

        wantsLayer = true
        metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        
        // Ensure Metal layer is added to the view hierarchy
        layer = metalLayer
        
        // Check for Metal support
        guard let device = metalLayer.device else {
            print("Warning: Metal not available on this system")
            return
        }

        renderer = MetalSpectrumRenderer(device: device)

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        displayLink = link
        
        if let dl = displayLink {
            CVDisplayLinkSetOutputHandler(dl) { [weak self] _,_,_,_,_ in
                guard let self = self else { return kCVReturnSuccess }

                let now = CACurrentMediaTime()
                if (now - self.lastDrawTime) < (1.0 / self.targetFPS) {
                    return kCVReturnSuccess
                }
                self.lastDrawTime = now

                DispatchQueue.main.async {
                    self.drawFrame()
                }
                return kCVReturnSuccess
            }
            CVDisplayLinkStart(dl)
        }
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    deinit {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }
    
    override var isOpaque: Bool {
        return false
    }
    
    // Provide intrinsic content size to help with layout
    override var intrinsicContentSize: NSSize {
        return NSSize(width: NSView.noIntrinsicMetric, height: 140 * appUIScale)
    }

    private func analyseSpectrum() {
        guard let rb = monitoring.currentRingBuffer() else {
            #if DEBUG
            print("Warning: No ring buffer available")
            #endif
            return
        }

        let sampleRate: Double
        if monitoring.displaySampleRate > 0 {
            sampleRate = monitoring.displaySampleRate
        } else {
            sampleRate = 48_000.0
        }

        // Apply FFT size multiplier for smoother spectrum (e.g., 1024 * 3 = 3072)
        let trueFFTSize = min(fftSize * fftSizeMultiplier, 8192)
        
        // Throttle FFT analysis to a fixed rate (20 Hz is optimal for audio spectrum)
        // This significantly reduces CPU usage while maintaining smooth animation
        let now = Date()
        if let last = lastAnalysisTime {
            let elapsed = now.timeIntervalSince(last)
            // Target 20 Hz FFT rate (50ms between updates)
            let targetInterval = 1.0 / 20.0  // 50ms
            if elapsed < targetInterval {
                return // Skip this frame to maintain target rate
            }
        }
        lastAnalysisTime = now

        FFTAnalyser_Configure(trueFFTSize, sampleRate)

        var mags = [Float](repeating: minDB, count: visualBinCount)
        
        // Use the currently selected channel (atomic read, thread-safe)
        let channelToAnalyze = FFTAnalyser_GetSelectedChannel()
        let result = FFTAnalyser_Compute(rb, channelToAnalyze, &mags, visualBinCount)
        if result != 0 {
            #if DEBUG
            fftErrorCount += 1
            if fftErrorCount % 100 == 1 {  // Print every 100th error to avoid spam
                print("Warning: FFTAnalyser_Compute failed: \(result)")
            }
            #endif
            return
        }

        let smoothing = Float(decay.smoothingFactor)
        let gainDB: Float = 0.0  // Visual sensitivity adjustment (0 dB = neutral)

        for i in 0..<visualBinCount {
            let currentDB = mags[i] + gainDB
            let previousDB = spectrumDB[i]
            let smoothed = previousDB * smoothing + currentDB * (1.0 - smoothing)
            spectrumDB[i] = smoothed
        }
        
        #if DEBUG
        // Log first spectrum update to verify data flow
        if !hasLoggedSpectrum {
            hasLoggedSpectrum = true
            print("Success: First spectrum data received")
            print("   Sample values: \(spectrumDB.prefix(5).map { String(format: "%.1f", $0) })")
        }
        #endif
    }

    private func buildVertices() -> [SIMD2<Float>] {
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(visualBinCount * 2)

        // Add small padding to prevent clipping at edges
        // This creates a margin between the spectrum and the view bounds
        let horizontalPadding: Float = 0.02  // 2% margin on each side (4% total)
        let verticalPadding: Float = 0.05    // 5% margin on top/bottom (10% total)
        
        // Adjust coordinate ranges to leave margin
        let xScale: Float = 1.0 - horizontalPadding
        let yScale: Float = 1.0 - verticalPadding

        // Get frequency range for logarithmic positioning
        let minFreq = monitoring.spectrumMinFreqHz
        let maxFreq = monitoring.spectrumMaxFreqHz
        
        // Precompute log10 range for positioning (matches FFTAnalyser.c and FrequencyLabelsView)
        let log10Min = log10(max(minFreq, 1.0))
        let log10Max = log10(maxFreq)
        let log10Range = log10Max - log10Min
        
        guard log10Range > 0 else {
            // Fallback to linear if log range is invalid
            for i in 0..<visualBinCount {
                let xNorm = Float(i) / Float(visualBinCount - 1)
                let x = (xNorm * 2.0 - 1.0) * xScale
                let clampedDB = min(max(spectrumDB[i], minDB), maxDB)
                let norm = (clampedDB - minDB) / (maxDB - minDB)
                let y = (norm * 2.0 - 1.0) * yScale
                points.append(SIMD2<Float>(x, y))
                points.append(SIMD2<Float>(x, -1.0))
            }
            return points
        }

        for i in 0..<visualBinCount {
            // Calculate the center frequency of this visual bin using log10 spacing
            // This matches the band mapping in FFTAnalyser_EnsureBandMap()
            let t = Float(i) / Float(visualBinCount - 1)  // 0.0 to 1.0
            let log10Freq = log10Min + Double(t) * log10Range
            
            // Convert frequency back to position (0.0 to 1.0)
            let position = Float((log10Freq - log10Min) / log10Range)
            
            // Map position to NDC space [-xScale, +xScale]
            let x = (position * 2.0 - 1.0) * xScale

            let clampedDB = min(max(spectrumDB[i], minDB), maxDB)
            let norm = (clampedDB - minDB) / (maxDB - minDB) // 0.0 .. 1.0
            
            // Map to [-yScale, +yScale] with bottom clamped to -1.0 (floor)
            let y = (norm * 2.0 - 1.0) * yScale              // -yScale to +yScale (top margin)

            // Top point on the spectrum curve (with top margin)x
            points.append(SIMD2<Float>(x, y))
            // Corresponding bottom point at -1.0 (no bottom margin, spectrum fills to floor)
            points.append(SIMD2<Float>(x, -1.0))
        }

        return points
    }

    func drawFrame() {
        guard let renderer = renderer else {
            #if DEBUG
            if !warnedAboutRenderer {
                warnedAboutRenderer = true
                print("Warning: MetalSpectrumRenderer not initialized")
            }
            #endif
            return
        }
        
        guard let drawable = metalLayer.nextDrawable() else {
            #if DEBUG
            if !warnedAboutDrawable {
                warnedAboutDrawable = true
                print("Warning: Could not get Metal drawable")
                print("   Metal layer frame: \(metalLayer.frame)")
                print("   Metal layer bounds: \(bounds)")
            }
            #endif
            return
        }

        // Update analysis before drawing
        analyseSpectrum()

        let vertices = buildVertices()
        renderer.updateSpectrum(vertices)
        renderer.drawSpectrum(baseColor, in: drawable)
        
        #if DEBUG
        if !hasLoggedDraw {
            hasLoggedDraw = true
            print("Success: First Metal frame drawn")
            print("   Vertices: \(vertices.count)")
            print("   Drawable size: \(drawable.texture.width)x\(drawable.texture.height)")
        }
        #endif
    }

    override func layout() {
        super.layout()
        metalLayer.frame = bounds
        
        // Ensure Metal layer is properly sized on first layout
        if bounds.width > 0 && bounds.height > 0 {
            let scale = window?.backingScaleFactor ?? 2.0
            metalLayer.drawableSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
        }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Update drawable size when moved to a window
        if let window = window, bounds.width > 0 && bounds.height > 0 {
            metalLayer.drawableSize = CGSize(
                width: bounds.width * window.backingScaleFactor,
                height: bounds.height * window.backingScaleFactor
            )
        }
    }
}

// MARK: - Legacy Spectrum Hosting View (Core Graphics)

/// Lightweight spectrum view using Core Graphics for older macOS versions
/// This provides the same visual style as MetalSpectrumHostingView but with
/// broader compatibility (macOS 10.15+)
final class LegacySpectrumHostingView: NSView {
    private let visualBinCount = 127
    private let minDB: Float = -120.0
    private let maxDB: Float = 0.0

    var themeColor: NSColor = .green
    
    private var monitoring: MonitoringState
    var appUIScale: CGFloat {
        didSet {
            if oldValue != appUIScale {
                invalidateIntrinsicContentSize()
            }
        }
    }
    var fftSize: Int
    var fftSizeMultiplier: Int
    var decay: SpectrumView.DecayOption

    // Smoothed spectrum in dB space
    private var spectrumDB: [Float]
    
    // Throttle spectrum analysis to avoid duplicate work
    private var lastAnalysisTime: Date?
    
    // Timer for display refresh in the legacy Core Graphics path.
    fileprivate var displayTimer: Timer?
    
    // Debug flags
    private var hasLoggedSpectrum = false
    private var hasLoggedDraw = false
    private var warnedNoContext = false
    private var warnedNoBounds = false
    private var fftErrorCount = 0

    init(monitoring: MonitoringState, fftSize: Int, fftSizeMultiplier: Int, decay: SpectrumView.DecayOption, appUIScale: CGFloat) {
        self.monitoring = monitoring
        self.appUIScale = appUIScale
        self.fftSize = fftSize
        self.fftSizeMultiplier = fftSizeMultiplier
        self.decay = decay
        self.spectrumDB = Array(repeating: minDB, count: visualBinCount)

        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        
        // Schedule on common run loop mode to ensure it works even during tracking.
        displayTimer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.analyseSpectrum()
            self?.needsDisplay = true
        }
        
        if let timer = displayTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    deinit {
        displayTimer?.invalidate()
    }
    
    override var isOpaque: Bool {
        return false
    }
    
    override var wantsUpdateLayer: Bool {
        return false  // Use draw(_:) instead of updateLayer
    }
    
    // Provide intrinsic content size to help with layout
    override var intrinsicContentSize: NSSize {
        return NSSize(width: NSView.noIntrinsicMetric, height: 140 * appUIScale)
    }

    private func analyseSpectrum() {
        guard let rb = monitoring.currentRingBuffer() else {
            #if DEBUG
            print("Warning: [Legacy] No ring buffer available")
            #endif
            return
        }

        let sampleRate: Double
        if monitoring.displaySampleRate > 0 {
            sampleRate = monitoring.displaySampleRate
        } else {
            sampleRate = 48_000.0
        }

        // Apply FFT size multiplier for smoother spectrum (e.g., 1024 * 3 = 3072)
        let trueFFTSize = min(fftSize * fftSizeMultiplier, 8192)
        
        // Throttle FFT analysis to a fixed rate (20 Hz is optimal for audio spectrum)
        let now = Date()
        if let last = lastAnalysisTime {
            let elapsed = now.timeIntervalSince(last)
            let targetInterval = 1.0 / 20.0  // 50ms
            if elapsed < targetInterval {
                return
            }
        }
        lastAnalysisTime = now

        FFTAnalyser_Configure(trueFFTSize, sampleRate)

        var mags = [Float](repeating: minDB, count: visualBinCount)
        
        // Use the currently selected channel (atomic read, thread-safe)
        let channelToAnalyze = FFTAnalyser_GetSelectedChannel()
        let result = FFTAnalyser_Compute(rb, channelToAnalyze, &mags, visualBinCount)
        if result != 0 {
            #if DEBUG
            fftErrorCount += 1
            if fftErrorCount % 100 == 1 {
                print("Warning: [Legacy] FFTAnalyser_Compute failed: \(result)")
            }
            #endif
            return
        }

        let smoothing = Float(decay.smoothingFactor)
        let gainDB: Float = 0.0  // Visual sensitivity adjustment (0 dB = neutral)

        for i in 0..<visualBinCount {
            let currentDB = mags[i] + gainDB
            let previousDB = spectrumDB[i]
            let smoothed = previousDB * smoothing + currentDB * (1.0 - smoothing)
            spectrumDB[i] = smoothed
        }
        
        #if DEBUG
        if !hasLoggedSpectrum {
            hasLoggedSpectrum = true
            print("Success: [Legacy] First spectrum data received")
            print("   Sample values: \(spectrumDB.prefix(5).map { String(format: "%.1f", $0) })")
        }
        #endif
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard let context = NSGraphicsContext.current?.cgContext else {
            #if DEBUG
            if !warnedNoContext {
                warnedNoContext = true
                print("Warning: [Legacy] No graphics context")
            }
            #endif
            return
        }
        
        let bounds = self.bounds
        guard bounds.width > 0 && bounds.height > 0 else {
            #if DEBUG
            if !warnedNoBounds {
                warnedNoBounds = true
                print("Warning: [Legacy] Invalid bounds: \(bounds)")
            }
            #endif
            return
        }
        
        #if DEBUG
        if !hasLoggedDraw {
            hasLoggedDraw = true
            print("Success: [Legacy] First draw call")
            print("   Bounds: \(bounds)")
            print("   Dirty rect: \(dirtyRect)")
        }
        #endif
        
        // Clear background
        context.clear(bounds)
        
        // Calculate points with padding
        let horizontalPadding: CGFloat = 0.02 * bounds.width
        let verticalPadding: CGFloat = 0.05 * bounds.height
        
        let drawableWidth = bounds.width - (horizontalPadding * 2)
        let drawableHeight = bounds.height - (verticalPadding * 2)
        
        // Get frequency range for logarithmic positioning
        let minFreq = monitoring.spectrumMinFreqHz
        let maxFreq = monitoring.spectrumMaxFreqHz
        
        // Precompute log10 range for positioning
        let log10Min = log10(max(minFreq, 1.0))
        let log10Max = log10(maxFreq)
        let log10Range = log10Max - log10Min
        
        guard log10Range > 0 else { return }
        
        // Build path for spectrum fill
        let path = NSBezierPath()
        
        // Start from bottom-left
        path.move(to: NSPoint(x: horizontalPadding, y: 0))
        
        // Draw spectrum curve
        for i in 0..<visualBinCount {
            let t = Float(i) / Float(visualBinCount - 1)
            let log10Freq = log10Min + Double(t) * log10Range
            let position = CGFloat((log10Freq - log10Min) / log10Range)
            
            let x = horizontalPadding + position * drawableWidth
            
            let clampedDB = min(max(spectrumDB[i], minDB), maxDB)
            let norm = CGFloat((clampedDB - minDB) / (maxDB - minDB))
            let y = verticalPadding + norm * drawableHeight
            
            if i == 0 {
                path.line(to: NSPoint(x: x, y: y))
            } else {
                path.line(to: NSPoint(x: x, y: y))
            }
        }
        
        // Close path to bottom-right and back to start
        path.line(to: NSPoint(x: bounds.width - horizontalPadding, y: 0))
        path.close()
        
        // Create gradient fill (theme color to darker/transparent)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        // Convert theme color to RGB
        guard let rgbColor = themeColor.usingColorSpace(.deviceRGB) else { return }
        let r = CGFloat(rgbColor.redComponent)
        let g = CGFloat(rgbColor.greenComponent)
        let b = CGFloat(rgbColor.blueComponent)
        
        // Create gradient from bright theme color (top) to darker/transparent (bottom)
        let topColor = CGColor(red: r, green: g, blue: b, alpha: 0.8)
        let bottomColor = CGColor(red: r * 0.2, green: g * 0.2, blue: b * 0.2, alpha: 0.1)
        
        guard let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [topColor, bottomColor] as CFArray,
            locations: [1.0, 0.0]
        ) else { return }
        
        // Fill with gradient
        context.saveGState()
        
        // Convert NSBezierPath to CGPath (for macOS < 14.0 compatibility)
        let cgPath = convertBezierPathToCGPath(path)
        context.addPath(cgPath)
        context.clip()
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: bounds.height),
            end: CGPoint(x: 0, y: 0),
            options: []
        )
        context.restoreGState()
        
        // Draw outline stroke
        themeColor.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
    
    /// Convert NSBezierPath to CGPath for pre-macOS 14 compatibility
    private func convertBezierPathToCGPath(_ bezierPath: NSBezierPath) -> CGPath {
        let path = CGMutablePath()
        let pointCount = bezierPath.elementCount
        
        if pointCount > 0 {
            var points = [NSPoint](repeating: NSPoint.zero, count: 3)
            
            for i in 0..<pointCount {
                let type = bezierPath.element(at: i, associatedPoints: &points)
                
                switch type {
                case .moveTo:
                    path.move(to: points[0])
                case .lineTo:
                    path.addLine(to: points[0])
                case .curveTo:
                    path.addCurve(to: points[2], control1: points[0], control2: points[1])
                case .cubicCurveTo:
                    path.addCurve(to: points[2], control1: points[0], control2: points[1])
                case .quadraticCurveTo:
                    path.addQuadCurve(to: points[1], control: points[0])
                case .closePath:
                    path.closeSubpath()
                @unknown default:
                    break
                }
            }
        }
        
        return path
    }
}
