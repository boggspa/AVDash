import CoreAudio

// MARK: - FaderCapStyle Enum
enum FaderCapStyle {
    // Standard fader cap: default neutral gray for typical channel strips
    case standard

    // FX Return: pink-red blend for return FX channels (reverb, delay, etc.)
    case fxReturn

    // Aux Return: cool blue gradient for auxiliary return signals
    case auxReturn

    // Virtual Instrument: synth/MIDI channel shading
    case virtualInstrument

    // Output: red-to-black gradient for final mix output
    case output

    // FX Send: vibrant pink-purple send channel styling for auxiliary effects sends
    case fxSend

    // Aux Send: rich blue-indigo send style for monitor/control sends
    case auxSend

    // DCA Group: bold yellow-orange styling for grouped channel control
    case dca

    var gradient: LinearGradient {
        switch self {
        case .standard:
            return LinearGradient(
                gradient: Gradient(colors: [
                    Color(.sRGB, red: 0.7, green: 0.7, blue: 0.7),
                    Color(.sRGB, red: 0.9, green: 0.9, blue: 0.9),
                    Color(.sRGB, red: 0.7, green: 0.7, blue: 0.7)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        case .fxReturn:
            return LinearGradient(gradient: Gradient(colors: [.pink.opacity(0.4), .red.opacity(0.4)]), startPoint: .top, endPoint: .bottom)
        case .auxReturn:
            return LinearGradient(gradient: Gradient(colors: [.blue.opacity(0.3), Color(red: 0.0, green: 0.75, blue: 0.8).opacity(0.4)]), startPoint: .top, endPoint: .bottom)
        case .virtualInstrument:
            return LinearGradient(gradient: Gradient(colors: [.green.opacity(0.3), Color(red: 0.62, green: 0.96, blue: 0.78).opacity(0.4)]), startPoint: .top, endPoint: .bottom)
        case .output:
            return LinearGradient(gradient: Gradient(colors: [.red.opacity(0.8), .black]), startPoint: .top, endPoint: .bottom)
        case .fxSend:
            return LinearGradient(gradient: Gradient(colors: [.pink.opacity(0.8), .purple.opacity(0.6)]), startPoint: .top, endPoint: .bottom)
        case .auxSend:
            return LinearGradient(gradient: Gradient(colors: [.blue.opacity(0.9), Color(red: 0.29, green: 0.0, blue: 0.51).opacity(0.8)]), startPoint: .top, endPoint: .bottom)
        case .dca:
            return LinearGradient(gradient: Gradient(colors: [.yellow.opacity(0.9), .orange.opacity(0.8)]), startPoint: .top, endPoint: .bottom)
        }
    }
}

// MARK: - ChannelRole Enum
enum ChannelRole {
    case input
    case output
}
// When creating FaderView, pass role: .output for output strips and role: .input for input strips.

//
//  FaderView.swift
//  AVCMeter
//
//  Created by Chris Izatt on 06/07/2025.
//

import Foundation
import MetalKit
import SwiftUI

// MARK: - HourglassShape for Fader Thumb
private struct HourglassShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let insetX = rect.width * 0.22
        let topY = rect.minY
        let bottomY = rect.maxY
        let midY = rect.midY

        path.move(to: CGPoint(x: rect.minX + insetX, y: topY))
        path.addLine(to: CGPoint(x: rect.maxX - insetX, y: topY))
        path.addLine(to: CGPoint(x: rect.midX + insetX, y: midY))
        path.addLine(to: CGPoint(x: rect.maxX - insetX, y: bottomY))
        path.addLine(to: CGPoint(x: rect.minX + insetX, y: bottomY))
        path.addLine(to: CGPoint(x: rect.midX - insetX, y: midY))
        path.closeSubpath()

        return path
    }
}


// MARK: - Custom FaderView (macOS only)
#if os(macOS)
import AppKit

/// A vertical fader UI styled as a capsule with a draggable thumb.
struct FaderView: View {
    @Binding var value: Double // 0.0 ... 1.0
    let minValue: Double
    let maxValue: Double
    let trackHeight: CGFloat
    let trackWidth: CGFloat
    let thumbHeight: CGFloat
    let thumbWidth: CGFloat
    let capStyle: FaderCapStyle
    // Add device ID for linking context
    var deviceID: AudioDeviceID? = nil
    var channelIndex: Int? = nil
    let role: ChannelRole
    var inputChannel: Int? = nil
    var outputChannel: Int? = nil
    private let defaultValue: Double = 1.0


