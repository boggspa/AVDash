//
//  HardwareGraphsRenderer.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 17/12/2025.
//

import Metal
import MetalKit
import AppKit

/// Minimal Metal renderer for rolling usage graphs (CPU / GPU / RAM)
/// Designed for Big Sur + Intel
final class HardwareGraphsRenderer: NSObject, MTKViewDelegate {

    struct Vertex {
        var position: SIMD2<Float>
        var color: SIMD4<Float>
        // uv.y is 0 at baseline and 1 at the line (top of fill). Used for top-band tinting.
        var uv: SIMD2<Float>
        // The sample value for this x, normalized 0..1 (used to decide if this column is "spiking").
        var level: Float
        // Padding to keep 16-byte alignment similar across Swift/Metal
        var _pad: Float
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState

    private var vertexBuffer: MTLBuffer?
    private var vertexBufferCapacity: Int = 0
    private let stateLock = NSLock()
    private var lockedValues: [Float] = []
    private var lockedLineColor: SIMD4<Float> = SIMD4<Float>(0.25, 0.55, 1.0, 1.0)
    private var lockedSmoothingAlpha: Float = 0.40

    /// Normalized history values (0...1)
    var values: [Float] {
        get { locked { lockedValues } }
        set { update(values: newValue, lineColor: lineColor) }
    }

    /// Line color for the graph (RGBA, 0...1). Default is CPU blue.
    var lineColor: SIMD4<Float> {
        get { locked { lockedLineColor } }
        set { locked { lockedLineColor = Self.sanitizedColor(newValue) } }
    }

    /// Display-only smoothing for graph rendering. Lower values smooth more, higher values track raw samples more closely.
    /// This does not alter the underlying history data; it only affects the rendered line/fill shape.
    var smoothingAlpha: Float {
        get { locked { lockedSmoothingAlpha } }
        set { locked { lockedSmoothingAlpha = max(0.05, min(newValue, 1.0)) } }
    }

    init?(mtkView: MTKView) {
        let compilerCache = HardwareMetalCompilerCache.shared
        guard let device = compilerCache.device,
              let queue = compilerCache.commandQueue,
              let pipelineState = compilerCache.pipelineState(
                vertexFunctionName: "graph_vertex",
                fragmentFunctionName: "graph_fragment",
                pixelFormat: .bgra8Unorm,
                blendingMode: .preMultipliedAlpha
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
        // 10% opaque black background so underlying UI can subtly show through
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0.10)

        // Ensure the backing layer is treated as non-opaque so alpha is respected
        mtkView.wantsLayer = true
        mtkView.layer?.isOpaque = false
        mtkView.layer?.backgroundColor = NSColor.clear.cgColor

        super.init()
        mtkView.delegate = self
    }

    func update(values: [Float], lineColor: SIMD4<Float>, smoothingAlpha: Float? = nil) {
        let sanitizedValues = values.map(Self.sanitizedRatio)
        let sanitizedColor = Self.sanitizedColor(lineColor)

        locked {
            lockedValues = sanitizedValues
            lockedLineColor = sanitizedColor
            if let smoothingAlpha {
                lockedSmoothingAlpha = max(0.05, min(smoothingAlpha, 1.0))
            }
        }
    }

    // MARK: - MTKViewDelegate

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return }

        commandBuffer.label = "HardwareGraphsRenderer.Draw"
        MetalGPUStatsCollector.shared.record(commandBuffer: commandBuffer)

        encoder.setRenderPipelineState(pipelineState)

        let renderState = locked {
            (
                values: lockedValues,
                lineColor: lockedLineColor,
                smoothingAlpha: lockedSmoothingAlpha
            )
        }
        let fillVerts = buildFillVertices(
            values: renderState.values,
            lineColor: renderState.lineColor,
            smoothingAlpha: renderState.smoothingAlpha
        )
        let lineVerts = buildLineVertices(
            values: renderState.values,
            lineColor: renderState.lineColor,
            smoothingAlpha: renderState.smoothingAlpha
        )

