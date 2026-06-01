// CapsuleMeterView.swift
//
// This SwiftUI view renders a single vertical capsule meter for audio input level visualization.
// It displays real-time RMS and peak dB levels using a vertical gradient fill, updating every 0.2 seconds.
// Used in AVCMeter to represent per-channel audio activity, with support for theme-aware styling and peak hold behavior.
import AVFoundation
import Foundation
import SwiftUI

struct CapsuleMeterView: View {
    @EnvironmentObject var themeManager: ThemeManager
    var context: DeviceMeteringContext
    var channelIndex: Int
    var channelMask: [Bool] = []
    // MARK: - State Variables
    // These hold the current and smoothed RMS and Peak values for rendering the capsule.
    @State private var currentRMS: Float = -100.0
    @State private var currentPeak: Float = -100.0
    @State private var heldPeakValue: Float = -100.0
    @State private var heldPeakColor: Color = .secondary
    @State private var instantPeak: Float = -100.0
    @State private var formattedRMSDbText: String = "-100.0"
    @State private var formattedPeakDbText: String = "-100.0"
    // Note: context.heldPeakDb is shadowed, so mutation won't persist unless handled upstream.

    @State private var timer = Timer.publish(every: 0.05, on: .current, in: .common).autoconnect()

    // MARK: - Derived Properties
    // Computed properties used to simplify rendering logic.
    var rmsValue: Float {
        currentRMS
    }

    var heldPeakDb: Float {
        currentPeak
    }

    var level: Float {
        let rawPeak = context.peakBuffer.max(for: channelIndex)
        return max(0.0, min(rawPeak, 1.0))
    }

    // MARK: - Helpers
    // Utility function for converting linear values to decibels.
    func linearToDb(_ linear: Float) -> Float {
        if linear <= 0 {
            return -100.0
        } else {
            return 20.0 * log10(linear)
        }
    }

    // MARK: - Visual Styling Logic
    // These functions and computed vars help colorize the capsule based on thresholds.
    var shouldLogRMS: Bool {
        let dbRMS = rmsValue
        let clampedDb = max(-100.0, min(0.0, dbRMS))
        let lastLogged = UserDefaults.standard.float(forKey: "lastLoggedRMS")
        return abs(clampedDb - lastLogged) > 0.5
    }

    var rmsColor: Color {
        let dbRMS = rmsValue
        if dbRMS >= -6.0 {
            return .red
        } else if dbRMS >= -18.0 {
            return .orange
        } else if dbRMS >= -24.0 {
            return Color(red: 0.4, green: 1.0, blue: 0.4)
        } else if dbRMS >= -40.0 {
            return .green
        } else if dbRMS >= -64.0 {
            return Color(red: 0.1, green: 0.6, blue: 0.1)
        } else {
            return .secondary
        }
    }

    // Accepts clampedPeakDb as parameter for correct color logic
    func peakColor(for clampedPeakDb: Float) -> Color {
        if clampedPeakDb >= -6.0 {
            return .red
        } else if clampedPeakDb >= -18.0 {
            return .orange
        } else if clampedPeakDb >= -24.0 {
            return Color(red: 0.4, green: 1.0, blue: 0.4)
        } else if clampedPeakDb >= -40.0 {
            return .green
        } else if clampedPeakDb >= -64.0 {
            return Color(red: 0.1, green: 0.6, blue: 0.1)
        } else {
            return .secondary
        }
    }

