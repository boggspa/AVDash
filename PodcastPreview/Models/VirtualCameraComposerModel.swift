
import Foundation
import SwiftUI
import Combine
import AVFoundation
import Metal
import AppKit
import PodcastPreviewCore

class VirtualCameraLayer: Identifiable, ObservableObject, Equatable {
    let id = UUID()

    enum LayerType: String, CaseIterable, Identifiable {
        case videoSource = "Video Source"
        case mediaFile = "Media File"
        case image = "Image"
        case text = "Text"

        var id: String { rawValue }
    }

    enum FileSourceKind: String, CaseIterable, Identifiable {
        case image = "Image"
        case movie = "Movie"

        var id: String { rawValue }
    }

    enum TextAlignmentOption: String, CaseIterable, Identifiable {
        case leading = "Left"
        case center = "Center"
        case trailing = "Right"

        var id: String { rawValue }

        var textAlignment: TextAlignment {
            switch self {
            case .leading:
                return .leading
            case .center:
                return .center
            case .trailing:
                return .trailing
            }
        }
    }

    @Published var type: LayerType
    @Published var name: String
    @Published var isVisible: Bool = true
    @Published var opacity: Float = 1.0
    @Published var position: CGPoint = .zero
    @Published var scale: CGFloat = 1.0
    @Published var rotationDegrees: Double = 0

    // Type-specific data
    @Published var videoDeviceID: String? = nil
    @Published var imageURL: URL? = nil
    @Published var mediaURL: URL? = nil
    @Published var mediaKind: FileSourceKind = .image
    @Published var text: String = "Overlay Text"
    @Published var textColor: Color = .white
    @Published var fontSize: CGFloat = 40
    @Published var fontFamily: String = NSFont.systemFont(ofSize: NSFont.systemFontSize).familyName ?? "System"
    @Published var textAlignment: TextAlignmentOption = .center
    @Published var isBold: Bool = false
    @Published var isItalic: Bool = false

    init(type: LayerType, name: String) {
        self.type = type
        self.name = name
    }

    static func == (lhs: VirtualCameraLayer, rhs: VirtualCameraLayer) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class VirtualCameraComposerModel: ObservableObject {
    static let shared = VirtualCameraComposerModel()

    private static let preferredFrameRates: [Double] = [
        12,
        15,
        23.976,
        24,
        25,
        29.97,
        30,
        48,
        50,
        59.94,
        60,
        90,
        100,
        120,
        144,
        240
    ]

    @Published var isOutputActive: Bool = false
    @Published var deviceName: String = "PodcastPreview Virtual Camera"
    @Published var resolution: String = "1920x1080"
    @Published var frameRate: Double = 30

    @Published var layers: [VirtualCameraLayer] = []
    @Published var availableVideoDevices: [VideoMonitoringModel.CameraDevice] = []
    @Published private(set) var availableFrameRates: [Double] = [24, 30, 60]
    @Published private(set) var availableFontFamilies: [String] = []

    private var cancellables = Set<AnyCancellable>()

    init() {
        availableFontFamilies = NSFontManager.shared.availableFontFamilies.sorted()
        refreshDevices()
    }

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )

        availableVideoDevices = discovery.devices.map { dev in
            VideoMonitoringModel.CameraDevice(id: dev.uniqueID, uniqueID: dev.uniqueID, displayName: dev.localizedName)
        }

        let supportedFrameRates = Self.supportedFrameRates(for: discovery.devices)
        availableFrameRates = supportedFrameRates.isEmpty ? Self.preferredFrameRates : supportedFrameRates

