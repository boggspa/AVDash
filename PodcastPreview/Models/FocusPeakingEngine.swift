//
//  FocusPeakingEngine.swift
//  PodcastPreview
//
//  Core focus peaking processor using Metal compute shaders
//

import Foundation
import Metal
import MetalKit
import CoreVideo
import simd
import Observation

// MARK: - Settings & Types

struct FocusPeakingSettings {
    var edgeThreshold: Float = 0.15     // 0.0–1.0 (lower = more sensitive)
    var opacity: Float = 0.7             // Overlay opacity
    var thickness: Int = 1               // Edge dilation radius (pixels)
    var enablePreBlur: Bool = false      // Gaussian blur before detection
    var peakColor: SIMD3<Float> = SIMD3(1.0, 0.0, 0.0) // RGB red
}

enum FocusPeakingError: Error {
    case metalNotAvailable
    case shaderCompilationFailed
    case textureCreationFailed
    case bufferCreationFailed
}

// MARK: - Focus Peaking Engine

@available(macOS 14.0, iOS 17.0, *)
@Observable
final class FocusPeakingEngine {

    // MARK: - Public Properties

    var isEnabled: Bool = false
    var settings = FocusPeakingSettings()
    var overlayRenderPipelineState: MTLRenderPipelineState { edgeOverlayPipeline }
    var overlayColor: SIMD3<Float> { settings.peakColor }
    var overlayOpacity: Float { settings.opacity }

    /// Manually reset the engine if experiencing issues
    func reset() {
        print("Focus Peaking: Manual reset requested")
        consecutiveErrors = 0
        lastErrorTime = nil
        textureSets.removeAll()
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }

    // MARK: - Private Properties

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    // Compute pipelines
    private let sobelPipeline: MTLComputePipelineState
    private let blurPipeline: MTLComputePipelineState?
    private let dilatePipeline: MTLComputePipelineState
    private let nv12ToRGBPipeline: MTLComputePipelineState?

    // Render pipeline for compositing
    private let overlayPipeline: MTLRenderPipelineState
    private let edgeOverlayPipeline: MTLRenderPipelineState

    // Texture cache for zero-copy CVPixelBuffer → MTLTexture
    private var textureCache: CVMetalTextureCache?

    // Triple buffering: 3 sets of textures that rotate
    private struct TextureSet {
        let videoTexture: MTLTexture
        let edgeTexture: MTLTexture
        let workTexture: MTLTexture  // For blur/dilation
    }

    private var textureSets: [TextureSet] = []
    private var currentTextureSetIndex = 0
    private var textureWidth: Int = 0
    private var textureHeight: Int = 0
    private let frameSemaphore = DispatchSemaphore(value: 3)

    // Error recovery tracking
    private var consecutiveErrors = 0
    private let maxConsecutiveErrors = 5
    private var lastErrorTime: Date?

    // MARK: - Initialization

    init() throws {
        let compilerCache = HardwareMetalCompilerCache.shared
        guard let device = compilerCache.device, let commandQueue = compilerCache.commandQueue else {
            throw FocusPeakingError.metalNotAvailable
        }
        self.device = device
        self.commandQueue = commandQueue

        guard let sobelPipeline = compilerCache.computePipelineState(functionName: "sobelEdgeDetect"),
              let dilatePipeline = compilerCache.computePipelineState(functionName: "dilateEdges"),
              let overlayPipeline = compilerCache.pipelineState(
                vertexFunctionName: "overlayVertex",
                fragmentFunctionName: "overlayFragment",
                pixelFormat: .bgra8Unorm,
                blendingMode: .alphaBlend
              ),
              let edgeOverlayPipeline = compilerCache.pipelineState(
                vertexFunctionName: "overlayVertex",
                fragmentFunctionName: "edgeOverlayFragment",
                pixelFormat: .bgra8Unorm,
                blendingMode: .alphaBlend
              ) else {
            throw FocusPeakingError.shaderCompilationFailed
        }

        self.sobelPipeline = sobelPipeline
        self.dilatePipeline = dilatePipeline
        self.blurPipeline = compilerCache.computePipelineState(functionName: "gaussianBlur")
        self.nv12ToRGBPipeline = compilerCache.computePipelineState(functionName: "convertNV12ToRGB")
        self.overlayPipeline = overlayPipeline
        self.edgeOverlayPipeline = edgeOverlayPipeline

        // Create texture cache
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        // Ensure CVMetalTextureCache was created
        guard textureCache != nil else {
            throw FocusPeakingError.textureCreationFailed
        }
    }

