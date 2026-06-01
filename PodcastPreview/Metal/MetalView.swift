//
//  MetalView.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 07/12/2025.
//

import SwiftUI
import AppKit
import Metal
import QuartzCore
import simd
import os.lock

enum MeterPeakHoldSettings {
    static var duration: TimeInterval = 1.0
}

private func simdColor(from color: Color) -> SIMD3<Float> {
    #if canImport(AppKit)
    let nsColor = NSColor(color)
    let rgb = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
    return SIMD3(Float(r), Float(g), Float(b))
    #else
    return SIMD3(0.0, 1.0, 0.0)
    #endif
}

struct MetalMeterView: NSViewRepresentable {
    @ObservedObject var monitoring: MonitoringState
    let channelIndex: Int

    func makeNSView(context: Context) -> MetalHostingView {
        MetalHostingView()
    }

    func updateNSView(_ nsView: MetalHostingView, context: Context) {
        let themeColor = monitoring.displayThemeColor
        nsView.baseColor = simdColor(from: themeColor)

        let (level, held) = levelForChannel()
        nsView.updateLevels(level: level, peakHold: held)
    }

    // Per-channel peak hold tracking
    private static var heldLevels: [Int: Float] = [:]
    private static var lastPeakTimes: [Int: Date] = [:]
    static var holdDuration: TimeInterval {
        get { MeterPeakHoldSettings.duration }
        set { MeterPeakHoldSettings.duration = newValue }
    }
    
    /// Clean up stale peak hold entries (call when device changes or monitoring stops)
    static func clearPeakHoldData() {
        heldLevels.removeAll()
        lastPeakTimes.removeAll()
    }

    private func levelForChannel() -> (Float, Float) {
        let meters = monitoring.channelMetering
        guard channelIndex < meters.count else { return (0, 0) }

        let now = Date()
        let linearPeak = meters[channelIndex].peak

        // Convert to dBFS and apply calibration offset
        let db = MeterScale.dbFS(fromLinear: linearPeak,
                                 minDB: MeterScale.defaultMinDB) + monitoring.meterCalibrationDB
        let level = MeterScale.normalized(fromDB: db,
                                          minDB: MeterScale.defaultMinDB,
                                          maxDB: MeterScale.defaultMaxDB)

        // Fetch current held values
        var held = MetalMeterView.heldLevels[channelIndex] ?? 0
        var lastTime = MetalMeterView.lastPeakTimes[channelIndex] ?? now

        // If this frame’s level is higher, update hold instantly
        if level > held {
            held = level
            lastTime = now
        } else {
            // If we've exceeded the hold duration, let the bar drop to the current level
            if now.timeIntervalSince(lastTime) > MeterPeakHoldSettings.duration {
                held = level
                lastTime = now
            }
        }

        MetalMeterView.heldLevels[channelIndex] = held
        MetalMeterView.lastPeakTimes[channelIndex] = lastTime

        return (level, held)
    }
}

struct MetalMeterStripView: NSViewRepresentable {
    let metering: [MeteringResult]
    let themeColor: Color
    let calibrationDB: Float
    let meterWidth: CGFloat
    let meterSpacing: CGFloat

    func makeNSView(context: Context) -> MetalMeterStripHostingView {
        MetalMeterStripHostingView()
    }

    func updateNSView(_ nsView: MetalMeterStripHostingView, context: Context) {
        nsView.updateMeters(
            metering: metering,
            calibrationDB: calibrationDB,
            color: simdColor(from: themeColor),
            meterWidth: meterWidth,
            meterSpacing: meterSpacing
        )
    }
}

struct MetalHorizontalMeterStripView: NSViewRepresentable {
    let levels: [Float]
    let peakHolds: [Float]
    let themeColor: Color
    let meterHeight: CGFloat
    let meterSpacing: CGFloat

    func makeNSView(context: Context) -> MetalHorizontalMeterStripHostingView {
        MetalHorizontalMeterStripHostingView()
    }

    func updateNSView(_ nsView: MetalHorizontalMeterStripHostingView, context: Context) {
        nsView.updateMeters(
            levels: levels,
            peakHolds: peakHolds,
            color: simdColor(from: themeColor),
            meterHeight: meterHeight,
            meterSpacing: meterSpacing
        )
    }
}

private struct MeterStripRenderState {
    var levels: [Float] = []
    var peakHolds: [Float] = []
    var color: SIMD3<Float> = SIMD3(0.0, 0.9, 0.0)
    var meterWidth: CGFloat = 12.0
    var meterSpacing: CGFloat = 4.0
}

private struct HorizontalMeterStripRenderState {
    var levels: [Float] = []
    var peakHolds: [Float] = []
    var color: SIMD3<Float> = SIMD3(0.0, 0.9, 0.0)
    var meterHeight: CGFloat = 12.0
    var meterSpacing: CGFloat = 4.0
}

