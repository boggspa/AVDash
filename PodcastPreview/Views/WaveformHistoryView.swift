//
//  WaveformHistoryView.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 18/03/2026.
//

import SwiftUI
import PodcastPreviewShared
import Combine
import AppKit
import Metal
import QuartzCore
import simd

// MARK: - Waveform History View

struct WaveformHistoryView: View {
    @Environment(\.appUIScale) private var appUIScale
    @ObservedObject var monitoring: MonitoringState
    @Binding var historyDuration: TimeInterval

    private var scaledHeight: CGFloat { 80 * appUIScale }
    private var scaledPadding: CGFloat { 12 * appUIScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Waveform History")
                    .font(.system(size: 13 * appUIScale, weight: .semibold))

                Spacer()

                // Duration picker
                Menu {
                    Button("1 second") { historyDuration = 1.0 }
                    Button("2 seconds") { historyDuration = 2.0 }
                    Button("5 seconds") { historyDuration = 5.0 }
                    Button("10 seconds") { historyDuration = 10.0 }
                    Button("30 seconds") { historyDuration = 30.0 }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(Int(historyDuration))s")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            MetalWaveformHistoryView(
                monitoring: monitoring,
                historyDuration: historyDuration
            )
            .frame(height: scaledHeight)
            .background(
                ThemeRoundedRectangle(cornerRadius: 16).themed(fill: Color.black.opacity(0.15), stroke: Color.clear)
            )
        }
        .padding(scaledPadding)
    }
}

// MARK: - Metal Waveform History View

struct MetalWaveformHistoryView: NSViewRepresentable {
    @ObservedObject var monitoring: MonitoringState
    var historyDuration: TimeInterval

    func makeNSView(context: Context) -> WaveformHistoryHostingView {
        WaveformHistoryHostingView(
            monitoring: monitoring,
            historyDuration: historyDuration
        )
    }

    func updateNSView(_ nsView: WaveformHistoryHostingView, context: Context) {
        let theme = monitoring.displayWaveformThemeColor
        nsView.baseColor = simdColor(from: theme)
        nsView.historyDuration = historyDuration
    }

    private func simdColor(from color: Color) -> SIMD3<Float> {
        let nsColor = NSColor(color)
        let rgbColor = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        return SIMD3(
            Float(rgbColor.redComponent),
            Float(rgbColor.greenComponent),
            Float(rgbColor.blueComponent)
        )
    }
}

// MARK: - Waveform History Hosting View

final class WaveformHistoryHostingView: NSView {
    private var metalLayer: CAMetalLayer!
    private var renderer: WaveformHistoryRenderer!
    private var displayLink: CVDisplayLink?

    var baseColor: SIMD3<Float> = SIMD3(0, 1, 0)
    var historyDuration: TimeInterval = 2.0

    private weak var monitoring: MonitoringState?

    // Waveform data storage: circular buffer of amplitude envelopes
    private var waveformBuffer: [WaveformSample] = []
    private var bufferCapacity: Int = 0
    private var writeIndex: Int = 0

    // Sample timing
    private var sampleRate: Double = 48000.0
    private var lastUpdateTime: Date?

    // Rendering optimization
    private let targetFPS: CFTimeInterval = 20.0
    private var lastRenderTime: CFTimeInterval = 0

    struct WaveformSample {
        var minAmplitude: Float  // Negative peak (for bottom of waveform)
        var maxAmplitude: Float  // Positive peak (for top of waveform)
        var timestamp: Date

        static let zero = WaveformSample(minAmplitude: 0, maxAmplitude: 0, timestamp: Date())
    }

