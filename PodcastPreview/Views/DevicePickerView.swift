//
//  DevicePickerView.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 07/12/2025.
//

import SwiftUI

struct DevicePickerView: View {
    @ObservedObject var monitoring: MonitoringState

    var body: some View {
        Menu {
            ForEach(monitoring.devices) { device in
                Button(device.name) {
                    monitoring.startMonitoring(device: device)
                }
            }

            if let selected = monitoring.selectedDevice {
                Divider()
                Button("Stop \"\(selected.name)\"") {
                    monitoring.stopMonitoring()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(monitoring.selectedDevice?.name ?? "Select Input Device")
                Image(systemName: "chevron.down")
                    .imageScale(.small)
            }
        }
    }
}
