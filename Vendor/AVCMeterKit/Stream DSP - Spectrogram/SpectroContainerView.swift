//
//  SpectroContainerView.swift
//  AVCMeter
//
//  Created by Chris Izatt on 29/06/2025.
//

import SwiftUI
import MetalKit
#if os(macOS)
import AppKit
#endif

/// A SwiftUI-compatible view that hosts a Metal-based spectrogram renderer.
///
/// Use this view to display a real-time spectrum analyzer using Metal.
/// - Parameters:
///   - deviceID: Audio device ID to monitor.
///   - channelIndex: Specific input channel index.
///   - fftSize: FFT size (number of bins).
///   - themeColor: Primary color used for rendering spectrum.
struct SpectroContainerView: NSViewRepresentable {
    let deviceID: Int32           ///< Audio device ID to monitor
    let channelIndex: Int32       ///< Specific input channel index
    let fftSize: Int32            ///< FFT size (number of bins)
    let themeColor: SIMD4<Float>  ///< Primary color used for rendering spectrum
    let themeMode: Int32          ///< Theme mode id passed to the shader
    let externalAudioSource: FFTAudioSource? ///< Optional mixer-fed source for non-input channels

    init(
        deviceID: Int32,
        channelIndex: Int32,
        fftSize: Int32,
        themeColor: SIMD4<Float>,
        themeMode: Int32 = 0,
        externalAudioSource: FFTAudioSource? = nil
    ) {
        self.deviceID = deviceID
        self.channelIndex = channelIndex
        self.fftSize = fftSize
        self.themeColor = themeColor
        self.themeMode = themeMode
        self.externalAudioSource = externalAudioSource
    }

    /// Coordinator class connecting MTKView to the Metal renderer
    public class Coordinator: NSObject, MTKViewDelegate {
        var renderer: MetalSpectroRenderer?
        let deviceID: Int32
        let channelIndex: Int32
        let fftSize: Int32
        var externalFeed: MixerSpectrogramFeed?
        var parent: SpectroContainerView?

        /// Initializes the coordinator with references needed for rendering
        /// - Parameters:
        ///   - renderer: An optional MetalSpectroRenderer to be wired at runtime
        ///   - deviceID: Audio device identifier
        ///   - channelIndex: Channel number for rendering
        ///   - fftSize: Size of FFT window
        init(renderer: MetalSpectroRenderer?, deviceID: Int32, channelIndex: Int32, fftSize: Int32) {
            self.renderer = renderer
            self.deviceID = deviceID
            self.channelIndex = channelIndex
            self.fftSize = fftSize
        }

        /// Called when the drawable size changes — currently unused
        /// - Parameter view: The MetalKit view whose drawable size changed
        /// - Parameter size: The new size of the drawable
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        /// Called once per frame to draw the spectrogram mesh
        /// - Parameter view: The MetalKit view being rendered to
        func draw(in view: MTKView) {
            guard let renderer = renderer else { return }
            renderer.draw(in: view)
        }

        @objc func closeButtonTapped() {
            NSApp.keyWindow?.close()
        }
    }

    /// Creates the coordinator which acts as the MTKView delegate
    /// - Returns: Configured coordinator instance
    public func makeCoordinator() -> SpectroContainerView.Coordinator {
        let coordinator = Coordinator(renderer: nil, deviceID: deviceID, channelIndex: channelIndex, fftSize: fftSize)
        coordinator.parent = self
        return coordinator
    }

