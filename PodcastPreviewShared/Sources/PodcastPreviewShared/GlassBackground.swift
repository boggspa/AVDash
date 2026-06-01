import SwiftUI

public enum ThemeAppearanceOverride: String, CaseIterable, Identifiable {
    case system
    case dark
    case light
    case midnight
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case graphite
    case rainbow
    case nebula
    case citrus
    case twilight
    case ocean
    case sunset
    case forest
    case cyber
    case candy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system:   return "System"
        case .dark:     return "Dark"
        case .light:    return "Light"
        case .midnight: return "Midnight"
        case .blue:     return "Blue"
        case .purple:   return "Purple"
        case .pink:     return "Pink"
        case .red:      return "Red"
        case .orange:   return "Orange"
        case .yellow:   return "Yellow"
        case .green:    return "Green"
        case .graphite: return "Graphite"
        case .rainbow:  return "Rainbow"
        case .nebula:   return "Nebula"
        case .citrus:   return "Citrus"
        case .twilight: return "Twilight"
        case .ocean:    return "Ocean"
        case .sunset:   return "Sunset"
        case .forest:   return "Forest"
        case .cyber:    return "Cyber"
        case .candy:    return "Candy"
        }
    }

    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light, .citrus:
            return .light
        default:
            return .dark
        }
    }
}

public enum ThemeCornerStyle: String, CaseIterable, Identifiable {
    case rounded
    case hard

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rounded: return "Rounded"
        case .hard:    return "Hard"
        }
    }
}

public enum ThemeAccentStyle: String, CaseIterable, Identifiable {
    case system
    case blue
    case purple
    case pink
    case orange
    case green
    case red
    case yellow

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system:  return "System"
        case .blue:    return "Blue"
        case .purple:  return "Purple"
        case .pink:    return "Pink"
        case .orange:  return "Orange"
        case .green:   return "Green"
        case .red:     return "Red"
        case .yellow:  return "Yellow"
        }
    }

    public var color: Color {
        switch self {
        case .system:  return Color.accentColor
        case .blue:    return Color.blue
        case .purple:  return Color.purple
        case .pink:    return Color.pink
        case .orange:  return Color.orange
        case .green:   return Color.green
        case .red:     return Color.red
        case .yellow:  return Color.yellow
        }
    }
}

public extension Color {
    init(hex: String) {
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
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

public enum AppChromeStyle {
    case panel
    case header
    case hud
}

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

public enum VisualEffectOverride: String, CaseIterable, Identifiable {
    case auto
    case liquidGlass
    case thinMaterial
    case classic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto:         return "Auto"
        case .liquidGlass:  return "LiquidGlass"
        case .thinMaterial: return "ultraThinMaterial"
        case .classic:      return "PoorMansGlassBackground"
        }
    }
}

private struct VisualEffectOverrideKey: EnvironmentKey {
    static let defaultValue: VisualEffectOverride = .auto
}

private struct PoorMansGlassTuningKey: EnvironmentKey {
    static let defaultValue: PoorMansGlassTuning? = nil
}

private struct ThemeAppearanceOverrideKey: EnvironmentKey {
    static let defaultValue: ThemeAppearanceOverride = .system
}

public extension EnvironmentValues {
    var visualEffectOverride: VisualEffectOverride {
        get { self[VisualEffectOverrideKey.self] }
        set { self[VisualEffectOverrideKey.self] = newValue }
    }

    var poorMansGlassTuningOverride: PoorMansGlassTuning? {
        get { self[PoorMansGlassTuningKey.self] }
        set { self[PoorMansGlassTuningKey.self] = newValue }
    }

    var themeAppearance: ThemeAppearanceOverride {
        get { self[ThemeAppearanceOverrideKey.self] }
        set { self[ThemeAppearanceOverrideKey.self] = newValue }
    }
}

public extension View {
    func visualEffectOverride(_ override: VisualEffectOverride) -> some View {
        environment(\.visualEffectOverride, override)
    }

    func poorMansGlassTuning(_ tuning: PoorMansGlassTuning?) -> some View {
        environment(\.poorMansGlassTuningOverride, tuning)
    }

    func themeAppearance(_ appearance: ThemeAppearanceOverride) -> some View {
        environment(\.themeAppearance, appearance)
    }
}

public struct GlassBackground<S: Shape>: View {
    let style: AppChromeStyle
    let cornerRadius: CGFloat
    let shape: S

    @Environment(\.visualEffectOverride) private var effectOverride
    @Environment(\.poorMansGlassTuningOverride) private var poorMansGlassTuningOverride
    @Environment(\.themeAppearance) private var appearance

    public init(_ style: AppChromeStyle,
         cornerRadius: CGFloat = 16,
         shape: S) {
        self.style = style
        self.cornerRadius = cornerRadius
        self.shape = shape
    }

    public var body: some View {
        Group {
            #if os(iOS)
            shape.fill(.ultraThinMaterial)
            #else
            if effectOverride == .classic {
                PoorMansGlassBackground(
                    style: style,
                    cornerRadius: cornerRadius,
                    tuning: poorMansGlassTuningOverride ?? .neutral,
                    appearance: appearance
                )
            } else if effectOverride == .liquidGlass || effectOverride == .thinMaterial {
                if #available(macOS 12.0, *) {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        if appearance == .midnight {
                             shape.fill(Color(hex: "#020308").opacity(0.45))
                             shape.fill(
                                 RadialGradient(
                                     colors: [Color(hex: "#1A44AA").opacity(0.15), .clear],
                                     center: .topTrailing,
                                     startRadius: 0,
                                     endRadius: 300
                                 )
                             )
                             .blendMode(.screen)

                             shape.fill(
                                 LinearGradient(
                                     colors: [
                                         Color.white.opacity(0.02),
                                         Color.clear,
                                         Color.black.opacity(0.25)
                                     ],
                                     startPoint: .top,
                                     endPoint: .bottom
                                 )
                             )
                             .blendMode(.overlay)
                        }
                    }
                } else {
                    PoorMansGlassBackground(
                        style: style,
                        cornerRadius: cornerRadius,
                        tuning: poorMansGlassTuningOverride ?? .neutral,
                        appearance: appearance
                    )
                }
            } else {
                // .auto
                if #available(macOS 12.0, *) {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        if appearance == .midnight {
                             shape.fill(Color(hex: "#020308").opacity(0.45))
                             shape.fill(
                                 RadialGradient(
                                     colors: [Color(hex: "#1A44AA").opacity(0.15), .clear],
                                     center: .topTrailing,
                                     startRadius: 0,
                                     endRadius: 300
                                 )
                             )
                             .blendMode(.screen)

                             shape.fill(
                                 LinearGradient(
                                     colors: [
                                         Color.white.opacity(0.02),
                                         Color.clear,
                                         Color.black.opacity(0.25)
                                     ],
                                     startPoint: .top,
                                     endPoint: .bottom
                                 )
                             )
                             .blendMode(.overlay)
                        }
                    }
                } else {
                    PoorMansGlassBackground(
                        style: style,
                        cornerRadius: cornerRadius,
                        tuning: poorMansGlassTuningOverride ?? .neutral,
                        appearance: appearance
                    )
                }
            }
            #endif
        }
    }
}
