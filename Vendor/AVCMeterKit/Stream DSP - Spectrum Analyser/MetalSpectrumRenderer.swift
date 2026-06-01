func spectrumLineColor(for themeMode: ThemeMode) -> Color {
    spectrumLineColor(for: SpectrumThemeMode(from: themeMode))
}

func simdColor(from color: Color) -> SIMD4<Float> {
    #if os(macOS)
    let nsColor = NSColor(color)
    guard let rgb = nsColor.usingColorSpace(.deviceRGB) else {
        return SIMD4<Float>(1, 1, 1, 1)
    }
    return SIMD4<Float>(Float(rgb.redComponent),
                        Float(rgb.greenComponent),
                        Float(rgb.blueComponent),
                        Float(rgb.alphaComponent))
    #else
    return SIMD4<Float>(1, 1, 1, 1) // fallback for non-macOS
    #endif
}

private final class SpectrumMetalBundleToken: NSObject {}

private func makeSpectrumLibrary(device: MTLDevice) -> MTLLibrary? {
    let frameworkBundle = Bundle(for: SpectrumMetalBundleToken.self)
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
            print("Spectrum Metal library load failed at \(url.path): \(error)")
        }
    }

    do {
        return try device.makeDefaultLibrary(bundle: frameworkBundle)
    } catch {
        print("Spectrum default library from framework bundle failed: \(error)")
    }

    do {
        return try device.makeDefaultLibrary(bundle: .main)
    } catch {
        print("Spectrum default library from main bundle failed: \(error)")
    }

    if let library = device.makeDefaultLibrary() {
        return library
    }

    print("Spectrum Metal library resolution exhausted with no library found")
    return nil
}

extension MetalSpectrumRenderer.Coordinator {
    /// Receive new vertex array and count, reupload to GPU.
    func update(vertexData: [Float], vertexCount: Int) {
        guard let device = self.device else { return }
        //print("MetalSpectrumRenderer.Coordinator.update called with vertexCount =", vertexCount)
        self.vertexCount = vertexCount
        let dataSize = vertexData.count * MemoryLayout<Float>.stride
        // Only allocate when we actually have data to upload
        if dataSize > 0 && (vertexBuffer == nil || vertexBuffer!.length < dataSize) {
            vertexBuffer = device.makeBuffer(length: dataSize, options: .storageModeShared)
        }
        if let buf = vertexBuffer, dataSize > 0 {
            memcpy(buf.contents(), vertexData, dataSize)
        }
    }
}

//
//  MetalSpectrumRenderer.swift
//  AVCMeter
//
//  Created by Chris Izatt on 26/06/2025.
//

import Foundation
import MetalKit
import SwiftUI

struct MetalSpectrumRenderer: NSViewRepresentable {
    @ObservedObject var spectrumProcessor: SafeFFTSpectrumProcessor
    var channelIndex: Int
    var themeMode: ThemeMode