    // Removed local bubble @State and timers to sync via ChannelStateManager
    // Bubble overlays are now synced via ChannelStateManager.bubbleStates, supporting linked channels

    @ObservedObject private var bubbleStore = ChannelBubbleStore.shared

    /// dbBubble overlay references ChannelStateManager.shared.bubbleStates for linked channel bubbles
    private var dbBubble: some View {
        Group {
            if let deviceID = deviceID, let channelIndex = channelIndex {
                let bubbleState = bubbleStore.states["\(deviceID)-\(channelIndex)"] ?? ChannelBubbleState()
                if bubbleState.showDB {
                    Text(String(format: "%+7.1f dB", bubbleState.dbValue))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 90, height: 30)
                        .offset(x: -8)
                        .background(
                            Capsule()
                                .fill(.clear)
                                .background(LiquidGlassBackground())
                                .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 1)
                        )
                        .offset(x: -20, y: (-thumbHeight * 1.5) + 180)
                        .zIndex(1000)
                }
            }
        }
    }

    /// Persistent global channel index bubble overlay
    private var globalChannelIndexBubble: some View {
        Group {
            if let deviceID = deviceID, let channelIndex = channelIndex {
                switch role {
                case .output:
                    let globalIndex = ChannelStateManager.shared.globalOutputIndex(for: deviceID, channel: channelIndex)
                    if let idx = globalIndex {
                        Text("Out #\(idx + 1)")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 80, height: 28)
                            .background(
                                Capsule()
                                    .fill(.clear)
                                    .background(LiquidGlassBackground())
                                    .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 1)
                            )
                            .offset(x: -20, y: 205)
                            .zIndex(1001)
                    } else {
                        Text("Out --")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 80, height: 28)
                            .background(
                                Capsule()
                                    .fill(.clear)
                                    .background(LiquidGlassBackground())
                                    .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 1)
                            )
                            .offset(x: -20, y: 205)
                            .zIndex(1001)
                    }
                case .input:
                    let globalIndex = ChannelStateManager.shared.globalInputIndex(for: deviceID, channel: channelIndex)
                    if let idx = globalIndex {
                        Text("In #\(idx + 1)")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 80, height: 28)
                            .background(
                                Capsule()
                                    .fill(.clear)
                                    .background(LiquidGlassBackground())
                                    .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 1)
                            )
                            .offset(x: -20, y: 205)
                            .zIndex(1001)
                    } else {
                        Text("In --")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 80, height: 28)
                            .background(
                                Capsule()
                                    .fill(.clear)
                                    .background(LiquidGlassBackground())
                                    .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 1)
                            )
                            .offset(x: -20, y: 205)
                            .zIndex(1001)
                    }
                }
            } else {
                EmptyView()
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let totalHeight = trackHeight-28
            let availableHeight = totalHeight - thumbHeight
            let clampedValue = min(max(value, minValue), maxValue)
            let progress = CGFloat(clampedValue)
            let y = ((1.2 - progress) * availableHeight) + (thumbHeight / 2)

            ZStack {
                // Custom dB tick marks using explicit mapping
                ZStack {
                    ForEach([6, 0, -6, -15, -100], id: \.self) { db in
                        let positionRatio: CGFloat = {
                            switch db {
                            case 6: return 1.0
                            case 0: return 0.75
                            case -6: return 0.5
                            case -15: return 0.25
                            case -100: return 0.0
                            default: return 0.0
                            }
                        }()
                        Rectangle()
                            .fill(db == 0 ? Color.white : Color.gray.opacity(0.5))
                            .frame(width: db == 0 ? 18 : (db % 12 == 0 ? 12 : 6), height: db == 0 ? 2 : 1)
                            .position(x: 15, y: (1.0 - positionRatio) * trackHeight)
                    }
                }
                .frame(width: 30, height: trackHeight)

                // Fader rail
                Rectangle()
                    .fill(Color.black.opacity(0.6))
                    .frame(width: 2, height: trackHeight)

                // Thumb (fader cap) - styled per capStyle
                HourglassShape()
                    .fill(capStyle.gradient)
                    .overlay(
                        HourglassShape()
                            .stroke(Color.white.opacity(0.2), lineWidth: 2)
                    )
                    .frame(width: thumbWidth, height: thumbHeight)
                    .shadow(color: Color.black.opacity(0.3), radius: 1, x: 0, y: 1)
                    .overlay(
                        ZStack {
                            Rectangle()
                                .stroke(Color.black.opacity(0.2), lineWidth: 1)
                            VStack(spacing: 2) {
                                ForEach(0..<11) { index in
                                    if index == 5 {
                                        ZStack {
                                            Rectangle()
                                                .fill(Color.black)
                                            Rectangle()
                                                .stroke(Color.black.opacity(1.0), lineWidth: 1)
                                        }
                                        .frame(width: 24, height: 1.5)
                                    } else if index == 0 {
                                            Rectangle()
                                            .fill(Color.black.opacity(0.5))
                                                .frame(width: 26, height: 1.0)
                                    } else if index == 1 {
                                            Rectangle()
                                            .fill(Color.black.opacity(0.5))
                                                .frame(width: 21, height: 1.0)
                                    } else if index == 3 {
                                            Rectangle()
                                            .fill(Color.black.opacity(0.5))
                                                .frame(width: 20, height: 1.0)
                                    } else if index == 4 {
                                            Rectangle()
                                            .fill(Color.black.opacity(0.5))
                                                .frame(width: 19, height: 1.0)
                                    } else if index == 6 {
                                            Rectangle()
                                            .fill(Color.black.opacity(0.5))
                                                .frame(width: 19, height: 1.0)
                                    } else if index == 7 {
                                            Rectangle()
                                            .fill(Color.black.opacity(0.5))
                                                .frame(width: 20, height: 1.0)
                                    } else if index == 8 {
                                            Rectangle()
                                            .fill(Color.black.opacity(0.5))
                                                .frame(width: 21, height: 1.0)
                                    } else if index == 10 {
                                            Rectangle()
                                            .fill(Color.black.opacity(0.5))
                                                .frame(width: 26, height: 1.0)
                                    } else {
                                        Rectangle()
                                            .fill(Color.gray.opacity(1.0))
                                            .frame(width: 22, height: 1)
                                            .shadow(color: Color.black.opacity(0.3), radius: 1, x: 0, y: 1)
                                    }
                                }
                            }
                        }
                    )
                    .position(x: geo.size.width / 2, y: y-6)
                    // Persistent global channel index bubble overlay
                    .overlay(globalChannelIndexBubble) // This bubble is always visible above the thumb.
                    // Overlay DB bubble above thumb if needed
                    .overlay(dbBubble)
                    // maxValue should be set to 1.2 to allow for +20% headroom.
                    // The fader track and gesture support this full range, allowing value to go beyond 1.0.
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        #if os(macOS)
                        if NSEvent.modifierFlags.contains(.option) {
                            self.value = defaultValue

                            if let deviceID = deviceID, let channelIndex = channelIndex {
                                let computedDB: Double
                                switch role {
                                case .output:
                                    computedDB = Double(ChannelStateManager.shared.outputFaderDB(for: deviceID, channel: channelIndex))
                                case .input:
                                    computedDB = Double(ChannelStateManager.shared.faderDB(for: deviceID, channel: channelIndex))
                                }
                                ChannelStateManager.shared.showBubble(for: deviceID, channel: channelIndex, dbValue: computedDB, isDB: true, show: true, duration: 2.0)
                            } else {
                                let computedDB = Double(ChannelStateManager.shared.faderValueToDB(value: Float(defaultValue), minDB: -60.0, maxDB: 12.0))
                                ChannelStateManager.shared.showBubble(for: 0, channel: 0, dbValue: computedDB, isDB: true, show: true, duration: 2.0)
                            }
                            return
                        }
                        #endif

                        // drag.location.y is cursor Y in ZStack coordinates (0 = top of track)
                        // Invert the display formula: y_thumb = (1.2 - value) * availableH + thumbHeight/2
                        // Thumb is drawn at position y-6, so: cursor_y ≈ (1.2-value)*availableH + thumbHeight/2 - 6
                        // Solving for value: value = 1.2 - (cursor_y - thumbHeight/2 + 6) / availableH
                        let totalH = trackHeight - 28
                        let availableH = totalH - thumbHeight
                        let cursorY = drag.location.y
                        let newValue = Double(1.2 - (cursorY - thumbHeight / 2 + 6.0) / CGFloat(availableH))
                        let clampedValue = min(max(Double(minValue), newValue), Double(maxValue))
                        self.value = clampedValue

                        if let deviceID = deviceID, let channelIndex = channelIndex {
                            let computedDB: Double
                            switch role {
                            case .output:
                                computedDB = Double(ChannelStateManager.shared.outputFaderDB(for: deviceID, channel: channelIndex))
                            case .input:
                                computedDB = Double(ChannelStateManager.shared.faderDB(for: deviceID, channel: channelIndex))
                            }
                            ChannelStateManager.shared.showBubble(for: deviceID, channel: channelIndex, dbValue: computedDB, isDB: true, show: true, duration: 2.0)
                        } else {
                            let computedDB = Double(ChannelStateManager.shared.faderValueToDB(value: Float(clampedValue), minDB: -60.0, maxDB: 12.0))
                            ChannelStateManager.shared.showBubble(for: 0, channel: 0, dbValue: computedDB, isDB: true, show: true, duration: 2.0)
                        }
                    }
                    .onEnded { _ in }
            )
        }
        .frame(width: trackWidth + 30, height: trackHeight)
    }
}
#endif
// dB Y axis label positions for the mixer strips
// Key: dB value, Value: (label string, relative vertical position in GeometryReader)
let yAxisLabels: [Int: (label: String, position: CGFloat)] = [
    0:    ("  0", 0.02),
    -3:   (" -3", 0.10),
    -6:   (" -6", 0.17),
    -9:   (" -9", 0.24),
    -12:  ("-12", 0.305),
    -18:  ("-18", 0.425),
    -24:  ("-24", 0.535),
    -36:  ("-36", 0.72),
    -48:  ("-48", 0.85),
    -60:  ("-60", 0.94),
    -72:  ("-∞", 0.98)
]