        if !availableFrameRates.contains(where: { abs($0 - frameRate) < 0.001 }) {
            frameRate = availableFrameRates.first(where: { abs($0 - 30) < 0.001 }) ?? availableFrameRates.first ?? 30
        }
    }

    func addLayer(type: VirtualCameraLayer.LayerType) {
        let count = layers.filter { $0.type == type }.count + 1
        let layer = VirtualCameraLayer(type: type, name: "\(type.rawValue) \(count)")

        switch type {
        case .videoSource:
            layer.videoDeviceID = availableVideoDevices.first?.uniqueID
            if let deviceName = cameraDisplayName(for: layer.videoDeviceID) {
                layer.name = deviceName
            }
        case .mediaFile:
            layer.mediaKind = .image
        case .image:
            break
        case .text:
            if let systemFamily = availableFontFamilies.first(where: { $0 == layer.fontFamily }) {
                layer.fontFamily = systemFamily
            } else if let firstFamily = availableFontFamilies.first {
                layer.fontFamily = firstFamily
            }
        }

        layers.insert(layer, at: 0) // Add to top
    }

    func removeLayer(id: UUID) {
        layers.removeAll { $0.id == id }
    }

    func moveLayer(from source: IndexSet, to destination: Int) {
        layers.move(fromOffsets: source, toOffset: destination)
    }

    func toggleOutput() {
        isOutputActive.toggle()
        if isOutputActive {
            startVirtualCamera()
        } else {
            stopVirtualCamera()
        }
    }

    private func startVirtualCamera() {
        print("Starting Virtual Camera Output: \(deviceName) (\(resolution) @ \(frameRateLabel(frameRate))fps)")
        VirtualCameraPublisher.shared.start(
            deviceName: deviceName,
            resolution: resolution,
            frameRate: frameRate,
            layers: layers
        )
        if !VirtualCameraPublisher.shared.isRunning {
            isOutputActive = false
        }
    }

    private func stopVirtualCamera() {
        print("Stopping Virtual Camera Output")
        VirtualCameraPublisher.shared.stop()
    }

    func installDriver() {
        VirtualCameraDriverService.shared.installDriver()
    }

    func uninstallDriver() {
        VirtualCameraDriverService.shared.uninstallDriver()
    }

    func cameraDisplayName(for uniqueID: String?) -> String? {
        guard let uniqueID else { return nil }
        return availableVideoDevices.first(where: { $0.uniqueID == uniqueID })?.displayName
    }

    func recognizedSourceName(for layer: VirtualCameraLayer) -> String {
        switch layer.type {
        case .videoSource:
            return cameraDisplayName(for: layer.videoDeviceID) ?? "No Camera Source"
        case .mediaFile:
            return layer.mediaURL?.lastPathComponent ?? "No Media File"
        case .image:
            return layer.imageURL?.lastPathComponent ?? "No Image"
        case .text:
            return layer.text.isEmpty ? "Text Layer" : layer.text
        }
    }

    func updateSourceNameIfNeeded(for layer: VirtualCameraLayer) {
        let currentLowercased = layer.name.lowercased()
        let shouldUpdate = currentLowercased.hasPrefix(layer.type.rawValue.lowercased())
            || currentLowercased.contains("no source")
            || currentLowercased.contains("no image")
            || currentLowercased.contains("media file")
            || cameraDisplayName(for: layer.videoDeviceID) == layer.name

        guard shouldUpdate else { return }
        layer.name = recognizedSourceName(for: layer)
    }

    func makeRenderSnapshot() -> VirtualCameraRenderSnapshot {
        let canvasSize = VirtualCameraRenderSnapshot.parseResolution(resolution)
        return VirtualCameraRenderSnapshot(
            deviceName: deviceName,
            resolution: resolution,
            frameRate: frameRate,
            canvasSize: canvasSize,
            layers: layers.map { makeRenderLayerSnapshot(from: $0, canvasSize: canvasSize) }
        )
    }

    func makeRenderLayerSnapshot(from layer: VirtualCameraLayer, canvasSize: CGSize) -> VirtualCameraRenderLayerSnapshot {
        let normalizedCenter = CGPoint(
            x: 0.5 + (canvasSize.width > 0 ? (layer.position.x / canvasSize.width) : 0),
            y: 0.5 + (canvasSize.height > 0 ? (layer.position.y / canvasSize.height) : 0)
        )

        let source: VirtualCameraRenderLayerSource
        switch layer.type {
        case .videoSource:
            source = .videoSource(deviceID: layer.videoDeviceID, displayName: cameraDisplayName(for: layer.videoDeviceID))
        case .mediaFile:
            source = .mediaFile(url: layer.mediaURL, kind: layer.mediaKind)
        case .image:
            source = .image(url: layer.imageURL)
        case .text:
            source = .text(
                VirtualCameraRenderTextStyle(
                    text: layer.text,
                    color: VirtualCameraRenderColor(color: layer.textColor),
                    fontSize: layer.fontSize,
                    fontFamily: layer.fontFamily,
                    alignment: layer.textAlignment,
                    isBold: layer.isBold,
                    isItalic: layer.isItalic
                )
            )
        }

        return VirtualCameraRenderLayerSnapshot(
            id: layer.id,
            name: layer.name,
            isVisible: layer.isVisible,
            opacity: CGFloat(layer.opacity),
            normalizedCenter: normalizedCenter,
            scale: layer.scale,
            rotationDegrees: layer.rotationDegrees,
            source: source
        )
    }

    func frameRateLabel(_ rate: Double) -> String {
        if abs(rate.rounded() - rate) < 0.001 {
            return String(Int(rate.rounded()))
        }
        return String(format: "%.3f", rate)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }

    private static func supportedFrameRates(for devices: [AVCaptureDevice]) -> [Double] {
        var supportedRates = Set<Int>()

        for device in devices {
            for format in device.formats {
                for range in format.videoSupportedFrameRateRanges {
                    let minimumRate = max(1, Int(ceil(range.minFrameRate)))
                    let maximumRate = min(240, Int(floor(range.maxFrameRate)))

                    if minimumRate <= maximumRate {
                        for integerRate in minimumRate...maximumRate {
                            supportedRates.insert(integerRate * 1000)
                        }
                    }

                    for preferredRate in preferredFrameRates where preferredRate >= range.minFrameRate - 0.001 && preferredRate <= range.maxFrameRate + 0.001 {
                        supportedRates.insert(Int((preferredRate * 1000).rounded()))
                    }
                }
            }
        }

        if supportedRates.isEmpty {
            supportedRates = Set(preferredFrameRates.map { Int(($0 * 1000).rounded()) })
        }

        return supportedRates
            .sorted()
            .map { Double($0) / 1000.0 }
    }
}
