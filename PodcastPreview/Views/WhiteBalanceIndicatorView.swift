//
//  WhiteBalanceIndicatorView.swift
//  PodcastPreview
//
//  User-friendly white balance feedback UI
//

import SwiftUI
import PodcastPreviewShared

/// Educational white balance indicator for non-technical users
struct WhiteBalanceIndicatorView: View {
    let result: WhiteBalanceAnalyzer.WhiteBalanceResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "thermometer.medium")
                    .foregroundColor(temperatureColor)

                Text("Scene Lighting")
                    .font(.system(size: 12, weight: .semibold))

                Spacer()

                if let result = result, result.confidence > 0.3 {
                    Text(temperatureLabel)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            if let result = result, result.confidence > 0.3 {
                // Visual temperature indicator
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        // Cool to Warm gradient bar
                        ZStack(alignment: .leading) {
                            // Background gradient (2000K warm/orange -> 10000K cool/blue)
                            LinearGradient(
                                colors: [
                                    Color.orange.opacity(0.3),  // Warm (low K)
                                    Color.white.opacity(0.3),   // Neutral (~5500K)
                                    Color.blue.opacity(0.3)     // Cool (high K)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(height: 24)
                            .cornerRadius(16)

                            // Temperature marker
                            Circle()
                                .fill(temperatureColor)
                                .frame(width: 12, height: 12)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: 2)
                                )
                                .offset(x: temperaturePosition(width: geometry.size.width))
                        }
                        .frame(height: 24)
                    }
                }
                .frame(height: 24)

                // Explanation text
                Text(explanationText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Actionable tip
                if shouldShowTip {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.yellow)
                            .frame(width: 12, height: 12)

                        Text(tipText)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                    .background(
                        ThemeRoundedRectangle(cornerRadius: 6)
                            .fill(Color.yellow.opacity(0.1))
                    )
                }
            } else {
                // Low confidence or no result
                Text("Analyzing scene...")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            ThemeRoundedRectangle(cornerRadius: 16).themed(fill: Color.black.opacity(0.05), stroke: Color.white.opacity(0.1))
        )
    }

    // MARK: - Computed Properties

    private var temperatureColor: Color {
        guard let temp = result?.temperature else { return .white }

        switch temp {
        case ..<3000:
            return .orange
        case 3000..<5000:
            return .yellow
        case 5000..<6000:
            return .white
        case 6000..<8000:
            return Color(red: 0.7, green: 0.85, blue: 1.0) // Light blue
        default:
            return .blue
        }
    }

    private var temperatureLabel: String {
        guard let temp = result?.temperature else { return "" }
        return "\(Int(temp))K"
    }

    private func temperaturePosition(width: CGFloat) -> CGFloat {
        guard let temp = result?.temperature else { return 0 }

        // Map 2000K-10000K to 0-1
        let normalized = (temp - 2000) / 8000
        let clamped = max(0, min(1, normalized))

        // Convert to position (account for circle width so it doesn't overflow)
        let circleWidth: CGFloat = 12
        let availableWidth = width - circleWidth

        return CGFloat(clamped) * availableWidth
    }

    private var explanationText: String {
        guard let temp = result?.temperature else { return "" }

        switch temp {
        case ..<2500:
            return "Very warm lighting (like candlelight). Scene appears orange/red."
        case 2500..<3500:
            return "Warm lighting (like traditional light bulbs). Scene appears orange."
        case 3500..<5000:
            return "Neutral-warm lighting (like LED bulbs). Slight orange tint."
        case 5000..<6000:
            return "Daylight balanced. Colors appear natural."
        case 6000..<7000:
            return "Cool lighting (like cloudy daylight). Slight blue tint."
        case 7000..<9000:
            return "Cool lighting (like open shade). Scene appears blue."
        default:
            return "Very cool lighting (like deep shade). Scene appears very blue."
        }
    }

    private var shouldShowTip: Bool {
        guard let temp = result?.temperature else { return false }
        // Show tip if significantly off from neutral (5500K)
        return abs(temp - 5500) > 1000
    }

    private var tipText: String {
        guard let temp = result?.temperature else { return "" }

        if temp < 4500 {
            return "Add cooler (bluer) lighting or adjust camera white balance to 'Tungsten' preset"
        } else if temp > 7000 {
            return "Add warmer (yellower) lighting or adjust camera white balance to 'Shade' preset"
        } else {
            return "Lighting is close to neutral. No adjustment needed."
        }
    }
}

// MARK: - Integration Example

struct WhiteBalanceButtonView: View {
    @Binding var whiteBalanceResult: WhiteBalanceAnalyzer.WhiteBalanceResult?
    let onAnalyze: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onAnalyze) {
                HStack {
                    Image(systemName: "camera.metering.center.weighted")
                    Text("Check Scene Lighting")
                }
            }
            .buttonStyle(.bordered)
            .help("Analyze current frame to detect color temperature")

            if let result = whiteBalanceResult {
                WhiteBalanceIndicatorView(result: result)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 14.0, *)
#Preview("Warm Scene") {
    WhiteBalanceIndicatorView(
        result: WhiteBalanceAnalyzer.WhiteBalanceResult(
            temperature: 2800,
            tint: 0,
            redGain: 0.7,
            greenGain: 0.85,
            blueGain: 1.0,
            confidence: 0.8
        )
    )
    .frame(width: 400)
    .padding()
}

@available(macOS 14.0, *)
#Preview("Cool Scene") {
    WhiteBalanceIndicatorView(
        result: WhiteBalanceAnalyzer.WhiteBalanceResult(
            temperature: 7500,
            tint: 0,
            redGain: 1.0,
            greenGain: 0.9,
            blueGain: 0.75,
            confidence: 0.7
        )
    )
    .frame(width: 400)
    .padding()
}

@available(macOS 14.0, *)
#Preview("Neutral Scene") {
    WhiteBalanceIndicatorView(
        result: WhiteBalanceAnalyzer.WhiteBalanceResult(
            temperature: 5500,
            tint: 0,
            redGain: 1.0,
            greenGain: 1.0,
            blueGain: 1.0,
            confidence: 0.6
        )
    )
    .frame(width: 400)
    .padding()
}
#endif
