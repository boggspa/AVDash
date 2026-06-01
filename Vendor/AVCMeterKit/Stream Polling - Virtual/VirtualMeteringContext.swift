//
//  VirtualMeteringContext.swift
//  AVCMeter
//
//  Created by Chris Izatt on 07/07/2025.
//

import Foundation
import CoreAudio

@_silgen_name("Mixer_GetAuxSendPeak")
private func Mixer_GetAuxSendPeak(_ busIndex: UInt32) -> Float

@_silgen_name("Mixer_GetAuxSendRMS")
private func Mixer_GetAuxSendRMS(_ busIndex: UInt32) -> Float

@_silgen_name("Mixer_GetFXSendPeak")
private func Mixer_GetFXSendPeak(_ busIndex: UInt32) -> Float

@_silgen_name("Mixer_GetFXSendRMS")
private func Mixer_GetFXSendRMS(_ busIndex: UInt32) -> Float

@_silgen_name("Mixer_GetAuxReturnPeak")
private func Mixer_GetAuxReturnPeak(_ busIndex: UInt32) -> Float

@_silgen_name("Mixer_GetAuxReturnRMS")
private func Mixer_GetAuxReturnRMS(_ busIndex: UInt32) -> Float

@_silgen_name("Mixer_GetFXReturnPeak")
private func Mixer_GetFXReturnPeak(_ busIndex: UInt32) -> Float

@_silgen_name("Mixer_GetFXReturnRMS")
private func Mixer_GetFXReturnRMS(_ busIndex: UInt32) -> Float

/// A logical grouping of virtual audio channels (not tied to HAL/CoreAudio devices).
struct VirtualMeteringContext: Identifiable {
    var deviceID: AudioDeviceID = 0
    let id = UUID()
    let name: String
    var channels: [VirtualChannel]

    // Simulated metering (can be fed by render engine or mock/test data)
    var peakLevels: [Float]
    var rmsLevels: [Float]

    init(name: String, channels: [VirtualChannel], deviceID: AudioDeviceID = 0) {
        self.name = name
        self.channels = channels
        self.deviceID = deviceID
        self.peakLevels = Array(repeating: 0.0, count: channels.count)
        self.rmsLevels = Array(repeating: 0.0, count: channels.count)
    }

    // Accessors
    func peak(for index: Int) -> Float {
        guard channels.indices.contains(index) else { return 0.0 }

        switch channels[index].type {
        case .auxSend:
            return Mixer_GetAuxSendPeak(UInt32(index))
        case .fxSend:
            return Mixer_GetFXSendPeak(UInt32(index))
        case .auxReturn:
            return Mixer_GetAuxReturnPeak(UInt32(index))
        case .fxReturn:
            return Mixer_GetFXReturnPeak(UInt32(index))
        default:
            guard index < peakLevels.count else { return 0.0 }
            return peakLevels[index]
        }
    }

    func rms(for index: Int) -> Float {
        guard channels.indices.contains(index) else { return 0.0 }

        switch channels[index].type {
        case .auxSend:
            return Mixer_GetAuxSendRMS(UInt32(index))
        case .fxSend:
            return Mixer_GetFXSendRMS(UInt32(index))
        case .auxReturn:
            return Mixer_GetAuxReturnRMS(UInt32(index))
        case .fxReturn:
            return Mixer_GetFXReturnRMS(UInt32(index))
        default:
            guard index < rmsLevels.count else { return 0.0 }
            return rmsLevels[index]
        }
    }
}
