import SwiftUI
import AppKit

/// CPU-based spectrogram renderer using CGImage bitmap generation.
///
/// Reads the already-normalized [0,1] float history from `SpectroManager`'s
/// history ring buffer and converts it to an `NSImage` via `CGContext` at ~20 fps.
/// This is the compatibility-mode replacement for `MetalSpectroRenderer` /
/// `SpectroContainerView` on machines with weaker GPUs.
///
/// Session lifecycle mirrors `SpectroContainerView`:
///   - `acquireSpectrogramSession` is called by the parent before this view is shown
///   - `onDisappear` stops the external feed and calls `releaseSpectrogramSession`
struct CPUSpectrogramView: View {
    // MARK: - Properties

    let deviceID: Int32
    let channelIndex: Int32
    let themeColor: SIMD4<Float>
    let themeMode: Int32
    let externalAudioSource: FFTAudioSource?

    // MARK: - State
    // MARK: - State

    @State private var spectroImage: NSImage? = nil
    @State private var externalFeed: MixerSpectrogramFeed? = nil

    // Tick at 20 fps — acceptable for the compatibility path
    private let renderTimer = Timer.publish(every: 1.0 / 20.0, on: .main, in: .common).autoconnect()

    // MARK: - Body

    var body: some View {
        Group {
            if let img = spectroImage {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.low)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.black.opacity(0.6)
            }
        }
        .onAppear {
            // Start external mixer feed if one was provided (mirrors SpectroContainerView)
            if let source = externalAudioSource {
                let feed = MixerSpectrogramFeed(source: source, deviceID: deviceID, channelIndex: channelIndex)
                feed.start()
                externalFeed = feed
            }
        }
        .onDisappear {
            externalFeed?.stop()
            externalFeed = nil
            SpectroManager.shared.releaseSpectrogramSession(
                deviceID: UInt32(deviceID),
                channel: channelIndex
            )
        }
        .onReceive(renderTimer) { _ in
            rebuildImage()
        }
    }

    // MARK: - Image Generation

    private func rebuildImage() {
        guard let histBuf = SpectroManager.shared.historyRingBuffer(for: deviceID, channel: channelIndex) else { return }

        var filledFrames = 0
        var numBins = 0
        guard let ptr = SpectroManager.shared.getLinearSnapshot(
            histBuf,
            maxFrames: SpectroManager.spectrogramDisplayFrames,
            outFrames: &filledFrames,
            outHeight: &numBins
        ), filledFrames > 0, numBins > 0 else { return }

        // Data layout: ptr[bin * filledFrames + frame]
        // Each value is already normalized to [0, 1] by SpectroProcessor.
        let width    = filledFrames
        let height   = numBins
        let bytesPerPixel = 4
        let bytesPerRow   = width * bytesPerPixel

        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        // Match MetalSpectroShader frequency mapping:
        // screenFrac 0..1 -> frequency 20Hz..12.5kHz -> texture Y in [0, 1].
        let fMin: Float = 20.0
        let fMax: Float = 12_500.0
        let nyquist: Float = 24_000.0

        for row in 0..<height {
            let rowDenom = max(height - 1, 1)
            let screenFrac = Float(height - 1 - row) / Float(rowDenom)
            let freq = fMin * pow(fMax / fMin, screenFrac)
            let texY = min(max(freq / nyquist, 0.0), 1.0)

            for col in 0..<width {
                let colDenom = max(width - 1, 1)
                let texX = Float(col) / Float(colDenom)
                let value = sampleBilinear(
                    snapshot: ptr,
                    width: filledFrames,
                    height: numBins,
                    xNorm: texX,
                    yNorm: texY
                )
                let (r, g, b, a) = heatmapRGBA(value)
                let offset = row * bytesPerRow + col * bytesPerPixel
                pixels[offset + 0] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
                pixels[offset + 3] = a
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = ctx.makeImage() else { return }

        spectroImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    // MARK: - Colour Mapping

    /// Maps a normalized intensity [0,1] to an RGBA tuple using the same
    /// transfer function as `fragment_spectrogram` in MetalSpectroShader.metal.
    private func heatmapRGBA(_ v: Float) -> (UInt8, UInt8, UInt8, UInt8) {
        let gain = min(max(v, 0), 1)

        let themeRGB = SIMD3<Float>(themeColor.x, themeColor.y, themeColor.z)
        let baseShadow = baseShadowColor(for: themeMode)
        let orange = SIMD3<Float>(1.0, 0.5, 0.0)
        let red = SIMD3<Float>(0.85, 0.0, 0.0)

        let rgb: SIMD3<Float>
        let alpha: Float

        if gain < 0.01 {
            rgb = SIMD3<Float>(0, 0, 0)
            alpha = 0.0
        } else if gain < 0.15 {
            let t = smoothstep(0.01, 0.15, gain)
            rgb = mix(baseShadow, themeRGB, t)
            alpha = mix(0.2, 1.0, t)
        } else if gain < 0.5 {
            let t = smoothstep(0.15, 0.5, gain)
            rgb = mix(themeRGB, orange, t)
            alpha = 1.0
        } else {
            let t = smoothstep(0.5, 1.0, gain)
            rgb = mix(orange, red, t)
            alpha = 1.0
        }

        return (
            UInt8(min(max(rgb.x * 255.0, 0.0), 255.0)),
            UInt8(min(max(rgb.y * 255.0, 0.0), 255.0)),
            UInt8(min(max(rgb.z * 255.0, 0.0), 255.0)),
            UInt8(min(max(alpha * 255.0, 0.0), 255.0))
        )
    }

    private func sampleBilinear(
        snapshot: UnsafePointer<Float>,
        width: Int,
        height: Int,
        xNorm: Float,
        yNorm: Float
    ) -> Float {
        guard width > 0, height > 0 else { return 0.0 }

        let fx = min(max(xNorm, 0.0), 1.0) * Float(max(width - 1, 1))
        let fy = min(max(yNorm, 0.0), 1.0) * Float(max(height - 1, 1))

        let x0 = max(0, min(width - 1, Int(floor(fx))))
        let y0 = max(0, min(height - 1, Int(floor(fy))))
        let x1 = min(width - 1, x0 + 1)
        let y1 = min(height - 1, y0 + 1)

        let tx = fx - Float(x0)
        let ty = fy - Float(y0)

        let i00 = snapshot[y0 * width + x0]
        let i10 = snapshot[y0 * width + x1]
        let i01 = snapshot[y1 * width + x0]
        let i11 = snapshot[y1 * width + x1]

        let top = i00 + (i10 - i00) * tx
        let bottom = i01 + (i11 - i01) * tx
        return top + (bottom - top) * ty
    }

    private func baseShadowColor(for themeMode: Int32) -> SIMD3<Float> {
        switch themeMode {
        case 0: return SIMD3<Float>(0.0, 0.0, 0.3)  // light
        case 1: return SIMD3<Float>(0.0, 0.2, 0.6)  // dark
        case 2: return SIMD3<Float>(0.0, 0.3, 0.3)  // thinMaterial
        case 3: return SIMD3<Float>(0.3, 0.0, 0.4)  // purple
        case 4: return SIMD3<Float>(0.3, 0.6, 0.3)  // mint
        case 5: return SIMD3<Float>(0.5, 0.3, 0.6)  // lavender
        case 6: return SIMD3<Float>(0.2, 0.2, 0.5)  // indigo
        case 7: return SIMD3<Float>(0.2, 0.2, 0.2)  // gray
        case 8: return SIMD3<Float>(0.0, 0.0, 0.0)  // hollow
        case 9, 10: return SIMD3<Float>(0.3, 0.0, 0.4) // glass themes (purple-ish)
        case 11: return SIMD3<Float>(0.0, 0.1, 0.4) // midnight (deep blue)
        default: return SIMD3<Float>(0.1, 0.4, 0.1)
        }
    }

    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }

    private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float {
        a + (b - a) * t
    }

    private func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / max(edge1 - edge0, 0.0001), 0.0), 1.0)
        return t * t * (3.0 - 2.0 * t)
    }
}
