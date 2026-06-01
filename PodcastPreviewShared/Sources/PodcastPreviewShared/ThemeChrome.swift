import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

public extension VisualEffectOverride {
    var devLabel: String { displayName }
}

private struct SharedThemeAccentStyleKey: EnvironmentKey {
    static let defaultValue: ThemeAccentStyle = .system
}

public extension EnvironmentValues {
    var accentStyle: ThemeAccentStyle {
        get { self[SharedThemeAccentStyleKey.self] }
        set { self[SharedThemeAccentStyleKey.self] = newValue }
    }
}

public extension View {
    func applyThemeEnvironment() -> some View {
        modifier(SharedThemeEnvironment())
    }
}

private struct SharedThemeEnvironment: ViewModifier {
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
            .modifier(SharedAccentColorModifier(accentColor: accentStyle.color))
            .background(SharedThemeAppearanceConfigurator(appearance: appearance).frame(width: 0, height: 0))
            .preferredColorScheme(appearance.preferredColorScheme)
    }
}

private struct SharedAccentColorModifier: ViewModifier {
    let accentColor: Color

    func body(content: Content) -> some View {
        if #available(macOS 13.0, iOS 16.0, *) {
            content.tint(accentColor)
        } else {
            content
        }
    }
}

private struct SharedThemeAppearanceConfigurator: View {
    let appearance: ThemeAppearanceOverride

    var body: some View {
        #if canImport(AppKit)
        SharedThemeAppearanceNSView(appearance: appearance)
        #else
        EmptyView()
        #endif
    }
}

#if canImport(AppKit)
private struct SharedThemeAppearanceNSView: NSViewRepresentable {
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
#endif

#if DEBUG
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

                Text("Tune the Big Sur fallback glass and backdrop wash.")
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
        String(format: "%.2fx", value)
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

            Slider(value: value, in: 0.15...2.50, step: 0.01)
        }
    }
}

public extension View {
    func applyDevVisualEffectEnvironment() -> some View {
        modifier(SharedDevVisualEffectEnvironment())
    }
}

private struct SharedDevVisualEffectEnvironment: ViewModifier {
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
            SharedThemePopoverContent(
                visualEffectSelection: visualEffectSelection,
                appearanceSelection: appearanceSelection,
                cornerStyleSelection: cornerStyleSelection,
                accentStyleSelection: accentStyleSelection
            )
        }
    }
}

private struct SharedThemePopoverContent: View {
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

            themePicker("Glass", selection: $visualEffectSelection, options: VisualEffectOverride.allCases)

            Divider()

            themePicker("System theme", selection: $appearanceSelection, options: ThemeAppearanceOverride.allCases)

            Divider()

            themePicker("Corners", selection: $cornerStyleSelection, options: ThemeCornerStyle.allCases)

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
                #if os(macOS)
                .pickerStyle(.radioGroup)
                #else
                .pickerStyle(.menu)
                #endif
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    @ViewBuilder
    private func themePicker<Option: Identifiable & Hashable>(
        _ title: String,
        selection: Binding<Option>,
        options: [Option]
    ) -> some View where Option.ID == String {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            Picker("", selection: selection) {
                ForEach(options) { option in
                    Text(displayName(for: option)).tag(option)
                }
            }
            #if os(macOS)
            .pickerStyle(.radioGroup)
            #else
            .pickerStyle(.menu)
            #endif
        }
    }

    private func displayName<Option>(for option: Option) -> String {
        switch option {
        case let value as VisualEffectOverride:
            return value.displayName
        case let value as ThemeAppearanceOverride:
            return value.displayName
        case let value as ThemeCornerStyle:
            return value.displayName
        default:
            return String(describing: option)
        }
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
        }
        return RoundedRectangle(cornerRadius: cornerRadius, style: style)
            .inset(by: insetAmount)
            .path(in: rect)
    }

    public func inset(by amount: CGFloat) -> ThemeRoundedRectangle {
        var shape = self
        shape.insetAmount += amount
        return shape
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

public extension InsettableShape {
    @ViewBuilder
    func themed(
        fill: Color = GraphiteSlateTheme.cardFill,
        stroke: Color = GraphiteSlateTheme.cardStroke,
        lineWidth: CGFloat = 1
    ) -> some View {
        self.fill(fill)
            .overlay(self.stroke(stroke, lineWidth: lineWidth))
            .overlay(CardBackgroundOverlay(shape: self))
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
            default:
                EmptyView()
            }
        }
    }
}

