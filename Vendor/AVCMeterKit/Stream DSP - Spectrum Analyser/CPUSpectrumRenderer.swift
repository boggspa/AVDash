import SwiftUI
import AppKit

/// CPU-based spectrum renderer.
///
/// Uses exactly the same data pipeline as the Metal renderer:
///   1. Calls `SpectrumMeshBuilder.makeSpectrumVertices` — the same helper
///      that `MetalSpectrumRenderer.updateNSView` uses — to get NDC vertex data.
///   2. Extracts peak (top) vertices for each bin.
///   3. Converts NDC → CG view coordinates and draws fill + outline via CGContext.
///
/// This guarantees the curve lands in the same pixel positions as the Metal path,
/// including alignment with the manually-tweaked y-axis grid offsets in SpectrumContainerView.
struct CPUSpectrumRenderer: View {
    @ObservedObject var spectrumProcessor: SafeFFTSpectrumProcessor
    var themeMode: ThemeMode

    var body: some View {
        _CPUSpectrumNSView(spectrumProcessor: spectrumProcessor, themeMode: themeMode)
    }
}

// MARK: - NSViewRepresentable bridge

private struct _CPUSpectrumNSView: NSViewRepresentable {
    @ObservedObject var spectrumProcessor: SafeFFTSpectrumProcessor
    var themeMode: ThemeMode

    func makeNSView(context: Context) -> SpectrumCGView {
        let view = SpectrumCGView()
        // Mirror MetalSpectrumRenderer.makeNSView — start the processor here so the
        // FFT pipeline is running from the first draw call, not just from onAppear.
        spectrumProcessor.start()
        view.startRedrawTimer()
        return view
    }

    func updateNSView(_ nsView: SpectrumCGView, context: Context) {
        // Called whenever spectrumProcessor publishes (via @ObservedObject) or parent re-renders.
        nsView.spectrumProcessor = spectrumProcessor
        nsView.themeMode = themeMode
        nsView.needsDisplay = true
    }
}

// MARK: - Core Graphics drawing view

final class SpectrumCGView: NSView {

    // Hold a reference to the processor so draw() can call makeSpectrumVertices itself,
    // exactly as MetalSpectrumRenderer.updateNSView does.
    var spectrumProcessor: SafeFFTSpectrumProcessor?
    var themeMode: ThemeMode = .liquidGlass

    private var redrawTimer: Timer?

    override var isOpaque: Bool { false }

    func startRedrawTimer() {
        let newTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0,
                                           repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
        RunLoop.main.add(newTimer, forMode: .common)
        redrawTimer = newTimer
    }

    deinit { redrawTimer?.invalidate() }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let processor = spectrumProcessor else { return }

        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        // Build vertex data — identical call to MetalSpectrumRenderer.updateNSView
        let sampleRate = processor.sampleRate
        let nyquist    = sampleRate / 2.0
        let maxFreq    = min(20_000.0, nyquist)
        let (vertexData, vertexCount) = SpectrumMeshBuilder.makeSpectrumVertices(
            processor: processor,
            minFrequency: 20.0,
            maxFrequency: maxFreq
        )
        guard vertexCount > 0 else { return }

        // makeSpectrumVertices produces 2 triangles (6 vertices of 3 floats) per bin.
        // Vertex layout per group of 6:
        //   [0] bottom-left  (x, -1.0, intensity)
        //   [1] top-left     (x, y,    intensity)  ← spectrum peak this bin
        //   [2] top-right    (nextX, nextY, nextI)
        //   [3] bottom-left  (repeat)
        //   [4] top-right    (repeat)
        //   [5] bottom-right (nextX, -1.0, nextI)
        let floatsPerVertex = 3
        let verticesPerBin  = 6
        let floatsPerBin    = floatsPerVertex * verticesPerBin   // 18
        let binCount        = vertexData.count / floatsPerBin

        // --- Collect the top (peak) vertex for each bin ---
        // Top-left of bin i is at index [i * 18 + 3], [i * 18 + 4]  (x, y in NDC)
        var peakPoints = [CGPoint]()
        peakPoints.reserveCapacity(binCount + 1)

        for i in 0..<binCount {
            let base = i * floatsPerBin
            let ndcX = CGFloat(vertexData[base + 3])   // top-left x
            let ndcY = CGFloat(vertexData[base + 4])   // top-left y
            peakPoints.append(ndcToView(ndcX, ndcY, w: w, h: h))
        }

        // Append the top-right of the last bin to close the outline cleanly
        if binCount > 0 {
            let lastBase = (binCount - 1) * floatsPerBin
            let ndcX = CGFloat(vertexData[lastBase + 6])  // top-right x (vertex[2])
            let ndcY = CGFloat(vertexData[lastBase + 7])  // top-right y
            peakPoints.append(ndcToView(ndcX, ndcY, w: w, h: h))
        }

