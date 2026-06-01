//
//  ThemeManager.swift
//  AVCMeter
//
//  This file defines the ThemeManager, which controls the UI's theme mode (light, dark, thinMaterial)
//  and the accent color. It provides mechanisms for cycling themes and colors with animations and
//  manages transient UI messages related to those changes.
//

import Foundation
import CoreAudio
import SwiftUI

// MARK: - Enum for Theme Modes

/// Represents the available visual themes for the application's UI.
///
/// Includes standard light and dark modes, a translucent thin material style, and several color-tinted themes.
/// Used to control the appearance of views and capsules throughout the app.
enum ThemeMode: Int, CaseIterable {
    /// Standard light theme.
    case light
    /// Standard dark theme.
    case dark
    /// Apple-style translucent blur material theme.
    case thinMaterial
    /// Purple tinted theme.
    case purple
    /// Mint tinted theme.
    case mint
    /// Lavender tinted theme.
    case lavender
    /// Indigo tinted theme.
    case indigo
    /// Gray tinted theme.
    case gray
    /// Hollow or transparent theme.
    case hollow
    /// Custom Liquid Glass theme using bespoke SwiftUI background.
    case liquidGlass
    /// Simulated Liquid Glass for older macOS (Big Sur+) using layered visual effects.
    case poorMansGlass
    /// Deep dark theme with blue glows.
    case midnight
    case blue
    case pink
    case red
    case orange
    case yellow
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
}

/// Represents the available visual styles for channel strips.
enum ChannelStripColor: Int, CaseIterable {
    case standard
    case red
    case blue
    case green
    case orange
    case yellow
    case gray
    case white
    case mint
    case pink
    case purple
}

/// Represents the corner style for UI elements.
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

// MARK: - Theme Manager Class

/// An observable object responsible for managing the application's theme and accent colors.
///
/// This class tracks the current theme mode, capsule theme mode (which can be device-specific),
/// the accent color used throughout the UI, and transient UI messages related to theme and color changes.
/// It provides functionality to cycle through themes and accent colors with animated feedback.
///
/// Usage:
/// - Bind views to `@Published` properties such as `currentThemeMode` and `accentColor` to reactively update UI.
/// - Call `toggleTheme()` to cycle through the main themes with animated flash messages.
/// - Call `cycleAccentColorAndShowMessage()` to cycle accent colors with a brief UI flash label.
/// - Supports device-specific capsule themes via `deviceCapsuleThemes`.
@MainActor
class ThemeManager: ObservableObject {
    /// The currently selected main theme mode for the application UI.
    @Published var currentThemeMode: ThemeMode = .liquidGlass

    /// The theme mode used for capsule UI elements, which can be independent from the main app theme.
    @Published var capsuleThemeMode: ThemeMode = .light

    /// The currently selected accent color used for highlights and backgrounds.
    @Published var accentColor: NSColor = NSColor.gray.withAlphaComponent(0.25)

    /// A transient message string displayed when the theme changes.
    @Published var themeMessage: String? = nil

    /// Controls whether the theme change flash animation is visible.
    @Published var showThemeFlash: Bool = false

    /// A transient message string displayed when the accent color changes.
    @Published var colorMessage: String? = nil

    /// Controls whether the accent color change flash animation is visible.
    @Published var showColorFlash: Bool = false

    /// Used to force views to refresh when per-device themes or settings change.
    @Published var deviceThemeVersion = UUID()

    /// When true, the framework is being hosted inside another app and should avoid
    /// mutating the shared app window or drawing its own full-window backdrop.
    var isEmbeddedInHost: Bool = false

    /// Dictionary mapping audio device IDs to their specific capsule theme modes.
    ///
    /// This allows individual audio devices to have customized capsule appearances.
    @Published var deviceCapsuleThemes: [AudioDeviceID: ThemeMode] = [:]

    /// Dictionary mapping audio device IDs to their specific spectrum window scale factors.
    ///
    /// This allows individual audio devices to use custom spectrum window sizes (e.g., 1/2x, 2x).
    @Published var deviceSpectrumScaleFactors: [AudioDeviceID: Double] = [:]

    /// Dictionary mapping audio device IDs to a selected ChannelStripColor for visual customization.
    @Published var deviceChannelStripColors: [AudioDeviceID: ChannelStripColor] = [:]