public struct ThemeTintOverlay<S: InsettableShape>: View {
    let shape: S
    let baseColor: Color

    public init(shape: S, baseColor: Color) {
        self.shape = shape
        self.baseColor = baseColor
    }

    public var body: some View {
        ZStack {
            shape.fill(baseColor.opacity(0.12))
            shape.strokeBorder(baseColor.opacity(0.25), lineWidth: 0.5)
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
            shape.fill(
                LinearGradient(
                    colors: [
                        Color(white: 0.85).opacity(0.08),
                        Color(white: 0.65).opacity(0.03),
                        Color(white: 0.45).opacity(0.05)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .blendMode(.plusLighter)

            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.12),
                        Color.white.opacity(0.02),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.5
            )
            .blendMode(.screen)
        }
    }
}

public struct LiquidGlassPillBackground: View {
    public let style: AppChromeStyle

    private let pillShape = Capsule(style: .continuous)

    public init(style: AppChromeStyle) {
        self.style = style
    }

    public var body: some View {
        GlassBackground(style, cornerRadius: 999, shape: pillShape)
            .clipShape(pillShape)
    }
}

public enum AppBackdropStyle {
    case liquidGlass
}

public struct LiquidGlassBackdrop: View {
    public var style: AppBackdropStyle
    @AppStorage("theme.appearanceOverride") private var storedAppearance = ThemeAppearanceOverride.system.rawValue

    public init(style: AppBackdropStyle = .liquidGlass) {
        self.style = style
    }

    public var body: some View {
        let appearance = ThemeAppearanceOverride(rawValue: storedAppearance) ?? .system
        let gradient = LinearGradient(
            colors: backdropColors(for: appearance),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        if #available(macOS 12.0, *) {
            gradient.background(.ultraThinMaterial)
        } else {
            gradient
        }
    }

    private func backdropColors(for appearance: ThemeAppearanceOverride) -> [Color] {
        switch appearance {
        case .light, .citrus:
            return [
                Color.white.opacity(0.78),
                Color(red: 0.86, green: 0.91, blue: 0.96).opacity(0.55),
                Color.white.opacity(0.68)
            ]
        case .ocean:
            return [
                Color(red: 0.01, green: 0.06, blue: 0.10).opacity(0.94),
                Color(red: 0.02, green: 0.20, blue: 0.24).opacity(0.72),
                Color.black.opacity(0.86)
            ]
        case .forest:
            return [
                Color(red: 0.02, green: 0.08, blue: 0.05).opacity(0.94),
                Color(red: 0.08, green: 0.18, blue: 0.10).opacity(0.72),
                Color.black.opacity(0.86)
            ]
        case .sunset:
            return [
                Color(red: 0.10, green: 0.04, blue: 0.06).opacity(0.94),
                Color(red: 0.23, green: 0.10, blue: 0.06).opacity(0.70),
                Color.black.opacity(0.84)
            ]
        case .nebula, .purple, .pink, .candy:
            return [
                Color(red: 0.05, green: 0.03, blue: 0.10).opacity(0.94),
                Color(red: 0.17, green: 0.07, blue: 0.24).opacity(0.68),
                Color.black.opacity(0.86)
            ]
        default:
            return [
                Color.black.opacity(0.92),
                Color(red: 0.06, green: 0.07, blue: 0.075).opacity(0.72),
                Color.black.opacity(0.86)
            ]
        }
    }
}

public struct LiquidGlassPanel: View {
    public let cornerRadius: CGFloat
    public let style: AppChromeStyle

