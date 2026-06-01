//
//  MetalRenderer.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 07/12/2025.
//

import Metal
import MetalKit
import simd
import QuartzCore

nonisolated final class MetalGPUStatsCollector: @unchecked Sendable {
    static let shared = MetalGPUStatsCollector()

    private let queue = DispatchQueue(label: "podcastpreview.gpu.stats", qos: .utility)
    private var accumulatedGPUSeconds: Double = 0
    private var lastSampleTime: CFTimeInterval = CACurrentMediaTime()

    private init() {}

    func record(commandBuffer: MTLCommandBuffer) {
        commandBuffer.addCompletedHandler { [weak self] cb in
            guard let self else { return }

            let start = cb.gpuStartTime
            let end = cb.gpuEndTime
            guard start > 0, end >= start else { return }

            let duration = end - start
            self.queue.async {
                self.accumulatedGPUSeconds += duration
            }
        }
    }

    func consumePercentSinceLastSample() -> Double? {
        queue.sync {
            let now = CACurrentMediaTime()
            let wall = now - lastSampleTime
            guard wall > 0 else { return nil }

            let gpu = accumulatedGPUSeconds
            accumulatedGPUSeconds = 0
            lastSampleTime = now

            let percent = (gpu / wall) * 100.0
            return min(max(percent, 0.0), 100.0)
        }
    }

    func reset() {
        queue.sync {
            accumulatedGPUSeconds = 0
            lastSampleTime = CACurrentMediaTime()
        }
    }
}

struct SpectrumVertex {
    var position: SIMD2<Float>
    var magnitude: Float
}

struct MeterStripVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var channelIndex: UInt32
}

final class MetalRenderer {
    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let commandQueue: MTLCommandQueue
    var levelBuffer: MTLBuffer
    var peakBuffer: MTLBuffer
    var colorBuffer: MTLBuffer

    init?(device: MTLDevice) {
        let compilerCache = HardwareMetalCompilerCache.shared
        guard let sharedDevice = compilerCache.device,
              let queue = compilerCache.commandQueue,
              let pipelineState = compilerCache.pipelineState(
                vertexFunctionName: "vertex_main",
                fragmentFunctionName: "fragment_main",
                pixelFormat: .bgra8Unorm,
                blendingMode: .opaque
              ) else {
            return nil
        }

        self.device = sharedDevice
        self.commandQueue = queue
        self.pipeline = pipelineState

        levelBuffer = device.makeBuffer(length: MemoryLayout<Float>.stride, options: [])!
        peakBuffer  = device.makeBuffer(length: MemoryLayout<Float>.stride, options: [])!
        colorBuffer = device.makeBuffer(length: MemoryLayout<SIMD3<Float>>.stride, options: [])!
    }

