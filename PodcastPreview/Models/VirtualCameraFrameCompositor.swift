import Foundation
import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import IOSurface
import SwiftUI
import PodcastPreviewCore

struct VirtualCameraPublisherFrameSnapshot: Codable {
    let frameSequence: UInt64
    let surfaceID: UInt32
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let frameRate: Double
    let layerCount: Int
    let rendererBackend: String
}

final class VirtualCameraCaptureSource {
    private let monitoringModel = VideoMonitoringModel()
    private let stateQueue = DispatchQueue(label: "VirtualCameraCaptureSource.state")
    private var latestPixelBuffer: CVPixelBuffer?

    init(uniqueID: String) {
        monitoringModel.previewMode = .metal
        monitoringModel.formatPreference = .auto
        monitoringModel.onFrame = { [weak self] pixelBuffer, _ in
            guard let self else { return }
            self.stateQueue.async {
                self.latestPixelBuffer = pixelBuffer
            }
        }
        monitoringModel.refreshDevices()
        monitoringModel.selectCamera(uniqueID: uniqueID)
    }

    var session: AVCaptureSession {
        monitoringModel.session
    }

    func latestFrame() -> CVPixelBuffer? {
        stateQueue.sync {
            latestPixelBuffer
        }
    }

    func stop() {
        monitoringModel.onFrame = nil
        monitoringModel.selectCamera(uniqueID: nil)
        monitoringModel.stop()
    }
}

@MainActor
final class VirtualCameraFrameCompositor {
    static let rendererBackend = "iosurface-bgra-compositor-v1"

    private let transportRootURL: URL
    private let frameEncoder: PropertyListEncoder
    private let ciContext = CIContext(options: nil)
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0
    private var frameSequence: UInt64 = 0
    private var recentPixelBuffers: [CVPixelBuffer] = []
    private var captureSources: [String: VirtualCameraCaptureSource] = [:]
    private var cachedImages: [URL: CGImage] = [:]
    private var cachedMovieGenerators: [URL: AVAssetImageGenerator] = [:]

    init(transportRootURL: URL) {
        self.transportRootURL = transportRootURL
        let frameEncoder = PropertyListEncoder()
        frameEncoder.outputFormat = .xml
        self.frameEncoder = frameEncoder
    }

    func stop() {
        for source in captureSources.values {
            if let uniqueID = captureSources.first(where: { $0.value === source })?.key {
                VirtualCameraCaptureSourcePool.shared.release(uniqueID: uniqueID)
            }
        }
        captureSources.removeAll()
        cachedImages.removeAll()
        cachedMovieGenerators.removeAll()
        recentPixelBuffers.removeAll()
        pixelBufferPool = nil
        poolWidth = 0
        poolHeight = 0
        frameSequence = 0
    }

    func renderFrame(snapshot: VirtualCameraRenderSnapshot) throws -> VirtualCameraPublisherFrameSnapshot? {
        let width = max(Int(snapshot.canvasSize.width.rounded()), 1)
        let height = max(Int(snapshot.canvasSize.height.rounded()), 1)
        reconcileCaptureSources(with: snapshot.layers)

        guard let pixelBuffer = makePixelBuffer(width: width, height: height) else {
            return nil
        }

        let currentFrameSequence = frameSequence
        frameSequence += 1

        render(snapshot: snapshot, frameSequence: currentFrameSequence, into: pixelBuffer)

        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            return nil
        }

        let snapshotRecord = VirtualCameraPublisherFrameSnapshot(
            frameSequence: currentFrameSequence,
            surfaceID: IOSurfaceGetID(surface),
            width: width,
            height: height,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            frameRate: max(snapshot.frameRate, 1),
            layerCount: snapshot.layers.count,
            rendererBackend: Self.rendererBackend
        )

        let data = try frameEncoder.encode(snapshotRecord)
        try data.write(to: Self.frameStatePropertyListURL(rootURL: transportRootURL), options: .atomic)

        recentPixelBuffers.append(pixelBuffer)
        if recentPixelBuffers.count > 8 {
            recentPixelBuffers.removeFirst(recentPixelBuffers.count - 8)
        }