    /// A SwiftUI `Color` derived from the current accent `NSColor` with reduced opacity for fill backgrounds.
    ///
    /// This color is typically used for subtle background fills that complement the accent color.
    var accentFillColor: Color {
        Color(accentColor).opacity(0.35)
    }

    static let shared = ThemeManager()

    private var themeMessageTimer: Timer? = nil
    private var colorMessageTimer: Timer? = nil

    // MARK: - Predefined Accent Colors

    /// Provides a curated list of accent colors available for cycling.
    ///
    /// Each color is an `NSColor` instance with a set alpha transparency to be used as accent backgrounds or highlights.
    /// The list includes system colors and some custom tints to provide variety.
    ///
    /// - Returns: An array of `NSColor` objects representing the accent color options.
    var accentColors: [NSColor] {
        [
            NSColor.systemPink.withAlphaComponent(0.6),
            NSColor.systemTeal.withAlphaComponent(0.65),
            NSColor.systemOrange.withAlphaComponent(0.6),
            NSColor.systemPurple.withAlphaComponent(0.65),
            NSColor.systemIndigo.withAlphaComponent(0.64),
            NSColor.systemYellow.withAlphaComponent(0.65),
            NSColor.systemRed.withAlphaComponent(0.65),
            NSColor.systemBlue.withAlphaComponent(0.65),
            NSColor.systemGreen.withAlphaComponent(0.65),
            NSColor.systemMint.withAlphaComponent(0.65),
            NSColor.brown.withAlphaComponent(0.65),
            NSColor.cyan.withAlphaComponent(0.65),
            NSColor.magenta.withAlphaComponent(0.65),
            NSColor.orange.withAlphaComponent(0.65),
            NSColor.gray.withAlphaComponent(0.65),
            NSColor.white.withAlphaComponent(0.40),
            NSColor.controlBackgroundColor,
            NSColor.controlBackgroundColor.withAlphaComponent(0.1)
        ]
    }

    // MARK: - Accent Color Cycling

    /// Advances the accent color to the next color in the predefined list.
    ///
    /// If the current accent color is not found in the list, cycling starts from the first color.
    /// This method updates the `accentColor` property to the new color.
    func cycleAccentColor() {
        let current = accentColor
        let idx = accentColors.firstIndex(where: { $0 == current }) ?? 0
        let nextIdx = (idx + 1) % accentColors.count
        accentColor = accentColors[nextIdx]
    }

    /// Returns a human-readable label for a given accent color.
    ///
    /// This is primarily used to display descriptive messages in the UI when the accent color changes.
    ///
    /// - Parameter color: The `NSColor` to get the label for.
    /// - Returns: A `String` representing the color's common name or "Custom" if unknown.
    func accentColorLabel(for color: NSColor) -> String {
        switch color {
        case NSColor.systemPink.withAlphaComponent(0.6): return "Pink"
        case NSColor.systemTeal.withAlphaComponent(0.65): return "Teal"
        case NSColor.systemOrange.withAlphaComponent(0.6): return "Orange"
        case NSColor.systemPurple.withAlphaComponent(0.65): return "Purple"
        case NSColor.systemIndigo.withAlphaComponent(0.64): return "Indigo"
        case NSColor.systemYellow.withAlphaComponent(0.65): return "Yellow"
        case NSColor.systemRed.withAlphaComponent(0.65): return "Red"
        case NSColor.systemBlue.withAlphaComponent(0.65): return "Blue"
        case NSColor.systemGreen.withAlphaComponent(0.65): return "Green"
        case NSColor.systemMint.withAlphaComponent(0.65): return "Mint"
        case NSColor.brown.withAlphaComponent(0.65): return "Brown"
        case NSColor.cyan.withAlphaComponent(0.65): return "Cyan"
        case NSColor.magenta.withAlphaComponent(0.65): return "Magenta"
        case NSColor.orange.withAlphaComponent(0.65): return "Orange (Alt)"
        case NSColor.gray.withAlphaComponent(0.65): return "Gray"
        case NSColor.white.withAlphaComponent(0.40): return "White"
        case NSColor.controlBackgroundColor: return "Neutral"
        case NSColor.controlBackgroundColor.withAlphaComponent(0.1): return "Neutral (Light)"
        default: return "Custom"
        }
    }

    // MARK: - Theme Switching Logic

