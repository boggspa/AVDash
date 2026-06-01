//
//  SpectrumContainerView.swift
//  AVCMeter
//
//  Created by Chris Izatt on 29/06/2025.
//

import Foundation
import SwiftUI

struct SpectrumContainer: View {
    @ObservedObject var processor: SafeFFTSpectrumProcessor
    let themeMode: ThemeMode
    let scale: CGFloat

    // Observing settings so the view re-evaluates when the user switches mode.
    @ObservedObject private var settings = VisualisationSettings.shared

    let yAxisMarkers: [Int: CGFloat] = [
        15: 10,
        0: 22,
        -6: -6,
        -15: -18,
        -24: -28,
        -30: -55,
        -40: -64,
        -60: -38
    ]

    let yAxisLineOffsets: [Int: CGFloat] = [
        15: 27,
        0: 10,
        -6: 0,
        -15: -9,
        -24: -18,
        -30: -26,
        -40: -38,
        -60: -60
    ]

    var body: some View {
        let chartTopInset: CGFloat = 22 * scale

        return GeometryReader { geo in
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: chartTopInset)

                    GeometryReader { chartGeo in
                        ZStack(alignment: .top) {
                            // --- Renderer selection ---
                            // RenderBackendResolver reads the current performance mode and
                            // Metal availability; re-evaluated whenever settings changes.
                            if RenderBackendResolver.resolveSpectrumBackend() == .cpu {
                                CPUSpectrumRenderer(
                                    spectrumProcessor: processor,
                                    themeMode: themeMode
                                )
                                .frame(width: chartGeo.size.width, height: chartGeo.size.height)
                            } else {
                                MetalSpectrumRenderer(
                                    spectrumProcessor: processor,
                                    channelIndex: 0,
                                    themeMode: themeMode
                                )
                                .frame(width: chartGeo.size.width, height: chartGeo.size.height)
                                .background(Color.clear)
                            }

                            // Horizontal grid lines
                            ForEach(Array(yAxisMarkers.keys).sorted(by: >), id: \.self) { db in
                                let yOffset = yAxisLineOffsets[db] ?? 0
                                let normalized = 1.0 - ((Float(db) + 60) / 75.0)
                                let baseY = CGFloat(normalized) * (chartGeo.size.height - 16 * scale)
                                let y = baseY + (yOffset * scale)
                                Path { path in
                                    path.move(to: CGPoint(x: 16, y: y))
                                    path.addLine(to: CGPoint(x: chartGeo.size.width, y: y))
                                }
                                .stroke(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4]))
                            }

                            // Y-axis and bottom axis
                            Path { path in
                                let leftMargin: CGFloat = 16
                                let bottomMargin: CGFloat = 16
                                let topY: CGFloat = 0
                                let bottomY = chartGeo.size.height - bottomMargin
                                path.move(to: CGPoint(x: leftMargin, y: topY))
                                path.addLine(to: CGPoint(x: leftMargin, y: bottomY))
                                path.move(to: CGPoint(x: leftMargin, y: bottomY))
                                path.addLine(to: CGPoint(x: chartGeo.size.width, y: bottomY))
                            }
                            .stroke(Color.white, lineWidth: 1)

                            // Y-axis labels
                            HStack(alignment: .top, spacing: 0) {
                                VStack(spacing: 0) {
                                    ForEach(Array(yAxisMarkers.keys).sorted(by: >), id: \.self) { db in
                                        Text("\(db)")
                                            .font(.system(size: 10 * scale))
                                            .foregroundColor(.white)
                                            .frame(maxHeight: .infinity, alignment: .top)
                                            .offset(y: (yAxisMarkers[db] ?? 0) * scale)
                                    }
                                }
                                .frame(width: 24)
                                .padding(.top, 8)
                                .padding(.leading, 8)
                                Spacer()
                            }

                            // X-axis grid lines and labels using dictionary-based markers
                            let xAxisMarkers: [String: CGFloat] = [
                                "20": 0.035,
                                "50": 0.0658,
                                "60": 0.0952,
                                "80": 0.156,
                                "100": 0.198,
                                "200": 0.312,
                                "300": 0.380,
                                "500": 0.458,
                                "800": 0.530,
                                "1k": 0.563,
                                "2k": 0.666,
                                "3k": 0.724,
                                "5k": 0.798,
                                "8k": 0.867,
                                "10k": 0.898,
                                "12k": 0.925,
                                "16k": 0.966,
                                "20k": 0.994
                            ]

                            ForEach(Array(xAxisMarkers.keys.sorted { xAxisMarkers[$0]! < xAxisMarkers[$1]! }), id: \.self) { label in
                                let normalized = xAxisMarkers[label] ?? 0.0
                                let x = normalized * chartGeo.size.width
                                Path { path in
                                    let topMargin: CGFloat = 0
                                    let bottomMargin: CGFloat = 16 * scale
                                    path.move(to: CGPoint(x: x, y: topMargin * scale))
                                    path.addLine(to: CGPoint(x: x, y: chartGeo.size.height - (bottomMargin * scale)))
                                }
                                .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3]))
                            }

                            GeometryReader { labelGeo in
                                ZStack {
                                    ForEach(Array(xAxisMarkers.keys.sorted { xAxisMarkers[$0]! < xAxisMarkers[$1]! }), id: \.self) { label in
                                        let normalized = xAxisMarkers[label] ?? 0.0
                                        let x = normalized * labelGeo.size.width
                                        Text(label)
                                            .font(.system(size: 10 * scale))
                                            .foregroundColor(.white)
                                            .position(x: x, y: labelGeo.size.height - (7 * scale))
                                    }
                                }
                            }
                        }
                        .clipped()
                    }
                }

                VStack {
                    Text("\(processor.deviceName) – Channel \(processor.channelIndex + 1)")
                        .font(.system(size: 18 * scale, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.top, 10)
                        .padding(.leading, 8)
                }
                .onAppear {
                    processor.start()
                }

                HStack {
                    Spacer()
                    VStack {
                        Button(action: {
                            NSApp.keyWindow?.close()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.white.opacity(0.7))
                                .font(.system(size: 14 * scale, weight: .bold))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.top, 10)
                        .padding(.trailing, 8)
                        Spacer()
                    }
                }
            }
            .background(Color.clear)
        }
        .onDisappear {
            processor.stop()
        }
    }
}