// MARK: - PanDialView (Functional Rotary Dial for Pan)
struct PanDialView: View {
    @Binding var value: Double
    var themeMode: ThemeMode
    var deviceID: AudioDeviceID
    var channelIndex: Int
    private let minValue: Double = 0
    private let maxValue: Double = 127
    private let angleRange: Double = 270.0
    private let defaultValue: Double = 63.0

    @ObservedObject private var bubbleStore = ChannelBubbleStore.shared

    // Removed local bubble @State and timer
    // Bubble overlays are now synced via ChannelStateManager.bubbleStates, supporting linked channels
    /// panBubble overlay references ChannelStateManager.shared.bubbleStates for linked channel bubbles
    private var panBubble: some View {
        Group {
            let bubbleState = bubbleStore.states["\(deviceID)-\(channelIndex)"] ?? ChannelBubbleState()
            if bubbleState.showPan {
                Text(String(format: "%.1f", bubbleState.panValue))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 70, height: 30)
                    .offset(x: 0)
                    .background(
                        Capsule()
                            .fill(.clear)
                            .background(LiquidGlassBackground())
                            .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 1)
                    )
                    .offset(x: -20, y: 35)
                    .zIndex(1000)
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                let angle = Angle(degrees: ((value / 127.0) * angleRange) - 135.0)

                Circle()
                    .stroke(Color.gray.opacity(0.5), lineWidth: 2)
                Circle()
                    .fill(Color.black.opacity(0.4))

                // Colored arc to show pan angle (center to value), root at the pointer's center position
                do {
                    let fromTrim = CGFloat(min(value, 63.0) / 127.0 * 0.75)
                    let toTrim = CGFloat(max(value, 63.0) / 127.0 * 0.75)
                    Circle()
                        .trim(from: fromTrim, to: toTrim)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    meterGreenColor(for: themeMode).opacity(0.9),
                                    meterGreenColor(for: themeMode)
                                ]),
                                center: .center,
                                startAngle: .degrees(-135),
                                endAngle: .degrees(135)
                            ),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-225))
                }

                // Center dot
                ZStack {
                    Circle()
                        .fill(Color(.sRGB, red: 0.9, green: 0.9, blue: 0.9).opacity(1.0))
                    Circle()
                        .stroke(Color.black.opacity(1.0), lineWidth: 5)
                }
                .frame(width: 28, height: 28)

                // Pointer (should appear above arc)
                ZStack {
                    Rectangle()
                        .fill(Color.white)
                    Rectangle()
                        .stroke(Color.black, lineWidth: 1)
                }
                .frame(width: 4, height: size * 0.45)
                .offset(x: -0.05, y: -size * 0.245)
                .rotationEffect(angle)
                .overlay(panBubble)

            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        #if os(macOS)
                        if NSEvent.modifierFlags.contains(.option) {
                            value = defaultValue
                            ChannelStateManager.shared.showBubble(for: deviceID, channel: channelIndex, panValue: value, isDB: false, show: true, duration: 2.0)
                            return
                        }
                        #endif

                        let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                        let dx = gesture.location.x - center.x
                        let dy = gesture.location.y - center.y
                        var angle = atan2(dy, dx) * 180 / .pi
                        angle += 135
                        let threshold = 12.0 // degrees from 0 or 270 to snap
                        if angle >= 0 && angle < threshold {
                            value = minValue
                        } else if angle > 270 - threshold && angle <= 270 {
                            value = maxValue
                        } else if angle >= 0 && angle <= 270 {
                            let newValue = angle / 270 * 127
                            value = min(max(newValue, minValue), maxValue)
                        }
                        // else do nothing if angle is outside 0...270 range

                        // Show pan bubble via ChannelStateManager, syncing linked channels
                        ChannelStateManager.shared.showBubble(for: deviceID, channel: channelIndex, panValue: value, isDB: false, show: true, duration: 2.0)
                    }
                    .onEnded { _ in
                        // Bubble fade handled by ChannelStateManager timer internally
                    }
            )
        }
    }
}



