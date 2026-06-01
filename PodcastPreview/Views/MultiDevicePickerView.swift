//
//  MultiDevicePickerView.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 17/03/2026.
//
//  Device picker supporting simultaneous multi-device peak metering
//

import SwiftUI

struct MultiDevicePickerView: View {
    @ObservedObject var manager: MultiDeviceAudioManager
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Audio Input Devices")
                    .font(.headline)

                Spacer()

                if !manager.activeDevices.isEmpty || manager.isSpectrumMode {
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            manager.stopAll()
                        }
                    }) {
                        Label("Stop All", systemImage: "stop.circle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.2))
            .cornerRadius(8)

            // Device List
            if isExpanded {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(manager.availableDevices) { device in
                            DeviceRowView(
                                device: device,
                                isActive: manager.isDeviceActive(device),
                                mode: manager.monitoringMode(for: device),
                                isSpectrumMode: manager.isSpectrumMode,
                                onTogglePeakMonitoring: {
                                    manager.togglePeakMonitoring(for: device)
                                },
                                onStartSpectrum: {
                                    manager.startSpectrumMode(for: device)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 300)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(
            ThemeRoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.15))
                .overlay(
                    ThemeRoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

struct DeviceRowView: View {
    @ObservedObject var device: AudioDeviceModel
    let isActive: Bool
    let mode: String
    let isSpectrumMode: Bool
    let onTogglePeakMonitoring: () -> Void
    let onStartSpectrum: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Selection indicator (checkbox for peak, radio for spectrum)
            ZStack {
                Circle()
                    .stroke(device.themeColor.opacity(0.5), lineWidth: 2)
                    .frame(width: 22, height: 22)

                if isActive {
                    Circle()
                        .fill(device.themeColor)
                        .frame(width: 14, height: 14)
                }
            }

            // Device info
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(device.transportType.rawValue)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if !device.manufacturer.isEmpty {
                        Text("•")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.5))

                        Text(device.manufacturer)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    if isActive {
                        Text("•")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.5))

                        Text(mode)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(device.themeColor)
                    }
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 10) {
                // Peak monitoring toggle
                Button(action: onTogglePeakMonitoring) {
                    Image(systemName: device.isMonitoring && mode == "Peak" ? "waveform.circle.fill" : "waveform.circle")
                        .foregroundColor(device.isMonitoring && mode == "Peak" ? device.themeColor : .secondary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .disabled(mode == "Spectrum")  // Only disable if THIS device is in spectrum mode
                .help("Peak Metering")

                // Spectrum mode toggle
                Button(action: onStartSpectrum) {
                    Image(systemName: mode == "Spectrum" ? "waveform.path.ecg.rectangle.fill" : "waveform.path.ecg.rectangle")
                        .foregroundColor(mode == "Spectrum" ? device.themeColor : .secondary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .help("Spectrum Analysis (Exclusive)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            ThemeRoundedRectangle(cornerRadius: 16)
                .fill(isActive ? device.themeColor.opacity(0.1) : Color.clear)
                .overlay(
                    ThemeRoundedRectangle(cornerRadius: 16)
                        .stroke(isActive ? device.themeColor.opacity(0.3) : Color.white.opacity(0.05), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // Allow tapping to toggle peak if this device isn't in spectrum mode
            if mode != "Spectrum" {
                onTogglePeakMonitoring()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    MultiDevicePickerView(manager: MultiDeviceAudioManager())
        .frame(width: 400)
        .padding()
        .background(Color.black)
}
