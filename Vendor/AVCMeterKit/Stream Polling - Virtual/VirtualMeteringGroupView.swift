//
//  VirtualMeteringGroupView.swift
//  AVCMeter
//
//  Created by Chris Izatt on 07/07/2025.
//

import SwiftUI

/// A horizontal row (or vertical column) of virtual channel strips.
struct VirtualMeteringGroupView: View {
    let context: VirtualMeteringContext

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(context.channels.enumerated()), id: \.1.id) { index, channel in
                switch channel.type {
                case .virtualInstrument:
                    VirtualInstrumentStripView(deviceID: context.deviceID, channelIndex: index)
                default:
                    FXReturnStripView(channel: channel, context: context, channelIndex: index)
                }
            }
        }
        .padding()
    }
}
