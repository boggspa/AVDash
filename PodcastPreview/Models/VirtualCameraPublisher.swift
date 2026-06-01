import Foundation
import AppKit
import Combine
import SwiftUI
import PodcastPreviewCore

struct VirtualCameraPublisherColorSnapshot: Codable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
}

struct VirtualCameraPublisherPointSnapshot: Codable {
    let x: Double
    let y: Double
}

struct VirtualCameraPublisherLayerSnapshot: Codable {
    let id: UUID
    let type: String
    let name: String
    let isVisible: Bool
    let opacity: Float
    let position: VirtualCameraPublisherPointSnapshot
    let scale: Double
    let rotationDegrees: Double
    let videoDeviceID: String?
    let imageURL: String?
    let mediaURL: String?
    let mediaKind: String?
    let text: String?
    let textColor: VirtualCameraPublisherColorSnapshot?
    let fontSize: Double?
    let fontFamily: String?
    let textAlignment: String?
    let isBold: Bool?
    let isItalic: Bool?
}

struct VirtualCameraPublisherSessionSnapshot: Codable {
    let deviceName: String
    let resolution: String
    let frameRate: Double
    let startedAt: Date
    let layers: [VirtualCameraPublisherLayerSnapshot]
    let rendererBackend: String
}

struct VirtualCameraDALRuntimeStatus: Codable, Equatable {
    let statusVersion: Int
    let lastUpdatedAtReferenceTime: Double
    let isStreamRunning: Bool
    let isSuspended: Bool
    let isUsingPublishedSurface: Bool
    let isFallbackActive: Bool
    let startCount: UInt32
    let queueDepth: UInt32
    let width: UInt32
    let height: UInt32
    let frameRate: Double
    let layerCount: UInt32
    let lastDriverFrameSequence: UInt64
    let lastPublishedFrameSequence: UInt64?

    var updatedAt: Date {
        Date(timeIntervalSinceReferenceDate: lastUpdatedAtReferenceTime)
    }

    var isStale: Bool {
        Date().timeIntervalSince(updatedAt) > 2.0
    }

    var healthState: String {
        if isStale { return "Stale" }
        if !isStreamRunning { return "Idle" }
        if isSuspended { return "Suspended" }
        if isFallbackActive { return "Fallback" }
        if isUsingPublishedSurface { return "Consuming" }
        return "Waiting"
    }
}

@MainActor
final class VirtualCameraPublisher: ObservableObject {
    static let shared = VirtualCameraPublisher()

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var statusMessage: String = "Composer publisher is idle."
    @Published private(set) var lastPublishedFrameSequence: UInt64?
    @Published private(set) var lastPublishedResolutionText: String = "—"
    @Published private(set) var lastPublishedFrameRateText: String = "—"
    @Published private(set) var lastPublishedLayerCount: Int = 0
    @Published private(set) var publishFailureCount: Int = 0
    @Published private(set) var lastPublishedAt: Date?

    @Published private(set) var runtimeStatus: VirtualCameraDALRuntimeStatus?

    private let jsonEncoder: JSONEncoder
    private let propertyListEncoder: PropertyListEncoder
    private var compositor: VirtualCameraFrameCompositor?
    private var frameTimer: Timer?
    private var runtimeStatusTimer: Timer?
    private var activeFrameRate: Double = 0
    private var lastPublishMetricsTick: TimeInterval = Date().timeIntervalSinceReferenceDate
    private var publishedFramesSinceLastMetricsTick: Int = 0

    private init() {
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        jsonEncoder.dateEncodingStrategy = .iso8601

        let propertyListEncoder = PropertyListEncoder()
        propertyListEncoder.outputFormat = .xml

        self.jsonEncoder = jsonEncoder
        self.propertyListEncoder = propertyListEncoder

        startRuntimeStatusPolling()
    }

    func start(
        deviceName: String,
        resolution: String,
        frameRate: Double,
        layers: [VirtualCameraLayer]
    ) {
        resetPublishMetrics()
        let stateURL = Self.sessionStateURL()
        let propertyListURL = Self.sessionStatePropertyListURL()
        let renderSnapshot = VirtualCameraComposerModel.shared.makeRenderSnapshot()
        let snapshot = VirtualCameraPublisherSessionSnapshot(
            deviceName: deviceName,
            resolution: resolution,
            frameRate: frameRate,
            startedAt: Date(),
            layers: renderSnapshot.layers.map(Self.makeLayerSnapshot(from:)),
            rendererBackend: VirtualCameraFrameCompositor.rendererBackend
        )

        do {
            try persistSessionSnapshot(snapshot, jsonURL: stateURL, propertyListURL: propertyListURL)
            stopFrameTimer()
            compositor?.stop()
            compositor = VirtualCameraFrameCompositor(transportRootURL: Self.transportRootURL())
            isRunning = true
            statusMessage = "Composer publisher wrote session state and started IOSurface frame export."
            AppDebugConsole.log(statusMessage, category: "Video")
            startFrameTimer(frameRate: frameRate)
            publishFrameTick()
        } catch {
            stopFrameTimer()
            compositor?.stop()
            compositor = nil
            isRunning = false
            statusMessage = "Composer publisher failed to persist session state: \(error.localizedDescription)"
            AppDebugConsole.log(statusMessage, category: "Video")
        }
    }

