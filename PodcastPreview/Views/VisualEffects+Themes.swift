import SwiftUI
import AppKit

import PodcastPreviewShared

private struct GraphShowGridlinesKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

public extension EnvironmentValues {
    var graphShowGridlines: Bool {
        get { self[GraphShowGridlinesKey.self] }
        set { self[GraphShowGridlinesKey.self] = newValue }
    }
}

#if DEBUG
/// A simple developer picker that stores the override in AppStorage and can be embedded in a dev menu.
public struct DevVisualEffectPicker: View {
    @AppStorage("theme.visualEffectOverride") private var stored = VisualEffectOverride.auto.rawValue

    public init() {}

    public var body: some View {
        let selection = Binding<VisualEffectOverride>(
            get: { VisualEffectOverride(rawValue: stored) ?? .auto },
            set: { stored = $0.rawValue }
        )
        Picker("Visual Theme", selection: selection) {
            ForEach(VisualEffectOverride.allCases) { option in
                Text(option.displayName).tag(option)
            }
        }
        .pickerStyle(.menu)
    }
}

public struct DevPoorMansGlassTuningMenu: View {
    @State private var isPresented = false
    @AppStorage("dev.pmGlassIntensity") private var intensity: Double = PoorMansGlassTuning.releaseBigSurFallback.intensity
    @AppStorage("dev.pmGlassHaze") private var haze: Double = PoorMansGlassTuning.releaseBigSurFallback.haze
    @AppStorage("dev.pmGlassHighlight") private var highlight: Double = PoorMansGlassTuning.releaseBigSurFallback.highlight
    @AppStorage("dev.pmGlassChroma") private var chroma: Double = PoorMansGlassTuning.releaseBigSurFallback.chroma
    @AppStorage("dev.pmGlassRim") private var rim: Double = PoorMansGlassTuning.releaseBigSurFallback.rim

    public init() {}