        guard !fillVerts.isEmpty, !lineVerts.isEmpty else {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        let fillBytes = fillVerts.count * MemoryLayout<Vertex>.stride
        let lineBytes = lineVerts.count * MemoryLayout<Vertex>.stride
        let totalBytes = fillBytes + lineBytes

        // Only reallocate buffer if we need more capacity (with 20% headroom to reduce reallocations)
        if vertexBuffer == nil || vertexBufferCapacity < totalBytes {
            let newCapacity = max(totalBytes, totalBytes + (totalBytes / 5))
            guard let newBuffer = device.makeBuffer(length: newCapacity, options: .storageModeShared) else {
                encoder.endEncoding()
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }
            vertexBuffer = newBuffer
            vertexBufferCapacity = newBuffer.length
        }

        // Single combined copy is more efficient than two separate memcpy calls
        guard let vertexBuffer else {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }
        let bufferContents = vertexBuffer.contents()
        fillVerts.withUnsafeBytes { fillPtr in
            lineVerts.withUnsafeBytes { linePtr in
                guard let fillBaseAddress = fillPtr.baseAddress,
                      let lineBaseAddress = linePtr.baseAddress else { return }
                bufferContents.copyMemory(from: fillBaseAddress, byteCount: fillBytes)
                bufferContents.advanced(by: fillBytes).copyMemory(from: lineBaseAddress, byteCount: lineBytes)
            }
        }

        // Fill
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: fillVerts.count)

        // Line
        encoder.setVertexBuffer(vertexBuffer, offset: fillBytes, index: 0)
        encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: lineVerts.count)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // No-op (normalized coordinates)
    }

    private func smoothedValues(from values: [Float], smoothingAlpha: Float) -> [Float] {
        guard values.count > 2 else { return values }

        let alpha = max(0.05, min(smoothingAlpha, 1.0))
        var result: [Float] = []
        result.reserveCapacity(values.count)

        var previous = max(0, min(values[0], 1))
        result.append(previous)

        for i in 1..<values.count {
            let raw = max(0, min(values[i], 1))
            let smoothed = (alpha * raw) + ((1.0 - alpha) * previous)
            result.append(smoothed)
            previous = smoothed
        }

        return result
    }

    // MARK: - Geometry

    private func buildLineVertices(
        values: [Float],
        lineColor: SIMD4<Float>,
        smoothingAlpha: Float
    ) -> [Vertex] {
        let displayValues = smoothedValues(from: values, smoothingAlpha: smoothingAlpha)
        guard displayValues.count > 1 else { return [] }

        var verts: [Vertex] = []
        let count = displayValues.count

        let color = lineColor

        for i in 0..<count {
            let v = max(0, min(displayValues[i], 1))
            let x = -1.0 + (Float(i) / Float(count - 1)) * 2.0
            let y = -1.0 + v * 2.0
            verts.append(Vertex(
                position: SIMD2<Float>(x, y),
                color: color,
                uv: SIMD2<Float>(0, 1),
                level: v,
                _pad: 0
            ))
        }

        return verts
    }

    private func buildFillVertices(
        values: [Float],
        lineColor: SIMD4<Float>,
        smoothingAlpha: Float
    ) -> [Vertex] {
        let displayValues = smoothedValues(from: values, smoothingAlpha: smoothingAlpha)
        guard displayValues.count > 1 else { return [] }

        var verts: [Vertex] = []
        let count = displayValues.count

        // Same color as line but translucent alpha
        let fillColor = SIMD4<Float>(lineColor.x, lineColor.y, lineColor.z, 0.18)

        for i in 0..<count {
            let v = max(0, min(displayValues[i], 1))
            let x = -1.0 + (Float(i) / Float(count - 1)) * 2.0
            let y = -1.0 + v * 2.0

            // baseline at y=-1 (0%) then actual point
            verts.append(Vertex(
                position: SIMD2<Float>(x, -1.0),
                color: fillColor,
                uv: SIMD2<Float>(0, 0),
                level: v,
                _pad: 0
            ))
            verts.append(Vertex(
                position: SIMD2<Float>(x, y),
                color: fillColor,
                uv: SIMD2<Float>(0, 1),
                level: v,
                _pad: 0
            ))
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

    private nonisolated static func sanitizedColor(_ color: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(
            sanitizedChannel(color.x),
            sanitizedChannel(color.y),
            sanitizedChannel(color.z),
            sanitizedChannel(color.w)
        )
    }

    private nonisolated static func sanitizedChannel(_ value: Float) -> Float {
        guard value.isFinite else { return 1 }
        return min(max(value, 0), 1)
    }
}