    init(monitoring: MonitoringState, historyDuration: TimeInterval) {
        self.monitoring = monitoring
        self.historyDuration = historyDuration

        super.init(frame: .zero)

        // Initialize circular buffer
        updateBufferCapacity()

        // Setup Metal layer
        wantsLayer = true
        metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        layer = metalLayer

        if let device = metalLayer.device {
            renderer = WaveformHistoryRenderer(device: device)
        }

        // Setup display link with a fixed time-based render cap.
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        displayLink = link

        if let dl = displayLink {
            CVDisplayLinkSetOutputHandler(dl) { [weak self] _, _, _, _, _ in
                guard let self = self else { return kCVReturnSuccess }

                let now = CACurrentMediaTime()
                if (now - self.lastRenderTime) < (1.0 / self.targetFPS) {
                    return kCVReturnSuccess
                }
                self.lastRenderTime = now

                DispatchQueue.main.async {
                    self.captureWaveformSample()
                    self.drawFrame()
                }
                return kCVReturnSuccess
            }
            CVDisplayLinkStart(dl)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }

    // MARK: - Buffer Management

    private func updateBufferCapacity() {
        // Calculate samples needed for the history duration
        // We want roughly 2-4 samples per pixel for smooth waveform display
        let pixelsPerSecond: Double = 100.0  // Reasonable density for waveform display
        let targetSamples = Int(historyDuration * pixelsPerSecond)

        if bufferCapacity != targetSamples {
            bufferCapacity = targetSamples
            waveformBuffer = Array(repeating: .zero, count: bufferCapacity)
            writeIndex = 0
        }
    }

    // MARK: - Audio Capture

    private func captureWaveformSample() {
        guard let monitoring = monitoring else { return }
        guard let rb = monitoring.currentRingBuffer() else { return }

        // Get sample rate from device
        if monitoring.displaySampleRate > 0 {
            sampleRate = monitoring.displaySampleRate
        }

        // Calculate samples per waveform point
        let now = Date()
        let targetInterval = historyDuration / Double(bufferCapacity)

        if let last = lastUpdateTime {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < targetInterval {
                return  // Skip this frame to maintain target sample rate
            }
        }
        lastUpdateTime = now

        // Get the currently selected channel (same as spectrum analyzer)
        let channel = Int32(FFTAnalyser_GetSelectedChannel())

        // Calculate how many audio frames to analyze for this waveform sample
        // We want to capture enough samples to show the amplitude envelope
        let samplesPerPoint = Int(sampleRate * targetInterval)

        // Read audio data from ring buffer
        var samples = [Float](repeating: 0, count: samplesPerPoint)
        let result = RingBuffer_ReadChannel(rb, channel, &samples, UInt32(samplesPerPoint))

        guard result == 0 else { return }

        // Calculate min/max amplitude for this time slice (amplitude envelope)
        var minAmp: Float = 0.0
        var maxAmp: Float = 0.0

        for sample in samples {
            if sample < minAmp { minAmp = sample }
            if sample > maxAmp { maxAmp = sample }
        }

        // Store in circular buffer
        let waveformSample = WaveformSample(
            minAmplitude: minAmp,
            maxAmplitude: maxAmp,
            timestamp: now
        )

        waveformBuffer[writeIndex] = waveformSample
        writeIndex = (writeIndex + 1) % bufferCapacity

        // Clean up old samples that are outside our history window
        cleanupOldSamples()
    }

    private func cleanupOldSamples() {
        let now = Date()
        let cutoffTime = now.addingTimeInterval(-historyDuration)

        // Mark samples older than cutoff as zero
        for i in 0..<bufferCapacity {
            if waveformBuffer[i].timestamp < cutoffTime {
                waveformBuffer[i] = .zero
            }
        }
    }

    // MARK: - Rendering

    private func buildVertices() -> [SIMD2<Float>] {
        updateBufferCapacity()  // Ensure buffer matches current duration setting

        var vertices: [SIMD2<Float>] = []
        vertices.reserveCapacity(bufferCapacity * 2)

        let now = Date()

        // Build vertices from oldest to newest (left to right)
        // Read from circular buffer starting at writeIndex (oldest) to writeIndex-1 (newest)
        for i in 0..<bufferCapacity {
            let bufferIndex = (writeIndex + i) % bufferCapacity
            let sample = waveformBuffer[bufferIndex]

            // Calculate age and position
            let age = now.timeIntervalSince(sample.timestamp)
            let normalizedAge = Float(age / historyDuration)  // 0.0 (newest) to 1.0 (oldest)

            // X position: -1.0 (oldest/left) to +1.0 (newest/right)
            let x = (1.0 - normalizedAge) * 2.0 - 1.0

            // Y positions: map amplitude to -1.0 to +1.0 range
            // Apply slight scaling to prevent clipping at edges
            let yScale: Float = 0.9
            let yMin = sample.minAmplitude * yScale
            let yMax = sample.maxAmplitude * yScale

            // Add two vertices per sample: top and bottom
            vertices.append(SIMD2<Float>(x, yMax))  // Top
            vertices.append(SIMD2<Float>(x, yMin))  // Bottom
        }

        return vertices
    }

    private func drawFrame() {
        guard let drawable = metalLayer.nextDrawable(),
              let renderer = renderer else { return }

        let vertices = buildVertices()
        renderer.updateWaveform(vertices)
        renderer.drawWaveform(baseColor, in: drawable)
    }

    override func layout() {
        super.layout()
        metalLayer.frame = bounds
    }
}

// MARK: - Metal Renderer

final class WaveformHistoryRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState

    private var vertexBuffer: MTLBuffer?
    private var vertexCount: Int = 0

    init(device: MTLDevice) {
        let compilerCache = HardwareMetalCompilerCache.shared
        guard let sharedDevice = compilerCache.device,
              let queue = compilerCache.commandQueue,
              let pipelineState = compilerCache.pipelineState(
                vertexFunctionName: "waveformVertexShader",
                fragmentFunctionName: "waveformFragmentShader",
                pixelFormat: .bgra8Unorm,
                blendingMode: .preMultipliedAlpha
              ) else {
            fatalError("Failed to create pipeline state")
        }

        self.device = sharedDevice
        self.commandQueue = queue
        self.pipelineState = pipelineState
    }

    func updateWaveform(_ vertices: [SIMD2<Float>]) {
        guard !vertices.isEmpty else { return }

        let dataSize = vertices.count * MemoryLayout<SIMD2<Float>>.stride
        vertexBuffer = device.makeBuffer(bytes: vertices, length: dataSize, options: [])
        vertexCount = vertices.count
    }

    func drawWaveform(_ color: SIMD3<Float>, in drawable: CAMetalDrawable) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let vertexBuffer = vertexBuffer,
              vertexCount > 0 else { return }
        commandBuffer.label = "WaveformHistoryRenderer.Draw"
        MetalGPUStatsCollector.shared.record(commandBuffer: commandBuffer)

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        // Pass color as fragment shader argument
        var colorUniform = color
        encoder.setFragmentBytes(&colorUniform, length: MemoryLayout<SIMD3<Float>>.size, index: 0)

        // Draw as triangle strip (fills between top and bottom vertices)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertexCount)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
