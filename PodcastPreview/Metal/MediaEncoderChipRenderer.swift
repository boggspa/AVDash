import SwiftUI
import Combine
import MetalKit
import simd
import PodcastPreviewCore

private final class TransparentMediaEncoderChipMTKView: MTKView {
    override var isOpaque: Bool { false }
}

final class MediaEncoderGPUStats: ObservableObject {
    static let shared = MediaEncoderGPUStats()

    @Published private(set) var submittedCommandBuffers: Int = 0
    @Published private(set) var completedCommandBuffers: Int = 0

    private init() {}

    func recordSubmitted() {
        DispatchQueue.main.async {
            self.submittedCommandBuffers += 1
        }
    }

    func recordCompleted() {
        DispatchQueue.main.async {
            self.completedCommandBuffers += 1
        }
    }
}

struct MediaEncoderChipMetalView: NSViewRepresentable {
    let activityState: MediaEngineStatsSampler.ActivityState
    let activityValue: Float
    let cornerRadius: CGFloat
    let symbolName: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = TransparentMediaEncoderChipMTKView(frame: .zero, device: device)
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.framebufferOnly = false
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 30
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.colorPixelFormat = .bgra8Unorm
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.isOpaque = false
            metalLayer.backgroundColor = NSColor.clear.cgColor
        }

        context.coordinator.attach(to: view)
        context.coordinator.renderer?.update(
            activityState: activityState,
            activityValue: activityValue,
            cornerRadius: Float(cornerRadius),
            symbolName: symbolName
        )
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.renderer?.update(
            activityState: activityState,
            activityValue: activityValue,
            cornerRadius: Float(cornerRadius),
            symbolName: symbolName
        )
    }

    final class Coordinator {
        fileprivate var renderer: MediaEncoderChipRenderer?

        func attach(to view: MTKView) {
            guard renderer == nil else {
                view.delegate = renderer
                return
            }

            guard let renderer = MediaEncoderChipRenderer(mtkView: view) else { return }
            self.renderer = renderer
            view.delegate = renderer
        }
    }
}

fileprivate final class MediaEncoderChipRenderer: NSObject, MTKViewDelegate {
    private struct Uniforms {
        var viewportSize: SIMD2<Float>
        var glowColor: SIMD4<Float>
        var intensity: Float
        var cornerRadius: Float
        var time: Float
        var active: Float
        var padding: SIMD2<Float>
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var symbolTexture: MTLTexture?
    private var startTime = CACurrentMediaTime()
    private var currentState: MediaEngineStatsSampler.ActivityState = .idle
    private var currentValue: Float = 0.0
    private var currentCornerRadius: Float = 14.0
    private var currentSymbolName: String = "cpu"

    init?(mtkView: MTKView) {
        let compilerCache = HardwareMetalCompilerCache.shared
        guard let device = compilerCache.device,
              let queue = compilerCache.commandQueue,
              let pipelineState = compilerCache.pipelineState(
                vertexFunctionName: "mediaEncoderChipVertex",
                fragmentFunctionName: "mediaEncoderChipFragment",
                pixelFormat: .bgra8Unorm,
                blendingMode: .alphaBlend
              ) else {
            return nil
        }

        self.device = device
        self.commandQueue = queue
        self.pipelineState = pipelineState

        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if let metalLayer = mtkView.layer as? CAMetalLayer {
            metalLayer.isOpaque = false
            metalLayer.backgroundColor = NSColor.clear.cgColor
        }

        super.init()
        mtkView.delegate = self
    }

    func update(activityState: MediaEngineStatsSampler.ActivityState, activityValue: Float, cornerRadius: Float, symbolName: String) {
        currentState = activityState
        currentValue = activityValue
        currentCornerRadius = cornerRadius
        if currentSymbolName != symbolName || symbolTexture == nil {
            currentSymbolName = symbolName
            symbolTexture = makeSymbolTexture(named: symbolName)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else { return }

        let commandBuffer = commandQueue.makeCommandBuffer()
        guard let commandBuffer else { return }
        MediaEncoderGPUStats.shared.recordSubmitted()

        let elapsed = Float(CACurrentMediaTime() - startTime)
        let glowColor: SIMD4<Float>
        let intensity: Float
        let active: Float

        switch currentState {
        case .idle:
            glowColor = SIMD4<Float>(0.10, 0.10, 0.22, 0.0)
            intensity = 0.0
            active = 0.0
        case .active:
            glowColor = SIMD4<Float>(0.30, 0.29, 0.78, 1.0)
            intensity = max(0.18, min(currentValue, 0.46))
            active = 1.0
        case .busy:
            glowColor = SIMD4<Float>(0.42, 0.41, 0.95, 1.0)
            intensity = max(0.34, min(currentValue, 0.68))
            active = 1.0
        @unknown default:
            glowColor = SIMD4<Float>(0.2, 0.2, 0.2, 1.0)
            intensity = 0.0
            active = 0.0
        }

        var uniforms = Uniforms(
            viewportSize: SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            glowColor: glowColor,
            intensity: intensity,
            cornerRadius: currentCornerRadius,
            time: elapsed,
            active: active,
            padding: SIMD2<Float>(10.0, 10.0)
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            commandBuffer.commit()
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        if let symbolTexture {
            encoder.setFragmentTexture(symbolTexture, index: 0)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { _ in
            MediaEncoderGPUStats.shared.recordCompleted()
        }
        commandBuffer.commit()
    }

    private func makeSymbolTexture(named symbolName: String) -> MTLTexture? {
        let pointSize: CGFloat = 72
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration) else {
            return nil
        }

        let size = NSSize(width: pointSize, height: pointSize)
        let renderedImage = NSImage(size: size)
        renderedImage.lockFocus()
        NSColor(red: 0.37, green: 0.36, blue: 0.90, alpha: 1.0).set()
        image.draw(in: NSRect(origin: .zero, size: size))
        renderedImage.unlockFocus()

        guard let tiffData = renderedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else {
            return nil
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitsPerComponent = 8
        var rawData = [UInt8](repeating: 0, count: Int(height * bytesPerRow))

        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        rawData.withUnsafeBytes { bytes in
            if let baseAddress = bytes.baseAddress {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: bytesPerRow
                )
            }
        }

        return texture
    }
}
