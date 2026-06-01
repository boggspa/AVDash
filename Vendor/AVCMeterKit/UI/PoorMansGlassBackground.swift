/// A lightweight "liquid glass" approximation for macOS 11 and earlier.
/// Uses NSVisualEffectView (available on Big Sur) plus subtle gradient/noise/specular layers.
/// This is intentionally simple and GPU-friendly for Intel.

import SwiftUI
import AppKit

extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 1, 1, 0)
        }

        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue:  CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}

private enum PMGlassLayerName {
    static let tint = "pmGlass.tint"
    static let ambient = "pmGlass.ambient"
    static let chroma = "pmGlass.chroma"
    static let specular = "pmGlass.specular"
    static let caustic = "pmGlass.caustic"
    static let vignette = "pmGlass.vignette"
    static let noise = "pmGlass.noise"
    static let border = "pmGlass.border"
    static let rim = "pmGlass.rim"
}

private final class PMGlassEffectView: NSVisualEffectView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        postsFrameChangedNotifications = true
        autoresizingMask = [.width, .height]

        // Listen for frame changes to update layers
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frameDidChange),
            name: NSView.frameDidChangeNotification,
            object: self
        )
    }

    @objc private func frameDidChange() {
        // Force layer update when frame changes
        needsLayout = true
        if let layer = layer {
            layer.sublayers?.forEach { $0.frame = layer.bounds }
            layer.setNeedsLayout()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

struct PoorMansGlassBackground: NSViewRepresentable {
    let style: AppChromeStyle
    let cornerRadius: CGFloat
    let reduceBlur: Bool
    let tuning: PoorMansGlassTuning
    let themeMode: ThemeMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let vfx = PMGlassEffectView(frame: .zero)
        vfx.wantsLayer = true
        vfx.state = .active
        vfx.blendingMode = reduceBlur ? .behindWindow : .withinWindow
        vfx.material = materialForStyle
        vfx.isEmphasized = false
        vfx.translatesAutoresizingMaskIntoConstraints = true
        vfx.autoresizingMask = [.width, .height]

        vfx.layer?.cornerRadius = cornerRadius
        vfx.layer?.masksToBounds = true

        // Set base background color to avoid gray appearance
        vfx.layer?.backgroundColor = NSColor.clear.cgColor

        // Defer layer installation to ensure view has proper bounds
        DispatchQueue.main.async {
            self.installOrUpdateLayers(in: vfx)
        }
        return vfx
    }

    func updateNSView(_ vfx: NSVisualEffectView, context: Context) {
        vfx.material = materialForStyle
        vfx.state = .active
        vfx.blendingMode = reduceBlur ? .behindWindow : .withinWindow
        vfx.isEmphasized = false
        vfx.translatesAutoresizingMaskIntoConstraints = true
        vfx.autoresizingMask = [.width, .height]

        vfx.wantsLayer = true
        vfx.layer?.cornerRadius = cornerRadius
        vfx.layer?.masksToBounds = true
        vfx.layer?.backgroundColor = NSColor.clear.cgColor

        installOrUpdateLayers(in: vfx)
    }

    // MARK: - Style

    private var materialForStyle: NSVisualEffectView.Material {
        if themeMode == .midnight {
            return .hudWindow
        }
        if reduceBlur {
            switch style {
            case .panel:
                // Use ultraThinMaterial for better glass effect on macOS 15+
                if #available(macOS 15.0, *) {
                    return .contentBackground
                } else {
                    return .windowBackground
                }
            case .header:
                return .headerView
            case .hud:
                if #available(macOS 15.0, *) {
                    return .contentBackground
                } else {
                    return .windowBackground
                }
            }
        }

        // Use hudWindow material for more blur on main window
        switch style {
        case .panel:
            return .hudWindow
        case .header:
            return .titlebar
        case .hud:
            return .hudWindow
        }
    }

    private var tintColor: NSColor {
        if themeMode == .midnight {
            return NSColor(hex: "#020308").withAlphaComponent(scaledAlpha(0.65))
        }
        switch style {
        case .panel:
            return NSColor.black.withAlphaComponent(scaledAlpha(reduceBlur ? 0.42 : 0.35))
        case .header:
            return NSColor.black.withAlphaComponent(scaledAlpha(reduceBlur ? 0.35 : 0.28))
        case .hud:
            return NSColor(
                calibratedWhite: 0.01,
                alpha: scaledAlpha(reduceBlur ? 0.35 : 0.28)
            )
        }
    }

    private var borderColor: NSColor {
        switch style {
        case .panel:
            return NSColor.white.withAlphaComponent(scaledAlpha(0.18, floor: 0.45))
        case .header:
            return NSColor.white.withAlphaComponent(scaledAlpha(0.14, floor: 0.45))
        case .hud:
            return NSColor.white.withAlphaComponent(scaledAlpha(0.16, floor: 0.45))
        }
    }

    private var outerShadowColor: NSColor {
        switch style {
        case .panel:
            return NSColor.black.withAlphaComponent(0.20)
        case .header:
            return NSColor.black.withAlphaComponent(0.18)
        case .hud:
            return NSColor.black.withAlphaComponent(0.38)
        }
    }

    private func scaledAlpha(_ base: CGFloat, floor: CGFloat = 0.0) -> CGFloat {
        base * max(floor, tuning.intensity)
    }

    private func scaledHazeAlpha(_ base: CGFloat) -> CGFloat {
        scaledAlpha(base * tuning.haze)
    }

    private func scaledHighlightAlpha(_ base: CGFloat) -> CGFloat {
        scaledAlpha(base * tuning.highlight)
    }

    private func scaledChromaAlpha(_ base: CGFloat) -> CGFloat {
        scaledAlpha(base * tuning.chroma)
    }

    private func scaledRimAlpha(_ base: CGFloat, floor: CGFloat = 0.2) -> CGFloat {
        base * max(floor, tuning.intensity * tuning.rim)
    }

    // MARK: - Layers

    private func installOrUpdateLayers(in vfx: NSVisualEffectView) {
        guard let root = vfx.layer else { return }

        // A subtle drop shadow improves separation from the background.
        root.shadowColor = outerShadowColor.cgColor
        root.shadowOpacity = 1.0
        root.shadowRadius = style == .hud ? 24 : 18
        root.shadowOffset = CGSize(width: 0, height: style == .hud ? -8 : -6)

        // Ensure we have a predictable backing.
        let bounds = root.bounds

        // 1) Tint layer (very subtle) to steer the material toward your desired look.
        let tint = ensureLayer(name: PMGlassLayerName.tint, in: root) { CALayer() }
        tint.frame = bounds
        tint.backgroundColor = tintColor.cgColor

        // 1b) Soft interior bloom so the center feels lighter than the edges.
        let ambient = ensureLayer(name: PMGlassLayerName.ambient, in: root) { CAGradientLayer() }
        if let g = ambient as? CAGradientLayer {
            g.type = .radial
            g.frame = bounds
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 1.0, y: 1.0)
            let centerAlpha: CGFloat = style == .hud ? (reduceBlur ? 0.23 : 0.29) : (reduceBlur ? 0.19 : 0.23)
            let baseColor = themeMode == .midnight ? NSColor(hex: "#1A44AA") : NSColor.black
            g.colors = [
                baseColor.withAlphaComponent(scaledAlpha(centerAlpha * 0.22)).cgColor,
                baseColor.withAlphaComponent(scaledAlpha(centerAlpha * 0.14)).cgColor,
                NSColor.clear.cgColor
            ]
            g.locations = [0.0, 0.34, 1.0]
        }
        ambient.compositingFilter = "screenBlendMode"

        // 1c) Tahoe-like chroma bleed: subtle cool/warm wash rather than a flat cyan sheet.
        let chroma = ensureLayer(name: PMGlassLayerName.chroma, in: root) { CAGradientLayer() }
        if let g = chroma as? CAGradientLayer {
            g.frame = bounds
            g.startPoint = CGPoint(x: 0.0, y: 0.95)
            g.endPoint = CGPoint(x: 1.0, y: 0.05)

            if themeMode == .midnight {
                let cool = NSColor(hex: "#1A44AA").withAlphaComponent(scaledChromaAlpha(0.15)).cgColor
                let neutral = NSColor(hex: "#050812").withAlphaComponent(scaledChromaAlpha(0.12)).cgColor
                let warm = NSColor(hex: "#010103").withAlphaComponent(scaledChromaAlpha(0.10)).cgColor
                g.colors = [cool, neutral, warm]
            } else {
                let cool = NSColor(
                    calibratedRed: 0.34,
                    green: 0.84,
                    blue: 0.98,
                    alpha: scaledChromaAlpha(style == .hud ? 0.095 : 0.055)
                ).cgColor
                let neutral = NSColor.black.withAlphaComponent(
                    scaledChromaAlpha(style == .hud ? 0.018 : 0.013)
                ).cgColor
                let warm = NSColor(
                    calibratedRed: 1.00,
                    green: 0.63,
                    blue: 0.34,
                    alpha: scaledChromaAlpha(style == .hud ? 0.075 : 0.045)
                ).cgColor
                g.colors = [cool, neutral, warm]
            }
            g.locations = [0.0, 0.46, 1.0]
        }
        chroma.opacity = Float(style == .hud ? scaledAlpha(0.96) : scaledAlpha(0.72))
        chroma.compositingFilter = themeMode == .midnight ? "screenBlendMode" : "overlayBlendMode"

        // 2) Specular highlight (top glow) to mimic "liquid" sheen.
        let specular = ensureLayer(name: PMGlassLayerName.specular, in: root) { CAGradientLayer() }
        if let g = specular as? CAGradientLayer {
            g.frame = bounds
            g.startPoint = CGPoint(x: 0.5, y: 1.0)
            g.endPoint = CGPoint(x: 0.5, y: 0.46)
            let top = NSColor.white.withAlphaComponent(
                scaledHighlightAlpha(
                    reduceBlur ? (style == .hud ? 0.10 : 0.12) : (style == .hud ? 0.18 : 0.18)
                )
            ).cgColor
            let mid = NSColor.black.withAlphaComponent(
                scaledHighlightAlpha(style == .hud ? 0.075 : 0.045)
            ).cgColor
            let clear = NSColor.clear.cgColor
            g.colors = [top, mid, clear]
            g.locations = [0.0, 0.20, 1.0]
        }
        specular.compositingFilter = "screenBlendMode"

        // 2a) Narrow crest highlight near the top edge for a stronger curved-glass feel.
        let caustic = ensureLayer(name: PMGlassLayerName.caustic, in: root) { CAGradientLayer() }
        if let g = caustic as? CAGradientLayer {
            g.frame = bounds
            g.startPoint = CGPoint(x: 0.5, y: 1.0)
            g.endPoint = CGPoint(x: 0.5, y: 0.75)
            g.colors = [
                NSColor.black.withAlphaComponent(scaledHighlightAlpha(style == .hud ? 0.18 : 0.10)).cgColor,
                NSColor.black.withAlphaComponent(scaledHighlightAlpha(style == .hud ? 0.055 : 0.028)).cgColor,
                NSColor.clear.cgColor
            ]
            g.locations = [0.0, 0.22, 1.0]
        }
        caustic.opacity = Float(style == .hud ? scaledAlpha(1.0) : scaledAlpha(0.72))
        caustic.compositingFilter = "screenBlendMode"

        // 2b) Frost matte/haze (makes it look more "frosted" than "wet")
        let haze = ensureLayer(name: "pmGlass.haze", in: root) { CAGradientLayer() }
        if let g = haze as? CAGradientLayer {
            g.frame = bounds
            g.startPoint = CGPoint(x: 0.0, y: 1.0)
            g.endPoint = CGPoint(x: 1.0, y: 0.0)
            let a = reduceBlur ? ((style == .hud) ? 0.10 : 0.16) : ((style == .hud) ? 0.065 : 0.11)
            g.colors = [
                NSColor.black.withAlphaComponent(scaledHazeAlpha(a)).cgColor,
                NSColor.black.withAlphaComponent(scaledHazeAlpha(a * 0.42)).cgColor,
                NSColor.clear.cgColor
            ]
            g.locations = [0.0, 0.48, 1.0]
        }
        haze.compositingFilter = "softLightBlendMode"

        // 2c) A gentle edge vignette makes the center feel clearer, closer to Tahoe's depth.
        let vignette = ensureLayer(name: PMGlassLayerName.vignette, in: root) { CAGradientLayer() }
        if let g = vignette as? CAGradientLayer {
            g.type = .radial
            g.frame = bounds
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 1.0, y: 1.0)
            g.colors = [
                NSColor.clear.cgColor,
                NSColor.clear.cgColor,
                NSColor.black.withAlphaComponent(scaledHazeAlpha(style == .hud ? 0.015 : 0.015)).cgColor
            ]
            g.locations = [0.0, 0.72, 1.0]
        }
        vignette.compositingFilter = "multiplyBlendMode"

        // 3) Noise layer (very low opacity) to reduce banding and add "glass" texture.
        let noise = ensureLayer(name: PMGlassLayerName.noise, in: root) { CALayer() }
        noise.frame = bounds
        noise.contents = noiseCGImage(size: 256, seed: 42)
        noise.contentsGravity = .resizeAspectFill
        noise.opacity = Float(
            scaledAlpha(
                reduceBlur ? (style == .hud ? 0.028 : 0.03) : (style == .hud ? 0.005 : 0.005)
            )
        )
        // Frost looks better with a gentler blend than full overlay.
        noise.compositingFilter = "softLightBlendMode"

        // 4) Border / inner stroke
        let border = ensureLayer(name: PMGlassLayerName.border, in: root) { CAShapeLayer() }
        if let s = border as? CAShapeLayer {
            s.frame = bounds
            let inset: CGFloat = 0.5
            let r = max(0, cornerRadius - inset)
            let path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), cornerWidth: r, cornerHeight: r, transform: nil)
            s.path = path
            s.fillColor = NSColor.clear.cgColor
            s.strokeColor = borderColor.cgColor
            s.lineWidth = 1.0
        }

        // 4b) Extra inner rim so the edge catches light like Tahoe's denser glass.
        let rim = ensureLayer(name: PMGlassLayerName.rim, in: root) { CAShapeLayer() }
        if let s = rim as? CAShapeLayer {
            s.frame = bounds
            let inset: CGFloat = 1.5
            let r = max(0, cornerRadius - inset)
            s.path = CGPath(
                roundedRect: bounds.insetBy(dx: inset, dy: inset),
                cornerWidth: r,
                cornerHeight: r,
                transform: nil
            )
            s.fillColor = NSColor.clear.cgColor
            s.strokeColor = NSColor.white.withAlphaComponent(
                scaledRimAlpha(style == .hud ? 0.29 : 0.035, floor: 0.55)
            ).cgColor
            s.lineWidth = 2.0
        }
        rim.compositingFilter = "screenBlendMode"

        // Keep order stable.
        reorder(
            root: root,
            names: [
                PMGlassLayerName.tint,
                PMGlassLayerName.ambient,
                PMGlassLayerName.chroma,
                PMGlassLayerName.specular,
                PMGlassLayerName.caustic,
                "pmGlass.haze",
                PMGlassLayerName.vignette,
                PMGlassLayerName.noise,
                PMGlassLayerName.border,
                PMGlassLayerName.rim
            ]
        )
    }

    private func ensureLayer<T: CALayer>(name: String, in root: CALayer, builder: () -> T) -> CALayer {
        if let existing = root.sublayers?.first(where: { $0.name == name }) {
            return existing
        }
        let layer = builder()
        layer.name = name
        layer.masksToBounds = true
        root.addSublayer(layer)
        return layer
    }

    private func reorder(root: CALayer, names: [String]) {
        guard let subs = root.sublayers else { return }
        let dict = Dictionary(uniqueKeysWithValues: subs.compactMap { l in l.name.map { ($0, l) } })
        var ordered: [CALayer] = []
        ordered.reserveCapacity(names.count)
        for n in names {
            if let l = dict[n] { ordered.append(l) }
        }
        // Append any other layers we didn't explicitly manage.
        for l in subs {
            if let n = l.name, names.contains(n) { continue }
            ordered.append(l)
        }
        root.sublayers = ordered
    }

    // MARK: - Noise

    /// Generates a small monochrome noise tile. Cached via the static store to avoid re-allocations.
    private func noiseCGImage(size: Int, seed: UInt32) -> CGImage? {
        NoiseCache.shared.image(size: size, seed: seed)
    }
}

private final class NoiseCache {
    static let shared = NoiseCache()
    private var cache: [String: CGImage] = [:]
    private let lock = NSLock()

    func image(size: Int, seed: UInt32) -> CGImage? {
        let key = "\(size)-\(seed)"
        lock.lock(); defer { lock.unlock() }
        if let img = cache[key] { return img }

        let w = size
        let h = size
        let bytesPerPixel = 1
        let bytesPerRow = w * bytesPerPixel
        var data = [UInt8](repeating: 0, count: w * h)

        // Simple LCG for deterministic noise (fast, no allocations).
        var state = seed == 0 ? 1 : seed
        func next() -> UInt32 {
            state = 1664525 &* state &+ 1013904223
            return state
        }

        for i in 0..<(w * h) {
            // Centered noise around mid-gray for overlay blend.
            let r = UInt8(truncatingIfNeeded: next() >> 24)
            data[i] = 110 &+ (r % 36) // 110..145
        }

        guard let provider = CGDataProvider(data: NSData(bytes: &data, length: data.count)) else { return nil }

        // Use sRGB color space for compatibility
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        guard let cg = CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }

        cache[key] = cg
        return cg
    }
}
