import Foundation
import CoreAudio
import MetalKit
import simd
import SwiftUI
import Combine
#if os(macOS)
import AppKit
#endif

private final class WaveformMetalBundleToken: NSObject {}

private func makeWaveformLibrary(device: MTLDevice) -> MTLLibrary? {
    let frameworkBundle = Bundle(for: WaveformMetalBundleToken.self)
    var candidateURLs: [URL] = []

    if let frameworkURL = frameworkBundle.url(forResource: "default", withExtension: "metallib") {
        candidateURLs.append(frameworkURL)
    }

    if let privateFrameworksURL = Bundle.main.privateFrameworksURL {
        let fallbackURL = privateFrameworksURL
            .appendingPathComponent("AVCMeterKit.framework")
            .appendingPathComponent("Resources")
            .appendingPathComponent("default.metallib")
        candidateURLs.append(fallbackURL)
    }

    if let mainBundleURL = Bundle.main.url(forResource: "default", withExtension: "metallib") {
        candidateURLs.append(mainBundleURL)
    }

    for url in candidateURLs {
        do {
            return try device.makeLibrary(URL: url)
        } catch {
            print("Waveform Metal library load failed at \(url.path): \(error)")
        }
    }

    do {
        return try device.makeDefaultLibrary(bundle: frameworkBundle)
    } catch {
        print("Waveform default library from framework bundle failed: \(error)")
    }

    do {
        return try device.makeDefaultLibrary(bundle: .main)
    } catch {
        print("Waveform default library from main bundle failed: \(error)")
    }

    if let library = device.makeDefaultLibrary() {
        return library
    }

    print("Waveform Metal library resolution exhausted with no library found")
    return nil
}


class AudioSampleBuffer: ObservableObject {
    @Published var samples: [Float] = []
    @Published var cachedVertices: [SIMD2<Float>] = []
    @Published var cachedColors: [SIMD4<Float>] = []

    func getSamples() -> [Float] {
        return samples
    }
}

protocol WaveformAudioSource: AnyObject {
    func readSamples(frameCount: Int) -> [Float]
    func stop() throws
}

extension MixerVisualizerAudioSource: WaveformAudioSource {}
extension VirtualInstrumentPreFaderAudioSource: WaveformAudioSource {}

enum WaveformThemeMode: Int {
    case dark, light, thinMaterial, midnight, purple, mint, lavender, indigo, gray, hollow

    init?(themeMode: ThemeMode) {
        self.init(rawValue: themeMode.rawValue)
    }
}

func waveformLineColor(for themeMode: WaveformThemeMode) -> Color {
    switch themeMode {
    case .dark, .midnight:
        return Color(red: 0.1, green: 0.6, blue: 0.1)
    case .light:
        return Color(red: 0.1, green: 0.4, blue: 0.9)
    case .thinMaterial:
        return Color.green.opacity(0.8)
    case .purple:
        return Color.purple.opacity(0.8)
    case .mint:
        return Color(red: 0.62, green: 0.96, blue: 0.78).opacity(0.8)
    case .lavender:
        return Color(red: 0.75, green: 0.6, blue: 0.9)
    case .indigo:
        return Color(red: 0.29, green: 0.0, blue: 0.51).opacity(0.8)
    case .gray:
        return Color.gray.opacity(0.7)
    case .hollow:
        return Color.clear
    }
}

func waveformThemeColor(for themeMode: WaveformThemeMode) -> Color {
    return waveformLineColor(for: themeMode)
}

extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        return max(min(self, range.upperBound), range.lowerBound)
    }
}

// Update WaveformView to accept theme mode
struct WaveformView: View {
    @StateObject private var buffer: AudioSampleBuffer
    @ObservedObject private var visualisationSettings = VisualisationSettings.shared
    @State private var viewWidth: CGFloat = 1.0
    @State private var isActive = false
    var deviceID: AudioDeviceID
    var channelIndex: Int
    var themeMode: WaveformThemeMode
    var deviceName: String
    var mixerAudioSource: WaveformAudioSource?
    /// Called when the close button is tapped
    var onClose: (() -> Void)? = nil
    var scale: CGFloat

    /// Display settings for waveform timescale
    private let sampleRate = 48_000
    private static let updateInterval: TimeInterval = 1.0 / 30.0
    private let waveformTimer = Timer.publish(every: WaveformView.updateInterval, on: .main, in: .common).autoconnect()
    private var maxSamples: Int {
        max(1, visualisationSettings.waveformDurationSeconds) * sampleRate
    }