// MARK: - AuxSendDialView

struct AuxSendDialView: View {
    var themeMode: ThemeMode
    @Binding var value: Double
    private let minValue: Double = 0
    private let maxValue: Double = 127
    private let angleRange: Double = 270.0
    private let defaultValue: Double = 0.0

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                // Updated angle calculation to start from minimum value (0)
                let angle = Angle(degrees: (value / 127.0) * angleRange - 135.0)

                Circle()
                    .stroke(Color.gray.opacity(0.5), lineWidth: 2)
                Circle()
                    .fill(Color.black.opacity(0.4))

                // Updated arc calculation: arc starts at min value (0)
                let fromTrim = CGFloat(0.0)
                let toTrim = CGFloat(value / 127.0 * 0.75)
                Circle()
                    .trim(from: fromTrim, to: toTrim)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                meterGreenColor(for: themeMode).opacity(0.9),
                                meterGreenColor(for: themeMode)
                            ]),
                            center: .center,
                            startAngle: .degrees(-135),
                            endAngle: .degrees(135)
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-225))

                Circle()
                    .fill(Color(.sRGB, red: 0.05, green: 0.1, blue: 0.6, opacity: 1.0))
                    .frame(width: 20, height: 20)
                ZStack {
                    Rectangle()
                        .fill(Color.white)
                    Rectangle()
                        .stroke(Color.black, lineWidth: 1)
                }
                .frame(width: 2, height: size * 0.45)
                .offset(y: -size * 0.265)
                .rotationEffect(angle)

                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.4))
                    Circle()
                        .stroke(Color.black.opacity(0.5), lineWidth: 2)
                }
                .frame(width: 16, height: 16)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        #if os(macOS)
                        if NSEvent.modifierFlags.contains(.option) {
                            value = defaultValue
                            return
                        }
                        #endif

                        let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                        let dx = gesture.location.x - center.x
                        let dy = gesture.location.y - center.y
                        var angle = atan2(dy, dx) * 180 / .pi
                        angle += 135
                        guard angle >= 0, angle <= 270 else { return }
                        value = min(max((angle / 270.0) * 127.0, minValue), maxValue)
                    }
            )
        }
    }
}

