//
//  AudioBridgeConfig.swift
//  AVCMeter
//
//  Created by Chris Izatt on 13/06/2025.
//

import Foundation

/// Defines the operating mode of the audio bridge
enum AudioBridgeMode {
    case transmit
    case receive
}

/// Configuration used to set up the audio bridge stream
struct AudioBridgeConfig: Equatable {
    var sampleRate: Double
    var numChannels: Int
    var frameSize: Int         // Number of samples per frame (usually matches audio engine block size)
    var port: UInt16
    var mode: AudioBridgeMode
    var isEnabled: Bool = false
    var preferredDeviceName: String? = nil // Optional device label filter (for future use)
    var destinationHost: String = "127.0.0.1"

    static let defaultTX = AudioBridgeConfig(
        sampleRate: 48000,
        numChannels: 2,
        frameSize: 2048,
        port: 52001,
        mode: .transmit,
        destinationHost: "127.0.0.1"
    )

    static let defaultRX = AudioBridgeConfig(
        sampleRate: 48000,
        numChannels: 2,
        frameSize: 2048,
        port: 52001,
        mode: .receive,
        destinationHost: "127.0.0.1"
    )
}