    /// Cycles through the main theme modes.
    ///
    /// Updates the application's appearance accordingly and triggers a brief animated flash message indicating the new theme.
    /// The `NSApp.appearance` is set to the appropriate `NSAppearance` or `nil` for material/glass themes.
    ///
    /// The flash message automatically disappears after 2 seconds.
    func toggleTheme() {
        let themeCycle: [ThemeMode] = [
            .light, .dark, .thinMaterial, .midnight, .blue, .pink, .red, .orange, .yellow, .graphite,
            .rainbow, .nebula, .citrus, .twilight, .ocean, .sunset, .forest, .cyber, .candy,
            .liquidGlass, .poorMansGlass
        ]
        let current = currentThemeMode
        let nextIdx = (themeCycle.firstIndex(of: current) ?? 0) + 1
        let nextTheme = themeCycle[nextIdx % themeCycle.count]
        currentThemeMode = nextTheme

        switch nextTheme {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
            themeMessage = "Light Theme"
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            themeMessage = "Dark Theme"
        case .thinMaterial:
            NSApp.appearance = nil
            themeMessage = "Thin Material"
        case .midnight:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            themeMessage = "Midnight"
        case .blue:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            themeMessage = "Blue"
        case .pink:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            themeMessage = "Pink"
        case .red:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            themeMessage = "Red"
        case .orange:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            themeMessage = "Orange"
        case .yellow:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            themeMessage = "Yellow"
        case .graphite:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            themeMessage = "Graphite"
        case .rainbow:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            themeMessage = "Rainbow"
        case .nebula:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            themeMessage = "Nebula"
        case .citrus:
            NSApp.appearance = NSAppearance(named: .aqua)
            themeMessage = "Citrus"
        case .twilight:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            themeMessage = "Twilight"
        case .ocean:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            themeMessage = "Ocean"
        case .sunset:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            themeMessage = "Sunset"
        case .forest:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            themeMessage = "Forest"
        case .cyber:
            NSApp.appearance = NSAppearance(named: .darkAqua)
            themeMessage = "Cyber"
        case .candy:
            NSApp.appearance = NSAppearance(named: .aqua)
            themeMessage = "Candy"
        case .liquidGlass:
            NSApp.appearance = nil
            themeMessage = "Liquid Glass"
        case .poorMansGlass:
            NSApp.appearance = nil
            themeMessage = "Liquid Glass (Legacy)"
        default:
            NSApp.appearance = nil
            themeMessage = nil
        }

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) {
                self.showThemeFlash = true
            }
        }

        themeMessageTimer?.invalidate()
        let newThemeTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.3)) {
                    self.showThemeFlash = false
                    self.themeMessage = nil
                }
            }
        }
        RunLoop.main.add(newThemeTimer, forMode: .common)
        themeMessageTimer = newThemeTimer
    }

    /// Cycles the accent color to the next option and displays a brief flash message with the color's label.
    ///
    /// This provides visual feedback to the user when changing accent colors.
    /// The flash message automatically disappears after 1.5 seconds.
    func cycleAccentColorAndShowMessage() {
        cycleAccentColor()
        let label = accentColorLabel(for: accentColor)
        colorMessage = "\(label) Accent"

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) {
                self.showColorFlash = true
            }
        }

        colorMessageTimer?.invalidate()
        let newColorTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.3)) {
                    self.showColorFlash = false
                    self.colorMessage = nil
                }
            }
        }
        RunLoop.main.add(newColorTimer, forMode: .common)
        colorMessageTimer = newColorTimer
    }

    // MARK: - Message Reset

    /// Immediately cancels any active theme message timer and clears the theme flash message.
    ///
    /// Use this to programmatically reset the theme message display state.
    func resetThemeMessage() {
        themeMessageTimer?.invalidate()
        themeMessage = nil
        showThemeFlash = false
    }

    /// Immediately cancels any active color message timer and clears the color flash message.
    ///
    /// Use this to programmatically reset the color message display state.
    func resetColorMessage() {
        colorMessageTimer?.invalidate()
        colorMessage = nil
        showColorFlash = false
    }

    /// Updates the main app window's transparency and background to match the current theme mode.
    func updateWindowForCurrentTheme() {
#if os(macOS)
        guard isEmbeddedInHost == false else { return }
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }
            let theme = self.currentThemeMode
            let glassThemes: [ThemeMode] = [
                .liquidGlass, .poorMansGlass, .midnight, .blue, .pink, .red, .orange,
                .yellow, .graphite, .rainbow, .nebula, .citrus, .twilight, .ocean,
                .sunset, .forest, .cyber, .candy
            ]
            if glassThemes.contains(theme) {
                window.isOpaque = false
                window.backgroundColor = .clear
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                if !window.styleMask.contains(.fullSizeContentView) {
                    window.styleMask.insert(.fullSizeContentView)
                }
            } else {
                window.isOpaque = true
                window.backgroundColor = NSColor.windowBackgroundColor
                window.titlebarAppearsTransparent = false
                window.titleVisibility = .visible
                window.styleMask.remove(.fullSizeContentView)
            }
        }