    func stop() {
        let stateURL = Self.sessionStateURL()
        let propertyListURL = Self.sessionStatePropertyListURL()
        let frameStateURL = Self.frameStatePropertyListURL()
        stopFrameTimer()
        compositor?.stop()
        compositor = nil
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: propertyListURL)
        try? FileManager.default.removeItem(at: frameStateURL)
        isRunning = false
        resetPublishMetrics()
        statusMessage = "Composer publisher is idle."
        AppDebugConsole.log("Composer publisher stopped and cleared session state.", category: "Video")
    }

    static func transportRootURL(fileManager: FileManager = .default) -> URL {
        if let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupportURL
                .appendingPathComponent("PodcastPreview", isDirectory: true)
                .appendingPathComponent("VirtualCamera", isDirectory: true)
        }

        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PodcastPreviewVirtualCamera", isDirectory: true)
    }

    static func sessionStateURL(fileManager: FileManager = .default) -> URL {
        transportRootURL(fileManager: fileManager)
            .appendingPathComponent("publisher-session.json")
    }

    static func sessionStatePropertyListURL(fileManager: FileManager = .default) -> URL {
        transportRootURL(fileManager: fileManager)
            .appendingPathComponent("publisher-session.plist")
    }

    static func frameStatePropertyListURL(fileManager: FileManager = .default) -> URL {
        transportRootURL(fileManager: fileManager)
            .appendingPathComponent("publisher-frame.plist")
    }

    static func runtimeStatusPropertyListURL(fileManager: FileManager = .default) -> URL {
        transportRootURL(fileManager: fileManager)
            .appendingPathComponent("runtime-status.plist")
    }

    private func persistSessionSnapshot(
        _ snapshot: VirtualCameraPublisherSessionSnapshot,
        jsonURL: URL,
        propertyListURL: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: jsonURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encodedJSON = try jsonEncoder.encode(snapshot)
        let encodedPropertyList = try propertyListEncoder.encode(snapshot)
        try encodedJSON.write(to: jsonURL, options: .atomic)
        try encodedPropertyList.write(to: propertyListURL, options: .atomic)
    }

    private func startFrameTimer(frameRate: Double) {
        stopFrameTimer()

        let sanitizedFrameRate = max(frameRate, 1)
        activeFrameRate = sanitizedFrameRate
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / sanitizedFrameRate, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishFrameTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func stopFrameTimer() {
        frameTimer?.invalidate()
        frameTimer = nil
        activeFrameRate = 0
    }

    private func startRuntimeStatusPolling() {
        runtimeStatusTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollRuntimeStatus()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        runtimeStatusTimer = timer
    }

    private func pollRuntimeStatus() {
        let url = Self.runtimeStatusPropertyListURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            if runtimeStatus != nil { runtimeStatus = nil }
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = PropertyListDecoder()
            let status = try decoder.decode(VirtualCameraDALRuntimeStatus.self, from: data)
            if runtimeStatus != status {
                runtimeStatus = status
            }
        } catch {
            // Silently ignore decode errors for now
        }
    }

    private func publishFrameTick() {
        guard isRunning, let compositor else { return }

        let composer = VirtualCameraComposerModel.shared
        let renderSnapshot = composer.makeRenderSnapshot()
        let currentFrameRate = max(renderSnapshot.frameRate, 1)
        if abs(activeFrameRate - currentFrameRate) > 0.001 {
            startFrameTimer(frameRate: currentFrameRate)
        }

        do {
            if let publishedSnapshot = try compositor.renderFrame(snapshot: renderSnapshot) {
                recordPublishedFrame(publishedSnapshot)
            }
        } catch {
            publishFailureCount += 1
            statusMessage = "Composer publisher failed to publish IOSurface frame: \(error.localizedDescription)"
            AppDebugConsole.log(statusMessage, category: "Video")
        }
    }

    private func resetPublishMetrics() {
        lastPublishedFrameSequence = nil
        lastPublishedResolutionText = "—"
        lastPublishedFrameRateText = "—"
        lastPublishedLayerCount = 0
        publishFailureCount = 0
        lastPublishedAt = nil
        lastPublishMetricsTick = Date().timeIntervalSinceReferenceDate
        publishedFramesSinceLastMetricsTick = 0
    }

    private func recordPublishedFrame(_ snapshot: VirtualCameraPublisherFrameSnapshot) {
        lastPublishedFrameSequence = snapshot.frameSequence
        lastPublishedResolutionText = "\(snapshot.width)×\(snapshot.height)"
        lastPublishedLayerCount = snapshot.layerCount
        lastPublishedAt = Date()

        publishedFramesSinceLastMetricsTick += 1
        let now = Date().timeIntervalSinceReferenceDate
        let elapsed = now - lastPublishMetricsTick
        if elapsed >= 0.5 {
            let fps = Double(publishedFramesSinceLastMetricsTick) / elapsed
            lastPublishedFrameRateText = String(format: "%.0f fps", fps)
            publishedFramesSinceLastMetricsTick = 0
            lastPublishMetricsTick = now
        } else if lastPublishedFrameRateText == "—" {
            lastPublishedFrameRateText = String(format: "%.0f fps", snapshot.frameRate)
        }
    }

    private static func makeLayerSnapshot(from layer: VirtualCameraRenderLayerSnapshot) -> VirtualCameraPublisherLayerSnapshot {
        let textStyle = layer.textStyle
        let colorSnapshot = textStyle.map { textStyle in
            VirtualCameraPublisherColorSnapshot(
                red: Double(textStyle.color.red),
                green: Double(textStyle.color.green),
                blue: Double(textStyle.color.blue),
                alpha: Double(textStyle.color.alpha)
            )
        }

        return VirtualCameraPublisherLayerSnapshot(
            id: layer.id,
            type: layerTypeName(for: layer.source),
            name: layer.name,
            isVisible: layer.isVisible,
            opacity: Float(layer.opacity),
            position: VirtualCameraPublisherPointSnapshot(
                x: Double(layer.normalizedCenter.x),
                y: Double(layer.normalizedCenter.y)
            ),
            scale: Double(layer.scale),
            rotationDegrees: layer.rotationDegrees,
            videoDeviceID: layer.videoDeviceID,
            imageURL: layer.imageURL?.absoluteString,
            mediaURL: layer.mediaURL?.absoluteString,
            mediaKind: layer.mediaKind?.rawValue,
            text: textStyle?.text,
            textColor: colorSnapshot,
            fontSize: textStyle.map { Double($0.fontSize) },
            fontFamily: textStyle?.fontFamily,
            textAlignment: textStyle?.alignment.rawValue,
            isBold: textStyle?.isBold,
            isItalic: textStyle?.isItalic
        )
    }

    private static func makeLayerSnapshot(from layer: VirtualCameraLayer) -> VirtualCameraPublisherLayerSnapshot {
        VirtualCameraPublisherLayerSnapshot(
            id: layer.id,
            type: layer.type.rawValue,
            name: layer.name,
            isVisible: layer.isVisible,
            opacity: layer.opacity,
            position: VirtualCameraPublisherPointSnapshot(
                x: layer.position.x,
                y: layer.position.y
            ),
            scale: layer.scale,
            rotationDegrees: layer.rotationDegrees,
            videoDeviceID: layer.videoDeviceID,
            imageURL: layer.imageURL?.absoluteString,
            mediaURL: layer.mediaURL?.absoluteString,
            mediaKind: layer.type == .mediaFile ? layer.mediaKind.rawValue : nil,
            text: layer.type == .text ? layer.text : nil,
            textColor: layer.type == .text ? colorSnapshot(from: layer.textColor) : nil,
            fontSize: layer.type == .text ? layer.fontSize : nil,
            fontFamily: layer.type == .text ? layer.fontFamily : nil,
            textAlignment: layer.type == .text ? layer.textAlignment.rawValue : nil,
            isBold: layer.type == .text ? layer.isBold : nil,
            isItalic: layer.type == .text ? layer.isItalic : nil
        )
    }

    private static func layerTypeName(for source: VirtualCameraRenderLayerSource) -> String {
        switch source {
        case .videoSource:
            return VirtualCameraLayer.LayerType.videoSource.rawValue
        case .image:
            return VirtualCameraLayer.LayerType.image.rawValue
        case .mediaFile:
            return VirtualCameraLayer.LayerType.mediaFile.rawValue
        case .text:
            return VirtualCameraLayer.LayerType.text.rawValue
        }
    }

    private static func colorSnapshot(from color: Color) -> VirtualCameraPublisherColorSnapshot? {
        let converted = NSColor(color).usingColorSpace(.deviceRGB)
        guard let converted else { return nil }
        return VirtualCameraPublisherColorSnapshot(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent),
            alpha: Double(converted.alphaComponent)
        )
    }
}
