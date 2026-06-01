//
//  MetalSpectroRenderer.swift
//  AVCMeter
//
//  Created by Chris Izatt on 29/06/2025.
//





import Foundation
import MetalKit
import SwiftUI

private final class SpectroMetalBundleToken: NSObject {}

private func makeSpectrogramLibrary(device: MTLDevice) -> MTLLibrary? {
    let frameworkBundle = Bundle(for: SpectroMetalBundleToken.self)
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
            print("Spectrogram Metal library load failed at \(url.path): \(error)")
        }
    }

    do {
        return try device.makeDefaultLibrary(bundle: frameworkBundle)
    } catch {
        print("Spectrogram default library from framework bundle failed: \(error)")
    }

    do {
        return try device.makeDefaultLibrary(bundle: .main)
    } catch {
        print("Spectrogram default library from main bundle failed: \(error)")
    }

    if let library = device.makeDefaultLibrary() {
        return library
    }

    print("Spectrogram Metal library resolution exhausted with no library found")
    return nil
}

private enum SpectroRendererConfig {
    static let fftBinCount: Int = SpectroManager.fftBinCount
    static var displayFrames: Int { SpectroManager.spectrogramDisplayFrames }
}

/// A simple theme structure for controlling spectrum appearance and theme mode.
struct SpectroVisualTheme {
    var spectrumColor: SIMD4<Float>
    var themeMode: Int32
}

/// Represents a single vertex in the spectrogram, containing 2D position and intensity.
struct SpectroVertex {
    var position: SIMD2<Float>
    var intensity: Float
}

/// Metal renderer responsible for drawing the audio spectrogram using triangle strip geometry.
final class MetalSpectroRenderer: NSObject, MTKViewDelegate {
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    private var vertexBuffer: MTLBuffer?
    /// Sampler state for sampling the spectrogram scroll texture in the fragment shader
    private var samplerState: MTLSamplerState!
    private var spectroTexture: MTLTexture!
    private var theme: SpectroVisualTheme
    private var vertexCount: Int = 0
    private var deviceID: Int32
    private var channelIndex: Int32
    /// Device sample rate used for log-frequency Y axis mapping (default 48 kHz)
    private var sampleRate: Float = 48000.0

    var onFrameUpdate: ((Int) -> Void)?

    // MARK: - Scroll‑Texture Tail Properties
    /// Number of visible time columns (30-second display window).
    private let displayFrames: Int = SpectroRendererConfig.displayFrames
    /// Number of frequency bins (vertical resolution).
    private let numBins: Int = SpectroRendererConfig.fftBinCount / 2
    /// Throttle texture uploads
    private var lastTextureUpdate: CFTimeInterval = 0
    private let textureUpdateInterval: CFTimeInterval = 1.0 / 30.0
    /// Fraction of the texture that contains real data (0→1 as buffer fills)
    private var writeIndexNorm: Float = 0.0

    // MARK: - Initialization

    /// Initializes the MetalSpectroRenderer and configures the Metal pipeline.
    ///
    /// - Parameters:
    ///   - mtkView: The MTKView where the rendering will occur.
    ///   - theme: A visual theme to apply to the spectrum.
    ///   - deviceID: Identifier for the audio device.
    ///   - channelIndex: Audio channel index to monitor.
    init(mtkView: MTKView, theme: SpectroVisualTheme, deviceID: Int32, channelIndex: Int32) {
        self.device = mtkView.device
        self.commandQueue = device.makeCommandQueue()
        self.theme = theme
        self.deviceID = deviceID
        self.channelIndex = channelIndex
        super.init()
        mtkView.delegate = self
        mtkView.colorPixelFormat = .bgra8Unorm

        mtkView.layer?.isOpaque = false
        mtkView.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0

        vertexDescriptor.attributes[1].format = .float
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0

        vertexDescriptor.layouts[0].stride = MemoryLayout<SpectroVertex>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        pipelineDescriptor.vertexDescriptor = vertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat

        // Compile pipeline state asynchronously
        guard let library = makeSpectrogramLibrary(device: device),
              let vertFn = library.makeFunction(name: "vertex_fullscreen"),
              let fragFn = library.makeFunction(name: "fragment_spectrogram")
        else {
            print("Failed to load Metal shader functions")
            return
        }
        pipelineDescriptor.vertexFunction = vertFn
        pipelineDescriptor.fragmentFunction = fragFn

        // Create pipeline synchronously so we can catch errors immediately
        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create pipeline state:", error)
            self.pipelineState = nil
        }

        // MARK: - Scroll‑Texture Tail Setup
        // Allocate a single‑channel float texture for our scrolling spectrogram tail (30-second window).
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: displayFrames,
            height: numBins,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        self.spectroTexture = device.makeTexture(descriptor: desc)


