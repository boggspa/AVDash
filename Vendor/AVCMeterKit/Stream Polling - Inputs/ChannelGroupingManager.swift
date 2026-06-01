//
//  ChannelGroupingManager.swift
//  AVCMeter
//
//  Created by Chris Izatt on 13/06/2025.
//


import Foundation
import CoreAudio
import CoreGraphics

let defaultCapsuleHeight: CGFloat = 350

struct ChannelGroupingManager {
    static func groupChannelsPerDevice(activeDevices: [AudioDeviceID: DeviceMeteringContext], groupSize: Int = 64) -> [AudioDeviceID: [[Int]]] {
        var result: [AudioDeviceID: [[Int]]] = [:]

        for (deviceID, context) in activeDevices {
            let totalChannels = context.device.inputChannels

            // Validate that buffers are initialized correctly
            guard context.peakBuffer.count == context.rmsBuffer.count else {
                print("Skipping device \(deviceID): peak/rms buffer count mismatch")
                continue
            }

            // Insert: get mask for this device
            let mask = AudioDeviceManager.shared.selectedChannelMasks[deviceID] ?? Array(repeating: true, count: Int(totalChannels))

            var allGroups: [[Int]] = []
            var currentGroup: [Int] = []

            for channel in 0..<mask.count {
                if mask[channel] {
                    currentGroup.append(channel)
                    if currentGroup.count == groupSize {
                        allGroups.append(currentGroup)
                        currentGroup = []
                    }
                }
            }

            if !currentGroup.isEmpty {
                allGroups.append(currentGroup)
            }

            result[deviceID] = allGroups
        }

        return result
    }
}
