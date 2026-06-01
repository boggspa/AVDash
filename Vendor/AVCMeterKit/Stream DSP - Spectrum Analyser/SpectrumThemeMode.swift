//  SpectrumThemeMode.swift
//  AVCMeter
//
//  Shared enum and helpers for spectrum theming.

import SwiftUI

/// Enum describing the available spectrum theme modes
public enum SpectrumThemeMode {
    case dark, light, thinMaterial, liquidGlass, midnight, purple, mint, lavender, indigo, gray, hollow
}

// Helper to convert from ThemeMode to SpectrumThemeMode
extension SpectrumThemeMode {
    init(from themeMode: ThemeMode) {
        switch themeMode {
        case .light: self = .light
        case .dark: self = .dark
        case .thinMaterial: self = .thinMaterial
        case .liquidGlass: self = .liquidGlass
        case .midnight: self = .midnight
        case .purple: self = .purple
        case .mint: self = .mint
        case .lavender: self = .lavender
        case .indigo: self = .indigo
        case .gray: self = .gray
        case .hollow: self = .hollow
        case .poorMansGlass: self = .liquidGlass
        @unknown default: self = .dark
        }
    }
}

public func spectrumLineColor(for themeMode: SpectrumThemeMode) -> Color {
    switch themeMode {
    case .dark:
        return Color(red: 0.1, green: 0.6, blue: 0.1)
    case .midnight:
        return Color(red: 0.2, green: 0.8, blue: 1.0)
    case .light:
        return Color(red: 0.1, green: 0.2, blue: 0.6)
    case .thinMaterial:
        return Color.green.opacity(0.8)
    case .liquidGlass:
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