        guard peakPoints.count > 1 else { return }

        let themeIndex = spectrumThemeIndex(for: themeMode)
        let themeColor = spectrumThemeColor(for: themeIndex)
        let baseShadow = spectrumBaseShadow(for: themeIndex)
        let orange = NSColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0)
        let red = NSColor(red: 0.85, green: 0.0, blue: 0.0, alpha: 1.0)

        // --- Filled area from y=0 (bottom) up to the spectrum curve ---
        let fillPath = CGMutablePath()
        fillPath.move(to: CGPoint(x: peakPoints[0].x, y: 0))
        for pt in peakPoints { fillPath.addLine(to: pt) }
        fillPath.addLine(to: CGPoint(x: peakPoints.last!.x, y: 0))
        fillPath.closeSubpath()

        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                baseShadow.cgColor,
                themeColor.cgColor,
                themeColor.cgColor,
                orange.cgColor,
                red.cgColor
            ] as CFArray,
            locations: [0.0, 0.3, 0.48, 0.6, 1.0]
        ) {
            ctx.saveGState()
            ctx.addPath(fillPath)
            ctx.clip()
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: h),
                options: []
            )
            ctx.restoreGState()
        }

        // --- Spectrum outline ---
        ctx.beginPath()
        ctx.move(to: peakPoints[0])
        for pt in peakPoints.dropFirst() { ctx.addLine(to: pt) }
        ctx.setStrokeColor(themeColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
    }

    private func spectrumThemeIndex(for mode: ThemeMode) -> Int {
        switch SpectrumThemeMode(from: mode) {
        case .light: return 0
        case .dark, .midnight: return 1
        case .thinMaterial: return 2
        case .liquidGlass: return 3
        case .purple: return 4
        case .mint: return 5
        case .lavender: return 6
        case .indigo: return 7
        case .gray: return 8
        case .hollow: return 9
        }
    }

    private func spectrumThemeColor(for index: Int) -> NSColor {
        switch index {
        case 1: return NSColor(red: 0.0, green: 0.2, blue: 0.6, alpha: 1.0)
        case 2: return NSColor(red: 0.0, green: 0.3, blue: 0.3, alpha: 1.0)
        case 3: return NSColor(red: 0.6, green: 0.3, blue: 0.6, alpha: 1.0)
        case 4: return NSColor(red: 0.3, green: 0.0, blue: 0.4, alpha: 1.0)
        case 5: return NSColor(red: 0.3, green: 0.6, blue: 0.3, alpha: 1.0)
        case 6: return NSColor(red: 0.5, green: 0.3, blue: 0.6, alpha: 1.0)
        case 7: return NSColor(red: 0.2, green: 0.2, blue: 0.5, alpha: 1.0)
        case 8: return NSColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)
        case 9: return NSColor.clear
        default: return NSColor(red: 0.1, green: 0.4, blue: 0.1, alpha: 1.0)
        }
    }

    private func spectrumBaseShadow(for index: Int) -> NSColor {
        switch index {
        case 0: return NSColor(red: 0.0, green: 0.3, blue: 0.0, alpha: 1.0)
        case 1: return NSColor(red: 0.0, green: 0.2, blue: 0.6, alpha: 1.0)
        case 2: return NSColor(red: 0.0, green: 0.3, blue: 0.3, alpha: 1.0)
        case 3: return NSColor(red: 0.2, green: 0.1, blue: 0.2, alpha: 1.0)
        case 4: return NSColor(red: 0.3, green: 0.0, blue: 0.4, alpha: 1.0)
        case 5: return NSColor(red: 0.3, green: 0.6, blue: 0.3, alpha: 1.0)
        case 6: return NSColor(red: 0.5, green: 0.3, blue: 0.6, alpha: 1.0)
        case 7: return NSColor(red: 0.2, green: 0.2, blue: 0.5, alpha: 1.0)
        case 8: return NSColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1.0)
        case 9: return NSColor.clear
        default: return NSColor(red: 0.1, green: 0.4, blue: 0.1, alpha: 1.0)
        }
    }

    // MARK: Coordinate conversion

    /// Converts NDC [-1, 1] to AppKit/CG view coordinates (origin = bottom-left).
    private func ndcToView(_ ndcX: CGFloat, _ ndcY: CGFloat, w: CGFloat, h: CGFloat) -> CGPoint {
        let viewX = (ndcX + 1.0) * 0.5 * w
        let viewY = (ndcY + 1.0) * 0.5 * h           // y=0 at bottom in CG
        return CGPoint(x: viewX, y: max(0, min(h, viewY)))
    }
}