    init(
        buffer: AudioSampleBuffer,
        deviceID: AudioDeviceID,
        channelIndex: Int,
        themeMode: WaveformThemeMode,
        deviceName: String,
        mixerAudioSource: WaveformAudioSource? = nil,
        onClose: (() -> Void)? = nil,
        scale: CGFloat = 1.0
    ) {
        _buffer = StateObject(wrappedValue: buffer)
        self.deviceID = deviceID
        self.channelIndex = channelIndex
        self.themeMode = themeMode
        self.deviceName = deviceName
        self.mixerAudioSource = mixerAudioSource
        self.onClose = onClose ?? {
            #if os(macOS)
            NSApp.keyWindow?.close()
            #endif
        }
        self.scale = scale
    }


    var body: some View {
        GeometryReader { geo in
            // Update viewWidth whenever the size changes
            Color.clear.onAppear { viewWidth = geo.size.width }
                        .onChange(of: geo.size) { newSize in viewWidth = newSize.width }
            ZStack {
                ZStack(alignment: .top) {
                    // --- Renderer selection ---
                    // visualisationSettings is already observed; body re-evaluates on mode change.
                    if RenderBackendResolver.resolveWaveformBackend() == .cpu {
                        CPUWaveformRenderer(audioData: buffer, themeMode: themeMode)
                            .frame(maxWidth: .infinity, maxHeight: 170)
                            .clipped()
                    } else {
                        MetalWaveformRenderer(audioData: buffer, themeMode: themeMode)
                            .frame(maxWidth: .infinity, maxHeight: 170)
                            .clipped()
                    }

                    Text("\(deviceName) – Channel \(channelIndex + 1)")
                        .font(.system(size: 18 * scale, weight: .bold))
                        .foregroundColor(.primary)
                        .padding(.top, 8)
                }
                // Close button in top-right
                VStack {
                    HStack {
                        Spacer()
                        Button(action: {
                            #if os(macOS)
                            onClose?()  // call the passed-in close handler
                            #endif
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(4)
                    }
                    Spacer()
                }
            }
        }
        .onAppear {
            isActive = true
            buffer.samples = Array(repeating: 0.0, count: maxSamples)
            rebuildWaveformVertices(from: buffer.samples)
            if mixerAudioSource == nil {
                WaveformStreamManager.shared.startStream(for: deviceID, channelIndex: channelIndex)
            }
        }
        .onDisappear {
            isActive = false
            buffer.samples.removeAll()
            buffer.cachedVertices.removeAll()
            buffer.cachedColors.removeAll()
            if mixerAudioSource == nil {
                WaveformStreamManager.shared.clearSampleArrays(for: deviceID, channelIndex: channelIndex)
                WaveformStreamManager.shared.stopStream(for: deviceID, channelIndex: channelIndex)
            } else {
                try? mixerAudioSource?.stop()
            }
        }
        .onReceive(waveformTimer) { _ in
            guard isActive else { return }
            let expectedFrames = max(256, Int(Float(sampleRate) * Float(WaveformView.updateInterval) * 1.25))
            let incoming: [Float]
            if let mixerAudioSource {
                incoming = mixerAudioSource.readSamples(frameCount: expectedFrames)
            } else {
                incoming = WaveformStreamManager.shared.fetchSamples(
                    for: deviceID,
                    channelIndex: channelIndex,
                    frameCount: expectedFrames
                )
            }
            var history = buffer.samples
            if !incoming.isEmpty {
                history.append(contentsOf: incoming)
            }
            if history.count > maxSamples {
                history.removeFirst(history.count - maxSamples)
            } else if history.count < maxSamples {
                let padding = Array(repeating: Float(0.0), count: maxSamples - history.count)
                history = padding + history
            }
            buffer.samples = history
            rebuildWaveformVertices(from: history)
        }
        .onChange(of: viewWidth) { _ in
            rebuildWaveformVertices(from: buffer.samples)
        }
        .onChange(of: visualisationSettings.waveformDurationSeconds) { _ in
            var history = buffer.samples
            if history.count > maxSamples {
                history.removeFirst(history.count - maxSamples)
            } else if history.count < maxSamples {
                let padding = Array(repeating: Float(0.0), count: maxSamples - history.count)
                history = padding + history
            }
            buffer.samples = history
            rebuildWaveformVertices(from: history)
        }
    }

    private func rebuildWaveformVertices(from history: [Float]) {
        let pixelWidth = max(8, Int(viewWidth.rounded(.down)))
        let samples = history.isEmpty ? [Float(0.0)] : history
        let sampleCount = samples.count
        let samplesPerPixel = max(1.0, Float(sampleCount) / Float(pixelWidth))
        let verticalScale: Float = 2.2

        let base = waveformThemeColor(for: themeMode)
        let nsBase = NSColor(base).usingColorSpace(.deviceRGB) ?? .white
        let baseColor = SIMD4<Float>(
            Float(nsBase.redComponent),
            Float(nsBase.greenComponent),
            Float(nsBase.blueComponent),
            Float(nsBase.alphaComponent)
        )

        var vertices: [SIMD2<Float>] = []
        var colors: [SIMD4<Float>] = []
        vertices.reserveCapacity(pixelWidth * 2)
        colors.reserveCapacity(pixelWidth * 2)

        for px in 0..<pixelWidth {
            let start = min(sampleCount - 1, Int(Float(px) * samplesPerPixel))
            let end = min(sampleCount, max(start + 1, Int(Float(px + 1) * samplesPerPixel)))

            var minY = Float.greatestFiniteMagnitude
            var maxY = -Float.greatestFiniteMagnitude
            for idx in start..<end {
                let y = (samples[idx] * verticalScale).clamped(to: -1.0...1.0)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
            if !minY.isFinite || !maxY.isFinite {
                minY = 0.0
                maxY = 0.0
            }

            let x = (Float(px) / Float(max(pixelWidth - 1, 1))) * 2.0 - 1.0
            vertices.append(SIMD2<Float>(x, minY))
            vertices.append(SIMD2<Float>(x, maxY))

            let magnitude = max(abs(minY), abs(maxY))
            let color = colorVector(for: magnitude, baseColor: baseColor)
            colors.append(color)
            colors.append(color)
        }

        buffer.cachedVertices = vertices
        buffer.cachedColors = colors
    }

    private func colorVector(for magnitude: Float, baseColor: SIMD4<Float>) -> SIMD4<Float> {
        if magnitude >= 1.0 {
            return SIMD4<Float>(1.0, 0.1, 0.1, baseColor.w)
        }
        if magnitude >= 0.85 {
            let t = (magnitude - 0.85) / 0.15
            let orange = SIMD4<Float>(1.0, 0.5, 0.0, baseColor.w)
            return baseColor + t * (orange - baseColor)
        }
        return baseColor
    }
}

// Update MetalWaveformRenderer to receive themeMode
struct MetalWaveformRenderer: NSViewRepresentable {
    var audioData: AudioSampleBuffer
    var themeMode: WaveformThemeMode

    func makeNSView(context: Context) -> NSView {
        let mtkView = MTKView()
        mtkView.preferredFramesPerSecond = 60
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.clearColor = MTLClearColorMake(0, 0, 0, 0)
        mtkView.framebufferOnly = false
        mtkView.wantsLayer = true
        mtkView.layer?.isOpaque = false
        mtkView.layer?.backgroundColor = NSColor.clear.cgColor
        mtkView.delegate = context.coordinator
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        return mtkView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let mtkView = nsView as? MTKView {
            context.coordinator.themeMode = themeMode
            mtkView.setNeedsDisplay(mtkView.bounds)
        }
    }

    func makeCoordinator() -> Renderer {
        return Renderer(audioData: audioData, themeMode: themeMode)
    }

    class Renderer: NSObject, MTKViewDelegate {
        var audioData: AudioSampleBuffer
        var device: MTLDevice!
        var commandQueue: MTLCommandQueue!
        var vertexBuffer: MTLBuffer?
        private var colorBuffer: MTLBuffer?
        var themeMode: WaveformThemeMode
        var currentSamples: [Float] = []
        private var pipelineState: MTLRenderPipelineState?

        init(audioData: AudioSampleBuffer, themeMode: WaveformThemeMode) {
            self.audioData = audioData
            self.themeMode = themeMode
            self.device = MTLCreateSystemDefaultDevice()
            self.commandQueue = device.makeCommandQueue()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor else { return }

            // Always clear the frame to avoid any temporal ghosting artefacts.
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

            let baseVertices = audioData.cachedVertices
            guard baseVertices.count >= 2 else {
                return
            }

            let columnCount = baseVertices.count / 2
            var vertices: [SIMD2<Float>] = []
            var colors: [SIMD4<Float>] = []
            vertices.reserveCapacity(columnCount * 6)
            colors.reserveCapacity(columnCount * 6)

            let baseColors = audioData.cachedColors
            let halfWidth = columnHalfWidth(for: baseVertices)
            let minHeight: Float = 0.006

            for i in 0..<columnCount {
                let lower = baseVertices[i * 2]
                let upper = baseVertices[i * 2 + 1]
                let x = lower.x

                var yMin = min(lower.y, upper.y)
                var yMax = max(lower.y, upper.y)
                if (yMax - yMin) < minHeight {
                    let center = (yMin + yMax) * 0.5
                    yMin = center - minHeight * 0.5
                    yMax = center + minHeight * 0.5
                }

                let left = max(-1.0, x - halfWidth)
                let right = min(1.0, x + halfWidth)
                let color = baseColors.indices.contains(i * 2)
                    ? baseColors[i * 2]
                    : SIMD4<Float>(1.0, 1.0, 1.0, 1.0)

                let v0 = SIMD2<Float>(left, yMin)
                let v1 = SIMD2<Float>(left, yMax)
                let v2 = SIMD2<Float>(right, yMax)
                let v3 = SIMD2<Float>(right, yMin)

                vertices.append(contentsOf: [v0, v1, v2, v0, v2, v3])
                colors.append(contentsOf: [color, color, color, color, color, color])
            }

            let vertexCount = vertices.count
            guard vertexCount > 0 else {
                return
            }

            let dataSize = MemoryLayout<SIMD2<Float>>.stride * vertices.count
            if vertexBuffer == nil || vertexBuffer!.length < dataSize {
                vertexBuffer = device.makeBuffer(length: dataSize, options: [])
            }
            memcpy(vertexBuffer!.contents(), vertices, dataSize)

            let commandBuffer = commandQueue.makeCommandBuffer()
            let encoder = commandBuffer?.makeRenderCommandEncoder(descriptor: descriptor)

            // Cache pipeline state once. Guard shader lookups explicitly so we
            // never call into pipeline creation with nil shader functions.
            if pipelineState == nil {
                guard let library = makeWaveformLibrary(device: device),
                      let vertexFunction = library.makeFunction(name: "vertex_passthrough"),
                      let fragmentFunction = library.makeFunction(name: "fragment_color") else {
                    print("Failed to load waveform Metal shader functions")
                    return
                }

                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertexFunction
                descriptor.fragmentFunction = fragmentFunction
                descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].rgbBlendOperation = .add
                descriptor.colorAttachments[0].alphaBlendOperation = .add
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

                do {
                    pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
                } catch {
                    print("Failed to create waveform pipeline state: \(error)")
                    return
                }
            }
            guard let pipeline = pipelineState else { return }
            encoder?.setRenderPipelineState(pipeline)

            // Reuse a single, pre-allocated color buffer
            let colorDataSize = MemoryLayout<SIMD4<Float>>.stride * colors.count
            if colorBuffer == nil || colorBuffer!.length < colorDataSize {
                colorBuffer = device.makeBuffer(length: colorDataSize, options: [])
            }
            memcpy(colorBuffer!.contents(), colors, colorDataSize)

            encoder?.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder?.setVertexBuffer(colorBuffer, offset: 0, index: 1)
            encoder?.setFragmentBuffer(colorBuffer, offset: 0, index: 0)
            encoder?.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)

            encoder?.endEncoding()
            commandBuffer?.present(drawable)
            commandBuffer?.commit()
        }

        private func columnHalfWidth(for vertices: [SIMD2<Float>]) -> Float {
            guard vertices.count >= 4 else { return 0.0010 }

            var previousX = vertices[0].x
            var minSpacing = Float.greatestFiniteMagnitude
            for i in stride(from: 2, to: vertices.count, by: 2) {
                let spacing = abs(vertices[i].x - previousX)
                if spacing > 0 {
                    minSpacing = min(minSpacing, spacing)
                }
                previousX = vertices[i].x
            }

            guard minSpacing.isFinite, minSpacing > 0 else { return 0.0010 }

            // Keep columns visually thick but never let adjacent quads overlap.
            let desired = minSpacing * 0.45
            let maxSafe = max((minSpacing * 0.5) - 0.0001, 0.0002)
            return min(max(desired, 0.0002), maxSafe)
        }
    }
}


func writeToRingBuffer(_ buffer: UnsafeMutablePointer<PCMRingBuffer>, channelIndex: Int, samples: [Float], stride: Int) {
    samples.withUnsafeBufferPointer { ptr in
        guard let base = ptr.baseAddress else { return }
        writeSingleChannelToRingBuffer(buffer, Int32(channelIndex), base, Int32(samples.count), Int32(stride))
    }
}

// Store waveform sample arrays by device/channel
var sampleArrays: [String: [Float]] = [:]

// Reusable access to the ring buffer for waveform drawing
extension WaveformStreamManager {
    func getRingBuffer(deviceID: AudioDeviceID, channelIndex: Int) -> UnsafeMutablePointer<PCMRingBuffer>? {
        let key = "\(deviceID)-\(channelIndex)"
        return historyBuffers[key]
    }

    func releaseRingBuffer(deviceID: AudioDeviceID, channelIndex: Int) {
        let key = "\(deviceID)-\(channelIndex)"
        if let ptr = historyBuffers[key] {
            ptr.deallocate()
        }
    }

    func clearSampleArrays(for deviceID: AudioDeviceID, channelIndex: Int) {
        let key = "\(deviceID)-\(channelIndex)"
        sampleArrays[key] = nil
    }


}

var historyBuffers: [String: UnsafeMutablePointer<PCMRingBuffer>] = [:]
