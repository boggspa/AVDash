//
//  ChannelPickerView.swift
//  AVCMeter
//
//  Created by Chris Izatt on 18/06/2025.
//

import CoreAudio
import SwiftUI

/// Represents a single audio channel with identification and selection state.
///
/// This struct conforms to `Identifiable` and `Hashable` protocols to be used efficiently in SwiftUI lists.
/// Each channel has a unique identifier, a display name, an index corresponding to its position,
/// and a boolean indicating whether the channel is currently selected.
struct Channel: Identifiable, Hashable {
    /// Unique identifier for the channel.
    let id = UUID()
    /// Display name of the channel.
    let name: String
    /// Index of the channel, typically corresponding to its position in the device's channel list.
    let index: Int
    /// Indicates whether the channel is selected for use.
    var isSelected: Bool
}

/// A SwiftUI view that allows users to pick and toggle audio input channels for a given audio device.
///
/// This view displays a list of channels with toggles to enable or disable each channel.
/// It also visualizes the input level of each channel using a vertical capsule bar.
/// The view interacts with Core Audio APIs to load channel information from the specified device,
/// and updates the channel selection state through a provided stream manager.
///
/// - Note: The view expects bindings to arrays of `Channel` and corresponding input levels,
///         so that changes propagate back to the parent view or model.
struct ChannelPickerView: View {
    /// Binding to an array of `Channel` representing the current channels and their selection states.
    @Binding var channels: [Channel]
    /// Binding to an array of `Float` values representing the input levels for each channel.
    @Binding var inputLevels: [Float]
    /// Title to display above the channel list, typically the device or input name.
    var title: String
    /// The Core Audio device ID for which channels are being displayed and managed.
    var deviceID: AudioDeviceID
    /// An observed object managing multiple device streams and channel masks.
    @ObservedObject var streamManager: MultiDeviceStreamManager
    @EnvironmentObject var themeManager: ThemeManager

    /// Loads the available input channels from the specified audio device using Core Audio APIs.
    ///
    /// This function queries the device's stream configuration property to retrieve the number of input channels,
    /// then constructs a list of `Channel` objects representing each input channel.
    /// All channels are initially marked as selected.
    ///
    /// - Returns: An array of `Channel` instances representing the input channels of the device.
    func loadChannels() -> [Channel] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        // Query the size of the stream configuration property data.
        guard AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize) == noErr else {
            print("[ChannelPickerView] Failed to get stream config size")
            return []
        }

        // Allocate memory for the AudioBufferList based on the size.
        let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            .assumingMemoryBound(to: AudioBufferList.self)
        defer { bufferListPointer.deallocate() }

        // Retrieve the actual stream configuration data into the buffer list.
        guard AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer) == noErr else {
            print("[ChannelPickerView] Failed to get stream config")
            return []
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        var channelIndex = 0
        var result: [Channel] = []

        // Iterate through each buffer and its channels to create Channel instances.
        for buffer in bufferList {
            for _ in 0..<Int(buffer.mNumberChannels) {
                result.append(Channel(name: "Input \(channelIndex + 1)", index: channelIndex, isSelected: true))
                channelIndex += 1
            }
        }
        return result
    }

    /// The main view body displaying the channel picker interface.
    ///
    /// This view consists of a vertical stack containing:
    /// - A title text displaying the provided title.
    /// - A list of toggles for each channel, allowing selection or deselection.
    /// - A visual representation of the input level for each channel using a green capsule.
    ///
    /// The view updates the stream manager's channel mask whenever a channel's selection changes.
    /// It also reloads channels when the device ID changes or when the view appears if no channels are loaded.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Display the title with headline font.
            Text(title)
                .font(.headline)

            // Iterate over the binding array of channels to create toggles and level indicators.
            ForEach($channels) { $channel in
                HStack {
                    // Toggle to enable or disable the channel.
                    Toggle(isOn: $channel.isSelected) {
                        Text("Channel \(channel.index + 1): \(channel.name)")
                            .font(.subheadline)
                            .accessibilityLabel("Channel \(channel.index + 1) \(channel.name)")
                    }
                    // Update the stream manager's channel mask when the toggle changes.
                    .onChange(of: channel.isSelected) { _ in
                        streamManager.updateChannelMask(for: deviceID, mask: channels.map(\.isSelected))
                    }

                    // Visual representation of the input level as a vertical green capsule.
                    Capsule()
                        .frame(width: 6, height: 40 * CGFloat(min(inputLevels[safe: channel.index] ?? 0, 1.0)))
                        .foregroundColor(channelStripColor(for: themeManager.deviceChannelStripColors[deviceID] ?? .standard))
                        .padding(.leading, 4)
                }
            }
        }
        .padding()
        // Load channels when the view appears if none are loaded and no cached mask exists.
        .onAppear {
            if channels.isEmpty && streamManager.channelMaskCache[deviceID] == nil {
                channels = loadChannels()
            }
        }
        // Reload channels when the device ID changes.
        .onChange(of: deviceID) { _ in
            channels = loadChannels()
        }
    }
}

