//
//  NeuralEngineCapsuleRenderer.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 21/03/2026.
//


import SwiftUI
import MetalKit
import simd

private struct NeuralEngineCapsuleUniforms {
    var drawableSize: SIMD2<Float>
    var statusColor: SIMD4<Float>
    var capsuleSize: SIMD2<Float>
    var glowSize: SIMD2<Float>
    var layout: SIMD4<Float>      // x = topPadding, y = railPadding, z = capsuleSpacing, w = rowExtraHeight
    var capsuleCount: UInt32
    var isIdle: UInt32
    var isActive: UInt32
    var _padding: UInt32 = 0
}

final class NeuralEngineCapsuleRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer

    var capsuleCount: Int = 0
    var isIdle: Bool = true
    var isActive: Bool = false
    var statusColor: SIMD4<Float> = .zero
    var capsuleWidth: Float = 56
    var capsuleHeight: Float = 5
    var capsuleSpacing: Float = 1
    var railPadding: Float = 10
    var topPadding: Float = 6
    var rowExtraHeight: Float = 6
    var glowExtraWidth: Float = 7
    var glowExtraHeight: Float = 5.5

    init?(device: MTLDevice) {
        let compilerCache = HardwareMetalCompilerCache.shared
        guard let sharedDevice = compilerCache.device,
              let queue = compilerCache.commandQueue,
              let pipelineState = compilerCache.pipelineState(
                vertexFunctionName: "neuralCapsuleVertex",
                fragmentFunctionName: "neuralCapsuleFragment",
                pixelFormat: .bgra8Unorm,
                blendingMode: .alphaBlend
              ) else {
            return nil
        }

        self.device = sharedDevice
        self.commandQueue = queue
        self.pipelineState = pipelineState

        let vertices: [SIMD2<Float>] = [
            SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1),
            SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)
        ]
        guard let vertexBuffer = device.makeBuffer(bytes: vertices,
                                                   length: MemoryLayout<SIMD2<Float>>.stride * vertices.count,
                                                   options: []) else {
            return nil
        }
        self.vertexBuffer = vertexBuffer

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        commandBuffer.label = "NeuralEngineCapsuleRenderer.Draw"
        MetalGPUStatsCollector.shared.record(commandBuffer: commandBuffer)

        var uniforms = NeuralEngineCapsuleUniforms(
            drawableSize: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            statusColor: statusColor,
            capsuleSize: SIMD2(capsuleWidth, capsuleHeight),
            glowSize: SIMD2(capsuleWidth + glowExtraWidth, capsuleHeight + glowExtraHeight),
            layout: SIMD4(topPadding, railPadding, capsuleSpacing, rowExtraHeight),
            capsuleCount: UInt32(max(capsuleCount, 0)),
            isIdle: isIdle ? 1 : 0,
            isActive: isActive ? 1 : 0
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<NeuralEngineCapsuleUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<NeuralEngineCapsuleUniforms>.stride, index: 0)

        let instanceCount = max(capsuleCount, 0) * 3
        if instanceCount > 0 {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instanceCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

private final class NeuralEngineCapsuleMTKView: MTKView {
    override var isOpaque: Bool {
        get { false }
        set { }
    }
}

struct NeuralEngineCapsuleMetalView: NSViewRepresentable {
    let visibleCapsuleCount: Int
    let isIdle: Bool
    let isActive: Bool
    let statusColor: SIMD4<Float>
    let capsuleColumnWidth: CGFloat
    let cardContentHeight: CGFloat
    let capsuleWidth: CGFloat
    let capsuleHeight: CGFloat
    let capsuleSpacing: CGFloat
    let capsuleRailPadding: CGFloat
    let capsuleTopPadding: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = NeuralEngineCapsuleRenderer(device: device) else {
            return MTKView(frame: .zero)
        }

        let view = NeuralEngineCapsuleMTKView(frame: .zero, device: device)
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 30
        view.delegate = renderer

        context.coordinator.renderer = renderer
        applyState(to: renderer)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        applyState(to: renderer)
        view.draw()
    }

    private func applyState(to renderer: NeuralEngineCapsuleRenderer) {
        renderer.capsuleCount = visibleCapsuleCount
        renderer.isIdle = isIdle
        renderer.isActive = isActive
        renderer.statusColor = statusColor
        renderer.capsuleWidth = Float(capsuleWidth)
        renderer.capsuleHeight = Float(capsuleHeight)
        renderer.capsuleSpacing = Float(capsuleSpacing)
        renderer.railPadding = Float(capsuleRailPadding)
        renderer.topPadding = Float(capsuleTopPadding)
        renderer.rowExtraHeight = 6 * Float(max(capsuleWidth / 56.0, 0.0001))
    }

    final class Coordinator {
        var renderer: NeuralEngineCapsuleRenderer?
    }
}
