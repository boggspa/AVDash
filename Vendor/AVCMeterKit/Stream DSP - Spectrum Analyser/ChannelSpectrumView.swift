//
//  ChannelSpectrumView.swift
//  AVCMeter
//
//  Created by Chris Izatt on 22/06/2025.
//

import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif


struct ChannelSpectrumView: View {
    @EnvironmentObject var themeManager: ThemeManager
    let channelIndex: Int
    @ObservedObject var spectrumWrapper: ChannelFFTSpectrumWrapper
    @State private var magnitudes: [Float] = []
    /// Cached normalized x positions for each FFT bin
    @State private var xPositions: [CGFloat] = []
    @State private var timer: Timer? = nil
    private let smoothingFrames = 4
    @State private var magnitudeHistory: [[Float]] = []
    @State private var historyIndex: Int = 0

    var body: some View {
        let deviceName = spectrumWrapper.device.name
        let deviceID = spectrumWrapper.device.deviceID
        ZStack {
            VStack(alignment: .center) {
                VStack(alignment: .center, spacing: 0) {
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            Text("\(deviceName) – Channel \(channelIndex + 1)")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .offset(y: 18)
                                .padding(.bottom, 4)
                            let sampleRate: Float = 48000
                            let fftSize: Float = 2048
                            let binFreqStep = sampleRate / fftSize
                            let minFreq: Float = 20.0
                            let maxFreq: Float = 20000.0
                            let logMinFreq = log10(minFreq)
                            let logMaxFreq = log10(maxFreq)
                            let labelFrequencies: [Float] = [30, 40, 50, 60, 80, 100, 150, 200, 300, 400, 600, 800, 1000, 2000, 4000, 8000, 16000]
                            let mode: ThemeMode = themeManager.deviceCapsuleThemes[deviceID] ?? themeManager.capsuleThemeMode
                            let baseColor = spectrumLineColor(for: SpectrumThemeMode(from: mode))

                            Group {
                                if #available(macOS 12.0, *) {
                                    Canvas { context, size in
                                        guard magnitudes.count > 1 else { return }
                                        var path = Path()
                                        var points: [CGPoint] = []
                                        var xPosIndex = 0
                                        for (index, magnitude) in magnitudes.enumerated() {
                                            if xPosIndex >= xPositions.count { break }
                                            let freq = Float(index) * binFreqStep
                                            if freq < minFreq || freq > maxFreq { continue }
                                            let x = xPositions[xPosIndex]
                                            let y = size.height * (1.0 - CGFloat(magnitude))
                                            points.append(CGPoint(x: x, y: y))
                                            xPosIndex += 1
                                        }
                                        guard let first = points.first else { return }
                                        path.move(to: first)
                                        for idx in 1..<points.count {
                                            let prev = points[idx - 1]
                                            let current = points[idx]
                                            let mid = CGPoint(x: (prev.x + current.x) / 2, y: (prev.y + current.y) / 2)
                                            path.addQuadCurve(to: mid, control: prev)
                                            path.addQuadCurve(to: current, control: mid)
                                        }

                                        var fillPath = path
                                        if let currentPoint = path.currentPoint {
                                            fillPath.addLine(to: CGPoint(x: currentPoint.x, y: size.height))
                                        }
                                        fillPath.addLine(to: CGPoint(x: 0, y: size.height))
                                        fillPath.closeSubpath()

                                        let gradient = spectrumGradient(baseColor: baseColor)
                                        let gradientBrush = GraphicsContext.Shading.linearGradient(
                                            gradient,
                                            startPoint: CGPoint(x: 0, y: 0),
                                            endPoint: CGPoint(x: 0, y: size.height)
                                        )
                                        context.fill(fillPath, with: gradientBrush)

                                        for freq in labelFrequencies {
                                            let t = (log10(freq) - logMinFreq) / (logMaxFreq - logMinFreq)
                                            let x = CGFloat(t) * size.width
                                            let label = freq >= 1000 ? "\(Int(freq / 1000))k" : "\(Int(freq))"

                                            var gridPath = Path()
                                            gridPath.move(to: CGPoint(x: x, y: 0))
                                            gridPath.addLine(to: CGPoint(x: x, y: size.height))
                                            context.stroke(gridPath, with: .color(.white.opacity(0.2)), lineWidth: 0.2)

                                            let text = Text(label)
                                                .font(.system(size: 7))
                                                .foregroundColor(.secondary)
                                            let paddedX = min(max(x, 10), size.width - 10)
                                            context.draw(text, at: CGPoint(x: paddedX, y: size.height - 10), anchor: .top)
                                        }

                                        let dbFloor: Float = -50.0
                                        let dbCeil: Float = 10.0
                                        let dbStep: Float = 10.0
                                        let dbRange = stride(from: dbFloor, through: dbCeil, by: dbStep)
                                        let filteredDbRange = dbRange.filter { $0 != dbFloor && $0 != dbCeil }
                                        for db in filteredDbRange {
                                            let t = (db - dbFloor) / (dbCeil - dbFloor)
                                            let y = size.height * (1.0 - CGFloat(t))
                                            var hLine = Path()
                                            hLine.move(to: CGPoint(x: 0, y: y))
                                            hLine.addLine(to: CGPoint(x: size.width, y: y))
                                            context.stroke(hLine, with: .color(.white.opacity(0.15)), lineWidth: 0.5)

                                            let label = Text("\(Int(db)) dB")
                                                .font(.system(size: 7))
                                                .foregroundColor(.secondary)
                                            context.draw(label, at: CGPoint(x: 5, y: y - 5), anchor: .topLeading)
                                        }

                                        let strokeGradient = GraphicsContext.Shading.linearGradient(
                                            gradient,
                                            startPoint: CGPoint(x: 0, y: 0),
                                            endPoint: CGPoint(x: 0, y: size.height)
                                        )
                                        context.stroke(path, with: strokeGradient, lineWidth: 2.0)
                                    }
                                } else {
                                    legacySpectrumView(
                                        size: geometry.size,
                                        logMinFreq: logMinFreq,
                                        logMaxFreq: logMaxFreq,
                                        labelFrequencies: labelFrequencies,
                                        baseColor: baseColor
                                    )
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(8)
                            // Move xPositions computation to .onChange of magnitudes
                            .onChange(of: magnitudes) { _ in
                                // Recompute xPositions when magnitudes array changes
                                xPositions = magnitudes.enumerated().compactMap { i, _ in
                                    let freq = Float(i) * binFreqStep
                                    guard freq >= minFreq, freq <= maxFreq else { return nil }
                                    let logFreq = log10(freq)
                                    let t = (logFreq - logMinFreq) / (logMaxFreq - logMinFreq)
                                    return CGFloat(t) * geometry.size.width
                                }
                            }
                        }
                        .frame(width: 700, height: 300, alignment: .center)
                        .background(Color.clear)
                        .cornerRadius(12)
                        .shadow(radius: 6)
                    }
                    //.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                //.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .offset(x: 25, y: 25)
            //.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .onAppear {
                // Invalidate any existing timer
                timer?.invalidate()

                // Create timer on main thread, then use .common to ensure it fires during UI events
                let newTimer = Timer(timeInterval: 0.05, repeats: true) { _ in
                    // Offload FFT work to background queue
                    DispatchQueue.global(qos: .background).async {
                        self.spectrumWrapper.getPeakMagnitudes()
                        let magnitudesRaw = self.spectrumWrapper.peakMagnitudes()

                        // Convert to normalized dB values
                        let dbFloor: Float = -50.0
                        let dbCeil: Float = 10.0
                        let newFrame: [Float] = magnitudesRaw.map { val in
                            let db = 10 * log10(max(val, 1e-10))
                            let clampedDb = max(dbFloor, min(dbCeil, db))
                            return (clampedDb - dbFloor) / (dbCeil - dbFloor)
                        }

                        // Initialize history buffer if needed
                        if self.magnitudeHistory.isEmpty {
                            self.magnitudeHistory = Array(repeating: newFrame, count: smoothingFrames)
                        }
                        // Circular-buffer smoothing
                        self.magnitudeHistory[self.historyIndex] = newFrame
                        self.historyIndex = (self.historyIndex + 1) % smoothingFrames
                        // Smooth by averaging corresponding entries, guarding against mismatched lengths
                        let frameCount = newFrame.count
                        var smoothed = [Float](repeating: 0.0, count: frameCount)
                        for frame in self.magnitudeHistory {
                            let iterateCount = min(frame.count, frameCount)
                            for i in 0..<iterateCount {
                                smoothed[i] += frame[i]
                            }
                        }
                        let invCount = 1.0 / Float(smoothingFrames)
                        for i in 0..<smoothed.count {
                            smoothed[i] *= invCount
                        }

                        // Back to main thread to publish
                        DispatchQueue.main.async {
                            self.magnitudes = smoothed
                        }
                    }
                }
                RunLoop.main.add(newTimer, forMode: .common)
                timer = newTimer
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
            // Close button overlay
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
#if os(macOS)
                        NSApp.keyWindow?.close()
#endif
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(8)
                }
                Spacer()
            }
        } // end ZStack
    }
    private func spectrumGradient(baseColor: Color) -> Gradient {
        Gradient(stops: [
            .init(color: Color(red: 0.5, green: 0.0, blue: 0.0), location: 0.1),
            .init(color: Color(red: 0.5, green: 0.0, blue: 0.0).opacity(0.95), location: 0.15),
            .init(color: Color(red: 0.65, green: 0.35, blue: 0.1).opacity(0.85), location: 0.2),
            .init(color: Color(red: 0.4, green: 0.3, blue: 0.1).opacity(0.6), location: 0.35),
            .init(color: baseColor.opacity(0.75), location: 0.6),
            .init(color: baseColor.opacity(0.35), location: 0.9),
            .init(color: baseColor.opacity(0.0), location: 1.0),
        ])
    }

    private func spectrumPoints(in size: CGSize) -> [CGPoint] {
        guard magnitudes.count > 1 else { return [] }
        let sampleRate: Float = 48000
        let fftSize: Float = 2048
        let binFreqStep = sampleRate / fftSize
        let minFreq: Float = 20.0
        let maxFreq: Float = 20000.0

        var points: [CGPoint] = []
        var xPosIndex = 0
        for (index, magnitude) in magnitudes.enumerated() {
            if xPosIndex >= xPositions.count { break }
            let freq = Float(index) * binFreqStep
            if freq < minFreq || freq > maxFreq { continue }
            let x = xPositions[xPosIndex]
            let y = size.height * (1.0 - CGFloat(magnitude))
            points.append(CGPoint(x: x, y: y))
            xPosIndex += 1
        }
        return points
    }

    private func legacySpectrumPath(in size: CGSize) -> Path {
        let points = spectrumPoints(in: size)
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for idx in 1..<points.count {
            let prev = points[idx - 1]
            let current = points[idx]
            let mid = CGPoint(x: (prev.x + current.x) / 2, y: (prev.y + current.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
            path.addQuadCurve(to: current, control: mid)
        }
        return path
    }

    @ViewBuilder
    private func legacySpectrumView(
        size: CGSize,
        logMinFreq: Float,
        logMaxFreq: Float,
        labelFrequencies: [Float],
        baseColor: Color
    ) -> some View {
        let gradient = spectrumGradient(baseColor: baseColor)
        let path = legacySpectrumPath(in: size)
        let dbFloor: Float = -50.0
        let dbCeil: Float = 10.0
        let dbStep: Float = 10.0
        let filteredDbValues = Array(stride(from: dbFloor, through: dbCeil, by: dbStep)).filter { $0 != dbFloor && $0 != dbCeil }

        ZStack(alignment: .topLeading) {
            ForEach(labelFrequencies, id: \.self) { freq in
                let t = (log10(freq) - logMinFreq) / (logMaxFreq - logMinFreq)
                let x = CGFloat(t) * size.width
                let label = freq >= 1000 ? "\(Int(freq / 1000))k" : "\(Int(freq))"
                let paddedX = min(max(x, 10), size.width - 10)

                Path { p in
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                }
                .stroke(Color.white.opacity(0.2), lineWidth: 0.2)

                Text(label)
                    .font(.system(size: 7))
                    .foregroundColor(.secondary)
                    .position(x: paddedX, y: size.height - 10)
            }

            ForEach(filteredDbValues, id: \.self) { db in
                let t = (db - dbFloor) / (dbCeil - dbFloor)
                let y = size.height * (1.0 - CGFloat(t))

                Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)

                Text("\(Int(db)) dB")
                    .font(.system(size: 7))
                    .foregroundColor(.secondary)
                    .position(x: 22, y: y - 5)
            }

            path
                .fill(
                    LinearGradient(
                        gradient: gradient,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .mask(
                    Path { fillPath in
                        fillPath.addPath(path)
                        if let current = path.currentPoint {
                            fillPath.addLine(to: CGPoint(x: current.x, y: size.height))
                        }
                        fillPath.addLine(to: CGPoint(x: 0, y: size.height))
                        fillPath.closeSubpath()
                    }
                )

            path.stroke(
                LinearGradient(
                    gradient: gradient,
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 2.0
            )
        }
    }
}