// MARK: - FXSendDialView

struct FXSendDialView: View {
    var themeMode: ThemeMode
    @Binding var value: Double
    private let minValue: Double = 0
    private let maxValue: Double = 127
    private let angleRange: Double = 270.0
    private let defaultValue: Double = 0.0

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                let angle = Angle(degrees: (value / 127.0) * angleRange - 135.0)

                Circle()
                    .stroke(Color.gray.opacity(0.5), lineWidth: 2)
                Circle()
                    .fill(Color.black.opacity(0.4))

                let fromTrim = CGFloat(0.0)
                let toTrim = CGFloat(value / 127.0 * 0.75)
                Circle()
                    .trim(from: fromTrim, to: toTrim)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                meterGreenColor(for: themeMode).opacity(0.9),
                                meterGreenColor(for: themeMode)
                            ]),
                            center: .center,
                            startAngle: .degrees(-135),
                            endAngle: .degrees(135)
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-225))

                Circle()
                    .fill(Color(.sRGB, red: 0.6, green: 0.1, blue: 0.3, opacity: 1.0))
                    .frame(width: 20, height: 20)
                ZStack {
                    Rectangle()
                        .fill(Color.white)
                    Rectangle()
                        .stroke(Color.black, lineWidth: 1)
                }
                .frame(width: 2, height: size * 0.45)
                .offset(y: -size * 0.265)
                .rotationEffect(angle)

                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.4))
                    Circle()
                        .stroke(Color.black.opacity(0.5), lineWidth: 2)
                }
                .frame(width: 16, height: 16)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        #if os(macOS)
                        if NSEvent.modifierFlags.contains(.option) {
                            value = defaultValue
                            return
                        }
                        #endif

                        let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                        let dx = gesture.location.x - center.x
                        let dy = gesture.location.y - center.y
                        var angle = atan2(dy, dx) * 180 / .pi
                        angle += 135
                        guard angle >= 0, angle <= 270 else { return }
                        value = min(max((angle / 270.0) * 127.0, minValue), maxValue)
                    }
            )
        }
    }
}