    // MARK: - Processing Pipeline

    /// Process a video frame and return a texture with focus peaking overlay
    func process(_ pixelBuffer: CVPixelBuffer, into drawable: CAMetalDrawable) throws {
        // Auto-disable if too many consecutive errors
        if consecutiveErrors >= maxConsecutiveErrors {
            if let lastError = lastErrorTime, Date().timeIntervalSince(lastError) < 5.0 {
                print("Warning: Focus Peaking auto-disabled due to repeated errors. Retry in 5s...")
                throw FocusPeakingError.bufferCreationFailed
            } else {
                print("Focus Peaking: Attempting recovery...")
                consecutiveErrors = 0
                textureSets.removeAll()
            }
        }

        // Wait for available frame slot
        let semaphoreResult = frameSemaphore.wait(timeout: .now() + .milliseconds(100))
        guard semaphoreResult == .success else {
            print("Warning: Focus Peaking semaphore timeout")
            recordError()
            throw FocusPeakingError.bufferCreationFailed
        }

        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            frameSemaphore.signal()
            recordError()
            throw FocusPeakingError.bufferCreationFailed
        }
        commandBuffer.label = "FocusPeakingEngine.Process"
        MetalGPUStatsCollector.shared.record(commandBuffer: commandBuffer)

        // Add completion handler
        commandBuffer.addCompletedHandler { [weak self] buffer in
            if let error = buffer.error {
                print("Warning: Focus Peaking command buffer failed - \(error)")
                self?.recordError()
            } else {
                self?.consecutiveErrors = 0
            }
            self?.frameSemaphore.signal()
        }

        // Get frame dimensions
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Initialize or recreate texture sets if resolution changed
        if textureSets.isEmpty || textureWidth != width || textureHeight != height {
            try createTextureSets(width: width, height: height)
        }

        // Get current texture set and rotate
        let textureSet = textureSets[currentTextureSetIndex]
        currentTextureSetIndex = (currentTextureSetIndex + 1) % 3

        // Convert NV12 to RGB into videoTexture
        try convertNV12ToRGB(pixelBuffer, into: textureSet.videoTexture, using: commandBuffer)