private func isRenderable(_ view: NSView) -> Bool {
    if Thread.isMainThread {
        return view.window != nil && !view.bounds.isEmpty
    }

    return DispatchQueue.main.sync {
        view.window != nil && !view.bounds.isEmpty
    }
}

final class MetalMeterStripHostingView: NSView {
    private var metalLayer: CAMetalLayer!
    private var renderer: MultiChannelMetalRenderer!

    private var stateLock = os_unfair_lock_s()
    private var renderState = MeterStripRenderState()

    private var inFlightLock = os_unfair_lock_s()
    private var drawInFlight = false

    private var peakHolds: [Float] = []
    private var peakTimes: [Date] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.presentsWithTransaction = false
        if #available(macOS 10.13, *) {
            metalLayer.allowsNextDrawableTimeout = false
        }
        if #available(macOS 10.13.2, *) {
            metalLayer.maximumDrawableCount = 3
        }

        layer = metalLayer
        self.layer?.isOpaque = false

        renderer = MultiChannelMetalRenderer(device: metalLayer.device!)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    func updateMeters(
        metering: [MeteringResult],
        calibrationDB: Float,
        color: SIMD3<Float>,
        meterWidth: CGFloat,
        meterSpacing: CGFloat
    ) {
        let now = Date()
        var levels = [Float]()
        levels.reserveCapacity(metering.count)

        if peakHolds.count != metering.count {
            peakHolds = Array(repeating: 0.0, count: metering.count)
            peakTimes = Array(repeating: now, count: metering.count)
        }

        for (index, meter) in metering.enumerated() {
            let db = MeterScale.dbFS(fromLinear: meter.peak,
                                     minDB: MeterScale.defaultMinDB) + calibrationDB
            let level = MeterScale.normalized(fromDB: db,
                                              minDB: MeterScale.defaultMinDB,
                                              maxDB: MeterScale.defaultMaxDB)

            var held = peakHolds[index]
            var lastPeakTime = peakTimes[index]
            if level > held {
                held = level
                lastPeakTime = now
            } else if now.timeIntervalSince(lastPeakTime) > MeterPeakHoldSettings.duration {
                held = level
                lastPeakTime = now
            }

            levels.append(level)
            peakHolds[index] = held
            peakTimes[index] = lastPeakTime
        }

        os_unfair_lock_lock(&stateLock)
        renderState.levels = levels
        renderState.peakHolds = peakHolds
        renderState.color = color
        renderState.meterWidth = meterWidth
        renderState.meterSpacing = meterSpacing
        os_unfair_lock_unlock(&stateLock)

        requestDraw()
    }

    private func requestDraw() {
        os_unfair_lock_lock(&inFlightLock)
        if drawInFlight {
            os_unfair_lock_unlock(&inFlightLock)
            return
        }
        drawInFlight = true
        os_unfair_lock_unlock(&inFlightLock)

        os_unfair_lock_lock(&stateLock)
        let state = renderState
        os_unfair_lock_unlock(&stateLock)
        let shouldRender = isRenderable(self)

        MetalHostingView.renderQueue.async { [weak self] in
            guard let self else { return }
            defer {
                os_unfair_lock_lock(&self.inFlightLock)
                self.drawInFlight = false
                os_unfair_lock_unlock(&self.inFlightLock)
            }
            guard shouldRender else { return }
            self.drawFrame(state: state)
        }
    }

    private func drawFrame(state: MeterStripRenderState) {
        guard let drawable = metalLayer.nextDrawable() else { return }
        renderer.drawMeters(
            levels: state.levels,
            peakHolds: state.peakHolds,
            color: state.color,
            meterWidth: state.meterWidth,
            meterSpacing: state.meterSpacing,
            in: drawable
        )
    }

    override func layout() {
        super.layout()
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: bounds.width * metalLayer.contentsScale,
                                         height: bounds.height * metalLayer.contentsScale)
    }
}

final class MetalHorizontalMeterStripHostingView: NSView {
    private var metalLayer: CAMetalLayer!
    private var renderer: HorizontalMultiChannelMetalRenderer!

    private var stateLock = os_unfair_lock_s()
    private var renderState = HorizontalMeterStripRenderState()