    func drawLevel(_ level: Float, peak: Float, color: SIMD3<Float>, in drawable: CAMetalDrawable) {
        var levelCopy = level
        memcpy(levelBuffer.contents(), &levelCopy, MemoryLayout<Float>.size)

        var peakCopy = peak
        memcpy(peakBuffer.contents(), &peakCopy, MemoryLayout<Float>.size)

        var colorCopy = color
        memcpy(colorBuffer.contents(), &colorCopy, MemoryLayout<SIMD3<Float>>.size)

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        rpd.colorAttachments[0].storeAction = .store

        let commandBuffer = commandQueue.makeCommandBuffer()!
        commandBuffer.label = "MetalMeterView.Level"
        MetalGPUStatsCollector.shared.record(commandBuffer: commandBuffer)
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd)!
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(levelBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(peakBuffer,  offset: 0, index: 1)
        encoder.setFragmentBuffer(colorBuffer, offset: 0, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

final class MultiChannelMetalRenderer {
    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let commandQueue: MTLCommandQueue

    private var vertexBuffer: MTLBuffer?
    private var vertexCount: Int = 0
    private var cachedChannelCount = -1
    private var cachedMeterWidth: CGFloat = -1
    private var cachedMeterSpacing: CGFloat = -1

    private var levelBuffer: MTLBuffer?
    private var peakBuffer: MTLBuffer?
    private var colorBuffer: MTLBuffer

    init?(device: MTLDevice) {
        let compilerCache = HardwareMetalCompilerCache.shared
        guard let sharedDevice = compilerCache.device,
              let queue = compilerCache.commandQueue,
              let pipelineState = compilerCache.pipelineState(
                vertexFunctionName: "vertex_meter_strip",
                fragmentFunctionName: "fragment_meter_strip",
                pixelFormat: .bgra8Unorm,
                blendingMode: .opaque
              ) else {
            return nil
        }

        self.device = sharedDevice
        self.commandQueue = queue
        self.pipeline = pipelineState

        colorBuffer = device.makeBuffer(length: MemoryLayout<SIMD3<Float>>.stride, options: [])!
    }

    func drawMeters(
        levels: [Float],
        peakHolds: [Float],
        color: SIMD3<Float>,
        meterWidth: CGFloat,
        meterSpacing: CGFloat,
        in drawable: CAMetalDrawable
    ) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        rpd.colorAttachments[0].storeAction = .store

        let commandBuffer = commandQueue.makeCommandBuffer()!
        commandBuffer.label = "MetalMeterStripView.Draw"
        MetalGPUStatsCollector.shared.record(commandBuffer: commandBuffer)

        guard !levels.isEmpty, levels.count == peakHolds.count else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        updateVertexBuffer(channelCount: levels.count, meterWidth: meterWidth, meterSpacing: meterSpacing)
        updateFloatBuffer(&levelBuffer, values: levels)
        updateFloatBuffer(&peakBuffer, values: peakHolds)
        var colorCopy = color
        memcpy(colorBuffer.contents(), &colorCopy, MemoryLayout<SIMD3<Float>>.size)

        guard let vertexBuffer, let levelBuffer, let peakBuffer else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd)!
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(levelBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(peakBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(colorBuffer, offset: 0, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func updateFloatBuffer(_ buffer: inout MTLBuffer?, values: [Float]) {
        let length = MemoryLayout<Float>.stride * values.count
        if buffer == nil || buffer!.length < length {
            buffer = device.makeBuffer(length: length, options: [])
        }
        values.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress, let destination = buffer?.contents() else { return }
            memcpy(destination, source, length)
        }
    }

    private func updateVertexBuffer(channelCount: Int, meterWidth: CGFloat, meterSpacing: CGFloat) {
        guard channelCount > 0 else {
            vertexBuffer = nil
            vertexCount = 0
            cachedChannelCount = 0
            return
        }

        if cachedChannelCount == channelCount &&
            cachedMeterWidth == meterWidth &&
            cachedMeterSpacing == meterSpacing {
            return
        }

        let vertices = buildVertices(channelCount: channelCount,
                                     meterWidth: meterWidth,
                                     meterSpacing: meterSpacing)
        vertexCount = vertices.count
        vertexBuffer = device.makeBuffer(bytes: vertices,
                                         length: MemoryLayout<MeterStripVertex>.stride * vertices.count,
                                         options: [])
        cachedChannelCount = channelCount
        cachedMeterWidth = meterWidth
        cachedMeterSpacing = meterSpacing
    }

    private func buildVertices(channelCount: Int,
                               meterWidth: CGFloat,
                               meterSpacing: CGFloat) -> [MeterStripVertex] {
        let totalWidth = CGFloat(channelCount) * meterWidth +
            CGFloat(max(channelCount - 1, 0)) * meterSpacing
        guard totalWidth > 0 else { return [] }

        let normalizedMeterWidth = Float(meterWidth / totalWidth)
        let normalizedMeterSpacing = Float(meterSpacing / totalWidth)
        var vertices = [MeterStripVertex]()
        vertices.reserveCapacity(channelCount * 6)

        for channelIndex in 0..<channelCount {
            let leftUnit = Float(channelIndex) * (normalizedMeterWidth + normalizedMeterSpacing)
            let rightUnit = leftUnit + normalizedMeterWidth
            let left = leftUnit * 2.0 - 1.0
            let right = rightUnit * 2.0 - 1.0
            let channel = UInt32(channelIndex)

            let lowerLeft = MeterStripVertex(position: SIMD2(left, -1.0),
                                             uv: SIMD2(0.0, 0.0),
                                             channelIndex: channel)
            let lowerRight = MeterStripVertex(position: SIMD2(right, -1.0),
                                              uv: SIMD2(1.0, 0.0),
                                              channelIndex: channel)
            let upperLeft = MeterStripVertex(position: SIMD2(left, 1.0),
                                             uv: SIMD2(0.0, 1.0),
                                             channelIndex: channel)
            let upperRight = MeterStripVertex(position: SIMD2(right, 1.0),
                                              uv: SIMD2(1.0, 1.0),
                                              channelIndex: channel)

            vertices.append(lowerLeft)
            vertices.append(lowerRight)
            vertices.append(upperLeft)
            vertices.append(upperLeft)
            vertices.append(lowerRight)
            vertices.append(upperRight)
        }

        return vertices
    }
}

final class HorizontalMultiChannelMetalRenderer {
    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let commandQueue: MTLCommandQueue

    private var vertexBuffer: MTLBuffer?
    private var vertexCount: Int = 0
    private var cachedChannelCount = -1
    private var cachedMeterHeight: CGFloat = -1
    private var cachedMeterSpacing: CGFloat = -1

    private var levelBuffer: MTLBuffer?
    private var peakBuffer: MTLBuffer?
    private var colorBuffer: MTLBuffer

    init?(device: MTLDevice) {
        let compilerCache = HardwareMetalCompilerCache.shared
        guard let sharedDevice = compilerCache.device,
              let queue = compilerCache.commandQueue,
              let pipelineState = compilerCache.pipelineState(
                vertexFunctionName: "vertex_meter_strip",
                fragmentFunctionName: "fragment_meter_strip_horizontal",
                pixelFormat: .bgra8Unorm,
                blendingMode: .opaque
              ) else {
            return nil
        }

        self.device = sharedDevice
        self.commandQueue = queue
        self.pipeline = pipelineState

        colorBuffer = device.makeBuffer(length: MemoryLayout<SIMD3<Float>>.stride, options: [])!
    }

    func drawMeters(
        levels: [Float],
        peakHolds: [Float],
        color: SIMD3<Float>,
        meterHeight: CGFloat,
        meterSpacing: CGFloat,
        in drawable: CAMetalDrawable
    ) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        rpd.colorAttachments[0].storeAction = .store

        let commandBuffer = commandQueue.makeCommandBuffer()!
        commandBuffer.label = "MetalHorizontalMeterStripView.Draw"
        MetalGPUStatsCollector.shared.record(commandBuffer: commandBuffer)

        guard !levels.isEmpty, levels.count == peakHolds.count else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        updateVertexBuffer(channelCount: levels.count, meterHeight: meterHeight, meterSpacing: meterSpacing)
        updateFloatBuffer(&levelBuffer, values: levels)
        updateFloatBuffer(&peakBuffer, values: peakHolds)
        var colorCopy = color
        memcpy(colorBuffer.contents(), &colorCopy, MemoryLayout<SIMD3<Float>>.size)

        guard let vertexBuffer, let levelBuffer, let peakBuffer else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd)!
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(levelBuffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(peakBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(colorBuffer, offset: 0, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func updateFloatBuffer(_ buffer: inout MTLBuffer?, values: [Float]) {
        let length = MemoryLayout<Float>.stride * values.count
        if buffer == nil || buffer!.length < length {
            buffer = device.makeBuffer(length: length, options: [])
        }
        values.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress, let destination = buffer?.contents() else { return }
            memcpy(destination, source, length)
        }
    }

    private func updateVertexBuffer(channelCount: Int, meterHeight: CGFloat, meterSpacing: CGFloat) {
        guard channelCount > 0 else {
            vertexBuffer = nil
            vertexCount = 0
            cachedChannelCount = 0
            return
        }

        if cachedChannelCount == channelCount &&
            cachedMeterHeight == meterHeight &&
            cachedMeterSpacing == meterSpacing {
            return
        }

        let vertices = buildVertices(channelCount: channelCount,
                                     meterHeight: meterHeight,
                                     meterSpacing: meterSpacing)
        vertexCount = vertices.count
        vertexBuffer = device.makeBuffer(bytes: vertices,
                                         length: MemoryLayout<MeterStripVertex>.stride * vertices.count,
                                         options: [])
        cachedChannelCount = channelCount
        cachedMeterHeight = meterHeight
        cachedMeterSpacing = meterSpacing
    }

    private func buildVertices(channelCount: Int,
                               meterHeight: CGFloat,
                               meterSpacing: CGFloat) -> [MeterStripVertex] {
        let totalHeight = CGFloat(channelCount) * meterHeight +
            CGFloat(max(channelCount - 1, 0)) * meterSpacing
        guard totalHeight > 0 else { return [] }

        let normalizedMeterHeight = Float(meterHeight / totalHeight)
        let normalizedMeterSpacing = Float(meterSpacing / totalHeight)
        var vertices = [MeterStripVertex]()
        vertices.reserveCapacity(channelCount * 6)

        for channelIndex in 0..<channelCount {
            let topUnit = 1.0 - Float(channelIndex) * (normalizedMeterHeight + normalizedMeterSpacing)
            let bottomUnit = topUnit - normalizedMeterHeight
            let top = topUnit * 2.0 - 1.0
            let bottom = bottomUnit * 2.0 - 1.0
            let channel = UInt32(channelIndex)

            let lowerLeft = MeterStripVertex(position: SIMD2(-1.0, bottom),
                                             uv: SIMD2(0.0, 0.0),
                                             channelIndex: channel)
            let lowerRight = MeterStripVertex(position: SIMD2(1.0, bottom),
                                              uv: SIMD2(1.0, 0.0),
                                              channelIndex: channel)
            let upperLeft = MeterStripVertex(position: SIMD2(-1.0, top),
                                             uv: SIMD2(0.0, 1.0),
                                             channelIndex: channel)
            let upperRight = MeterStripVertex(position: SIMD2(1.0, top),
                                              uv: SIMD2(1.0, 1.0),
                                              channelIndex: channel)

            vertices.append(lowerLeft)
            vertices.append(lowerRight)
            vertices.append(upperLeft)
            vertices.append(upperLeft)
            vertices.append(lowerRight)
            vertices.append(upperRight)
        }

        return vertices
    }
}

final class MetalSpectrumRenderer {
    let device: MTLDevice
    let pipeline: MTLRenderPipelineState
    let commandQueue: MTLCommandQueue
    var vertexBuffer: MTLBuffer?
    var colorBuffer: MTLBuffer

    init?(device: MTLDevice) {
        let compilerCache = HardwareMetalCompilerCache.shared
        guard let sharedDevice = compilerCache.device,
              let queue = compilerCache.commandQueue,
              let pipelineState = compilerCache.pipelineState(
                vertexFunctionName: "vertex_spectrum",
                fragmentFunctionName: "fragment_spectrum_fill",
                pixelFormat: .bgra8Unorm,
                blendingMode: .opaque
              ) else {
            return nil
        }

        self.device = sharedDevice
        self.commandQueue = queue
        self.pipeline = pipelineState

        colorBuffer = device.makeBuffer(length: MemoryLayout<SIMD3<Float>>.stride, options: [])!
    }

    func updateSpectrum(_ points: [SIMD2<Float>]) {
        let count = points.count
        let verts: [SpectrumVertex] = points.map { p in
            SpectrumVertex(position: p, magnitude: p.y)
        }
        vertexBuffer = device.makeBuffer(bytes: verts,
                                         length: MemoryLayout<SpectrumVertex>.stride * count,
                                         options: [])
    }

    func drawSpectrum(_ baseColor: SIMD3<Float>, in drawable: CAMetalDrawable) {
        guard let vertexBuffer else { return }
        memcpy(colorBuffer.contents(), [baseColor], MemoryLayout<SIMD3<Float>>.size)
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
        rpd.colorAttachments[0].storeAction = .store
        let commandBuffer = commandQueue.makeCommandBuffer()!
        commandBuffer.label = "MetalSpectrumRenderer.Draw"
        MetalGPUStatsCollector.shared.record(commandBuffer: commandBuffer)
        let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.setFragmentBuffer(colorBuffer, offset: 0, index: 1)
        let vertCount = vertexBuffer.length / MemoryLayout<SpectrumVertex>.stride
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertCount)
        enc.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