        // Create a default sampler for the spectrogram texture
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        self.samplerState = device.makeSamplerState(descriptor: samplerDescriptor)

        // Prepare a 3‑vertex full‑screen triangle for sampling the scroll texture.
        let quadVerts: [SpectroVertex] = [
            SpectroVertex(position: [-1, -1], intensity: 0),
            SpectroVertex(position: [ 3, -1], intensity: 0),
            SpectroVertex(position: [-1,  3], intensity: 0),
        ]
        self.updateVertexBuffer(vertices: quadVerts)
    }

    // MARK: - Theme Update

    /// Updates the rendering theme dynamically.
    ///
    /// - Parameter newTheme: A new `SpectroVisualTheme` to apply.
    func updateTheme(_ newTheme: SpectroVisualTheme) {
        self.theme = newTheme
    }

    // MARK: - Vertex Buffer Update

    /// Updates the Metal vertex buffer with the new geometry data.
    ///
    /// - Parameter vertices: The array of `SpectroVertex` data to copy to the GPU.
    func updateVertexBuffer(vertices: [SpectroVertex]) {
        vertexCount = vertices.count
        guard vertexCount > 0 else {
            vertexBuffer = nil
            return
        }

        let length = vertexCount * MemoryLayout<SpectroVertex>.stride
        if vertexBuffer == nil || vertexBuffer!.length < length {
            vertexBuffer = device.makeBuffer(length: length, options: .storageModeShared)
        }
        if let buf = vertexBuffer {
            memcpy(buf.contents(), vertices, length)
        }
    }

    /// Uploads the latest snapshot into the scroll texture (right-anchored: newest data at right edge).
    private func updateTexture() {
        guard let historyBuffer = SpectroManager.shared.historyRingBuffer(for: deviceID, channel: channelIndex) else { return }
        var filledFrames = 0
        var numBins = 0
        guard let snapshot = SpectroManager.shared.getLinearSnapshot(
            historyBuffer,
            maxFrames: displayFrames,
            outFrames: &filledFrames,
            outHeight: &numBins
        ), filledFrames > 0 else { return }

        if spectroTexture == nil || spectroTexture?.width != displayFrames || spectroTexture?.height != numBins {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Float,
                width: displayFrames,
                height: numBins,
                mipmapped: false
            )
            desc.usage = [MTLTextureUsage.shaderRead, MTLTextureUsage.shaderWrite]
            spectroTexture = device.makeTexture(descriptor: desc)
        }

        // Left-anchored during fill, naturally transitions to full-width scroll once buffer is full.
        // Newest data is always at the rightmost filled column; once full it becomes the far-right edge.
        if let texture = spectroTexture, texture.width == displayFrames && texture.height == numBins {
            let region = MTLRegionMake2D(0, 0, filledFrames, numBins)
            let bytesPerRow = MemoryLayout<Float>.stride * filledFrames
            texture.replace(region: region, mipmapLevel: 0, withBytes: snapshot, bytesPerRow: bytesPerRow)
        }

        writeIndexNorm = Float(min(filledFrames, displayFrames)) / Float(displayFrames)
    }

    /// Responds to view size changes, if needed.
    ///
    /// - Parameters:
    ///   - view: The `MTKView` being resized.
    ///   - size: The new drawable size.
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Resize-related logic can go here
    }

    /// Single‑draw, GPU‑driven scrolling spectrogram tail.
    func draw(in view: MTKView) {
        guard let drawable   = view.currentDrawable,
              let passDesc   = view.currentRenderPassDescriptor,
              let cmdBuf     = commandQueue.makeCommandBuffer(),
              let encoder    = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc)
        else { return }
        // ensure pipeline is ready
        guard let pState = pipelineState else {
            encoder.endEncoding()
            cmdBuf.commit()
            return
        }

        // Throttle texture uploads to ~30fps; always continue to render even if no new data
        let now = CACurrentMediaTime()
        if now - lastTextureUpdate >= textureUpdateInterval {
            lastTextureUpdate = now
            updateTexture()
        }

        encoder.setRenderPipelineState(pState)
        if let vb = vertexBuffer {
            encoder.setVertexBuffer(vb, offset: 0, index: 0)
        }
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setFragmentTexture(spectroTexture, index: 0)
        encoder.setFragmentBytes(&theme.spectrumColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        var uMode = theme.themeMode
        encoder.setFragmentBytes(&uMode, length: MemoryLayout<Int32>.stride, index: 1)
        encoder.setFragmentBytes(&sampleRate, length: MemoryLayout<Float>.stride, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}
