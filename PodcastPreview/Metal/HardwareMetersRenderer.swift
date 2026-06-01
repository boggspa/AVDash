//
//  HardwareMetersRenderer.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 17/12/2025.
//

import Metal
import MetalKit

/// Very lightweight Metal renderer for CPU core meters.
/// Designed for Big Sur / Intel: one pipeline, one draw call.
final class HardwareMetersRenderer: NSObject, MTKViewDelegate {

    struct Vertex {
        var position: SIMD2<Float>
        var color: SIMD4<Float>
        // 0 at bottom of bar, 1 at top of bar
        var uv: SIMD2<Float>
        // Usage level for this core (0..1)
        var level: Float
        var _pad: Float
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var vertexBuffer: MTLBuffer?
    private let stateLock = NSLock()
    private var lockedCoreUsages: [Float] = []

    /// Normalized per-core usage values (0...1)
    var coreUsages: [Float] {
        get { locked { lockedCoreUsages } }
        set { update(coreUsages: newValue) }
    }

    init?(mtkView: MTKView) {
        let compilerCache = HardwareMetalCompilerCache.shared
        guard let device = compilerCache.device,
              let queue = compilerCache.commandQueue,
              let pipelineState = compilerCache.pipelineState(
                vertexFunctionName: "meter_vertex",
                fragmentFunctionName: "meter_fragment",
                pixelFormat: .bgra8Unorm,
                blendingMode: .opaque
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

        super.init()
        mtkView.delegate = self
    }

    func update(coreUsages: [Float]) {
        let sanitized = coreUsages.map(Self.sanitizedRatio)
        locked {
            lockedCoreUsages = sanitized
        }
    }

    // MARK: - MTKViewDelegate

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        commandBuffer.label = "HardwareMetersRenderer.Draw"
        MetalGPUStatsCollector.shared.record(commandBuffer: commandBuffer)

        encoder.setRenderPipelineState(pipelineState)

        let coreUsages = locked { lockedCoreUsages }
        let vertices = buildVertices(coreUsages: coreUsages)
        guard !vertices.isEmpty else {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        let length = vertices.count * MemoryLayout<Vertex>.stride

        if vertexBuffer == nil || vertexBuffer!.length < length {
            guard let newBuffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                encoder.endEncoding()
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }
            vertexBuffer = newBuffer
        }

        guard let vertexBuffer else {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }
        memcpy(vertexBuffer.contents(), vertices, length)

        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // No-op: using normalized coordinates
    }

    // MARK: - Geometry

    private func buildVertices(coreUsages: [Float]) -> [Vertex] {
        guard !coreUsages.isEmpty else { return [] }

        var verts: [Vertex] = []
        let count = coreUsages.count

        // Full vertical slot per core, with a thinner bar centered within each slot.
        let slotHeight: Float = 2.0 / Float(count)
        let barHeight: Float = slotHeight * 0.35   // thinner bars
        let halfBar: Float = barHeight * 0.5

        for i in 0..<count {
            let usage = max(0, min(coreUsages[i], 1))

            // Center the bar within its slot to create consistent spacing between meters.
            let centerY = 1.0 - (Float(i) + 0.5) * slotHeight
            let yTop = centerY + halfBar
            let yBottom = centerY - halfBar

            let xLeft: Float = -1.0
            let xRight: Float = -1.0 + usage * 2.0

            let color = SIMD4<Float>(0.25, 0.55, 1.0, 1.0)
            let backgroundColor = SIMD4<Float>(0.0, 0.0, 0.0, 0.10)
            let xFullRight: Float = 1.0

            // uv.x is normalized across the full bar width (-1..1) -> (0..1)
            let uvXLeft: Float = 0.0
            let uvXRight: Float = (xRight + 1.0) * 0.5
            let uvXFullRight: Float = 1.0

            // ---- Background (empty bar)
            verts.append(Vertex(position: SIMD2<Float>(xLeft,       yBottom), color: backgroundColor, uv: SIMD2<Float>(uvXLeft,      0), level: 0, _pad: 0))
            verts.append(Vertex(position: SIMD2<Float>(xFullRight,  yBottom), color: backgroundColor, uv: SIMD2<Float>(uvXFullRight, 0), level: 0, _pad: 0))
            verts.append(Vertex(position: SIMD2<Float>(xLeft,       yTop),    color: backgroundColor, uv: SIMD2<Float>(uvXLeft,      1), level: 0, _pad: 0))

            verts.append(Vertex(position: SIMD2<Float>(xFullRight,  yBottom), color: backgroundColor, uv: SIMD2<Float>(uvXFullRight, 0), level: 0, _pad: 0))
            verts.append(Vertex(position: SIMD2<Float>(xFullRight,  yTop),    color: backgroundColor, uv: SIMD2<Float>(uvXFullRight, 1), level: 0, _pad: 0))
            verts.append(Vertex(position: SIMD2<Float>(xLeft,       yTop),    color: backgroundColor, uv: SIMD2<Float>(uvXLeft,      1), level: 0, _pad: 0))

            // ---- Filled bar
            verts.append(Vertex(position: SIMD2<Float>(xLeft,  yBottom), color: color, uv: SIMD2<Float>(uvXLeft,  0), level: usage, _pad: 0))
            verts.append(Vertex(position: SIMD2<Float>(xRight, yBottom), color: color, uv: SIMD2<Float>(uvXRight, 0), level: usage, _pad: 0))
            verts.append(Vertex(position: SIMD2<Float>(xLeft,  yTop),    color: color, uv: SIMD2<Float>(uvXLeft,  1), level: usage, _pad: 0))

            verts.append(Vertex(position: SIMD2<Float>(xRight, yBottom), color: color, uv: SIMD2<Float>(uvXRight, 0), level: usage, _pad: 0))
            verts.append(Vertex(position: SIMD2<Float>(xRight, yTop),    color: color, uv: SIMD2<Float>(uvXRight, 1), level: usage, _pad: 0))
            verts.append(Vertex(position: SIMD2<Float>(xLeft,  yTop),    color: color, uv: SIMD2<Float>(uvXLeft,  1), level: usage, _pad: 0))
        }

        return verts
    }

    private func locked<T>(_ operation: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return operation()
    }

    private nonisolated static func sanitizedRatio(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
