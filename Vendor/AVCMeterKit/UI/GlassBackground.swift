// MARK: - Supporting Types for PoorMansGlassBackground
// These types are used by the fallback liquid glass implementation for older macOS versions

import SwiftUI
import AppKit

/// Style options for glass/chrome surfaces
enum AppChromeStyle {
    case panel
    case header
    case hud
}

/// Tuning parameters for the "poor man's glass" fallback effect
public struct PoorMansGlassTuning: Equatable, Sendable {
    public static let releaseBigSurFallback = PoorMansGlassTuning(
        intensity: 0.15,
        haze: 1.0,
        highlight: 0.15,
        chroma: 1.0,
        rim: 2.5
    )

    public var intensity: CGFloat
    public var haze: CGFloat
    public var highlight: CGFloat
    public var chroma: CGFloat
    public var rim: CGFloat

    public init(
        intensity: CGFloat = 1.0,
        haze: CGFloat = 1.0,
        highlight: CGFloat = 1.0,
        chroma: CGFloat = 1.0,
        rim: CGFloat = 1.0
    ) {
        self.intensity = intensity
        self.haze = haze
        self.highlight = highlight
        self.chroma = chroma
        self.rim = rim
    }

    public static let neutral = PoorMansGlassTuning()

    public func applyingMultipliers(_ multipliers: PoorMansGlassTuning) -> PoorMansGlassTuning {
        PoorMansGlassTuning(
            intensity: intensity * multipliers.intensity,
            haze: haze * multipliers.haze,
            highlight: highlight * multipliers.highlight,
            chroma: chroma * multipliers.chroma,
            rim: rim * multipliers.rim
        )
    }
}

/// Main entry point for applying glass-like backgrounds with per‑view flexibility.
/// Uses Apple Liquid Glass on macOS 26+, and PoorMansGlass fallback on older macOS.
struct GlassBackground<S: InsettableShape>: View {
    let style: AppChromeStyle
    let cornerRadius: CGFloat
    let shape: S

    @ObservedObject private var themeManager = ThemeManager.shared

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

    init(_ style: AppChromeStyle,
         cornerRadius: CGFloat = 16,
         shape: S) {
        self.style = style
        self.cornerRadius = cornerRadius
        self.shape = shape
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                // Native SwiftUI Liquid Glass on macOS 26+
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
                // Thin Material on macOS 15–25
                ZStack {
                    shape
                        .fill(.ultraThinMaterial)
                        .background(.clear)
                        .clipShape(shape)

                    ThemeOverlayView(shape: shape)
                        .clipShape(shape)
                }
            } else {
                // Poor man's fallback for older macOS versions (Big Sur and earlier)
                ZStack {
                    PoorMansGlassBackground(
                        style: style,
                        cornerRadius: cornerRadius,
                        reduceBlur: false,
                        tuning: poorMansGlassBaseTuning,
                        themeMode: themeManager.currentThemeMode
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
    @ObservedObject private var themeManager = ThemeManager.shared

    public init(shape: S) {
        self.shape = shape
    }

    public var body: some View {
        Group {
            switch themeManager.currentThemeMode {
            case .midnight:
                MidnightCardOverlay(shape: shape)
            case .blue:
                ThemeTintOverlay(shape: shape, baseColor: .blue)
            case .pink:
                ThemeTintOverlay(shape: shape, baseColor: .pink)
            case .red:
                ThemeTintOverlay(shape: shape, baseColor: .red)
            case .orange:
                ThemeTintOverlay(shape: shape, baseColor: .orange)
            case .yellow:
                ThemeTintOverlay(shape: shape, baseColor: .yellow)
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

public struct ThemeOverlayView<S: InsettableShape>: View {
    let shape: S
    @ObservedObject private var themeManager = ThemeManager.shared

    public init(shape: S) {
        self.shape = shape
    }

    public var body: some View {
        ZStack {
            switch themeManager.currentThemeMode {
            case .midnight:
                MidnightGlassOverlay(shape: shape)
            case .blue:
                ThemeTintOverlay(shape: shape, baseColor: .blue)
            case .pink:
                ThemeTintOverlay(shape: shape, baseColor: .pink)
            case .red:
                ThemeTintOverlay(shape: shape, baseColor: .red)
            case .orange:
                ThemeTintOverlay(shape: shape, baseColor: .orange)
            case .yellow:
                ThemeTintOverlay(shape: shape, baseColor: .yellow)
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

public struct MidnightGlassOverlay<S: InsettableShape>: View {
    let shape: S

    public init(shape: S) {
        self.shape = shape
    }

    public var body: some View {
        ZStack {
            shape.fill(Color(red: 2/255, green: 3/255, blue: 8/255).opacity(0.45))

            shape.fill(
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color(red: 26/255, green: 68/255, blue: 170/255).opacity(0.15),
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

/// Simple legacy glass fallback using NSVisualEffectView
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

public extension InsettableShape {
    @ViewBuilder
    func themed(fill: Color = Color.black.opacity(0.08), stroke: Color = Color.white.opacity(0.15), lineWidth: CGFloat = 1) -> some View {
        self.fill(fill)
            .overlay(
                self.stroke(stroke, lineWidth: lineWidth)
            )
            .overlay(CardBackgroundOverlay(shape: self))
    }
}

/// Window-level glass background
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
        nsView.state = .active
        nsView.isEmphasized = false
    }
}
