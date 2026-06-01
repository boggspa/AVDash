import SwiftUI
import CoreMIDI

/// A compact tile representing a MIDI device, matching the style of
/// virtual instrument tiles in the device list.
struct MIDIDeviceCard: View {
    let device: MIDIDeviceModel
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var midiManager: MIDIStateManager
    @State private var showEndpointsPopover = false

    var body: some View {
        VStack(spacing: 0) {
            midiDeviceInfoRow
                .frame(minWidth: 200)
                .padding()
                .background(ThemeRoundedRectangle(cornerRadius: 10, style: .continuous).themed(fill: themeManager.accentFillColor))
                .onTapGesture {
                    showEndpointsPopover = true
                }
                .popover(isPresented: $showEndpointsPopover) {
                    midiEndpointsPopover
                        .frame(width: 280)
                        .padding()
                }
        }
    }

    @ViewBuilder
    private var midiDeviceInfoRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text("\(device.manufacturer) | \(device.model)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text("\(device.inputEndpoints.count) in, \(device.outputEndpoints.count) out")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }

            Spacer()

            Button {
                showEndpointsPopover = true
            } label: {
                Image(systemName: "pianokeys")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show MIDI endpoints")
        }
    }

    @ViewBuilder
    private var midiEndpointsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(device.name)
                .font(.headline)
                .lineLimit(1)

            if !device.inputEndpoints.isEmpty {
                Text("Inputs")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(device.inputEndpoints, id: \.self) { endpoint in
                        Button {
                            midiManager.connectSource(endpoint)
                            showEndpointsPopover = false
                        } label: {
                            HStack {
                                Image(systemName: "arrow.down.right.circle")
                                    .font(.system(size: 12))
                                Text(getEndpointName(endpoint))
                                    .font(.system(size: 12))
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !device.outputEndpoints.isEmpty {
                Text("Outputs")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(device.outputEndpoints, id: \.self) { endpoint in
                        Button {
                            print("Selected output: \(getEndpointName(endpoint))")
                        } label: {
                            HStack {
                                Image(systemName: "arrow.up.right.circle")
                                    .font(.system(size: 12))
                                Text(getEndpointName(endpoint))
                                    .font(.system(size: 12))
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if device.inputEndpoints.isEmpty && device.outputEndpoints.isEmpty {
                Text("No endpoints available")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func getEndpointName(_ endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name)
        return name?.takeRetainedValue() as String? ?? "Unknown"
    }
}
