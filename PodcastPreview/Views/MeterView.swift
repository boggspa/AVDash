//
//  MeterView.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 07/12/2025.
//

import SwiftUI
import PodcastPreviewShared
import os.lock

struct MeterScaleView: View {
    @Environment(\.appUIScale) private var appUIScale
    let minDB: Float
    let maxDB: Float
    let ticks: [(label: String, pos: Float, db: Float)]

    init(minDB: Float = MeterScale.defaultMinDB,
         maxDB: Float = MeterScale.defaultMaxDB,
         step: Float = 10.0) {
        self.minDB = minDB
        self.maxDB = maxDB
        self.ticks = MeterScale.ticks(step: step, minDB: minDB, maxDB: maxDB)
    }

    private var scaledCaption2FontSize: CGFloat { 11 * appUIScale }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                    let y = geo.size.height * (1.0 - CGFloat(tick.pos))
                    Text(tick.label)
                        .font(.system(size: scaledCaption2FontSize, weight: .regular))
                        .frame(width: geo.size.width, alignment: .trailing)
                        .position(x: geo.size.width / 2, y: y)
                }
            }
        }
    }
}

struct MeterView: View {
    @Environment(\.appUIScale) private var appUIScale
    @ObservedObject var monitoring: MonitoringState

    var body: some View {
        // Use GeometryReader to make meters responsive to window size
        GeometryReader { geometry in
            meterContent(availableHeight: geometry.size.height)
        }
    }

    private func meterContent(availableHeight: CGFloat) -> some View {
        let scaleWidth: CGFloat = 60 * appUIScale       // dB scale column
        let meterWidth: CGFloat = 12 * appUIScale       // per-channel meter width
        let meterSpacing: CGFloat = 4 * appUIScale      // spacing between meters
        let sidePadding: CGFloat = 24 * appUIScale      // overall horizontal padding allowance
        let outerStackSpacing: CGFloat = 8 * appUIScale
        let cardCornerRadius: CGFloat = 32 * appUIScale
        let innerStackSpacing: CGFloat = 4 * appUIScale
        let contentSpacing: CGFloat = 8 * appUIScale

        // Dynamic meter height based on available space
        // Reserve space for labels and padding
        let labelsAndPadding: CGFloat = 60 * appUIScale
        let minMeterHeight: CGFloat = 160 * appUIScale
        let maxMeterHeight: CGFloat = 400 * appUIScale
        let meterHeight = min(max(availableHeight - labelsAndPadding, minMeterHeight), maxMeterHeight)

        let cardHeight: CGFloat = meterHeight + labelsAndPadding
        let scrollVerticalPadding: CGFloat = 2 * appUIScale
        let scrollHorizontalPadding: CGFloat = 4 * appUIScale
        let leadingPadding: CGFloat = 8 * appUIScale
        let topPadding: CGFloat = 12 * appUIScale
        let horizontalOffset: CGFloat = -32 * appUIScale
        let scaledCaption2FontSize: CGFloat = 11 * appUIScale

        let channelCount = max(monitoring.channelMetering.count, 1)

        let maxVisibleChannels = 8
        let visibleChannels = min(channelCount, maxVisibleChannels)
        let totalMetersWidth = CGFloat(channelCount) * meterWidth +
            CGFloat(max(channelCount - 1, 0)) * meterSpacing
        let visibleMetersWidth = CGFloat(visibleChannels) * meterWidth +
            CGFloat(max(visibleChannels - 1, 0)) * meterSpacing

        // Card width grows up to 8 channels, then stays fixed and meters scroll.
        let containerWidth = scaleWidth + visibleMetersWidth + sidePadding

        let shouldScroll = channelCount > maxVisibleChannels

        return ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: outerStackSpacing) {

                ZStack {
                    ThemeRoundedRectangle(cornerRadius: cardCornerRadius).themed()

                    // Left fixed scale + right meter strip (scrolls when > 8 channels)
                    HStack(alignment: .bottom, spacing: contentSpacing) {
                        MeterScaleView()
                            .frame(width: scaleWidth, height: meterHeight)

                        if shouldScroll {
                            ScrollView(.horizontal, showsIndicators: true) {
                                VStack(alignment: .leading, spacing: innerStackSpacing) {

                                    // 1) Meters row
                                    MetalMeterStripView(
                                        metering: monitoring.channelMetering,
                                        themeColor: monitoring.displayThemeColor,
                                        calibrationDB: monitoring.meterCalibrationDB,
                                        meterWidth: meterWidth,
                                        meterSpacing: meterSpacing
                                    )
                                    .frame(width: totalMetersWidth, height: meterHeight)

                                    // 2) Channel labels
                                    HStack(spacing: meterSpacing) {
                                        ForEach(Array(monitoring.channelMetering.enumerated()), id: \.offset) { index, _ in
                                            Text("\(index + 1)")
                                                .font(.system(size: scaledCaption2FontSize, weight: .regular))
                                                .frame(width: meterWidth)
                                        }
                                    }
                                }
                                .padding(.vertical, scrollVerticalPadding)
                                .padding(.horizontal, scrollHorizontalPadding)
                            }
                            .frame(width: visibleMetersWidth)
                        } else {
                            VStack(alignment: .leading, spacing: innerStackSpacing) {

                                // 1) Meters row
                                MetalMeterStripView(
                                    metering: monitoring.channelMetering,
                                    themeColor: monitoring.displayThemeColor,
                                    calibrationDB: monitoring.meterCalibrationDB,
                                    meterWidth: meterWidth,
                                    meterSpacing: meterSpacing
                                )
                                .frame(width: totalMetersWidth, height: meterHeight)

                                // 2) Channel labels
                                HStack(spacing: meterSpacing) {
                                    ForEach(Array(monitoring.channelMetering.enumerated()), id: \.offset) { index, _ in
                                        Text("\(index + 1)")
                                            .font(.system(size: scaledCaption2FontSize, weight: .regular))
                                            .frame(width: meterWidth)
                                    }
                                }
                            }
                            .frame(width: visibleMetersWidth, alignment: .leading)
                        }
                    }
                    .frame(width: containerWidth - sidePadding, alignment: .leading)
                    .offset(x: horizontalOffset)
                    .padding(.leading, leadingPadding)
                    .padding(.trailing, leadingPadding)

                }
                .frame(width: containerWidth, height: cardHeight)
            }
            .padding(.top, topPadding)
        }
    }
}

#Preview {
    MeterView(monitoring: MonitoringState())
}
