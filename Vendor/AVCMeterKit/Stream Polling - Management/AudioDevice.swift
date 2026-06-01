///
///  AudioDevice.swift
///  AVCMeter
///
///  This file defines the AudioDevice struct, which represents an audio input/output device on macOS.
///  It includes properties such as device name, channel counts, sample rate, and transport type.
///  It also contains a helper function to retrieve the UID of a given device using CoreAudio APIs.
///

import Foundation
import CoreAudio

/// A struct that represents an audio device, including identifying info and capabilities.
struct AudioDevice: Identifiable {
    var id: AudioDeviceID { deviceID }
    let deviceID: AudioDeviceID
    let name: String
    let inputChannels: UInt32
    let outputChannels: UInt32
    let sampleRate: Float64
    let transportType: String
    let uid: String

    /// Initializes a new AudioDevice with provided CoreAudio device properties.
    /// Automatically retrieves and sets the UID using a helper function.
    init(deviceID: AudioDeviceID, name: String, inputChannels: UInt32, outputChannels: UInt32, sampleRate: Float64, transportType: String) {
        self.deviceID = deviceID
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.sampleRate = sampleRate
        self.transportType = transportType
        self.uid = getDeviceUID(deviceID: deviceID) ?? ""
    }
}

/// Retrieves the unique identifier (UID) for a given audio device using CoreAudio APIs.
///
/// This function queries the `kAudioDevicePropertyDeviceUID` property for the given
/// `AudioDeviceID` using `AudioObjectGetPropertyData`.
///
/// - Parameter deviceID: The CoreAudio device ID to query.
/// - Returns: The UID string of the device, or `nil` if retrieval fails.
func getDeviceUID(deviceID: AudioDeviceID) -> String? {
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMaster
    )

    var uid: CFString = "" as CFString
    var dataSize = UInt32(MemoryLayout<CFString>.size)

    let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &uid)
    return status == noErr ? uid as String : nil
}