#Preview {
    ChannelPickerView(
        channels: .constant([
            Channel(name: "Mic 1", index: 0, isSelected: true),
            Channel(name: "Mic 2", index: 1, isSelected: false),
            Channel(name: "System Audio", index: 2, isSelected: false)
        ]),
        inputLevels: .constant([0.2, 0.6, 0.1]),
        title: "Input Channels",
        deviceID: 0,
        streamManager: MultiDeviceStreamManager()
    )
}

import Foundation

extension Collection {
    /// Safely returns the element at the specified index if it exists within the collection's bounds.
    ///
    /// - Parameter index: The index of the element to retrieve.
    /// - Returns: The element at `index` if it is within bounds; otherwise, `nil`.
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

// Add the following where visual input routing should appear:
/*
ForEach(Array(selectedDevices), id: \.self) { deviceID in
    if let device = manager.inputDevices.first(where: { $0.deviceID == deviceID }) {
        let maskBinding = Binding<[Channel]>(
            get: {
                let mask = manager.selectedChannelMasks[deviceID, default: Array(repeating: true, count: device.inputChannels)]
                return mask.enumerated().map { Channel(name: "Ch \($0.offset + 1)", index: $0.offset, isSelected: $0.element) }
            },
            set: { newChannels in
                manager.selectedChannelMasks[deviceID] = newChannels.map(\.isSelected)
                streamManager.updateChannelMask(for: deviceID, mask: newChannels.map(\.isSelected))
            }
        )

        ChannelPickerView(
            channels: maskBinding,
            inputLevels: streamManager.activePollers[deviceID]?.inputLevels ?? [],
            title: device.name,
            deviceID: deviceID,
            streamManager: streamManager
        )
        .padding(.bottom)
    }
}
*/

// MARK: - OutputChannelPickerView

/// A SwiftUI view that allows users to pick and toggle audio output channels for a given audio device.
///
/// This view displays a list of output channels with toggles to enable or disable each channel.
/// It also visualizes the output level of each channel using a vertical capsule bar.
/// The view interacts with Core Audio APIs to load channel information from the specified device,
/// and updates the channel selection state through a provided output manager.
///
/// - Note: The view expects bindings to arrays of `Channel` and corresponding output levels,
///         so that changes propagate back to the parent view or model.
struct OutputChannelPickerView: View {
    /// Binding to an array of `Channel` representing the current channels and their selection states.
    @Binding var channels: [Channel]
    /// Binding to an array of `Float` values representing the output levels for each channel.
    @Binding var outputLevels: [Float]
    /// Title to display above the channel list, typically the device or output name.
    var title: String
    /// The Core Audio device ID for which channels are being displayed and managed.
    var deviceID: AudioDeviceID
    /// An observed object managing output device streams and channel masks.
    @ObservedObject var outputManager: OutputDeviceManager
    @EnvironmentObject var themeManager: ThemeManager

