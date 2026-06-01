//
//  MetalOutputView.swift
//  AVCMeter
//
//  Created by Chris Izatt on 06/07/2025.
//

import Foundation
import CoreAudio
import SwiftUI
import MetalKit

#if os(macOS)
import AppKit
#endif



/// A simple Metal-powered capsule meter for audio **output** channels.
/// This mirrors `MetalCapsuleView`, but for output visualization only.
///
/// Currently this view uses placeholder fill values for scaffolding.
class MetalOutputView: MTKView, MTKViewDelegate {
    var channelIndex: Int = 0
    var themeMode: ThemeMode = .light
    var contextDeviceID: AudioDeviceID = 0
    var handler: OutputLevelHandler?

    // Output capsule meter state
    private var fillLevel: Float = 0.0
    private var lastUpdate: Date = .distantPast
    private var startColor: SIMD4<Float> = SIMD4<Float>(0.1, 0.6, 0.1, 1.0)
    private var endColor: SIMD4<Float> = SIMD4<Float>(0.2, 1.0, 0.2, 1.0)

    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        let metalDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frameRect, device: metalDevice)
        // Ensure transparency before any pipeline or view setup
        self.colorPixelFormat = .bgra8Unorm
        self.layer?.isOpaque = false
        self.layer?.backgroundColor = NSColor.clear.cgColor
        self.device = metalDevice
        self.commandQueue = metalDevice?.makeCommandQueue()
        self.delegate = self
        self.enableSetNeedsDisplay = false
        self.isPaused = false
        self.framebufferOnly = false
        self.preferredFramesPerSecond = 30
        self.clearColor = MTLClearColorMake(0, 0, 0, 0.0)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // Read current peak from output buffer
        let rawPeak = handler?(channelIndex) ?? 0.0
        let clamped = max(0.000_001, rawPeak)
        let db = 20.0 * log10(clamped)
        let norm = max(0.0, min(1.0, (db + 80.0) / 80.0))
        let targetFill = pow(norm, 1.5)

        // Exponential smoothing for fillLevel (time-based)
        let now = Date()
        let dt = Float(now.timeIntervalSince(lastUpdate))
        lastUpdate = now
        let smoothing: Float = 0.13
        if dt > 0.5 || fillLevel.isNaN {
            fillLevel = targetFill
        } else {
            let alpha = 1 - pow(1 - smoothing, dt * 60)
            fillLevel = fillLevel + (targetFill - fillLevel) * alpha
        }

        guard fillLevel > 0.01 else { return }

        // Level bands for color mapping
        let level = fillLevel
        if level > 0.95 {
            // Red for clipping
            startColor = SIMD4<Float>(1.0, 0.2, 0.2, 1.0)
            endColor = SIMD4<Float>(1.0, 0.4, 0.4, 1.0)
        } else if level > 0.75 {
            // Orange/Yellow for high
            startColor = SIMD4<Float>(1.0, 0.7, 0.1, 1.0)
            endColor = SIMD4<Float>(1.0, 0.9, 0.2, 1.0)
        } else {
            // Apply theme-specific colors for lower levels
            switch themeMode {
            case .light:
                startColor = SIMD4<Float>(0.2, 0.2, 1.0, 1.0)
                endColor = SIMD4<Float>(0.0, 0.0, 0.3, 0.5)     //green
            case .thinMaterial:
                startColor = SIMD4<Float>(0.0, 0.6, 0.7, 0.7)
                endColor = SIMD4<Float>(0.0, 0.2, 0.2, 0.3)     //turquoise
            case .purple:
                startColor = SIMD4<Float>(0.6, 0.2, 1.0, 1.0)  // vivid purple
                endColor = SIMD4<Float>(0.3, 0.0, 0.5, 0.5)    // deep purple
            case .dark:
                startColor = SIMD4<Float>(0.2, 0.6, 1.0, 1.0) // blue in dark mode
                endColor = SIMD4<Float>(0.0, 0.2, 0.4, 0.5)   // dark blue end
            case .mint:
                startColor = SIMD4<Float>(0.4, 1.0, 0.7, 1.0)
                endColor = SIMD4<Float>(0.1, 0.7, 0.4, 0.5)
            case .lavender:
                startColor = SIMD4<Float>(0.8, 0.7, 1.0, 1.0)
                endColor = SIMD4<Float>(0.5, 0.4, 0.7, 0.5)
            case .indigo:
                startColor = SIMD4<Float>(0.4, 0.3, 0.9, 1.0)
                endColor = SIMD4<Float>(0.15, 0.15, 0.4, 0.5)
            case .midnight:
                startColor = SIMD4<Float>(0.0, 0.4, 0.8, 1.0)
                endColor = SIMD4<Float>(0.0, 0.1, 0.2, 0.5)
            case .gray:
                startColor = SIMD4<Float>(0.7, 0.7, 0.7, 1.0)
                endColor = SIMD4<Float>(0.2, 0.2, 0.2, 0.5)
            case .hollow:
                startColor = SIMD4<Float>(0.9, 0.9, 0.9, 0.3)
                endColor = SIMD4<Float>(0.7, 0.7, 0.9, 0.1)
            case .liquidGlass:
                startColor = SIMD4<Float>(0.6, 0.9, 1.0, 0.7)
                endColor = SIMD4<Float>(0.3, 0.7, 0.9, 0.4)
            @unknown default:
                startColor = SIMD4<Float>(0.2, 0.6, 1.0, 1.0)
                endColor = SIMD4<Float>(0.0, 0.2, 0.4, 0.5)
            }
        }

        guard let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        preparePipelineIfNeeded()

        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0.0)
        descriptor.colorAttachments[0].loadAction = .clear

        /*
        guard fillLevel > 0.01 else {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }
        */

        if let pipelineState = pipelineState {
            encoder.setRenderPipelineState(pipelineState)

            // Capsule bar geometry (mirroring MetalCapsuleView)
            let screenWidth = Float(drawableSize.width)
            let screenHeight = Float(drawableSize.height)
            let capsuleWidth: Float = min(12.8, screenWidth)
            let barInset: Float = 1.5
            let barHeight = min(screenHeight - barInset * 2, 260)
            let barWidth = capsuleWidth - barInset * 2
            let x0 = (screenWidth - barWidth) / 2
            let x1 = x0 + barWidth
            let y0 = barInset
            let y1 = y0 + barHeight * 0.9

            // Convert to NDC
            func toNDCx(_ x: Float) -> Float { return (x / screenWidth) * 2 - 1 }
            func toNDCy(_ y: Float) -> Float { return (y / screenHeight) * 2 - 1 }

            let ndcLeft = toNDCx(x0)
            let ndcRight = toNDCx(x1)
            let ndcBottom = toNDCy(barInset)
            let ndcTop = toNDCy(y1)

            // Draw from bottom up
            let quadVertices: [Float] = [
                ndcLeft, ndcBottom, 0, 1,
                ndcRight, ndcBottom, 1, 1,
                ndcLeft, ndcTop, 0, 0,
                ndcRight, ndcTop, 1, 0
            ]

            let vertexBuffer = device!.makeBuffer(bytes: quadVertices, length: quadVertices.count * MemoryLayout<Float>.size, options: [])
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

            // Fragment uniforms
            var fill = min(max(fillLevel, Float(0.0)), Float(0.9))
            encoder.setFragmentBytes(&fill, length: MemoryLayout<Float>.size, index: 0)
            var start = startColor
            encoder.setFragmentBytes(&start, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            var end = endColor
            encoder.setFragmentBytes(&end, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
            var themeRaw: Int32 = {
                  switch themeMode {
                      case .light: return 0
                      case .dark, .midnight: return 1
                      case .thinMaterial: return 2
                      case .liquidGlass, .poorMansGlass: return 3
                      case .purple: return 4
                      case .mint: return 5
                      case .lavender: return 6
                      case .indigo: return 7
                      case .gray: return 8
                      case .hollow: return 9
                  }
              }()
            encoder.setFragmentBytes(&themeRaw, length: MemoryLayout<Int32>.size, index: 3)

            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func preparePipelineIfNeeded() {
        guard pipelineState == nil, let device = device else { return }

        let library: MTLLibrary? = {
            if let metallibURL = Bundle(for: MetalOutputView.self).url(forResource: "default", withExtension: "metallib"),
               let frameworkLibrary = try? device.makeLibrary(URL: metallibURL) {
                return frameworkLibrary
            }
            return device.makeDefaultLibrary()
        }()
        let vertexFunction = library?.makeFunction(name: "vertex_main")
        let fragmentFunction = library?.makeFunction(name: "fragment_main")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.size * 2
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.size * 4

        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = self.colorPixelFormat

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("Failed to create output meter pipeline state: \(error)")
        }
    }
}

/// SwiftUI view combining the Metal output capsule with textual RMS and peak value displays.
struct MetalOutputCapsuleWithText: View {
    @EnvironmentObject var themeManager: ThemeManager
    var channelIndex: Int
    var deviceID: AudioDeviceID
    var handler: OutputLevelHandler
    var channelHeaderYOffset: CGFloat = 18
    var channelHeaderYOffsetCPU: CGFloat = 42
    var capsuleYOffset: CGFloat = 0
    var showDbLabel: Bool = true
    var rmsText: String = "−∞"
    var rmsDb: Float = -100.0
    var showsRmsText: Bool = false
    var showsFeatureIcons: Bool = false
    var spectrumIconOn: Bool = false
    var spectrogramIconOn: Bool = false
    var waveformIconOn: Bool = false
    var onToggleSpectrum: (() -> Void)? = nil
    var onToggleSpectrogram: (() -> Void)? = nil
    var onToggleWaveform: (() -> Void)? = nil

    @State private var heldPeak: Float = -100.0
    @State private var displayedPeakText: String = "−∞"

    var body: some View {
        let isCPUBackend = RenderBackendResolver.resolveMeterBackend() == .cpu
        let themeMode = themeManager.deviceCapsuleThemes[deviceID] ?? themeManager.capsuleThemeMode

        VStack(spacing: 4) {
            Text("\(channelIndex + 1)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .offset(y: isCPUBackend ? channelHeaderYOffsetCPU : channelHeaderYOffset)

            Group {
                if isCPUBackend {
                    CPUOutputCapsuleView(
                        channelIndex: channelIndex,
                        themeMode: themeMode,
                        handler: handler
                    )
                } else {
                    MetalOutputCapsuleRepresentable(
                        channelIndex: channelIndex,
                        themeMode: themeMode,
                        contextDeviceID: deviceID,
                        handler: handler
                    )
                }
            }
            .frame(width: 12.8, height: 280)
            .offset(y: 14 + capsuleYOffset)

            VStack(spacing: 2) {
                Text(displayedPeakText)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(color(for: heldPeak))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: true, vertical: false)
                    .onTapGesture {
                        heldPeak = -100.0
                        displayedPeakText = "−∞"
                    }
                    .onAppear {
                        refreshPeakText()
                    }
                    .onReceive(MeterUpdateCoordinator.shared.publisher) { _ in
                        refreshPeakText()
                    }

                if showsRmsText {
                    Text(rmsText)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(rmsColor(for: rmsDb))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if showDbLabel {
                    Text("dB")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            if showsFeatureIcons {
                Button(action: { onToggleSpectrum?() }) {
                    Image(systemName: "waveform")
                        .padding(.top, 4)
                        .font(.system(size: 10, weight: .medium, design: .default))
                        .foregroundColor(iconColor(isOn: spectrumIconOn, theme: themeMode))
                }
                .buttonStyle(.plain)
                .help(spectrumIconOn ? "Close FFT Spectrum" : "Open FFT Spectrum")

                Button(action: { onToggleSpectrogram?() }) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .padding(.top, 6)
                        .font(.system(size: 10, weight: .medium, design: .default))
                        .foregroundColor(iconColor(isOn: spectrogramIconOn, theme: themeMode))
                }
                .buttonStyle(.plain)
                .help(spectrogramIconOn ? "Close Spectrogram" : "Open Spectrogram")

                Button(action: { onToggleWaveform?() }) {
                    Image(systemName: "waveform.path.ecg")
                        .padding(.top, 6)
                        .font(.system(size: 10, weight: .medium, design: .default))
                        .foregroundColor(iconColor(isOn: waveformIconOn, theme: themeMode))
                }
                .buttonStyle(.plain)
                .help(waveformIconOn ? "Close Waveform" : "Open Waveform")
            }
        }
    }

    private func color(for db: Float) -> Color {
        if db >= -6.0 { return .red }
        if db >= -18.0 { return .orange }
        if db >= -24.0 { return Color.green.opacity(0.7) }
        if db >= -40.0 { return .green }
        return .secondary
    }

    private func refreshPeakText() {
        let peakSample = handler(channelIndex)
        let peak = 20 * log10(max(peakSample, 0.000_001))
        guard peak > heldPeak else { return }

        heldPeak = peak
        if peak.isNaN || peak.isInfinite || peak < -100.0 {
            displayedPeakText = "−∞"
        } else {
            displayedPeakText = String(format: "%.0f", peak + 4.0)
        }
    }

    private func rmsColor(for db: Float) -> Color {
        if db >= -6.0 { return .red }
        if db >= -18.0 { return .orange }
        if db >= -24.0 { return Color(red: 0.4, green: 1.0, blue: 0.4) }
        if db >= -40.0 { return .green }
        if db >= -64.0 { return Color(red: 0.1, green: 0.6, blue: 0.1) }
        return .secondary
    }

    private func iconColor(isOn: Bool, theme: ThemeMode) -> Color {
        isOn ? .white : waveformIconColor(for: theme)
    }

    private func waveformIconColor(for theme: ThemeMode) -> Color {
        switch theme {
        case .light:
            return Color(red: 0.2, green: 0.6, blue: 0.2)
        case .thinMaterial:
            return Color(red: 0.0, green: 0.6, blue: 0.7)
        case .purple:
            return Color(red: 0.6, green: 0.2, blue: 1.0)
        case .mint:
            return Color(red: 0.62, green: 0.96, blue: 0.78)
        case .lavender:
            return Color.purple.opacity(0.6)
        case .indigo:
            return Color(red: 0.29, green: 0.0, blue: 0.51)
        case .gray:
            return Color.gray
        case .hollow:
            return Color.clear
        case .dark:
            return Color(red: 0.2, green: 0.6, blue: 1.0)
        case .midnight:
            return Color(red: 0.4, green: 0.8, blue: 1.0)
        @unknown default:
            return Color.blue
        }
    }
}

/// SwiftUI wrapper for `MetalOutputView`, to be used like MetalCapsuleView.
struct MetalOutputCapsuleRepresentable: NSViewRepresentable {
    var channelIndex: Int
    var themeMode: ThemeMode
    var contextDeviceID: AudioDeviceID
    var handler: OutputLevelHandler?

    func makeNSView(context: Context) -> MetalOutputView {
        let view = MetalOutputView(frame: CGRect(x: 0, y: 0, width: 12.8, height: 280), device: MTLCreateSystemDefaultDevice())
        view.channelIndex = channelIndex
        view.themeMode = themeMode
        view.contextDeviceID = contextDeviceID
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: MetalOutputView, context: Context) {
        nsView.themeMode = themeMode
    }
}


struct OutputMeterTileView: View {
    @EnvironmentObject var outputManager: OutputDeviceManager
    @EnvironmentObject var themeManager: ThemeManager

    let deviceID: AudioDeviceID
    let device: AudioDevice
    let grouped: Bool

    var body: some View {
        ZStack {
            Color.clear

            VStack(spacing: 6) {
                if grouped {
                    Text(device.name)
                        .font(.system(size: 11, weight: .semibold, design: .default))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: 120)
                        .padding(.bottom, 2)
                }

                HStack(spacing: 8) {
                    ForEach(0..<device.outputChannels, id: \.self) { channelIndex in
                        if let handler = outputManager.outputContexts[deviceID]?.handler {
                            MetalOutputCapsuleRepresentable(
                                channelIndex: Int(channelIndex),
                                themeMode: themeManager.deviceCapsuleThemes[deviceID] ?? themeManager.capsuleThemeMode,
                                contextDeviceID: deviceID,
                                handler: handler
                            )
                            .frame(width: 12.8, height: 280)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
        }
    }
}