    public var body: some View {
        Button("Glass Tune") {
            isPresented.toggle()
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Poor Man's Glass")
                    .font(.headline)

                Text("These controls tune the Big Sur fallback glass and backdrop wash.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                sliderRow("Opacity", value: $intensity)
                sliderRow("Haze", value: $haze)
                sliderRow("Highlights", value: $highlight)
                sliderRow("Chroma", value: $chroma)
                sliderRow("Rim", value: $rim)

                Divider()

                HStack {
                    Spacer()
                    Button("Reset") {
                        intensity = PoorMansGlassTuning.releaseBigSurFallback.intensity
                        haze = PoorMansGlassTuning.releaseBigSurFallback.haze
                        highlight = PoorMansGlassTuning.releaseBigSurFallback.highlight
                        chroma = PoorMansGlassTuning.releaseBigSurFallback.chroma
                        rim = PoorMansGlassTuning.releaseBigSurFallback.rim
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(14)
            .frame(width: 280)
        }
    }

    private func valueString(_ value: Double) -> String {
        String(format: "%.2f×", value)
    }

    @ViewBuilder
    private func sliderRow(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(valueString(value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            Slider(value: value, in: debugRange, step: 0.01)
        }
    }

    private var debugRange: ClosedRange<Double> {
        0.15...2.50
    }
}

private struct _DevVisualEffectEnv: ViewModifier {
    @AppStorage("theme.visualEffectOverride") private var stored = VisualEffectOverride.auto.rawValue
    @AppStorage("dev.pmGlassIntensity") private var intensity: Double = PoorMansGlassTuning.releaseBigSurFallback.intensity
    @AppStorage("dev.pmGlassHaze") private var haze: Double = PoorMansGlassTuning.releaseBigSurFallback.haze
    @AppStorage("dev.pmGlassHighlight") private var highlight: Double = PoorMansGlassTuning.releaseBigSurFallback.highlight
    @AppStorage("dev.pmGlassChroma") private var chroma: Double = PoorMansGlassTuning.releaseBigSurFallback.chroma
    @AppStorage("dev.pmGlassRim") private var rim: Double = PoorMansGlassTuning.releaseBigSurFallback.rim

    func body(content: Content) -> some View {
        let override = VisualEffectOverride(rawValue: stored) ?? .auto
        let tuning = PoorMansGlassTuning(
            intensity: intensity,
            haze: haze,
            highlight: highlight,
            chroma: chroma,
            rim: rim
        )
        return content
            .environment(\.visualEffectOverride, override)
            .environment(\.poorMansGlassTuningOverride, tuning)
    }
}
#endif

public struct ThemeMenuButton: View {
    @State private var isPresented = false
    @AppStorage("theme.visualEffectOverride") private var storedVisualEffect = VisualEffectOverride.auto.rawValue
    @AppStorage("theme.appearanceOverride") private var storedAppearance = ThemeAppearanceOverride.system.rawValue
    @AppStorage("theme.cornerStyle") private var storedCornerStyle = ThemeCornerStyle.rounded.rawValue
    @AppStorage("theme.accentStyle") private var storedAccentStyle = ThemeAccentStyle.system.rawValue

    private let chipHeight: CGFloat

    public init(chipHeight: CGFloat = 28) {
        self.chipHeight = chipHeight
    }

    private var visualEffectSelection: Binding<VisualEffectOverride> {
        Binding(
            get: { VisualEffectOverride(rawValue: storedVisualEffect) ?? .auto },
            set: { storedVisualEffect = $0.rawValue }
        )
    }

    private var appearanceSelection: Binding<ThemeAppearanceOverride> {
        Binding(
            get: { ThemeAppearanceOverride(rawValue: storedAppearance) ?? .system },
            set: { storedAppearance = $0.rawValue }
        )
    }

    private var cornerStyleSelection: Binding<ThemeCornerStyle> {
        Binding(
            get: { ThemeCornerStyle(rawValue: storedCornerStyle) ?? .rounded },
            set: { storedCornerStyle = $0.rawValue }
        )
    }

    private var accentStyleSelection: Binding<ThemeAccentStyle> {
        Binding(
            get: { ThemeAccentStyle(rawValue: storedAccentStyle) ?? .system },
            set: { storedAccentStyle = $0.rawValue }
        )
    }

    private var isThemeActive: Bool {
        storedVisualEffect != VisualEffectOverride.auto.rawValue
            || storedAppearance != ThemeAppearanceOverride.system.rawValue
            || storedCornerStyle != ThemeCornerStyle.rounded.rawValue
            || storedAccentStyle != ThemeAccentStyle.system.rawValue
    }

    public var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ZStack {
                if isPresented || isThemeActive {
                    LiquidGlassPillBackground(style: .hud)
                }

                HStack(spacing: 6) {
                    Image(systemName: "paintpalette")
                    Text("Theme")
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .foregroundColor(
                (isPresented || isThemeActive) ? Color.white.opacity(0.96) : Color.white.opacity(0.72)
            )
            .padding(.vertical, 5)
            .padding(.horizontal, 11)
            .frame(height: chipHeight)
            .fixedSize(horizontal: true, vertical: true)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Theme"))
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ThemePopoverContent(
                visualEffectSelection: visualEffectSelection,
                appearanceSelection: appearanceSelection,
                cornerStyleSelection: cornerStyleSelection,
                accentStyleSelection: accentStyleSelection
            )
        }
    }
}

private struct ThemePopoverContent: View {
    @Binding var visualEffectSelection: VisualEffectOverride
    @Binding var appearanceSelection: ThemeAppearanceOverride
    @Binding var cornerStyleSelection: ThemeCornerStyle
    @Binding var accentStyleSelection: ThemeAccentStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme")
                .font(.headline)

            Text("Choose the glass path and optional appearance override used across the app.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Glass")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                Picker("", selection: $visualEffectSelection) {
                    ForEach(VisualEffectOverride.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("System theme")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                Picker("", selection: $appearanceSelection) {
                    ForEach(ThemeAppearanceOverride.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Corners")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                Picker("", selection: $cornerStyleSelection) {
                    ForEach(ThemeCornerStyle.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Accent color")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)

                Picker("", selection: $accentStyleSelection) {
                    ForEach(ThemeAccentStyle.allCases) { option in
                        HStack {
                            Circle()
                                .fill(option.color)
                                .frame(width: 12, height: 12)
                            Text(option.displayName)
                        }
                        .tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}

public enum GraphiteSlateTheme {
    public static let windowBase = Color.black.opacity(0.96)
    public static let cardFill = Color(red: 0.030, green: 0.037, blue: 0.046).opacity(0.72)
    public static let cardStroke = Color.white.opacity(0.13)
    public static let elevatedCardFill = Color(red: 0.040, green: 0.047, blue: 0.058).opacity(0.82)
    public static let controlFill = Color.white.opacity(0.070)
    public static let controlHoverFill = Color.white.opacity(0.105)
    public static let controlActiveFill = Color(red: 0.035, green: 0.105, blue: 0.210).opacity(0.72)
    public static let rowFill = Color.white.opacity(0.035)
    public static let rowHoverFill = Color.white.opacity(0.060)
    public static let rowSelectedFill = Color.white.opacity(0.090)
    public static let separator = Color.white.opacity(0.090)
    public static let softSeparator = Color.white.opacity(0.055)
    public static let windowRim = Color.white.opacity(0.16)
    public static let windowRimHighlight = Color.white.opacity(0.060)
    public static let windowRimShadow = Color.black.opacity(0.36)
    public static let sidebarBase = Color.black.opacity(0.94)
    public static let sidebarTopHighlight = Color.white.opacity(0.035)
    public static let sidebarSlateTint = Color(red: 0.025, green: 0.065, blue: 0.120).opacity(0.24)
    public static let sidebarBottomShade = Color.black.opacity(0.22)
    public static let bottomNavy = Color(red: 0.012, green: 0.064, blue: 0.160)
    public static let accentBlue = Color(red: 0.060, green: 0.430, blue: 0.920)
    public static let accentBlueSoft = Color(red: 0.040, green: 0.220, blue: 0.520).opacity(0.42)
    public static let primaryText = Color.white.opacity(0.96)
    public static let secondaryText = Color.white.opacity(0.66)
    public static let tertiaryText = Color.white.opacity(0.44)
    public static let subduedText = Color.white.opacity(0.30)
    public static let shadow = Color.black.opacity(0.28)
}

public enum GraphiteSlateSurface: Equatable {
    case panel
    case elevated
    case control
    case activeControl
    case row
    case selectedRow
    case accent
}

public extension GraphiteSlateTheme {
    static func fill(for surface: GraphiteSlateSurface) -> Color {
        switch surface {
        case .panel:
            return cardFill
        case .elevated:
            return elevatedCardFill
        case .control:
            return controlFill
        case .activeControl:
            return controlActiveFill
        case .row:
            return rowFill
        case .selectedRow:
            return rowSelectedFill
        case .accent:
            return accentBlueSoft
        }
    }

    static func stroke(for surface: GraphiteSlateSurface) -> Color {
        switch surface {
        case .accent, .activeControl:
            return accentBlue.opacity(0.38)
        case .control, .row, .selectedRow:
            return softSeparator
        case .panel, .elevated:
            return cardStroke
        }
    }
}

public struct GraphiteSlatePillBackground: View {
    public let isActive: Bool

    public init(isActive: Bool = false) {
        self.isActive = isActive
    }

    public var body: some View {
        Capsule(style: .continuous)
            .fill(isActive ? GraphiteSlateTheme.controlActiveFill : GraphiteSlateTheme.controlFill)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        isActive ? GraphiteSlateTheme.accentBlue.opacity(0.35) : GraphiteSlateTheme.softSeparator,
                        lineWidth: 1
                    )
            )
    }
}

public struct GraphiteSlateWindowOverlay: View {
    public let backdropStrength: Double
    public let bottomGradientHeight: CGFloat

    public init(backdropStrength: Double = 1, bottomGradientHeight: CGFloat = 420) {
        self.backdropStrength = backdropStrength
        self.bottomGradientHeight = bottomGradientHeight
    }

    private var clampedStrength: Double {
        min(max(backdropStrength, 0.05), 2.20)
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.10 * clampedStrength),
                    Color.black.opacity(0.045 * clampedStrength),
                    Color.black.opacity(0.02 * clampedStrength)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            GraphiteSlateWindowBottomGradient(
                height: bottomGradientHeight,
                strength: clampedStrength
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

public struct GraphiteSlateWindowBottomGradient: View {
    public let height: CGFloat
    public let strength: Double

    public init(height: CGFloat = 420, strength: Double = 1) {
        self.height = height
        self.strength = strength
    }

    private var clampedStrength: Double {
        min(max(strength, 0.05), 1.60)
    }

    private func opacity(_ value: Double) -> Double {
        min(max(value * clampedStrength, 0), 1)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LinearGradient(
                colors: [
                    Color.clear,
                    GraphiteSlateTheme.bottomNavy.opacity(opacity(0.12)),
                    GraphiteSlateTheme.bottomNavy.opacity(opacity(0.54)),
                    Color.black.opacity(opacity(0.92))
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

public enum GraphiteSidebarSeparatorEdge: Equatable {
    case leading
    case trailing
}

private enum GraphiteRimLayerMode: Equatable {
    case window
    case sidebar(edge: GraphiteSidebarSeparatorEdge)
}

private final class GraphiteRimNSView: NSView {
    private enum LayerName {
        static let topGlow = "graphiteRim.topGlow"
        static let bottomShade = "graphiteRim.bottomShade"
        static let outerStroke = "graphiteRim.outerStroke"
        static let innerGradient = "graphiteRim.innerGradient"
        static let innerGradientMask = "graphiteRim.innerGradientMask"
        static let sideLine = "graphiteRim.sideLine"
        static let sideBloom = "graphiteRim.sideBloom"
    }

    var mode: GraphiteRimLayerMode = .window {
        didSet { needsLayout = true }
    }

    var cornerRadius: CGFloat = 16 {
        didSet { needsLayout = true }
    }

    var intensity: CGFloat = 1 {
        didSet { needsLayout = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        postsFrameChangedNotifications = true
        autoresizingMask = [.width, .height]
    }

    override func layout() {
        super.layout()
        installOrUpdateLayers()
    }

    private func installOrUpdateLayers() {
        guard let root = layer else { return }
        root.backgroundColor = NSColor.clear.cgColor
        root.masksToBounds = false

        switch mode {
        case .window:
            hideSidebarLayers(in: root)
            updateWindowLayers(in: root)
        case .sidebar(let edge):
            hideWindowLayers(in: root)
            updateSidebarLayers(in: root, edge: edge)
        }
    }

    private func updateWindowLayers(in root: CALayer) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        guard rect.width > 2, rect.height > 2 else { return }
        let radius = max(0, cornerRadius - 0.5)
        let clamped = min(max(intensity, 0.35), 1.75)

        let topGlow = ensureGradientLayer(name: LayerName.topGlow, in: root)
        topGlow.isHidden = false
        topGlow.frame = CGRect(x: 1, y: rect.height - 8, width: max(rect.width - 2, 1), height: 8)
        topGlow.startPoint = CGPoint(x: 0.5, y: 1.0)
        topGlow.endPoint = CGPoint(x: 0.5, y: 0.0)
        topGlow.colors = [
            NSColor.white.withAlphaComponent(0.055 * clamped).cgColor,
            NSColor.white.withAlphaComponent(0.018 * clamped).cgColor,
            NSColor.clear.cgColor
        ]
        topGlow.locations = [0.0, 0.36, 1.0]
        topGlow.compositingFilter = "screenBlendMode"

        let bottomShade = ensureGradientLayer(name: LayerName.bottomShade, in: root)
        bottomShade.isHidden = false
        bottomShade.frame = CGRect(x: 1, y: 0, width: max(rect.width - 2, 1), height: 10)
        bottomShade.startPoint = CGPoint(x: 0.5, y: 0.0)
        bottomShade.endPoint = CGPoint(x: 0.5, y: 1.0)
        bottomShade.colors = [
            NSColor.black.withAlphaComponent(0.22 * clamped).cgColor,
            NSColor.black.withAlphaComponent(0.08 * clamped).cgColor,
            NSColor.clear.cgColor
        ]
        bottomShade.locations = [0.0, 0.42, 1.0]
        bottomShade.compositingFilter = "multiplyBlendMode"

        let outerStroke = ensureShapeLayer(name: LayerName.outerStroke, in: root)
        outerStroke.isHidden = false
        outerStroke.frame = bounds
        outerStroke.path = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        outerStroke.fillColor = NSColor.clear.cgColor
        outerStroke.strokeColor = NSColor.white.withAlphaComponent(0.14 * clamped).cgColor
        outerStroke.lineWidth = 1.0
        outerStroke.compositingFilter = "screenBlendMode"

        let innerRect = bounds.insetBy(dx: 1.35, dy: 1.35)
        let innerGradient = ensureGradientLayer(name: LayerName.innerGradient, in: root)
        innerGradient.isHidden = false
        innerGradient.frame = bounds
        innerGradient.startPoint = CGPoint(x: 0.0, y: 1.0)
        innerGradient.endPoint = CGPoint(x: 1.0, y: 0.0)
        innerGradient.colors = [
            NSColor.white.withAlphaComponent(0.070 * clamped).cgColor,
            NSColor.white.withAlphaComponent(0.018 * clamped).cgColor,
            NSColor.black.withAlphaComponent(0.20 * clamped).cgColor
        ]
        innerGradient.locations = [0.0, 0.50, 1.0]
        innerGradient.compositingFilter = "screenBlendMode"

        let innerMask = (innerGradient.mask as? CAShapeLayer) ?? CAShapeLayer()
        innerMask.name = LayerName.innerGradientMask
        innerMask.frame = bounds
        innerMask.path = CGPath(
            roundedRect: innerRect,
            cornerWidth: max(0, cornerRadius - 1.35),
            cornerHeight: max(0, cornerRadius - 1.35),
            transform: nil
        )
        innerMask.fillColor = NSColor.clear.cgColor
        innerMask.strokeColor = NSColor.white.cgColor
        innerMask.lineWidth = 0.8
        innerGradient.mask = innerMask

        reorder(root: root, names: [
            LayerName.topGlow,
            LayerName.bottomShade,
            LayerName.outerStroke,
            LayerName.innerGradient
        ])
    }

    private func updateSidebarLayers(in root: CALayer, edge: GraphiteSidebarSeparatorEdge) {
        let clamped = min(max(intensity, 0.45), 2.05)
        let lineWidth: CGFloat = 2
        let bloomWidth: CGFloat = 18
        let lineX: CGFloat = edge == .leading ? 0 : max(bounds.width - lineWidth, 0)
        let bloomX: CGFloat = edge == .leading ? 0 : max(bounds.width - bloomWidth, 0)

        let sideLine = ensureLayer(name: LayerName.sideLine, in: root)
        sideLine.isHidden = false
        sideLine.frame = CGRect(x: lineX, y: 0, width: lineWidth, height: bounds.height)
        sideLine.backgroundColor = NSColor.white.withAlphaComponent(0.17 * clamped).cgColor
        sideLine.compositingFilter = "screenBlendMode"

        let sideBloom = ensureGradientLayer(name: LayerName.sideBloom, in: root)
        sideBloom.isHidden = false
        sideBloom.frame = CGRect(x: bloomX, y: 0, width: bloomWidth, height: bounds.height)
        sideBloom.startPoint = edge == .leading ? CGPoint(x: 0.0, y: 0.5) : CGPoint(x: 1.0, y: 0.5)
        sideBloom.endPoint = edge == .leading ? CGPoint(x: 1.0, y: 0.5) : CGPoint(x: 0.0, y: 0.5)
        sideBloom.colors = [
            NSColor.white.withAlphaComponent(0.090 * clamped).cgColor,
            NSColor.white.withAlphaComponent(0.026 * clamped).cgColor,
            NSColor.clear.cgColor
        ]
        sideBloom.locations = [0.0, 0.38, 1.0]
        sideBloom.compositingFilter = "screenBlendMode"

        let topGlow = ensureGradientLayer(name: LayerName.topGlow, in: root)
        topGlow.isHidden = false
        topGlow.frame = CGRect(x: 0, y: max(bounds.height - 18, 0), width: bounds.width, height: 18)
        topGlow.startPoint = CGPoint(x: 0.5, y: 1.0)
        topGlow.endPoint = CGPoint(x: 0.5, y: 0.0)
        topGlow.colors = [
            NSColor.white.withAlphaComponent(0.065 * clamped).cgColor,
            NSColor.white.withAlphaComponent(0.018 * clamped).cgColor,
            NSColor.clear.cgColor
        ]
        topGlow.locations = [0.0, 0.38, 1.0]
        topGlow.compositingFilter = "screenBlendMode"

        let bottomShade = ensureGradientLayer(name: LayerName.bottomShade, in: root)
        bottomShade.isHidden = false
        bottomShade.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 18)
        bottomShade.startPoint = CGPoint(x: 0.5, y: 0.0)
        bottomShade.endPoint = CGPoint(x: 0.5, y: 1.0)
        bottomShade.colors = [
            NSColor.black.withAlphaComponent(0.20 * clamped).cgColor,
            NSColor.clear.cgColor
        ]
        bottomShade.locations = [0.0, 1.0]
        bottomShade.compositingFilter = "multiplyBlendMode"

        reorder(root: root, names: [
            LayerName.sideBloom,
            LayerName.sideLine,
            LayerName.topGlow,
            LayerName.bottomShade
        ])
    }

    private func hideWindowLayers(in root: CALayer) {
        [LayerName.outerStroke, LayerName.innerGradient].forEach { name in
            root.sublayers?.first(where: { $0.name == name })?.isHidden = true
        }
    }

    private func hideSidebarLayers(in root: CALayer) {
        [LayerName.sideLine, LayerName.sideBloom].forEach { name in
            root.sublayers?.first(where: { $0.name == name })?.isHidden = true
        }
    }

    private func ensureLayer(name: String, in root: CALayer) -> CALayer {
        if let existing = root.sublayers?.first(where: { $0.name == name }) {
            return existing
        }
        let layer = CALayer()
        layer.name = name
        layer.masksToBounds = false
        root.addSublayer(layer)
        return layer
    }

    private func ensureGradientLayer(name: String, in root: CALayer) -> CAGradientLayer {
        if let existing = root.sublayers?.first(where: { $0.name == name }) as? CAGradientLayer {
            return existing
        }
        let layer = CAGradientLayer()
        layer.name = name
        layer.masksToBounds = false
        root.addSublayer(layer)
        return layer
    }

    private func ensureShapeLayer(name: String, in root: CALayer) -> CAShapeLayer {
        if let existing = root.sublayers?.first(where: { $0.name == name }) as? CAShapeLayer {
            return existing
        }
        let layer = CAShapeLayer()
        layer.name = name
        layer.masksToBounds = false
        root.addSublayer(layer)
        return layer
    }

    private func reorder(root: CALayer, names: [String]) {
        guard let sublayers = root.sublayers else { return }
        let keyed = Dictionary(uniqueKeysWithValues: sublayers.compactMap { layer in
            layer.name.map { ($0, layer) }
        })
        var ordered = names.compactMap { keyed[$0] }
        ordered.append(contentsOf: sublayers.filter { layer in
            guard let name = layer.name else { return true }
            return names.contains(name) == false
        })
        root.sublayers = ordered
    }
}

private struct GraphiteRimLayerHost: NSViewRepresentable {
    let mode: GraphiteRimLayerMode
    let cornerRadius: CGFloat
    let intensity: CGFloat

    func makeNSView(context: Context) -> GraphiteRimNSView {
        let view = GraphiteRimNSView(frame: .zero)
        view.mode = mode
        view.cornerRadius = cornerRadius
        view.intensity = intensity
        return view
    }

    func updateNSView(_ view: GraphiteRimNSView, context: Context) {
        view.mode = mode
        view.cornerRadius = cornerRadius
        view.intensity = intensity
        view.needsLayout = true
    }
}

public struct GraphiteSlateWindowRim: View {
    @Environment(\.visualEffectOverride) private var effectOverride
    @Environment(\.poorMansGlassTuningOverride) private var poorMansGlassTuningOverride

    public let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = 16) {
        self.cornerRadius = cornerRadius
    }

    private var rimIntensity: CGFloat {
        let tuning = poorMansGlassTuningOverride ?? .releaseBigSurFallback
        let compatibilityBoost: CGFloat
        if #available(macOS 12.0, *) {
            compatibilityBoost = effectOverride == .classic ? 1.16 : 1.0
        } else {
            compatibilityBoost = 1.24
        }
        let tuned = effectOverride == .classic ? tuning.rim * max(tuning.highlight, 0.35) : 1.0
        return min(max(tuned * compatibilityBoost * 1.22, 0.65), 2.05)
    }

    public var body: some View {
        GraphiteRimLayerHost(
            mode: .window,
            cornerRadius: cornerRadius,
            intensity: rimIntensity
        )
        .padding(0.5)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

public struct ThemeRoundedRectangle: Shape, InsettableShape {
    public var cornerRadius: CGFloat
    public var style: RoundedCornerStyle
    public var insetAmount: CGFloat = 0

    @AppStorage("theme.cornerStyle") private var storedCornerStyle = ThemeCornerStyle.rounded.rawValue

    public init(cornerRadius: CGFloat, style: RoundedCornerStyle = .circular) {
        self.cornerRadius = cornerRadius
        self.style = style
    }

    public func path(in rect: CGRect) -> Path {
        let currentStyle = ThemeCornerStyle(rawValue: storedCornerStyle) ?? .rounded
        if currentStyle == .hard {
            return Rectangle().inset(by: insetAmount).path(in: rect)
        } else {
            return RoundedRectangle(cornerRadius: cornerRadius, style: style).inset(by: insetAmount).path(in: rect)
        }
    }

    public func inset(by amount: CGFloat) -> some InsettableShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

public struct GraphiteSidebarBackground: View {
    public init() {}

    public var body: some View {
        ZStack {
            GraphiteSlateTheme.sidebarBase
            LinearGradient(
                colors: [
                    GraphiteSlateTheme.sidebarTopHighlight,
                    Color.clear,
                    GraphiteSlateTheme.sidebarSlateTint,
                    GraphiteSlateTheme.sidebarBottomShade
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

public struct GraphiteSidebarRim: View {
    @Environment(\.visualEffectOverride) private var effectOverride
    @Environment(\.poorMansGlassTuningOverride) private var poorMansGlassTuningOverride

    public let edge: GraphiteSidebarSeparatorEdge

    public init(edge: GraphiteSidebarSeparatorEdge = .trailing) {
        self.edge = edge
    }

    private var separatorAlignment: Alignment {
        switch edge {
        case .leading:
            return .leading
        case .trailing:
            return .trailing
        }
    }

    private var rimIntensity: CGFloat {
        let tuning = poorMansGlassTuningOverride ?? .releaseBigSurFallback
        let compatibilityBoost: CGFloat
        if #available(macOS 12.0, *) {
            compatibilityBoost = effectOverride == .classic ? 1.16 : 1.0
        } else {
            compatibilityBoost = 1.24
        }
        let tuned = effectOverride == .classic ? tuning.rim * max(tuning.highlight, 0.35) : 1.0
        return min(max(tuned * compatibilityBoost * 1.22, 0.65), 2.05)
    }

    public var body: some View {
        GraphiteRimLayerHost(
            mode: .sidebar(edge: edge),
            cornerRadius: 0,
            intensity: rimIntensity
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: separatorAlignment)
        .allowsHitTesting(false)
    }
}

private struct _GraphiteSlateSurfaceModifier: ViewModifier {
    let surface: GraphiteSlateSurface
    let cornerRadius: CGFloat
    let stroke: Color?
    let lineWidth: CGFloat

    func body(content: Content) -> some View {
        let shape = ThemeRoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.background(
            shape
                .fill(GraphiteSlateTheme.fill(for: surface))
                .overlay(
                    shape.stroke(stroke ?? GraphiteSlateTheme.stroke(for: surface), lineWidth: lineWidth)
                )
                .shadow(
                    color: surface == .elevated ? GraphiteSlateTheme.shadow : .clear,
                    radius: surface == .elevated ? 14 : 0,
                    x: 0,
                    y: surface == .elevated ? 8 : 0
                )
        )
    }
}

private struct _GraphiteSidebarSeparator: ViewModifier {
    let edge: GraphiteSidebarSeparatorEdge

    func body(content: Content) -> some View {
        content.overlay(
            GraphiteSidebarRim(edge: edge)
        )
    }
}

private struct _ThemeEnvironment: ViewModifier {
    @AppStorage("theme.visualEffectOverride") private var storedVisualEffect = VisualEffectOverride.auto.rawValue
    @AppStorage("theme.appearanceOverride") private var storedAppearance = ThemeAppearanceOverride.system.rawValue
    @AppStorage("theme.accentStyle") private var storedAccentStyle = ThemeAccentStyle.system.rawValue

    func body(content: Content) -> some View {
        let visualEffect = VisualEffectOverride(rawValue: storedVisualEffect) ?? .auto
        let appearance = ThemeAppearanceOverride(rawValue: storedAppearance) ?? .system
        let accentStyle = ThemeAccentStyle(rawValue: storedAccentStyle) ?? .system
        return content
            .environment(\.visualEffectOverride, visualEffect)
            .environment(\.accentStyle, accentStyle)
            .environment(\.themeAppearance, appearance)
            .modifier(_AccentColorModifier(accentColor: accentStyle.color))
            .background(_ThemeAppearanceConfigurator(appearance: appearance).frame(width: 0, height: 0))
            .preferredColorScheme(appearance.preferredColorScheme)
    }
}

private struct _AccentColorModifier: ViewModifier {
    let accentColor: Color

    func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content.tint(accentColor)
        } else {
            content
        }
    }
}

private struct _ThemeAppearanceConfigurator: NSViewRepresentable {
    let appearance: ThemeAppearanceOverride

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            applyAppearance()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            applyAppearance()
        }
    }

    private func applyAppearance() {
        switch appearance {
        case .system:
            NSApp.appearance = nil
        case .light, .citrus, .candy:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark, .midnight, .blue, .purple, .pink, .red, .orange, .yellow, .green, .graphite, .rainbow, .nebula, .twilight, .ocean, .sunset, .forest, .cyber:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        @unknown default:
            NSApp.appearance = nil
        }
    }
}

private extension Color {
    static var indigoCompat: Color {
        if #available(macOS 12, *) {
            return .indigo
        } else {
            return Color(red: 0.35, green: 0.34, blue: 0.84)
        }
    }

    static var cyanCompat: Color {
        if #available(macOS 12, *) {
            return .cyan
        } else {
            return Color(red: 0.2, green: 0.75, blue: 1.0)
        }
    }

    static var mintCompat: Color {
        if #available(macOS 12, *) {
            return .mint
        } else {
            return Color(red: 0.0, green: 0.78, blue: 0.74)
        }
    }
}

public struct CardBackgroundOverlay<S: InsettableShape>: View {
    let shape: S
    @Environment(\.themeAppearance) private var appearance

    public init(shape: S) {
        self.shape = shape
    }

    public var body: some View {
        Group {
            switch appearance {
            case .midnight:
                MidnightCardOverlay(shape: shape)
            case .blue:
                ThemeTintOverlay(shape: shape, baseColor: .blue)
            case .purple:
                ThemeTintOverlay(shape: shape, baseColor: .purple)
            case .pink:
                ThemeTintOverlay(shape: shape, baseColor: .pink)
            case .red:
                ThemeTintOverlay(shape: shape, baseColor: .red)
            case .orange:
                ThemeTintOverlay(shape: shape, baseColor: .orange)
            case .yellow:
                ThemeTintOverlay(shape: shape, baseColor: .yellow)
            case .green:
                ThemeTintOverlay(shape: shape, baseColor: .green)
            case .graphite:
                ThemeTintOverlay(shape: shape, baseColor: Color(white: 0.35))
            case .rainbow:
                RainbowCardOverlay(shape: shape)
            case .nebula:
                NebulaCardOverlay(shape: shape)
            case .citrus:
                CitrusCardOverlay(shape: shape)
            case .twilight:
                TwilightCardOverlay(shape: shape)
            case .ocean:
                OceanCardOverlay(shape: shape)
            case .sunset:
                SunsetCardOverlay(shape: shape)
            case .forest:
                ForestCardOverlay(shape: shape)
            case .cyber:
                CyberCardOverlay(shape: shape)
            case .candy:
                CandyCardOverlay(shape: shape)
            default:
                EmptyView()
            }
        }
    }
}

public struct ThemeTintOverlay<S: InsettableShape>: View {
    let shape: S
    let baseColor: Color

    public var body: some View {
        ZStack {
            shape.fill(baseColor.opacity(0.12))
            shape.strokeBorder(baseColor.opacity(0.25), lineWidth: 0.5)
        }
    }
}

public struct RainbowCardOverlay<S: InsettableShape>: View {
    let shape: S
    @State private var phase: CGFloat = 0

    public var body: some View {
        ZStack {
            shape.fill(
                LinearGradient(
                    gradient: Gradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red]),
                    startPoint: UnitPoint(x: 0 + phase, y: 0),
                    endPoint: UnitPoint(x: 1 + phase, y: 1)
                )
            )
            .opacity(0.12)

            shape.strokeBorder(
                LinearGradient(
                    gradient: Gradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red]),
                    startPoint: UnitPoint(x: 0 + phase, y: 0),
                    endPoint: UnitPoint(x: 1 + phase, y: 1)
                ),
                lineWidth: 1.0
            )
            .opacity(0.25)
        }
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

public struct TwilightCardOverlay<S: InsettableShape>: View {
    let shape: S
    public var body: some View {
        ZStack {
            shape.fill(
                LinearGradient(
                    gradient: Gradient(colors: [Color(red: 0.1, green: 0.05, blue: 0.2), Color(red: 0.2, green: 0.1, blue: 0.4)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .opacity(0.15)
            shape.strokeBorder(
                LinearGradient(
                    gradient: Gradient(colors: [Color.indigoCompat.opacity(0.4), .purple.opacity(0.2)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.0
            )
        }
    }
}

public struct OceanCardOverlay<S: InsettableShape>: View {
    let shape: S
    public var body: some View {
        ZStack {
            shape.fill(
                LinearGradient(
                    gradient: Gradient(colors: [Color(red: 0.0, green: 0.2, blue: 0.4), Color(red: 0.1, green: 0.4, blue: 0.6)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .opacity(0.15)
            shape.strokeBorder(
                LinearGradient(
                    gradient: Gradient(colors: [.blue.opacity(0.4), Color.cyanCompat.opacity(0.2)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.0
            )
        }
    }
}

public struct SunsetCardOverlay<S: InsettableShape>: View {
    let shape: S
    public var body: some View {
        ZStack {
            shape.fill(
                LinearGradient(
                    gradient: Gradient(colors: [Color(red: 0.4, green: 0.1, blue: 0.2), Color(red: 0.6, green: 0.3, blue: 0.1)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .opacity(0.15)
            shape.strokeBorder(
                LinearGradient(
                    gradient: Gradient(colors: [.orange.opacity(0.4), .red.opacity(0.2)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.0
            )
        }
    }
}

public struct ForestCardOverlay<S: InsettableShape>: View {
    let shape: S
    public var body: some View {
        ZStack {
            shape.fill(
                LinearGradient(
                    gradient: Gradient(colors: [Color(red: 0.05, green: 0.2, blue: 0.1), Color(red: 0.1, green: 0.4, blue: 0.2)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .opacity(0.15)
            shape.strokeBorder(
                LinearGradient(
                    gradient: Gradient(colors: [.green.opacity(0.4), Color.mintCompat.opacity(0.2)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.0
            )
        }
    }
}

public struct CyberCardOverlay<S: InsettableShape>: View {
    let shape: S
    public var body: some View {
        ZStack {
            shape.fill(
                LinearGradient(
                    gradient: Gradient(colors: [Color(red: 0.1, green: 0.1, blue: 0.15), Color(red: 0.05, green: 0.3, blue: 0.3)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .opacity(0.2)
            shape.strokeBorder(
                LinearGradient(
                    gradient: Gradient(colors: [Color.cyanCompat.opacity(0.5), .purple.opacity(0.3)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.0
            )
        }
    }
}

public struct CandyCardOverlay<S: InsettableShape>: View {
    let shape: S
    public var body: some View {
        ZStack {
            shape.fill(
                LinearGradient(
                    gradient: Gradient(colors: [Color(red: 0.5, green: 0.2, blue: 0.4), Color(red: 0.6, green: 0.3, blue: 0.5)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .opacity(0.15)
            shape.strokeBorder(
                LinearGradient(
                    gradient: Gradient(colors: [.pink.opacity(0.4), .purple.opacity(0.2)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.0
            )
        }
    }
}

public struct NebulaCardOverlay<S: InsettableShape>: View {
    let shape: S

    public var body: some View {
        ZStack {
            shape.fill(
                RadialGradient(
                    gradient: Gradient(colors: [Color.purple.opacity(0.2), Color.blue.opacity(0.1), .clear]),
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 300
                )
            )
            shape.fill(
                RadialGradient(
                    gradient: Gradient(colors: [Color.pink.opacity(0.15), .clear]),
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: 400
                )
            )
            shape.strokeBorder(
                LinearGradient(
                    gradient: Gradient(colors: [.purple.opacity(0.3), .pink.opacity(0.3)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.0
            )
        }
    }
}

public struct CitrusCardOverlay<S: InsettableShape>: View {
    let shape: S

    public var body: some View {
        ZStack {
            shape.fill(
                LinearGradient(
                    gradient: Gradient(colors: [Color.yellow.opacity(0.2), Color.green.opacity(0.1)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            shape.strokeBorder(
                LinearGradient(
                    gradient: Gradient(colors: [.yellow.opacity(0.4), .green.opacity(0.4)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.0
            )
        }
    }
}

public struct MidnightCardOverlay<S: InsettableShape>: View {
    let shape: S

    public init(shape: S) {
        self.shape = shape
    }

    public var body: some View {
        ZStack {
            // Base subtle silver + semi-transparent gradient
            shape.fill(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(white: 0.85).opacity(0.08),
                        Color(white: 0.65).opacity(0.03),
                        Color(white: 0.45).opacity(0.05)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .blendMode(.plusLighter)

            // High-end silver sheen edge
            shape.strokeBorder(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.white.opacity(0.12),
                        Color.white.opacity(0.02),
                        Color.clear
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.5
            )
            .blendMode(BlendMode.screen)
        }
    }
}

public struct ThemeOverlayView<S: InsettableShape>: View {
    let shape: S
    @Environment(\.themeAppearance) private var appearance

    public init(shape: S) {
        self.shape = shape
    }

    public var body: some View {
        ZStack {
            switch appearance {
            case .midnight:
                MidnightGlassOverlay(shape: shape)
            case .blue:
                ThemeTintOverlay(shape: shape, baseColor: .blue)
            case .purple:
                ThemeTintOverlay(shape: shape, baseColor: .purple)
            case .pink:
                ThemeTintOverlay(shape: shape, baseColor: .pink)
            case .red:
                ThemeTintOverlay(shape: shape, baseColor: .red)
            case .orange:
                ThemeTintOverlay(shape: shape, baseColor: .orange)
            case .yellow:
                ThemeTintOverlay(shape: shape, baseColor: .yellow)
            case .green:
                ThemeTintOverlay(shape: shape, baseColor: .green)
            case .graphite:
                ThemeTintOverlay(shape: shape, baseColor: Color(white: 0.35))
            case .rainbow:
                RainbowCardOverlay(shape: shape)
            case .nebula:
                NebulaCardOverlay(shape: shape)
            case .citrus:
                CitrusCardOverlay(shape: shape)
            case .twilight:
                TwilightCardOverlay(shape: shape)
            case .ocean:
                OceanCardOverlay(shape: shape)
            case .sunset:
                SunsetCardOverlay(shape: shape)
            case .forest:
                ForestCardOverlay(shape: shape)
            case .cyber:
                CyberCardOverlay(shape: shape)
            case .candy:
                CandyCardOverlay(shape: shape)
            default:
                EmptyView()
            }
        }
    }
}

public struct MidnightGlassOverlay<S: InsettableShape>: View {
    let shape: S

    public init(shape: S) {
        self.shape = shape
    }

    public var body: some View {
        ZStack {
            shape.fill(Color(hex: "#020308").opacity(0.45))

            shape.fill(
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color(hex: "#1A44AA").opacity(0.15),
                        Color.clear
                    ]),
                    center: .topTrailing,
                    startRadius: 10,
                    endRadius: 400
                )
            )
            .blendMode(.screen)

            shape.fill(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.white.opacity(0.02),
                        Color.clear,
                        Color.black.opacity(0.25)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .blendMode(.overlay)

            // Add the silver card overlay on top of the glass effect
            MidnightCardOverlay(shape: shape)
        }
    }
}

/// Main entry point for applying glass-like backgrounds with per‑view flexibility.
/// Uses Apple Liquid Glass on macOS 15+, and a custom NSVisualEffect fallback on older macOS.
struct GlassBackground<S: InsettableShape>: View {
    let style: AppChromeStyle
    let cornerRadius: CGFloat
    let shape: S

    @Environment(\.visualEffectOverride) private var effectOverride
    @Environment(\.poorMansGlassTuningOverride) private var poorMansGlassTuningOverride
    @Environment(\.themeAppearance) private var appearance

    private var poorMansGlassBaseTuning: PoorMansGlassTuning {
        switch style {
        case .panel:
            return PoorMansGlassTuning(
                intensity: 0.80,
                haze: 0.76,
                highlight: 1.04,
                chroma: 1.05,
                rim: 1.00
            )
        case .header:
            return PoorMansGlassTuning(
                intensity: 0.76,
                haze: 0.72,
                highlight: 1.06,
                chroma: 1.07,
                rim: 1.02
            )
        case .hud:
            return PoorMansGlassTuning(
                intensity: 0.68,
                haze: 0.60,
                highlight: 1.20,
                chroma: 1.16,
                rim: 1.14
            )
        }
    }

    private var resolvedPoorMansGlassTuning: PoorMansGlassTuning {
        let tuningMultipliers = poorMansGlassTuningOverride ?? .releaseBigSurFallback
        return poorMansGlassBaseTuning.applyingMultipliers(tuningMultipliers)
    }

    init(_ style: AppChromeStyle,
         cornerRadius: CGFloat = 16,
         shape: S) {
        self.style = style
        self.cornerRadius = cornerRadius
        self.shape = shape
    }

    var body: some View {
        Group {
            // First, respect the developer override when present.
            if (effectOverride == .liquidGlass), #available(macOS 26.0, *) {
                // Force: Native SwiftUI Liquid Glass on macOS 26+
                // On Tahoe, compute the glass field within the provided shape (prevents the large oval highlight).
                ZStack {
                    shape
                        .fill(.clear)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .glassEffect(glassForStyle, in: shape)
                        .compositingGroup()
                        .mask { shape.fill(.white) }

                    ThemeOverlayView(shape: shape)
                        .mask { shape.fill(.white) }
                }
            } else if (effectOverride == .thinMaterial), #available(macOS 15.0, *) {
                // Force: Thin Material on macOS 15–25
                ZStack {
                    shape
                        .fill(.ultraThinMaterial)
                        .background(.clear)
                        .clipShape(shape)

                    ThemeOverlayView(shape: shape)
                        .clipShape(shape)
                }
            } else if effectOverride == .classic {
                // Force: Classic fallback regardless of OS
                ZStack {
                    PoorMansGlassBackground(
                        style: style,
                        cornerRadius: cornerRadius,
                        reduceBlur: false,
                        tuning: resolvedPoorMansGlassTuning,
                        appearance: appearance
                    )
                    CardBackgroundOverlay(shape: shape)
                }
            } else if #available(macOS 26.0, *) {
                // Auto: Native SwiftUI Liquid Glass on macOS 26+
                // On Tahoe, compute the glass field within the provided shape (prevents the large oval highlight).
                ZStack {
                    shape
                        .fill(.clear)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .glassEffect(glassForStyle, in: shape)
                        .compositingGroup()
                        .mask { shape.fill(.white) }

                    ThemeOverlayView(shape: shape)
                        .mask { shape.fill(.white) }
                }
            } else if #available(macOS 15.0, *) {
                // Auto: Thin Material on macOS 15–25
                ZStack {
                    shape
                        .fill(.ultraThinMaterial)
                        .background(.clear)
                        .clipShape(shape)

                    ThemeOverlayView(shape: shape)
                        .clipShape(shape)
                }
            } else if #available(macOS 12.0, *) {
                // Auto: Legacy fallback for macOS 12–14
                ZStack {
                    LegacyGlassBackground(style: style, cornerRadius: cornerRadius, shape: shape)
                    ThemeOverlayView(shape: shape)
                        .clipShape(shape)
                }
            } else {
                // Auto: Poor man's fallback for older macOS versions
                ZStack {
                    PoorMansGlassBackground(
                        style: style,
                        cornerRadius: cornerRadius,
                        reduceBlur: false,
                        tuning: resolvedPoorMansGlassTuning,
                        appearance: appearance
                    )
                    CardBackgroundOverlay(shape: shape)
                }
            }
        }
    }

    @available(macOS 26.0, *)
    private var glassForStyle: Glass {
        switch style {
        case .panel:
            return .regular
        case .header:
            return .regular.tint(.black.opacity(0.15))
        case .hud:
            return .regular.tint(.black.opacity(0.12))
        }
    }
}


/// A capsule-shaped glass treatment for compact controls like tab pills.
/// Uses native Liquid Glass / thin material when available, and the richer Big Sur-style fallback otherwise.
struct LiquidGlassPillBackground: View {
    let style: AppChromeStyle

    private let pillShape = Capsule(style: .continuous)

    @Environment(\.themeAppearance) private var appearance

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                ZStack {
                    pillShape
                        .fill(.clear)
                        .glassEffect(glassForStyle, in: pillShape)
                        .compositingGroup()
                        .mask { pillShape.fill(.white) }

                    if appearance == .midnight {
                        MidnightGlassOverlay(shape: pillShape)
                            .mask { pillShape.fill(.white) }
                    }
                }
            } else if #available(macOS 15.0, *) {
                ZStack {
                    pillShape
                        .fill(.ultraThinMaterial)
                        .background(.clear)
                        .clipShape(pillShape)

                    if appearance == .midnight {
                        MidnightGlassOverlay(shape: pillShape)
                            .clipShape(pillShape)
                    }
                }
            } else if #available(macOS 12.0, *) {
                ZStack {
                    LegacyGlassBackground(style: style, cornerRadius: 999, shape: pillShape)
                    if appearance == .midnight {
                        MidnightGlassOverlay(shape: pillShape)
                            .clipShape(pillShape)
                    }
                }
            } else {
                PoorMansGlassBackground(
                    style: style,
                    cornerRadius: 999,
                    reduceBlur: false,
                    tuning: pillFallbackTuning,
                    appearance: appearance
                )
            }
        }
        .clipShape(pillShape)
    }

    private var pillFallbackTuning: PoorMansGlassTuning {
        switch style {
        case .panel:
            return PoorMansGlassTuning(
                intensity: 1.02,
                haze: 0.96,
                highlight: 1.20,
                chroma: 1.04,
                rim: 1.18
            )
        case .header:
            return PoorMansGlassTuning(
                intensity: 1.08,
                haze: 0.98,
                highlight: 1.28,
                chroma: 1.06,
                rim: 1.24
            )
        case .hud:
            return PoorMansGlassTuning(
                intensity: 0.96,
                haze: 0.90,
                highlight: 1.32,
                chroma: 1.10,
                rim: 1.20
            )
        }
    }

    @available(macOS 26.0, *)
    private var glassForStyle: Glass {
        switch style {
        case .panel:
            return .regular
        case .header:
            return .regular.tint(.black.opacity(0.15))
        case .hud:
            return .regular.tint(.black.opacity(0.12))
        }
    }
}

struct LegacyGlassBackground<S: InsettableShape>: NSViewRepresentable {
    let style: AppChromeStyle
    let cornerRadius: CGFloat
    let shape: S

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.blendingMode = .withinWindow
        view.material = materialForStyle
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = materialForStyle
        nsView.blendingMode = .withinWindow
        nsView.state = .active
        nsView.layer?.cornerRadius = cornerRadius
    }

    private var materialForStyle: NSVisualEffectView.Material {
        switch style {
        case .panel:  return .underWindowBackground
        case .header: return .titlebar
        case .hud:    return .hudWindow
        }
    }
}

struct WindowGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .hudWindow
        nsView.blendingMode = .withinWindow
    }
}

struct TransparentWindowConfigurator: NSViewRepresentable {
    var cornerRadius: CGFloat = 16
    var titlebarOverlayColor: NSColor = NSColor.black.withAlphaComponent(0.06)
    var enableTitlebarOverlay: Bool = true
    var allowsWindowBackgroundDragging: Bool = false

    private var isBigSur: Bool {
        if #available(macOS 12.0, *) {
            return false
        } else {
            return true
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            window.isOpaque = false
            window.backgroundColor = enableTitlebarOverlay ? titlebarOverlayColor : .clear
            window.isMovableByWindowBackground = allowsWindowBackgroundDragging

            if isBigSur {
                // Big Sur is noticeably more fragile when transparent titlebars, rounded content clipping,
                // and nested visual-effect views are combined. Keep the window configuration conservative.
                window.titlebarAppearsTransparent = false
                window.titleVisibility = .visible
            } else {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.toolbarStyle = .unified

                // Clear the AppKit hosting chain so opaque container backgrounds do not interfere
                // with glass sampling, but only apply rounded clipping to the actual contentView.
                var currentView: NSView? = window.contentView
                while let viewToFix = currentView {
                    viewToFix.wantsLayer = true
                    if viewToFix.layer == nil { viewToFix.makeBackingLayer() }
                    viewToFix.layer?.backgroundColor = NSColor.clear.cgColor

                    // Avoid nested rounded-rectangle artifacts by removing clipping from ancestor views.
                    if viewToFix !== window.contentView {
                        viewToFix.layer?.cornerRadius = 16
                        viewToFix.layer?.masksToBounds = false
                    }

                    currentView = viewToFix.superview
                }

                if let contentView = window.contentView {
                    contentView.wantsLayer = true
                    if contentView.layer == nil { contentView.makeBackingLayer() }
                    contentView.layer?.backgroundColor = NSColor.clear.cgColor
                    contentView.layer?.cornerRadius = cornerRadius
                    contentView.layer?.cornerCurve = .continuous
                    contentView.layer?.masksToBounds = true
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.isOpaque = false
            window.backgroundColor = enableTitlebarOverlay ? titlebarOverlayColor : .clear
            window.isMovableByWindowBackground = allowsWindowBackgroundDragging

            if isBigSur {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .visible
                if let contentView = window.contentView {
                    contentView.wantsLayer = true
                    if contentView.layer == nil { contentView.makeBackingLayer() }
                    contentView.layer?.backgroundColor = NSColor.clear.cgColor
                    contentView.layer?.cornerRadius = 16
                    contentView.layer?.masksToBounds = false
                }
            } else {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.toolbarStyle = .unified
                if let contentView = window.contentView {
                    contentView.wantsLayer = true
                    if contentView.layer == nil { contentView.makeBackingLayer() }
                    contentView.layer?.backgroundColor = NSColor.clear.cgColor
                    contentView.layer?.cornerRadius = cornerRadius
                    contentView.layer?.cornerCurve = .continuous
                    contentView.layer?.masksToBounds = true
                }
            }
        }
    }
}

// MARK: - Glass container and helpers (macOS 26+ with graceful fallback)

/// A wrapper that uses `GlassEffectContainer` on macOS 26+ and no-ops on earlier systems.
/// Use this to group multiple glass elements so they can merge/morph on Tahoe.
public struct GlassGroupContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    public init(spacing: CGFloat = 20, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    public var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: spacing) {
                    content()
                }
            } else {
                // Earlier systems: render content directly
                content()
            }
        }
    }
}