// MARK: - PostGainDialView

struct PostGainDialView: View {
    var themeMode: ThemeMode
    @Binding var value: Double
    private let minValue: Double = 0
    private let maxValue: Double = 127
    private let angleRange: Double = 270.0
    private let defaultValue: Double = 0.0

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                // The dial value spans the full 0 to 127 range.
                // The angle is mapped linearly over 270 degrees.
                let angle = Angle(degrees: (value / 127.0) * angleRange - 135.0)

                Circle()
                    .stroke(Color.gray.opacity(0.5), lineWidth: 2)
                Circle()
                    .fill(Color.black.opacity(0.4))

                let fromTrim = CGFloat(0.0)
                let toTrim = CGFloat(value / 127.0 * 0.75)
                Circle()
                    .trim(from: fromTrim, to: toTrim)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                meterGreenColor(for: themeMode).opacity(0.9),
                                meterGreenColor(for: themeMode)
                            ]),
                            center: .center,
                            startAngle: .degrees(-135),
                            endAngle: .degrees(135)
                        ),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-225))

                Circle()
                    .fill(Color(.sRGB, red: 0.04, green: 0.04, blue: 0.05, opacity: 1.0))
                    .frame(width: 20, height: 20)
                ZStack {
                    Rectangle()
                        .fill(Color.white)
                    Rectangle()
                        .stroke(Color.black, lineWidth: 1)
                }
                .frame(width: 2, height: size * 0.45)
                .offset(y: -size * 0.265)
                .rotationEffect(angle)

                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.06))
                    Circle()
                        .stroke(Color.red.opacity(0.9), lineWidth: 1)
                }
                .frame(width: 16, height: 16)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        #if os(macOS)
                        if NSEvent.modifierFlags.contains(.option) {
                            value = defaultValue
                            return
                        }
                        #endif

                        let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                        let dx = gesture.location.x - center.x
                        let dy = gesture.location.y - center.y
                        var angle = atan2(dy, dx) * 180 / .pi
                        angle += 135
                        // Clamp angle to valid dial range 0° to 270°
                        guard angle >= 0, angle <= 270 else { return }
                        // Map angle directly to the full value range of 0 to 127
                        value = min(max((angle / 270.0) * 127.0, minValue), maxValue)
                    }
            )
        }
    }
}


