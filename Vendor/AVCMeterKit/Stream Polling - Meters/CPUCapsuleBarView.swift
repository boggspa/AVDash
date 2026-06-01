import SwiftUI

/// CPU-based input-channel capsule meter.
///
/// Drop-in visual replacement for the Metal capsule in compatibility mode.
/// Replicates the fill-level computation and colour logic from
/// `MetalCapsuleView.updateLevels()` exactly so the meters look identical.
///
/// Rendering: a `LinearGradient` rectangle growing from the bottom, clipped to a
/// rounded rectangle to visually match the Metal-drawn meter column.
struct CPUCapsuleBarView: View {
    var context:      DeviceMeteringContext
    var channelIndex: Int
    var themeMode:    ThemeMode

    @State private var fillLevel:   Float = 0.0
    @State private var lastUpdate:  Date  = .distantPast

    // Manual visual tuning knobs for CPU fallback parity.
    // Increase topInset to make bars shorter; decrease to make them taller.
    private let cornerRadius: CGFloat = 4.0
    private let horizontalInset: CGFloat = 1.4
    private let topInset: CGFloat = 25.0
    private let bottomInset: CGFloat = -5.0

    // 30 fps — matches MetalCapsuleView.preferredFramesPerSecond
    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let trackHeight = max(0, geo.size.height - topInset - bottomInset)
            let barH = trackHeight * CGFloat(min(max(fillLevel, 0.0), 0.9))

            ZStack(alignment: .bottom) {
                // Background track opacity shared across CPU input/output meters.
                Color.black.opacity(CPUMeterVisualTuning.trackBackgroundOpacity)

                // Fill bar — grows upward from bottom with Metal-style threshold gradient
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
        .onReceive(timer) { _ in
            tick()
        }
    }

    // MARK: - Level update (mirrors MetalCapsuleView.updateLevels)

    private func tick() {
        let allPeaks = context.peakBuffer.allMostRecent()
        guard channelIndex < allPeaks.count else {
            fillLevel = 0
            return
        }

        let rawPeak  = allPeaks[channelIndex]
        let safe     = (rawPeak.isFinite && rawPeak > 0) ? rawPeak : Float(0.000_001)
        let db       = 20.0 * log10(safe) + 0   // +6 dB offset matches Metal path
        let clamped  = max(-100.0, min(0.0, db.isFinite ? db : -100.0))
        let norm     = max(0.0, (clamped + 80.0) / 80.0)
        let target   = pow(norm, 1.5)

        // Exponential smoothing (matches Metal's alpha calculation)
        let now  = Date()
        let dt   = Float(now.timeIntervalSince(lastUpdate))
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

        // Matches MetalCapsuleShader.metal stops:
        // red at 0.0, orange at 0.1, yellow at 0.125, green at 0.425, darkGreen at 1.0
        return Gradient(stops: [
            .init(color: red, location: 0.0),
            .init(color: orange, location: 0.1),
            .init(color: yellow, location: 0.375),
            .init(color: green, location: 0.525),
            .init(color: darkGreen, location: 1.0)
        ])
    }

    private func themeGreens() -> (Color, Color) {
        // Values mirror MetalCapsuleShader.metal mapping exactly.
        // Note: these are keyed to the legacy theme integer mapping used by MetalCapsuleView.
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
