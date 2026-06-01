//
//  DeviceChannel.swift
//  AVCMeter
//
//  Created by Chris Izatt on 11/06/2025.
//
//
//  DeviceChannel.swift
//  AVCMeter
//
//  Created by Chris Izatt on 11/06/2025.
//
//
//  This file defines the structure for an individual audio channel on a device.
//  Each channel tracks two main audio metrics: RMS (volume over time) and Peak (loudest instant).
//  Used in AVCMeter to represent the state of each input channel.
//

import Foundation

// MARK: - Audio Channel Representation

/// Represents a single audio channel on a device.
/// Tracks both RMS (average loudness) and Peak (highest instant) levels.
struct DeviceChannel: Identifiable {
    /// Unique identifier for the channel (e.g., channel index)
    let id: Int
    /// RMS (Root Mean Square) level - reflects average loudness
    var rms: Float
    /// Peak level - reflects the highest recent loudness
    var peak: Float
}