    func makeNSView(context: Context) -> MTKView {
        let device = MTLCreateSystemDefaultDevice()!
        let mtkView = MTKView(frame: .zero, device: device)
        mtkView.colorPixelFormat = .bgra8Unorm
        // Drive continuous redraw at preferred frame rate
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.delegate = context.coordinator
        mtkView.preferredFramesPerSecond = 30
        mtkView.framebufferOnly = false
        // Set transparent background and non-opaque view
        mtkView.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0)
        mtkView.wantsLayer = true
        mtkView.layer?.isOpaque = false
        mtkView.layer?.backgroundColor = NSColor.clear.cgColor
        context.coordinator.setup(
            device: device,
            pixelFormat: mtkView.colorPixelFormat,
            themeMode: SpectrumThemeMode(from: themeMode)
        )
        // Begin periodic FFT magnitude updates
        // Kick off the FFT processor
        spectrumProcessor.start()
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // Just update theme/color if needed - actual vertex generation happens in draw()
        let mode = SpectrumThemeMode(from: themeMode)
        context.coordinator.themeMode = mode
        context.coordinator.spectrumColor = spectrumLineColor(for: mode)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(spectrumProcessor: spectrumProcessor, channelIndex: channelIndex, themeMode: themeMode)
    }

    class Coordinator: NSObject, MTKViewDelegate {
        let spectrumProcessor: SafeFFTSpectrumProcessor
        let channelIndex: Int
        var device: MTLDevice!
        var commandQueue: MTLCommandQueue!
        var pipelineState: MTLRenderPipelineState?
        var vertexBuffer: MTLBuffer?
        var vertexCount: Int = 0
        var themeMode: SpectrumThemeMode = .liquidGlass
        var spectrumColor: Color = .green
        var lastMagnitudesHash: Int = 0

        init(spectrumProcessor: SafeFFTSpectrumProcessor, channelIndex: Int, themeMode: ThemeMode) {
            self.spectrumProcessor = spectrumProcessor
            self.channelIndex = channelIndex
            self.themeMode = SpectrumThemeMode(from: themeMode)
        }

        func setup(device: MTLDevice, pixelFormat: MTLPixelFormat, themeMode: SpectrumThemeMode) {
            self.device = device
            commandQueue = device.makeCommandQueue()
            self.themeMode = themeMode
            self.spectrumColor = spectrumLineColor(for: themeMode)
            guard let library = makeSpectrumLibrary(device: device) else {
                print("Failed to load Metal library for spectrum renderer")
                pipelineState = nil
                return
            }
            guard let vertexFunction = library.makeFunction(name: "spectrumVertexShader"),
                  let fragmentFunction = library.makeFunction(name: "spectrumFragmentShader") else {
                print("Failed to load spectrum shader functions from library")
                pipelineState = nil
                return
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFunction
            desc.fragmentFunction = fragmentFunction
            let vertexDesc = MTLVertexDescriptor()
            vertexDesc.attributes[0].format = .float2
            vertexDesc.attributes[0].offset = 0
            vertexDesc.attributes[0].bufferIndex = 0
            vertexDesc.attributes[1].format = .float
            vertexDesc.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
            vertexDesc.attributes[1].bufferIndex = 0
            vertexDesc.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride + MemoryLayout<Float>.stride
            desc.vertexDescriptor = vertexDesc
            desc.colorAttachments[0].pixelFormat = pixelFormat

            do {
                pipelineState = try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                print("Failed to create spectrum pipeline state: \(error)")
                pipelineState = nil
            }
        }

        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let passDesc = view.currentRenderPassDescriptor else { return }
            guard let pipelineState else { return }

            // Generate vertex data here at MTKView's cadence (30Hz), not in SwiftUI's updateNSView
            let sampleRate = spectrumProcessor.sampleRate
            let nyquist = sampleRate / 2.0
            let maxFreqDisplay: Float = min(20000.0, nyquist)

            let (vertexData, vertexCount) = SpectrumMeshBuilder.makeSpectrumVertices(
                processor: spectrumProcessor,
                minFrequency: 20.0,
                maxFrequency: maxFreqDisplay
            )

            // Upload to GPU
            update(vertexData: vertexData, vertexCount: vertexCount)

            guard let buf = vertexBuffer, vertexCount > 0 else { return }
            guard let cmd = commandQueue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc) else { return }
            enc.setRenderPipelineState(pipelineState)
            var colorComponents = simdColor(from: spectrumColor.opacity(0.2))
            enc.setFragmentBytes(&colorComponents, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            var themeInt: Int
            switch themeMode {
            case .light: themeInt = 0
            case .dark, .midnight: themeInt = 1
            case .thinMaterial: themeInt = 2
            case .liquidGlass: themeInt = 3
            case .purple: themeInt = 4
            case .mint: themeInt = 5
            case .lavender: themeInt = 6
            case .indigo: themeInt = 7
            case .gray: themeInt = 8
            case .hollow: themeInt = 9
            }
            enc.setFragmentBytes(&themeInt, length: MemoryLayout<Int>.size, index: 1)
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertexCount)
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    }


}