        // If focus peaking is disabled, just render the video
        guard isEnabled else {
            try renderPassthrough(textureSet.videoTexture, into: drawable, using: commandBuffer)
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        // Step 1: Optional pre-blur
        let preprocessedTexture: MTLTexture
        if settings.enablePreBlur, let blurPipeline = self.blurPipeline {
            try runComputePass(commandBuffer, pipeline: blurPipeline, input: textureSet.videoTexture, output: textureSet.workTexture)
            preprocessedTexture = textureSet.workTexture
        } else {
            preprocessedTexture = textureSet.videoTexture
        }

        // Step 2: Sobel edge detection
        try runSobelPass(commandBuffer, input: preprocessedTexture, output: textureSet.edgeTexture)

        // Step 3: Optional dilation (thicken edges) - reuse workTexture
        let finalEdgeTexture: MTLTexture
        if settings.thickness > 1 {
            try runDilationPass(commandBuffer, input: textureSet.edgeTexture, output: textureSet.workTexture)
            finalEdgeTexture = textureSet.workTexture
        } else {
            finalEdgeTexture = textureSet.edgeTexture
        }

        // Step 4: Composite overlay onto original frame
        try renderComposite(commandBuffer, videoTexture: textureSet.videoTexture, edgeMask: finalEdgeTexture, into: drawable)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func prepareEdgeMask(_ pixelBuffer: CVPixelBuffer, using commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        if consecutiveErrors >= maxConsecutiveErrors {
            if let lastError = lastErrorTime, Date().timeIntervalSince(lastError) < 5.0 {
                print("Warning: Focus Peaking auto-disabled due to repeated errors. Retry in 5s...")
                throw FocusPeakingError.bufferCreationFailed
            } else {
                print("Focus Peaking: Attempting recovery...")
                consecutiveErrors = 0
                textureSets.removeAll()
            }
        }

        let semaphoreResult = frameSemaphore.wait(timeout: .now() + .milliseconds(100))
        guard semaphoreResult == .success else {
            print("Warning: Focus Peaking semaphore timeout")
            recordError()
            throw FocusPeakingError.bufferCreationFailed
        }

        commandBuffer.addCompletedHandler { [weak self] buffer in
            if let error = buffer.error {
                print("Warning: Focus Peaking command buffer failed - \(error)")
                self?.recordError()
            } else {
                self?.consecutiveErrors = 0
            }
            self?.frameSemaphore.signal()
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if textureSets.isEmpty || textureWidth != width || textureHeight != height {
            try createTextureSets(width: width, height: height)
        }

        let textureSet = textureSets[currentTextureSetIndex]
        currentTextureSetIndex = (currentTextureSetIndex + 1) % 3

        try convertNV12ToRGB(pixelBuffer, into: textureSet.videoTexture, using: commandBuffer)

        let preprocessedTexture: MTLTexture
        if settings.enablePreBlur, let blurPipeline = self.blurPipeline {
            try runComputePass(commandBuffer, pipeline: blurPipeline, input: textureSet.videoTexture, output: textureSet.workTexture)
            preprocessedTexture = textureSet.workTexture
        } else {
            preprocessedTexture = textureSet.videoTexture
        }

        try runSobelPass(commandBuffer, input: preprocessedTexture, output: textureSet.edgeTexture)

        if settings.thickness > 1 {
            try runDilationPass(commandBuffer, input: textureSet.edgeTexture, output: textureSet.workTexture)
            return textureSet.workTexture
        }

        return textureSet.edgeTexture
    }


    // MARK: - Compute Passes

    private func runSobelPass(_ commandBuffer: MTLCommandBuffer, input: MTLTexture, output: MTLTexture) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw FocusPeakingError.bufferCreationFailed
        }

        encoder.setComputePipelineState(sobelPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)

        var threshold = settings.edgeThreshold
        encoder.setBytes(&threshold, length: MemoryLayout<Float>.stride, index: 0)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (output.width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (output.height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
    }

    private func runDilationPass(_ commandBuffer: MTLCommandBuffer, input: MTLTexture, output: MTLTexture) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw FocusPeakingError.bufferCreationFailed
        }

        encoder.setComputePipelineState(dilatePipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)

        var radius = Int32(settings.thickness)
        encoder.setBytes(&radius, length: MemoryLayout<Int32>.stride, index: 0)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (output.width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (output.height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
    }

    private func runComputePass(_ commandBuffer: MTLCommandBuffer, pipeline: MTLComputePipelineState, input: MTLTexture, output: MTLTexture) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw FocusPeakingError.bufferCreationFailed
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (output.width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (output.height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
    }

    // MARK: - Render Passes

    private func renderComposite(_ commandBuffer: MTLCommandBuffer, videoTexture: MTLTexture, edgeMask: MTLTexture, into drawable: CAMetalDrawable) throws {
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            throw FocusPeakingError.bufferCreationFailed
        }

        encoder.setRenderPipelineState(overlayPipeline)
        encoder.setFragmentTexture(videoTexture, index: 0)
        encoder.setFragmentTexture(edgeMask, index: 1)

        var color = settings.peakColor
        encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)

        var opacity = settings.opacity
        encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 1)

        // Draw full-screen quad (triangle strip)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    private func renderPassthrough(_ texture: MTLTexture, into drawable: CAMetalDrawable, using commandBuffer: MTLCommandBuffer) throws {
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            throw FocusPeakingError.bufferCreationFailed
        }

        encoder.setRenderPipelineState(overlayPipeline)
        encoder.setFragmentTexture(texture, index: 0)