// MARK: - Mute, Solo + Link Implementations

/// An example typically found within any Channel Strip:
///
///
///
/// @State private var isMuted = false
/// @State private var isSoloed = false
/// @State private var isLinked = false
///
/// Mute/Solo/Link buttons
///VStack {
///
///    Button(action: {
///        // Toggle link state (this example uses a local variable; replace with your logic as needed)
///        isLinked.toggle()
///        // You could implement shared volume and mute/solo states here
///    }) {
///        Image(systemName: "link")
///            .font(.system(size: 14, weight: .bold))
///            .foregroundColor(isLinked ? .white : .blue)
///            .padding(.horizontal, 2)
///            .background(
///                ZStack {
///                    isLinked ? Color.blue : Color.black.opacity(0.6)
///                    RoundedRectangle(cornerRadius: 6)
///                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
///                }
///            )
///            .cornerRadius(6)
///   }
///    .buttonStyle(PlainButtonStyle())
///}
///.offset(x: -48, y: 62)
///
///VStack {
///    Text("M")
///        .font(.system(size: 16, weight: .bold))
///        .foregroundColor(isMuted ? .white : .red)
///        .padding(.horizontal, 2)
///        .background(
///            ZStack {
///                isMuted ? Color.red : Color.black.opacity(0.6)
///                RoundedRectangle(cornerRadius: 6)
///                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
///            }
///        )
///        .cornerRadius(6)
///        .onTapGesture {
///            isMuted.toggle()
///            // Hook up actual mute logic if needed
///        }
///}
///.offset(x: -23, y: 43)
///
///VStack {
///    Text("S")
///        .font(.system(size: 16, weight: .bold))
///        .foregroundColor(isSoloed ? .white : .yellow)
///        .padding(.horizontal, 6)
///        .background(
///            ZStack {
///                isSoloed ? Color.yellow : Color.black.opacity(0.6)
///                RoundedRectangle(cornerRadius: 6)
///                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
///            }
///        )
///        .cornerRadius(6)
///        .onTapGesture {
///            isSoloed.toggle()
///            // Hook up actual solo logic if needed
///        }
///
///}
///.offset(x: -2, y: 24)
///}
///.frame(width: 36)


// MARK: - Link Button UI Example with Adjacent Channel Linking Logic

struct LinkButtonView: View {
    @State private var isLinkedLocal: Bool = false

    /// The channel number for this button
    var channel: Int

    /// The device ID for the channel, used to verify device context and linking
    var deviceID: AudioDeviceID

    var body: some View {
        // Use ChannelStateManager.shared for actual linked state
        let isLinked = ChannelStateManager.shared.isLinked(deviceID: deviceID, channel: channel)

        Button(action: {
            // This implements the adjacent linking logic:
            // When linking channel N:
            // - If N is odd, try to link N+1 (the next even channel)
            // - If N is even, try to link N-1 (the previous odd channel)
            // Only perform linking if both channels exist in the same device context.
            // Otherwise, do nothing.

            let adjacentChannel: Int
            if channel % 2 == 1 {
                adjacentChannel = channel + 1
            } else {
                adjacentChannel = channel - 1
            }

            // Check if adjacent channel exists within the same device context
            if ChannelStateManager.shared.channelExists(deviceID: deviceID, channel: adjacentChannel) {
                // Link the two adjacent channels together
                ChannelStateManager.shared.toggleLink(deviceID: deviceID, channel: channel)
            } else {
                // Adjacent channel does not exist, do nothing
            }
        }) {
            Image(systemName: "link")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(isLinked ? .white : .blue)
                .padding(.horizontal, 2)
                .background(
                    ZStack {
                        isLinked ? Color.blue : Color.black.opacity(0.6)
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.6), lineWidth: 1)
                    }
                )
                .cornerRadius(6)
        }
        .buttonStyle(PlainButtonStyle())
    }
}
