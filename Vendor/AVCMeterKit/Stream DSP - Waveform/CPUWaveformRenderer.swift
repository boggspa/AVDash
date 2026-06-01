import SwiftUI
import AppKit

/// CPU-based waveform renderer.
///
/// Consumes the pre-decimated `cachedVertices` and `cachedColors` already built
/// by `WaveformView.rebuildWaveformVertices(from:)`. No additional sample processing
/// is done here — this is a pure drawing layer used in compatibility mode.
///
/// Vertices are stored as min/max pairs in normalized device coordinates [-1, 1].
/// Each pair (index i*2, i*2+1) represents one vertical bar at a given x position.
///
/// Two implementations are compiled:
///   - macOS 12+: SwiftUI `Canvas` (zero-allocation per frame)
///   - macOS 11.x: `NSViewRepresentable` backed by Core Graphics (Big Sur compatible)
struct CPUWaveformRenderer: View {
    @ObservedObject var audioData: AudioSampleBuffer
    var themeMode: WaveformThemeMode

    var body: some View {
        if #available(macOS 12.0, *) {
            CPUWaveformCanvas(audioData: audioData, themeMode: themeMode)
        } else {
            CPUWaveformLegacyView(audioData: audioData, themeMode: themeMode)
        }
    }
}

// MARK: - macOS 12+ path (SwiftUI Canvas)

@available(macOS 12.0, *)
private struct CPUWaveformCanvas: View {
    @ObservedObject var audioData: AudioSampleBuffer
    var themeMode: WaveformThemeMode

    var body: some View {
        Canvas { context, size in
            drawBars(in: context, size: size)
        }
    }

    private func drawBars(in context: GraphicsContext, size: CGSize) {
        let vertices = audioData.cachedVertices
        let colors   = audioData.cachedColors
        let columnCount = vertices.count / 2
        guard columnCount > 0 else { return }

        let w = size.width
        let h = size.height
        let fallbackColor = waveformLineColor(for: themeMode)

        for i in 0..<columnCount {
            let lower = vertices[i * 2]
            let upper = vertices[i * 2 + 1]

            let x    = CGFloat((lower.x + 1.0) / 2.0) * w
            let yTop = CGFloat((1.0 - max(lower.y, upper.y)) / 2.0) * h
            let yBot = CGFloat((1.0 - min(lower.y, upper.y)) / 2.0) * h
            let barH = max(1.5, yBot - yTop)

            let barColor: Color
            if colors.indices.contains(i * 2) {
                let c = colors[i * 2]
                barColor = Color(red: Double(c.x), green: Double(c.y),
                                 blue: Double(c.z), opacity: Double(c.w))
            } else {
                barColor = fallbackColor
            }

            var bar = Path()
            bar.move(to:    CGPoint(x: x, y: yTop))
            bar.addLine(to: CGPoint(x: x, y: yTop + barH))
            context.stroke(bar, with: .color(barColor), lineWidth: 1.5)
        }
    }
}

// MARK: - macOS 11 path (Core Graphics via NSViewRepresentable)

private struct CPUWaveformLegacyView: NSViewRepresentable {
    @ObservedObject var audioData: AudioSampleBuffer
    var themeMode: WaveformThemeMode

    func makeNSView(context: Context) -> WaveformCGView {
        WaveformCGView()
    }

    func updateNSView(_ nsView: WaveformCGView, context: Context) {
        nsView.vertices  = audioData.cachedVertices
        nsView.colors    = audioData.cachedColors
        nsView.themeMode = themeMode
        nsView.needsDisplay = true
    }

    /// Custom NSView that draws waveform bars via Core Graphics.
    final class WaveformCGView: NSView {
        var vertices: [SIMD2<Float>] = []
        var colors:   [SIMD4<Float>] = []
        var themeMode: WaveformThemeMode = .dark

        override var isOpaque: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }

            let columnCount = vertices.count / 2
            guard columnCount > 0 else { return }

            let w = bounds.width
            let h = bounds.height
            let fallback = NSColor(waveformLineColor(for: themeMode))

            ctx.setLineWidth(1.5)

            for i in 0..<columnCount {
                let lower = vertices[i * 2]
                let upper = vertices[i * 2 + 1]

                // NDC → view (Core Graphics: y=0 at bottom, so no vertical flip needed)
                let x    = CGFloat((lower.x + 1.0) / 2.0) * w
                let yBot = CGFloat((min(lower.y, upper.y) + 1.0) / 2.0) * h
                let yTop = CGFloat((max(lower.y, upper.y) + 1.0) / 2.0) * h
                let barH = max(1.5, yTop - yBot)

                if colors.indices.contains(i * 2) {
                    let c = colors[i * 2]
                    ctx.setStrokeColor(CGColor(red: CGFloat(c.x), green: CGFloat(c.y),
                                               blue: CGFloat(c.z), alpha: CGFloat(c.w)))
                } else {
                    ctx.setStrokeColor(fallback.cgColor)
                }

                ctx.move(to:    CGPoint(x: x, y: yBot))
                ctx.addLine(to: CGPoint(x: x, y: yBot + barH))
                ctx.strokePath()
            }
        }
    }
}