    private var inFlightLock = os_unfair_lock_s()
    private var drawInFlight = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.presentsWithTransaction = false
        if #available(macOS 10.13, *) {
            metalLayer.allowsNextDrawableTimeout = false
        }
        if #available(macOS 10.13.2, *) {
            metalLayer.maximumDrawableCount = 3
        }

        layer = metalLayer
        self.layer?.isOpaque = false

        renderer = HorizontalMultiChannelMetalRenderer(device: metalLayer.device!)
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    func updateMeters(
        levels: [Float],
        peakHolds: [Float],
        color: SIMD3<Float>,
        meterHeight: CGFloat,
        meterSpacing: CGFloat
    ) {
        let clampedLevels = levels.map { min(max($0, 0.0), 1.0) }
        let clampedPeaks = peakHolds.map { min(max($0, 0.0), 1.0) }

        os_unfair_lock_lock(&stateLock)
        renderState.levels = clampedLevels
        renderState.peakHolds = clampedPeaks
        renderState.color = color
        renderState.meterHeight = meterHeight
        renderState.meterSpacing = meterSpacing
        os_unfair_lock_unlock(&stateLock)

        requestDraw()
    }

    private func requestDraw() {
        os_unfair_lock_lock(&inFlightLock)
        if drawInFlight {
            os_unfair_lock_unlock(&inFlightLock)
            return
        }
        drawInFlight = true
        os_unfair_lock_unlock(&inFlightLock)

        os_unfair_lock_lock(&stateLock)
        let state = renderState
        os_unfair_lock_unlock(&stateLock)
        let shouldRender = isRenderable(self)

        MetalHostingView.renderQueue.async { [weak self] in
            guard let self else { return }
            defer {
                os_unfair_lock_lock(&self.inFlightLock)
                self.drawInFlight = false
                os_unfair_lock_unlock(&self.inFlightLock)
            }
            guard shouldRender else { return }
            self.drawFrame(state: state)
        }
    }

    private func drawFrame(state: HorizontalMeterStripRenderState) {
        guard let drawable = metalLayer.nextDrawable() else { return }
        renderer.drawMeters(
            levels: state.levels,
            peakHolds: state.peakHolds,
            color: state.color,
            meterHeight: state.meterHeight,
            meterSpacing: state.meterSpacing,
            in: drawable
        )
    }

    override func layout() {
        super.layout()
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: bounds.width * metalLayer.contentsScale,
                                         height: bounds.height * metalLayer.contentsScale)
    }
}

final class MetalHostingView: NSView {
    static let renderQueue = DispatchQueue(label: "meter.metal.render", qos: .userInitiated)

    var metalLayer: CAMetalLayer!
    var renderer: MetalRenderer!

    // These are written on the main thread by SwiftUI updates, and read on the render thread.
    // Keep them simple and guarded.
    private var levelLock = os_unfair_lock_s()
    private var _level: Float = 0
    private var _peakHold: Float = 0

    // Prevent runaway queue backlogs if rendering can't keep up.
    private var inFlightLock = os_unfair_lock_s()
    private var drawInFlight: Bool = false

    var baseColor: SIMD3<Float> = SIMD3(0.0, 0.9, 0.0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0

        // Important for stutter reduction: avoid blocking when the drawable pool is exhausted.
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.presentsWithTransaction = false
        if #available(macOS 10.13, *) {
            metalLayer.allowsNextDrawableTimeout = false
        }
        if #available(macOS 10.13.2, *) {
            metalLayer.maximumDrawableCount = 3
        }

        layer = metalLayer
        self.layer?.isOpaque = false

        renderer = MetalRenderer(device: metalLayer.device!)!
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    func updateLevels(level: Float, peakHold: Float) {
        os_unfair_lock_lock(&levelLock)
        _level = level
        _peakHold = peakHold
        os_unfair_lock_unlock(&levelLock)

        requestDraw()
    }

    private func requestDraw() {
        drawFrameTick()
    }

    fileprivate func drawFrameTick() {
        // Render off-main-thread and only when new metering data arrives.
        // Guard against queue backlog: if a draw is already scheduled/running, skip this request.
        os_unfair_lock_lock(&inFlightLock)
        if drawInFlight {
            os_unfair_lock_unlock(&inFlightLock)
            return
        }
        drawInFlight = true
        os_unfair_lock_unlock(&inFlightLock)
        let shouldRender = isRenderable(self)

        MetalHostingView.renderQueue.async { [weak self] in
            guard let self else { return }
            defer {
                os_unfair_lock_lock(&self.inFlightLock)
                self.drawInFlight = false
                os_unfair_lock_unlock(&self.inFlightLock)
            }
            guard shouldRender else { return }
            self.drawFrame()
        }
    }

    private func drawFrame() {
        guard let drawable = metalLayer.nextDrawable() else { return }

        os_unfair_lock_lock(&levelLock)
        let level = _level
        let peakHold = _peakHold
        os_unfair_lock_unlock(&levelLock)

        renderer.drawLevel(level, peak: peakHold, color: baseColor, in: drawable)
    }

    override func layout() {
        super.layout()
        metalLayer.frame = bounds
        // Match drawableSize to view size; important for older GPUs to avoid implicit resizes.
        metalLayer.drawableSize = CGSize(width: bounds.width * metalLayer.contentsScale,
                                         height: bounds.height * metalLayer.contentsScale)
    }
}