        // Use one of the texture set's work textures as a fallback black mask
        // (It doesn't matter what's in it since opacity is 0)
        if !textureSets.isEmpty {
            encoder.setFragmentTexture(textureSets[0].workTexture, index: 1)
        } else {
            // Fallback: use the input texture itself (opacity is 0 anyway)
            encoder.setFragmentTexture(texture, index: 1)
        }

        var color = SIMD3<Float>(0, 0, 0)  // Doesn't matter, no edges
        encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)

        var opacity: Float = 0.0  // No overlay
        encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 1)

        // Draw full-screen quad
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    // MARK: - Triple Buffering

    /// Create 3 sets of textures for triple buffering
    private func createTextureSets(width: Int, height: Int) throws {
        print("Focus Peaking: Creating texture sets for \(width)x\(height)")

        textureSets.removeAll()
        textureWidth = width
        textureHeight = height

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private

        for i in 0..<3 {
            guard let videoTexture = device.makeTexture(descriptor: descriptor),
                  let edgeTexture = device.makeTexture(descriptor: descriptor),
                  let workTexture = device.makeTexture(descriptor: descriptor) else {
                throw FocusPeakingError.textureCreationFailed
            }

            videoTexture.label = "FocusPeaking.Video.\(i)"
            edgeTexture.label = "FocusPeaking.Edge.\(i)"
            workTexture.label = "FocusPeaking.Work.\(i)"

            textureSets.append(TextureSet(
                videoTexture: videoTexture,
                edgeTexture: edgeTexture,
                workTexture: workTexture
            ))
        }

        print("Success: Focus Peaking created 3 texture sets (\(textureSets.count * 3) textures total)")
    }

    /// Convert NV12 pixel buffer to RGB texture
    private func convertNV12ToRGB(_ pixelBuffer: CVPixelBuffer, into outputTexture: MTLTexture, using commandBuffer: MTLCommandBuffer) throws {
        guard let cache = textureCache,
              let nv12Pipeline = nv12ToRGBPipeline else {
            throw FocusPeakingError.shaderCompilationFailed
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Check pixel format
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        // If it's already BGRA, just copy directly
        if pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
           pixelFormat != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            // Direct BGRA8 path - use blit encoder to copy
            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvTexture
            )

            guard status == kCVReturnSuccess,
                  let cvTexture = cvTexture,
                  let sourceTexture = CVMetalTextureGetTexture(cvTexture) else {
                throw FocusPeakingError.textureCreationFailed
            }

            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                throw FocusPeakingError.bufferCreationFailed
            }

            blitEncoder.copy(
                from: sourceTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: outputTexture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )

            blitEncoder.endEncoding()
            return
        }

        // Get Y plane (plane 0)
        var yTexture: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .r8Unorm,
            width,
            height,
            0,
            &yTexture
        )

        guard yStatus == kCVReturnSuccess,
              let yTexture = yTexture,
              let yTex = CVMetalTextureGetTexture(yTexture) else {
            throw FocusPeakingError.textureCreationFailed
        }

        // Get UV plane (plane 1)
        var uvTexture: CVMetalTexture?
        let uvStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .rg8Unorm,
            width / 2,
            height / 2,
            1,
            &uvTexture
        )

        guard uvStatus == kCVReturnSuccess,
              let uvTexture = uvTexture,
              let uvTex = CVMetalTextureGetTexture(uvTexture) else {
            throw FocusPeakingError.textureCreationFailed
        }

        // Convert NV12 → RGB
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw FocusPeakingError.bufferCreationFailed
        }

        encoder.setComputePipelineState(nv12Pipeline)
        encoder.setTexture(yTex, index: 0)
        encoder.setTexture(uvTex, index: 1)
        encoder.setTexture(outputTexture, index: 2)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
    }

    // MARK: - Error Recovery

    private func recordError() {
        consecutiveErrors += 1
        lastErrorTime = Date()

        if consecutiveErrors >= maxConsecutiveErrors {
            print("Error: Focus Peaking too many errors (\(consecutiveErrors)). Auto-disabling temporarily.")
        }
    }
}