#endif
    }
}

// MARK: - Themed Green Color Utility

/// Returns a context-aware green color that adapts based on the given `ThemeMode`.
func meterGreenColor(for themeMode: ThemeMode) -> Color {
    switch themeMode {
    case .dark:
        return Color(red: 0.2, green: 0.2, blue: 1.0)
    case .light:
        return Color(red: 0.1, green: 0.8, blue: 0.2)
    case .thinMaterial:
        return Color.green.opacity(0.8)
    case .midnight, .blue, .ocean, .twilight:
        return Color(red: 0.2, green: 0.6, blue: 1.0)
    case .pink, .red, .sunset, .candy:
        return Color(red: 1.0, green: 0.2, blue: 0.4)
    case .orange, .yellow, .citrus:
        return Color(red: 1.0, green: 0.6, blue: 0.0)
    case .forest:
        return Color(red: 0.2, green: 0.8, blue: 0.3)
    case .cyber:
        return Color(red: 0.0, green: 1.0, blue: 0.8)
    case .graphite:
        return Color(white: 0.8)
    case .rainbow, .nebula:
        return Color.white
    case .liquidGlass, .poorMansGlass:
        return Color(red: 0.6, green: 0.32, blue: 0.6)
    case .purple:
        return Color.purple.opacity(0.8)
    case .mint:
        return Color(red: 0.62, green: 0.96, blue: 0.78).opacity(0.8)
    case .lavender:
        return Color(red: 0.75, green: 0.6, blue: 0.9)
    case .indigo:
        return Color(red: 0.29, green: 0.0, blue: 0.51).opacity(0.8)
    case .gray:
        return Color.gray.opacity(0.7)
    case .hollow:
        return Color.clear
    }
}

// MARK: - LiquidGlassBackground View

/// A SwiftUI View providing a high-fidelity glass backdrop for material themes.
public struct LiquidGlassBackground: View {
    public init() {}

    @Environment(\.colorScheme) private var colorScheme

    private var currentTheme: ThemeMode {
        ThemeManager.shared.currentThemeMode
    }