    public init(cornerRadius: CGFloat = 16, style: AppChromeStyle = .panel) {
        self.cornerRadius = cornerRadius
        self.style = style
    }

    public var body: some View {
        let shape = ThemeRoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        GlassBackground(style, cornerRadius: cornerRadius, shape: shape)
            .clipShape(shape)
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

public enum GraphiteSidebarSeparatorEdge: Equatable {
    case leading
    case trailing
}

public extension View {
    func graphiteSurface(
        _ surface: GraphiteSlateSurface = .panel,
        cornerRadius: CGFloat = 12,
        stroke: Color? = nil,
        lineWidth: CGFloat = 1
    ) -> some View {
        modifier(SharedGraphiteSlateSurfaceModifier(
            surface: surface,
            cornerRadius: cornerRadius,
            stroke: stroke,
            lineWidth: lineWidth
        ))
    }

    func graphiteSidebarSeparator(edge: GraphiteSidebarSeparatorEdge = .trailing) -> some View {
        overlay(GraphiteSidebarRim(edge: edge))
    }

    func graphiteSidebarChrome(separatorEdge: GraphiteSidebarSeparatorEdge = .trailing) -> some View {
        background(
            GraphiteSidebarBackground()
                .ignoresSafeArea()
        )
        .graphiteSidebarSeparator(edge: separatorEdge)
    }
}

private struct SharedGraphiteSlateSurfaceModifier: ViewModifier {
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

#if canImport(AppKit)
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

public struct WindowGlassBackground: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .hudWindow
        nsView.blendingMode = .withinWindow
    }
}

public struct TransparentWindowConfigurator: NSViewRepresentable {
    public var cornerRadius: CGFloat
    public var titlebarOverlayColor: NSColor
    public var enableTitlebarOverlay: Bool
    public var allowsWindowBackgroundDragging: Bool

    public init(
        cornerRadius: CGFloat = 16,
        titlebarOverlayColor: NSColor = NSColor.black.withAlphaComponent(0.06),
        enableTitlebarOverlay: Bool = true,
        allowsWindowBackgroundDragging: Bool = false
    ) {
        self.cornerRadius = cornerRadius
        self.titlebarOverlayColor = titlebarOverlayColor
        self.enableTitlebarOverlay = enableTitlebarOverlay
        self.allowsWindowBackgroundDragging = allowsWindowBackgroundDragging
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = enableTitlebarOverlay ? titlebarOverlayColor : .clear
        window.isMovableByWindowBackground = allowsWindowBackgroundDragging

        if #available(macOS 12.0, *) {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbarStyle = .unified
        } else {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible
        }

        if let contentView = window.contentView {
            contentView.wantsLayer = true
            if contentView.layer == nil { contentView.makeBackingLayer() }
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
            contentView.layer?.cornerRadius = cornerRadius
            contentView.layer?.masksToBounds = false
            if #available(macOS 10.15, *) {
                contentView.layer?.cornerCurve = .continuous
            }
        }
    }
}
#else
public struct GraphiteSlateWindowRim: View {
    public let cornerRadius: CGFloat
    public init(cornerRadius: CGFloat = 16) {
        self.cornerRadius = cornerRadius
    }
    public var body: some View { EmptyView() }
}

public struct GraphiteSidebarRim: View {
    public let edge: GraphiteSidebarSeparatorEdge
    public init(edge: GraphiteSidebarSeparatorEdge = .trailing) {
        self.edge = edge
    }
    public var body: some View { EmptyView() }
}
#endif

public struct GlassGroupContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    public init(spacing: CGFloat = 20, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    public var body: some View {
        content()
    }
}

public extension View {
    @ViewBuilder
    func glassUnion(id: String, in namespace: Namespace.ID) -> some View {
        self
    }

    @ViewBuilder
    func glassID(_ id: String, in namespace: Namespace.ID) -> some View {
        self
    }
}