    /// Sets up the underlying MTKView for the spectrogram
    /// - Parameter context: SwiftUI context to wire the coordinator
    /// - Returns: Configured MTKView instance
    func makeNSView(context: Context) -> MTKView {
        // Ensure Metal is available
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        let mtkView = MTKView(frame: .zero, device: metalDevice)
        let theme = SpectroVisualTheme(spectrumColor: themeColor, themeMode: themeMode)
        let renderer = MetalSpectroRenderer(mtkView: mtkView, theme: theme, deviceID: deviceID, channelIndex: channelIndex)
        context.coordinator.renderer = renderer
        if let externalSource = context.coordinator.parent?.externalAudioSource {
            let feeder = MixerSpectrogramFeed(source: externalSource, deviceID: deviceID, channelIndex: channelIndex)
            context.coordinator.externalFeed = feeder
            feeder.start()
        } else {
            context.coordinator.externalFeed = nil
        }
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = 30
        mtkView.delegate = context.coordinator

        let closeButton = NSButton(title: "X", target: nil, action: #selector(context.coordinator.closeButtonTapped))
        closeButton.target = context.coordinator
        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        closeButton.contentTintColor = .black
        closeButton.wantsLayer = true
        closeButton.layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.2).cgColor
        closeButton.layer?.cornerRadius = 8
        closeButton.layer?.masksToBounds = true
        closeButton.frame = NSRect(x: mtkView.bounds.width - 20, y: mtkView.bounds.height - 20, width: 16, height: 16)
        closeButton.autoresizingMask = [.minXMargin, .minYMargin]
        mtkView.addSubview(closeButton)

        return mtkView
    }

    /// Updates the view with new configuration — currently unused
    /// - Parameters:
    ///   - nsView: The MTKView instance to update
    ///   - context: SwiftUI context for coordinator and updates
    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.renderer?.updateTheme(
            SpectroVisualTheme(spectrumColor: themeColor, themeMode: themeMode)
        )
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.externalFeed?.stop()
        coordinator.externalFeed = nil
        SpectroManager.shared.releaseSpectrogramSession(
            deviceID: UInt32(coordinator.deviceID),
            channel: coordinator.channelIndex
        )
    }
}

// MARK: - Backend-selecting wrapper

/// Drop-in replacement for `SpectroContainerView` that routes to the Metal or CPU
/// renderer based on `RenderBackendResolver.resolveSpectrogramBackend()`.
///
/// Call sites that previously used `SpectroContainerView` should use this instead.
/// The Metal path delegates to `SpectroContainerView`; the CPU path delegates to
/// `CPUSpectrogramView`. Both honour the same session lifecycle.
struct SpectroBackendView: View {
    let deviceID: Int32
    let channelIndex: Int32
    let fftSize: Int32
    let themeColor: SIMD4<Float>
    let themeMode: Int32
    let deviceName: String
    let scale: CGFloat
    let externalAudioSource: FFTAudioSource?

    // Observing settings causes body to re-evaluate when the user switches mode.
    @ObservedObject private var settings = VisualisationSettings.shared

    init(
        deviceID: Int32,
        channelIndex: Int32,
        fftSize: Int32,
        themeColor: SIMD4<Float>,
        themeMode: Int32 = 0,
        deviceName: String,
        scale: CGFloat = 1.0,
        externalAudioSource: FFTAudioSource? = nil
    ) {
        self.deviceID = deviceID
        self.channelIndex = channelIndex
        self.fftSize = fftSize
        self.themeColor = themeColor
        self.themeMode = themeMode
        self.deviceName = deviceName
        self.scale = scale
        self.externalAudioSource = externalAudioSource
    }

    var body: some View {
        ZStack(alignment: .top) {
            if RenderBackendResolver.resolveSpectrogramBackend() == .cpu {
                CPUSpectrogramView(
                    deviceID: deviceID,
                    channelIndex: channelIndex,
                    themeColor: themeColor,
                    themeMode: themeMode,
                    externalAudioSource: externalAudioSource
                )
            } else {
                SpectroContainerView(
                    deviceID: deviceID,
                    channelIndex: channelIndex,
                    fftSize: fftSize,
                    themeColor: themeColor,
                    themeMode: themeMode,
                    externalAudioSource: externalAudioSource
                )
            }

            Text("\(deviceName) – Channel \(channelIndex + 1)")
                .font(.system(size: 18 * scale, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 10)
        }
    }
}