    public var body: some View {
        Group {
            let glassThemes: [ThemeMode] = [
                .midnight, .blue, .pink, .red, .orange, .yellow, .graphite,
                .rainbow, .nebula, .citrus, .twilight, .ocean, .sunset,
                .forest, .cyber, .candy
            ]

            if glassThemes.contains(currentTheme) {
                 ZStack {
                    if currentTheme == .citrus || currentTheme == .candy {
                        Color.white.opacity(0.85)
                    } else {
                        Color.black.opacity(0.55)
                    }

                    backgroundGradient
                        .opacity(currentTheme == .citrus || currentTheme == .candy ? 0.3 : 0.45)

                    accentGlow
                        .blendMode(.screen)

                    overlayGradient
                        .blendMode(.overlay)
                }
                .ignoresSafeArea()
            } else if #available(macOS 26.0, *) {
                GlassEffectContainer {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(.rect)
                        .glassEffect(in: .rect(cornerRadius: 20))
                }
                .allowsHitTesting(false)
            } else if #available(macOS 14.0, *) {
                ZStack {
                    VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.004))

                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.white.opacity(0.08), Color.clear]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.0
                        )
                }
                .ignoresSafeArea()
            } else {
                ZStack {
                    VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.004))

                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.white.opacity(0.08), Color.clear]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.0
                        )
                }
                .ignoresSafeArea()
            }
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            gradient: Gradient(colors: {
                switch currentTheme {
                case .midnight:
                    return [Color.black.opacity(0.40), Color(red: 2/255, green: 3/255, blue: 8/255).opacity(0.45), Color(red: 5/255, green: 8/255, blue: 18/255).opacity(0.50), Color(red: 1/255, green: 1/255, blue: 3/255).opacity(0.30)]
                case .blue:
                    return [Color.blue.opacity(0.3), Color.black.opacity(0.4)]
                case .pink:
                    return [Color.pink.opacity(0.3), Color.black.opacity(0.4)]
                case .red:
                    return [Color.red.opacity(0.3), Color.black.opacity(0.4)]
                case .orange:
                    return [Color.orange.opacity(0.3), Color.black.opacity(0.4)]
                case .yellow:
                    return [Color.yellow.opacity(0.3), Color.black.opacity(0.4)]
                case .graphite:
                    return [Color.gray.opacity(0.3), Color.black.opacity(0.4)]
                case .rainbow:
                    return [Color.black.opacity(0.5)]
                case .nebula:
                    return [Color(red: 0.1, green: 0.0, blue: 0.2).opacity(0.6), Color.black.opacity(0.4)]
                case .citrus:
                    return [Color.yellow.opacity(0.4), Color.green.opacity(0.2)]
                case .twilight:
                    return [Color(red: 0.1, green: 0.05, blue: 0.25).opacity(0.6), Color.black.opacity(0.4)]
                case .ocean:
                    return [Color(red: 0.0, green: 0.2, blue: 0.4).opacity(0.6), Color.black.opacity(0.4)]
                case .sunset:
                    return [Color(red: 0.4, green: 0.1, blue: 0.2).opacity(0.6), Color.black.opacity(0.4)]
                case .forest:
                    return [Color(red: 0.05, green: 0.2, blue: 0.1).opacity(0.6), Color.black.opacity(0.4)]
                case .cyber:
                    return [Color(red: 0.1, green: 0.1, blue: 0.15).opacity(0.6), Color.black.opacity(0.4)]
                case .candy:
                    return [Color(red: 0.5, green: 0.2, blue: 0.4).opacity(0.6), Color.black.opacity(0.4)]
                default:
                    return [Color.black.opacity(0.4)]
                }
            }()),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var accentGlow: some View {
        RadialGradient(
            gradient: Gradient(colors: {
                switch currentTheme {
                case .midnight:
                    return [Color(red: 26/255, green: 68/255, blue: 170/255).opacity(0.15), Color.clear]
                case .blue:
                    return [Color.blue.opacity(0.2), Color.clear]
                case .pink:
                    return [Color.pink.opacity(0.2), Color.clear]
                case .red:
                    return [Color.red.opacity(0.2), Color.clear]
                case .orange:
                    return [Color.orange.opacity(0.2), Color.clear]
                case .yellow:
                    return [Color.yellow.opacity(0.2), Color.clear]
                case .graphite:
                    return [Color.white.opacity(0.1), Color.clear]
                case .rainbow:
                    return [Color.blue.opacity(0.3), Color.clear]
                case .nebula:
                    return [Color.purple.opacity(0.3), Color.clear]
                case .citrus:
                    return [Color.orange.opacity(0.2), Color.clear]
                case .twilight:
                    return [Color.indigoCompat.opacity(0.2), Color.clear]
                case .ocean:
                    return [Color.blue.opacity(0.2), Color.clear]
                case .sunset:
                    return [Color.orange.opacity(0.2), Color.clear]
                case .forest:
                    return [Color.green.opacity(0.2), Color.clear]
                case .cyber:
                    return [Color.cyanCompat.opacity(0.2), Color.clear]
                case .candy:
                    return [Color.pink.opacity(0.2), Color.clear]
                default:
                    return [Color.white.opacity(0.1), Color.clear]
                }
            }()),
            center: .topTrailing,
            startRadius: 10,
            endRadius: 400
        )
    }

    private var overlayGradient: some View {
        LinearGradient(
            gradient: Gradient(colors: [
                Color.white.opacity(currentTheme == .citrus || currentTheme == .candy ? 0.4 : 0.02),
                Color.clear,
                Color.black.opacity(currentTheme == .citrus || currentTheme == .candy ? 0.05 : 0.25)
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: NS View for thinMaterial
/// SwiftUI wrapper for macOS `NSVisualEffectView`.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Theme Corner Style Shape

/// A custom shape that switches between rounded and hard corners based on the theme corner style.
public struct ThemeRoundedRectangle: Shape, InsettableShape {
    public var cornerRadius: CGFloat
    public var style: RoundedCornerStyle
    public var insetAmount: CGFloat = 0

    @AppStorage("theme.cornerStyle") private var storedCornerStyle = ThemeCornerStyle.rounded.rawValue

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
