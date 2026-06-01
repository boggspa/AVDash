import SwiftUI

/// CPU-based output-channel capsule meter.
///
/// Drop-in visual replacement for `MetalOutputView` in compatibility mode.
/// Uses the same gradient stops as CPUCapsuleBarView for visual consistency.
struct CPUOutputCapsuleView: View {
    var channelIndex: Int
    var themeMode:    ThemeMode
    var handler:      OutputLevelHandler?

    @State private var fillLevel:  Float = 0.0
    @State private var lastUpdate: Date  = .distantPast

    // Tuning constants for bar height/shape — adjust these to match Metal output meter appearance
    // Increase topInset to make bars shorter; decrease to make them taller.
    private let cornerRadius: CGFloat = 4.0
    private let horizontalInset: CGFloat = 1.4
    private let topInset: CGFloat = 25.0
    private let bottomInset: CGFloat = -5.0

    var body: some View {
        GeometryReader { geo in
            let trackHeight = max(0, geo.size.height - topInset - bottomInset)
            let barH = trackHeight * CGFloat(min(max(fillLevel, 0.0), 0.9))

            ZStack(alignment: .bottom) {
                Color.black.opacity(CPUMeterVisualTuning.trackBackgroundOpacity)

                LinearGradient(
                    gradient: meterGradient(),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .mask(
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle()
                            .frame(height: max(0, barH))
                    }
                )
            }
            .frame(height: trackHeight)
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
            .padding(.horizontal, horizontalInset)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .onAppear {
            MeterUpdateCoordinator.shared.start()
            tick()
        }
        .onReceive(MeterUpdateCoordinator.shared.publisher) { _ in
            tick()
        }
    }

    // MARK: - Level update (mirrors MetalOutputView.draw)

    private func tick() {
        let rawPeak = handler?(channelIndex) ?? 0.0
        let safe    = max(0.000_001, rawPeak)
        let db      = 20.0 * log10(safe) + 4.5
        let clamped = max(-100.0, min(0.0, db.isFinite ? db : -100.0))
        let norm    = max(0.0, (clamped + 80.0) / 80.0)
        let target  = pow(norm, 1.5)

        let now = Date()
        let dt  = Float(now.timeIntervalSince(lastUpdate))
        lastUpdate = now
        if fillLevel.isNaN {
            fillLevel = target
        } else {
            let decayTime: Float = 0.1
            let smoothingFactor = 1.0 - exp(-dt / decayTime)
            fillLevel += (target - fillLevel) * smoothingFactor
        }
    }

    private func meterGradient() -> Gradient {
        let red = Color(red: 0.85, green: 0.0, blue: 0.0)
        let orange = Color(red: 1.0, green: 0.5, blue: 0.0)
        let yellow = Color(red: 1.0, green: 1.0, blue: 0.0)
        let (green, darkGreen) = themeGreens()

        // Matches CPUCapsuleBarView gradient stops:
        // red at 0.0, orange at 0.1, yellow at 0.375, green at 0.525, darkGreen at 1.0
        return Gradient(stops: [
            .init(color: red, location: 0.0),
            .init(color: orange, location: 0.1),
            .init(color: yellow, location: 0.375),
            .init(color: green, location: 0.525),
            .init(color: darkGreen, location: 1.0)
        ])
    }

    private func themeGreens() -> (Color, Color) {
        // Values mirror CPUCapsuleBarView themeGreens() exactly.
        switch themeMode {
        case .light:
            return (Color(red: 0.2, green: 1.0, blue: 0.2), Color(red: 0.1, green: 0.4, blue: 0.1))
        case .dark, .midnight:
            return (Color(red: 0.24, green: 0.95, blue: 0.30), Color(red: 0.08, green: 0.35, blue: 0.09))
        case .thinMaterial:
            return (Color(red: 0.22, green: 0.92, blue: 0.30), Color(red: 0.08, green: 0.34, blue: 0.09))
        case .liquidGlass, .poorMansGlass:
            return (Color(red: 0.22, green: 0.92, blue: 0.30), Color(red: 0.08, green: 0.34, blue: 0.09))
        case .purple:
            return (Color(red: 0.6, green: 1.0, blue: 0.6), Color(red: 0.3, green: 0.0, blue: 0.4))
        case .mint:
            return (Color(red: 0.9, green: 0.6, blue: 1.0), Color(red: 0.3, green: 0.6, blue: 0.3))
        case .lavender:
            return (Color(red: 0.5, green: 0.5, blue: 1.0), Color(red: 0.5, green: 0.3, blue: 0.6))
        case .indigo:
            return (Color(red: 0.6, green: 0.6, blue: 0.6), Color(red: 0.2, green: 0.2, blue: 0.5))
        case .gray:
            return (Color(red: 1.0, green: 1.0, blue: 1.0), Color(red: 0.2, green: 0.2, blue: 0.2))
        case .hollow:
            return (Color(red: 0.2, green: 1.0, blue: 0.2), Color.clear)
        @unknown default:
            return (Color(red: 0.2, green: 0.9, blue: 0.2), Color(red: 0.1, green: 0.4, blue: 0.1))
        }
    }
}