    // MARK: - View Body
    // Builds the capsule layout with color overlays, dB tick labels, and live values.
    var body: some View {
        // Renders capsule meter using layout-relative dimensions.
        GeometryReader { geometry in
            let clampedLevel = max(0.0, min(1.0, level.isFinite ? level : 0.0))
            let capsuleWidth: CGFloat = 9
            let capsuleHeight: CGFloat = geometry.size.height * 1.8
            let fillHeight = capsuleHeight * CGFloat(clampedLevel)
            let dbRMS = rmsValue

            HStack(alignment: .bottom, spacing: 4) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach([0, -3, -6, -9, -12, -15, -18, -21, -24, -30, -35, -40, -45, -50, -60, -70, -80, -100], id: \.self) { db in
                        Text(db == -100 ? "-∞" : "\(db)")
                            .font(.system(size: 7, weight: .regular, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer(minLength: 3.6)
                    }
                }
                .frame(width: 20, alignment: .trailing)
                .offset(y: -18)

                    VStack(alignment: .center, spacing: 4) {

                        ZStack(alignment: .bottom) {
                            Capsule()
                                .fill(Color.black.opacity(0.85))
                                .frame(width: capsuleWidth, height: capsuleHeight)
                                .overlay(
                                    Capsule().stroke(
                                        themeManager.currentThemeMode == .thinMaterial
                                        ? Color(NSColor.windowBackgroundColor)
                                        : Color.clear,
                                        lineWidth: 1
                                    )
                                )

                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: meterGreenColor(for: themeManager.currentThemeMode), location: 0.0),
                                    .init(color: meterGreenColor(for: themeManager.currentThemeMode), location: 0.225),
                                    .init(color: themeManager.currentThemeMode == .light ? Color(red: 0.2, green: 0.2, blue: 1.0) : Color(red: 0.2, green: 1.0, blue: 0.2), location: 0.555),
                                    .init(color: Color.orange, location: 0.775),
                                    .init(color: Color(red: 0.85, green: 0.0, blue: 0.0), location: 0.95)
                                ]),
                                startPoint: .bottom,
                                endPoint: .top
                            )
                            .frame(width: capsuleWidth, height: capsuleHeight)
                            .mask(
                                VStack {
                                    Spacer(minLength: 0)
                                    Rectangle().frame(height: fillHeight)
                                }
                            )
                            .clipShape(Capsule())

                            Capsule()
                                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                                .frame(width: capsuleWidth, height: fillHeight)
                        }

                        Text(formattedRMSDbText)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(rmsColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: true, vertical: false)
                            .onChange(of: formattedRMSDbText) { newValue in
                                if shouldLogRMS {
                                    UserDefaults.standard.set(Float(newValue) ?? -100.0, forKey: "lastLoggedRMS")
                                }
                            }

                        Text(formattedPeakDbText)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(peakColor(for: max(-100.0, min(0.0, heldPeakValue + 3))))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .fixedSize(horizontal: true, vertical: false)
                            // Resets the held peak value to current peak when tapped.
                            .onTapGesture {
                                let rawPeak = context.peakBuffer.max(for: channelIndex)
                                heldPeakValue = linearToDb(rawPeak)
                                // Update color after adjustment and clamping
                                let newAdjustedPeakDb = heldPeakValue + 3
                                let newClampedPeakDb = max(-120.0, min(0.0, newAdjustedPeakDb))
                                heldPeakColor = peakColor(for: newClampedPeakDb)
                                formattedPeakDbText = String(format: "%.1f", newClampedPeakDb)
                            }
                            .onChange(of: formattedPeakDbText) { newValue in
                                if let newFloat = Float(newValue), newFloat > heldPeakDb {
                                    // Update logic to trigger external mutation if needed
                                }
                            }
                    }
                    .frame(width: capsuleWidth)
                }
            }

        .frame(height: 120)
        .onReceive(timer) { _ in
            guard channelIndex < context.rmsBuffer.count else {
                currentRMS = -100.0
                currentPeak = -100.0
                instantPeak = -100.0
                formattedRMSDbText = "-100.0"
                formattedPeakDbText = "-100.0"
                return
            }
            // Update capsule metering with fresh RMS and Peak values every 0.2s
            let newRMS = linearToDb(context.rmsBuffer.mostRecent(for: channelIndex))
            let rawPeak = context.peakBuffer.max(for: channelIndex)
            instantPeak = linearToDb(rawPeak)
            let newPeak = linearToDb(rawPeak)

            currentRMS = newRMS
            currentPeak = newPeak

            if currentPeak > heldPeakValue {
                heldPeakValue = currentPeak
                // Update color after adjustment and clamping
                let newAdjustedPeakDb = heldPeakValue + 3
                let newClampedPeakDb = max(-100.0, min(0.0, newAdjustedPeakDb))
                heldPeakColor = peakColor(for: newClampedPeakDb)
                formattedPeakDbText = String(format: "%.1f", newClampedPeakDb)
            } else {
                let adjustedPeakDb = heldPeakValue + 3
                let clampedPeakDb = max(-100.0, min(0.0, adjustedPeakDb))
                formattedPeakDbText = String(format: "%.1f", clampedPeakDb)
            }

            let clampedDb = max(-100.0, min(0.0, rmsValue))
            formattedRMSDbText = String(format: "%.1f", clampedDb)

            let now = Date().timeIntervalSince1970
            let lastLog = UserDefaults.standard.double(forKey: "lastCapsuleLog")
            if now - lastLog > 3.0 {
                let formattedRMS = String(format: "%.1f", currentRMS)
                let formattedPeak = String(format: "%.1f", currentPeak)
                UserDefaults.standard.set(now, forKey: "lastCapsuleLog")
            }
        }
    }
}
// End of CapsuleMeterView