    /// Loads the available output channels from the specified audio device using Core Audio APIs.
    ///
    /// This function queries the device's stream configuration property to retrieve the number of output channels,
    /// then constructs a list of `Channel` objects representing each output channel.
    /// All channels are initially marked as selected.
    ///
    /// - Returns: An array of `Channel` instances representing the output channels of the device.
    func loadChannels() -> [Channel] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        // Query the size of the stream configuration property data.
        guard AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize) == noErr else {
            print("[OutputChannelPickerView] Failed to get stream config size")
            return []
        }

        // Allocate memory for the AudioBufferList based on the size.
        let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            .assumingMemoryBound(to: AudioBufferList.self)
        defer { bufferListPointer.deallocate() }

        // Retrieve the actual stream configuration data into the buffer list.
        guard AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer) == noErr else {
            print("[OutputChannelPickerView] Failed to get stream config")
            return []
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        var channelIndex = 0
        var result: [Channel] = []

        // Iterate through each buffer and its channels to create Channel instances.
        for buffer in bufferList {
            for _ in 0..<Int(buffer.mNumberChannels) {
                result.append(Channel(name: "Output \(channelIndex + 1)", index: channelIndex, isSelected: true))
                channelIndex += 1
            }
        }
        return result
    }

    /// The main view body displaying the output channel picker interface.
    ///
    /// This view consists of a vertical stack containing:
    /// - A title text displaying the provided title.
    /// - A list of toggles for each channel, allowing selection or deselection.
    /// - A visual representation of the output level for each channel using a blue capsule.
    ///
    /// The view updates the output manager's channel mask whenever a channel's selection changes.
    /// It also reloads channels when the device ID changes or when the view appears if no channels are loaded.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Display the title with headline font.
            Text(title)
                .font(.headline)

            // Iterate over the binding array of channels to create toggles and level indicators.
            ForEach($channels) { $channel in
                HStack {
                    // Toggle to enable or disable the channel.
                    Toggle(isOn: $channel.isSelected) {
                        Text("Channel \(channel.index + 1): \(channel.name)")
                            .font(.subheadline)
                            .accessibilityLabel("Channel \(channel.index + 1) \(channel.name)")
                    }
                    // Update the output manager's channel mask when the toggle changes.
                    .onChange(of: channel.isSelected) { _ in
                        outputManager.updateChannelMask(for: deviceID, mask: channels.map(\.isSelected))
                    }

                    // Visual representation of the output level as a vertical blue capsule.
                    Capsule()
                        .frame(width: 6, height: 40 * CGFloat(min(outputLevels[safe: channel.index] ?? 0, 1.0)))
                        .foregroundColor(channelStripColor(for: themeManager.deviceChannelStripColors[deviceID] ?? .standard))
                        .padding(.leading, 4)
                }
            }
        }
        .padding()
        // Load channels when the view appears if none are loaded and no cached mask exists.
        .onAppear {
            if channels.isEmpty && outputManager.selectedChannelMasks[deviceID] == nil {
                channels = loadChannels()
            }
        }
        // Reload channels when the device ID changes.
        .onChange(of: deviceID) { _ in
            channels = loadChannels()
        }
    }
}

func channelStripColor(for style: ChannelStripColor) -> Color {
    switch style {
    case .standard: return Color.black.opacity(0.3)
    case .red: return Color.red.opacity(0.1)
    case .blue: return Color.blue.opacity(0.1)
    case .green: return Color.green.opacity(0.1)
    case .orange: return Color.orange.opacity(0.1)
    case .yellow: return Color.yellow.opacity(0.1)
    case .gray: return Color.gray.opacity(0.1)
    case .white: return Color.white.opacity(0.1)
    case .mint: return Color(red: 0.62, green: 0.96, blue: 0.78).opacity(0.1)
    case .pink: return Color.pink.opacity(0.1)
    case .purple: return Color.purple.opacity(0.1)
    }
}