        return snapshotRecord
    }

    func renderFrame(resolution: String, frameRate: Double, layers: [VirtualCameraLayer]) throws -> VirtualCameraPublisherFrameSnapshot? {
        let canvasSize = Self.parseResolution(resolution)
        reconcileCaptureSources(with: layers)

        guard let pixelBuffer = makePixelBuffer(width: canvasSize.width, height: canvasSize.height) else {
            return nil
        }

        let currentFrameSequence = frameSequence
        frameSequence += 1

        render(layers: layers, frameSequence: currentFrameSequence, frameRate: frameRate, into: pixelBuffer, canvasSize: CGSize(width: canvasSize.width, height: canvasSize.height))

        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            return nil
        }

        let snapshot = VirtualCameraPublisherFrameSnapshot(
            frameSequence: currentFrameSequence,
            surfaceID: IOSurfaceGetID(surface),
            width: canvasSize.width,
            height: canvasSize.height,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            frameRate: max(frameRate, 1),
            layerCount: layers.count,
            rendererBackend: Self.rendererBackend
        )

        let data = try frameEncoder.encode(snapshot)
        try data.write(to: Self.frameStatePropertyListURL(rootURL: transportRootURL), options: .atomic)

        recentPixelBuffers.append(pixelBuffer)
        if recentPixelBuffers.count > 8 {
            recentPixelBuffers.removeFirst(recentPixelBuffers.count - 8)
        }

        return snapshot
    }

    static func frameStatePropertyListURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent("publisher-frame.plist")
    }

    private static func parseResolution(_ resolution: String) -> (width: Int, height: Int) {
        let parts = resolution
            .lowercased()
            .split(separator: "x", maxSplits: 1)
            .map(String.init)

        if parts.count == 2,
           let width = Int(parts[0]),
           let height = Int(parts[1]),
           width > 0,
           height > 0 {
            return (width, height)
        }

        return (1920, 1080)
    }

    private func reconcileCaptureSources(with layers: [VirtualCameraLayer]) {
        let desiredIDs = Set(layers.compactMap { layer in
            layer.type == .videoSource ? layer.videoDeviceID : nil
        })

        for existingID in captureSources.keys where !desiredIDs.contains(existingID) {
            VirtualCameraCaptureSourcePool.shared.release(uniqueID: existingID)
            captureSources.removeValue(forKey: existingID)
        }

        for desiredID in desiredIDs where captureSources[desiredID] == nil {
            captureSources[desiredID] = VirtualCameraCaptureSourcePool.shared.acquire(uniqueID: desiredID)
        }
    }

    private func reconcileCaptureSources(with layers: [VirtualCameraRenderLayerSnapshot]) {
        let desiredIDs = Set(layers.compactMap(\.videoDeviceID))

        for existingID in captureSources.keys where !desiredIDs.contains(existingID) {
            VirtualCameraCaptureSourcePool.shared.release(uniqueID: existingID)
            captureSources.removeValue(forKey: existingID)
        }

        for desiredID in desiredIDs where captureSources[desiredID] == nil {
            captureSources[desiredID] = VirtualCameraCaptureSourcePool.shared.acquire(uniqueID: desiredID)
        }
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        guard width > 0, height > 0 else { return nil }

        if pixelBufferPool == nil || poolWidth != width || poolHeight != height {
            pixelBufferPool = createPixelBufferPool(width: width, height: height)
            poolWidth = width
            poolHeight = height
        }

        guard let pixelBufferPool else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer)
        guard status == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private func createPixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 8
        ]
        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferBytesPerRowAlignmentKey: width * 4,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [
                kIOSurfaceIsGlobal: true
            ] as CFDictionary
        ]

        var pixelBufferPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &pixelBufferPool
        )
        guard status == kCVReturnSuccess else { return nil }
        return pixelBufferPool
    }

    private func render(layers: [VirtualCameraLayer], frameSequence: UInt64, frameRate: Double, into pixelBuffer: CVPixelBuffer, canvasSize: CGSize) {
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let context = CGContext(
            data: baseAddress,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return
        }

        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: canvasSize))
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: canvasSize.height)
        context.scaleBy(x: 1, y: -1)

        for layer in layers.reversed() where layer.isVisible && layer.opacity > 0 {
            draw(layer: layer, frameSequence: frameSequence, frameRate: frameRate, in: context, canvasSize: canvasSize)
        }
    }

    private func render(snapshot: VirtualCameraRenderSnapshot, frameSequence: UInt64, into pixelBuffer: CVPixelBuffer) {
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard lockStatus == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let canvasSize = snapshot.canvasSize
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let context = CGContext(
            data: baseAddress,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return
        }

        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: canvasSize))
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: canvasSize.height)
        context.scaleBy(x: 1, y: -1)

        for layer in snapshot.layers.reversed() where layer.isVisible && layer.opacity > 0 {
            draw(layer: layer, frameSequence: frameSequence, frameRate: snapshot.frameRate, in: context, canvasSize: canvasSize)
        }
    }

    private func draw(layer: VirtualCameraLayer, frameSequence: UInt64, frameRate: Double, in context: CGContext, canvasSize: CGSize) {
        switch layer.type {
        case .videoSource:
            guard let videoDeviceID = layer.videoDeviceID,
                  let pixelBuffer = captureSources[videoDeviceID]?.latestFrame(),
                  let cgImage = ciContext.createCGImage(CIImage(cvPixelBuffer: pixelBuffer), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))) else {
                return
            }
            drawImage(cgImage, for: layer, in: context, canvasSize: canvasSize)
        case .image:
            guard let imageURL = layer.imageURL,
                  let cgImage = loadStaticImage(from: imageURL) else {
                return
            }
            drawImage(cgImage, for: layer, in: context, canvasSize: canvasSize)
        case .mediaFile:
            guard let mediaURL = layer.mediaURL else { return }
            switch layer.mediaKind {
            case .image:
                guard let cgImage = loadStaticImage(from: mediaURL) else { return }
                drawImage(cgImage, for: layer, in: context, canvasSize: canvasSize)
            case .movie:
                guard let cgImage = loadMovieFrame(from: mediaURL, frameSequence: frameSequence, frameRate: frameRate) else { return }
                drawImage(cgImage, for: layer, in: context, canvasSize: canvasSize)
            }
        case .text:
            drawText(layer: layer, in: context, canvasSize: canvasSize)
        }
    }

    private func draw(layer: VirtualCameraRenderLayerSnapshot, frameSequence: UInt64, frameRate: Double, in context: CGContext, canvasSize: CGSize) {
        switch layer.source {
        case let .videoSource(deviceID, _):
            guard let videoDeviceID = deviceID,
                  let pixelBuffer = captureSources[videoDeviceID]?.latestFrame(),
                  let cgImage = ciContext.createCGImage(CIImage(cvPixelBuffer: pixelBuffer), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))) else {
                return
            }
            drawImage(cgImage, for: layer, in: context, canvasSize: canvasSize)
        case let .image(imageURL):
            guard let imageURL,
                  let cgImage = loadStaticImage(from: imageURL) else {
                return
            }
            drawImage(cgImage, for: layer, in: context, canvasSize: canvasSize)
        case let .mediaFile(mediaURL, mediaKind):
            guard let mediaURL else { return }
            switch mediaKind {
            case .image:
                guard let cgImage = loadStaticImage(from: mediaURL) else { return }
                drawImage(cgImage, for: layer, in: context, canvasSize: canvasSize)
            case .movie:
                guard let cgImage = loadMovieFrame(from: mediaURL, frameSequence: frameSequence, frameRate: frameRate) else { return }
                drawImage(cgImage, for: layer, in: context, canvasSize: canvasSize)
            }
        case .text:
            drawText(layer: layer, in: context, canvasSize: canvasSize)
        }
    }

    private func drawImage(_ cgImage: CGImage, for layer: VirtualCameraLayer, in context: CGContext, canvasSize: CGSize) {
        let sourceSize = CGSize(width: max(cgImage.width, 1), height: max(cgImage.height, 1))
        let baseSize = fittedSize(for: sourceSize, within: CGSize(width: canvasSize.width * 0.6, height: canvasSize.height * 0.6))
        let anchor = CGPoint(x: canvasSize.width * 0.5 + layer.position.x, y: canvasSize.height * 0.5 + layer.position.y)

        context.saveGState()
        context.setAlpha(CGFloat(layer.opacity))
        context.translateBy(x: anchor.x, y: anchor.y)
        context.rotate(by: CGFloat(layer.rotationDegrees) * .pi / 180)
        context.scaleBy(x: max(layer.scale, 0.01), y: max(layer.scale, 0.01))
        context.draw(cgImage, in: CGRect(x: -baseSize.width / 2, y: -baseSize.height / 2, width: baseSize.width, height: baseSize.height))
        context.restoreGState()
    }

    private func drawImage(_ cgImage: CGImage, for layer: VirtualCameraRenderLayerSnapshot, in context: CGContext, canvasSize: CGSize) {
        let sourceSize = CGSize(width: max(cgImage.width, 1), height: max(cgImage.height, 1))
        let baseSize = layer.fittedContentSize(for: sourceSize, in: canvasSize)
        let anchor = layer.anchor(in: canvasSize)

        context.saveGState()
        context.setAlpha(layer.opacity)
        context.translateBy(x: anchor.x, y: anchor.y)
        context.rotate(by: CGFloat(layer.rotationDegrees) * .pi / 180)
        context.scaleBy(x: max(layer.scale, 0.01), y: max(layer.scale, 0.01))
        context.draw(cgImage, in: CGRect(x: -baseSize.width / 2, y: -baseSize.height / 2, width: baseSize.width, height: baseSize.height))
        context.restoreGState()
    }

    private func drawText(layer: VirtualCameraLayer, in context: CGContext, canvasSize: CGSize) {
        guard !layer.text.isEmpty else { return }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = nsTextAlignment(for: layer.textAlignment)

        let nsColor = NSColor(layer.textColor).usingColorSpace(.deviceRGB) ?? .white
        let attributedText = NSAttributedString(
            string: layer.text,
            attributes: [
                .font: font(for: layer),
                .foregroundColor: nsColor,
                .paragraphStyle: paragraphStyle
            ]
        )

        let bounds = attributedText.boundingRect(
            with: CGSize(width: canvasSize.width * 0.7, height: canvasSize.height * 0.7),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).integral

        let anchor = CGPoint(x: canvasSize.width * 0.5 + layer.position.x, y: canvasSize.height * 0.5 + layer.position.y)

        context.saveGState()
        context.setAlpha(CGFloat(layer.opacity))
        context.translateBy(x: anchor.x, y: anchor.y)
        context.rotate(by: CGFloat(layer.rotationDegrees) * .pi / 180)
        context.scaleBy(x: max(layer.scale, 0.01), y: max(layer.scale, 0.01))

        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        attributedText.draw(
            with: CGRect(x: -bounds.width / 2, y: -bounds.height / 2, width: max(bounds.width, 1), height: max(bounds.height, 1)),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        NSGraphicsContext.current = previousContext

        context.restoreGState()
    }

    private func drawText(layer: VirtualCameraRenderLayerSnapshot, in context: CGContext, canvasSize: CGSize) {
        guard let textStyle = layer.textStyle, !textStyle.text.isEmpty else { return }

        let attributedText = textStyle.attributedString()
        let bounds = textStyle.boundingRect(maxSize: CGSize(width: canvasSize.width * 0.7, height: canvasSize.height * 0.7))
        let anchor = layer.anchor(in: canvasSize)

        context.saveGState()
        context.setAlpha(layer.opacity)
        context.translateBy(x: anchor.x, y: anchor.y)
        context.rotate(by: CGFloat(layer.rotationDegrees) * .pi / 180)
        context.scaleBy(x: max(layer.scale, 0.01), y: max(layer.scale, 0.01))

        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        attributedText.draw(
            with: CGRect(x: -bounds.width / 2, y: -bounds.height / 2, width: max(bounds.width, 1), height: max(bounds.height, 1)),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        NSGraphicsContext.current = previousContext

        context.restoreGState()
    }

    private func loadStaticImage(from url: URL) -> CGImage? {
        if let cachedImage = cachedImages[url] {
            return cachedImage
        }

        guard let image = NSImage(contentsOf: url) else { return nil }
        var proposedRect = CGRect.zero
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }

        cachedImages[url] = cgImage
        return cgImage
    }

    private func loadMovieFrame(from url: URL, frameSequence: UInt64, frameRate: Double) -> CGImage? {
        let generator: AVAssetImageGenerator
        if let cachedGenerator = cachedMovieGenerators[url] {
            generator = cachedGenerator
        } else {
            let newGenerator = AVAssetImageGenerator(asset: AVAsset(url: url))
            newGenerator.appliesPreferredTrackTransform = true
            newGenerator.requestedTimeToleranceBefore = .zero
            newGenerator.requestedTimeToleranceAfter = .zero
            cachedMovieGenerators[url] = newGenerator
            generator = newGenerator
        }

        let durationSeconds = CMTimeGetSeconds(generator.asset.duration)
        let timeSeconds: Double
        if durationSeconds.isFinite, durationSeconds > 0 {
            timeSeconds = (Double(frameSequence) / max(frameRate, 1)).truncatingRemainder(dividingBy: durationSeconds)
        } else {
            timeSeconds = 0
        }

        return try? generator.copyCGImage(at: CMTime(seconds: timeSeconds, preferredTimescale: 600), actualTime: nil)
    }

    private func font(for layer: VirtualCameraLayer) -> NSFont {
        var font = NSFont(name: layer.fontFamily, size: layer.fontSize) ?? NSFont.systemFont(ofSize: layer.fontSize)
        if layer.isBold {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if layer.isItalic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    private func nsTextAlignment(for alignment: VirtualCameraLayer.TextAlignmentOption) -> NSTextAlignment {
        switch alignment {
        case .leading:
            return .left
        case .center:
            return .center
        case .trailing:
            return .right
        }
    }

    private func fittedSize(for sourceSize: CGSize, within maxSize: CGSize) -> CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0, maxSize.width > 0, maxSize.height > 0 else {
            return CGSize(width: 1, height: 1)
        }

        let widthScale = maxSize.width / sourceSize.width
        let heightScale = maxSize.height / sourceSize.height
        let scale = min(widthScale, heightScale)

        return CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    }
}
