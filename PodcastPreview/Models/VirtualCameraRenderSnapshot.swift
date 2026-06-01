import Foundation
import SwiftUI
import AppKit

struct VirtualCameraRenderColor {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(color: Color) {
        let converted = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        self.init(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent,
            alpha: converted.alphaComponent
        )
    }

    var swiftUIColor: Color {
        Color(.sRGB, red: Double(red), green: Double(green), blue: Double(blue), opacity: Double(alpha))
    }

    var nsColor: NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
    }
}

struct VirtualCameraRenderTextStyle {
    let text: String
    let color: VirtualCameraRenderColor
    let fontSize: CGFloat
    let fontFamily: String
    let alignment: VirtualCameraLayer.TextAlignmentOption
    let isBold: Bool
    let isItalic: Bool

    func font() -> NSFont {
        var font = NSFont(name: fontFamily, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        if isBold {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if isItalic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    func nsTextAlignment() -> NSTextAlignment {
        switch alignment {
        case .leading:
            return .left
        case .center:
            return .center
        case .trailing:
            return .right
        }
    }

    func attributedString() -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = nsTextAlignment()
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font(),
                .foregroundColor: color.nsColor,
                .paragraphStyle: paragraphStyle
            ]
        )
    }

    func boundingRect(maxSize: CGSize) -> CGRect {
        attributedString().boundingRect(
            with: maxSize,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).integral
    }
}

enum VirtualCameraRenderLayerSource {
    case videoSource(deviceID: String?, displayName: String?)
    case image(url: URL?)
    case mediaFile(url: URL?, kind: VirtualCameraLayer.FileSourceKind)
    case text(VirtualCameraRenderTextStyle)
}

struct VirtualCameraRenderLayerSnapshot: Identifiable {
    let id: UUID
    let name: String
    let isVisible: Bool
    let opacity: CGFloat
    let normalizedCenter: CGPoint
    let scale: CGFloat
    let rotationDegrees: Double
    let source: VirtualCameraRenderLayerSource

    var videoDeviceID: String? {
        if case let .videoSource(deviceID, _) = source {
            return deviceID
        }
        return nil
    }

    var videoDisplayName: String? {
        if case let .videoSource(_, displayName) = source {
            return displayName
        }
        return nil
    }

    var imageURL: URL? {
        if case let .image(url) = source {
            return url
        }
        return nil
    }

    var mediaURL: URL? {
        if case let .mediaFile(url, _) = source {
            return url
        }
        return nil
    }

    var mediaKind: VirtualCameraLayer.FileSourceKind? {
        if case let .mediaFile(_, kind) = source {
            return kind
        }
        return nil
    }

    var textStyle: VirtualCameraRenderTextStyle? {
        if case let .text(textStyle) = source {
            return textStyle
        }
        return nil
    }

    func anchor(in canvasSize: CGSize) -> CGPoint {
        CGPoint(
            x: canvasSize.width * normalizedCenter.x,
            y: canvasSize.height * normalizedCenter.y
        )
    }

    func fittedContentSize(for sourceSize: CGSize, in canvasSize: CGSize) -> CGSize {
        VirtualCameraRenderSnapshot.fittedSize(
            for: sourceSize,
            within: CGSize(width: canvasSize.width * 0.6, height: canvasSize.height * 0.6)
        )
    }

    func textBoundingRect(in canvasSize: CGSize) -> CGRect {
        textStyle?.boundingRect(
            maxSize: CGSize(width: canvasSize.width * 0.7, height: canvasSize.height * 0.7)
        ) ?? .zero
    }
}

struct VirtualCameraRenderSnapshot {
    let deviceName: String
    let resolution: String
    let frameRate: Double
    let canvasSize: CGSize
    let layers: [VirtualCameraRenderLayerSnapshot]

    static func parseResolution(_ resolution: String) -> CGSize {
        let parts = resolution
            .lowercased()
            .split(separator: "x", maxSplits: 1)
            .map(String.init)

        if parts.count == 2,
           let width = Double(parts[0]),
           let height = Double(parts[1]),
           width > 0,
           height > 0 {
            return CGSize(width: width, height: height)
        }

        return CGSize(width: 1920, height: 1080)
    }

    static func fittedSize(for sourceSize: CGSize, within maxSize: CGSize) -> CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0, maxSize.width > 0, maxSize.height > 0 else {
            return CGSize(width: 1, height: 1)
        }

        let widthScale = maxSize.width / sourceSize.width
        let heightScale = maxSize.height / sourceSize.height
        let scale = min(widthScale, heightScale)

        return CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
    }
}
