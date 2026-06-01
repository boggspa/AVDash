//
//  ChannelStateManager.swift
//  AVCMeter
//
//  Created by Chris Izatt on 07/07/2025.
//

import Foundation
import AudioToolbox

let MIXER_CHANNEL_INPUT: UInt32 = 0
let MIXER_CHANNEL_OUTPUT: UInt32 = 1
let MIXER_VIRTUAL_BUS_AUX_SEND: UInt32 = 0
let MIXER_VIRTUAL_BUS_FX_SEND: UInt32 = 1
let MIXER_VIRTUAL_BUS_AUX_RETURN: UInt32 = 2
let MIXER_VIRTUAL_BUS_FX_RETURN: UInt32 = 3


@_silgen_name("Mixer_SetChannelFader")
func Mixer_SetChannelFader(_ globalChannelIndex: Int32, _ value: Float)

@_silgen_name("Mixer_SetChannelGain")
func Mixer_SetChannelGain(_ globalChannelIndex: Int32, _ gain: Float)

@_silgen_name("Mixer_SetChannelPan")
func Mixer_SetChannelPan(_ globalChannelIndex: Int32, _ pan: Float)

@_silgen_name("Mixer_SetChannelAuxSend")
func Mixer_SetChannelAuxSend(_ globalChannelIndex: Int32, _ sendLevel: Float)

@_silgen_name("Mixer_SetChannelFXSend")
func Mixer_SetChannelFXSend(_ globalChannelIndex: Int32, _ sendLevel: Float)

@_silgen_name("Mixer_SetChannelAuxSendBus")
func Mixer_SetChannelAuxSendBus(_ globalChannelIndex: Int32, _ busIndex: UInt32)

@_silgen_name("Mixer_SetChannelFXSendBus")
func Mixer_SetChannelFXSendBus(_ globalChannelIndex: Int32, _ busIndex: UInt32)

@_silgen_name("Mixer_SetChannelAuxSendPreFade")
func Mixer_SetChannelAuxSendPreFade(_ globalChannelIndex: Int32, _ preFade: Int32)

@_silgen_name("Mixer_SetChannelFXSendPreFade")
func Mixer_SetChannelFXSendPreFade(_ globalChannelIndex: Int32, _ preFade: Int32)

@_silgen_name("Mixer_GetChannelAuxSendPreFade")
func Mixer_GetChannelAuxSendPreFade(_ globalChannelIndex: Int32) -> Int32

@_silgen_name("Mixer_GetChannelFXSendPreFade")
func Mixer_GetChannelFXSendPreFade(_ globalChannelIndex: Int32) -> Int32

@_silgen_name("Mixer_SetChannelEQConfig")
func Mixer_SetChannelEQConfig(_ globalChannelIndex: Int32, _ config: MixerEQConfig)

@_silgen_name("Mixer_SetChannelDynamicsConfig")
func Mixer_SetChannelDynamicsConfig(_ globalChannelIndex: Int32, _ config: MixerDynamicsConfig)

@_silgen_name("Mixer_SetVirtualBusEQConfig")
func Mixer_SetVirtualBusEQConfig(_ busType: UInt32, _ busIndex: UInt32, _ config: MixerEQConfig)

@_silgen_name("Mixer_SetVirtualBusDynamicsConfig")
func Mixer_SetVirtualBusDynamicsConfig(_ busType: UInt32, _ busIndex: UInt32, _ config: MixerDynamicsConfig)

@_silgen_name("Mixer_GetVirtualBusGainReduction")
func Mixer_GetVirtualBusGainReduction(_ busType: UInt32, _ busIndex: UInt32) -> Float

@_silgen_name("Mixer_GetChannelGainReduction")
func Mixer_GetChannelGainReduction(_ globalChannelIndex: UInt32) -> Float

// Added mute bridging to new Mixer.c C API
@_silgen_name("Mixer_SetChannelMute")
func Mixer_SetChannelMute(_ globalChannelIndex: Int32, _ mute: Int32)

@_silgen_name("Mixer_GetChannelMute")
func Mixer_GetChannelMute(_ globalChannelIndex: Int32) -> Int32

@_silgen_name("Mixer_SetChannelSolo")
func Mixer_SetChannelSolo(_ globalChannelIndex: Int32, _ solo: Int32)

@_silgen_name("Mixer_GetChannelSolo")
func Mixer_GetChannelSolo(_ globalChannelIndex: Int32) -> Int32

@_silgen_name("Mixer_GetGlobalChannelIndex")
func Mixer_GetGlobalChannelIndex(_ deviceID: UInt32, _ type: UInt32, _ deviceChannelIndex: UInt32) -> Int32

@_silgen_name("Mixer_SetChannelPolarity")
func Mixer_SetChannelPolarity(_ globalChannelIndex: Int32, _ flipped: Int32)

@_silgen_name("Mixer_GetChannelPolarity")
func Mixer_GetChannelPolarity(_ globalChannelIndex: Int32) -> Int32

@_silgen_name("Mixer_SetChannelDelay")
func Mixer_SetChannelDelay(_ globalChannelIndex: Int32, _ delaySamples: UInt32)

@_silgen_name("Mixer_GetChannelDelay")
func Mixer_GetChannelDelay(_ globalChannelIndex: Int32) -> UInt32

private func mixerGlobalChannelIndex(deviceID: AudioDeviceID, type: UInt32, channel: Int) -> Int32? {
    guard channel >= 0 else { return nil }
    let globalChannelIndex = Mixer_GetGlobalChannelIndex(deviceID, type, UInt32(channel))
    return globalChannelIndex >= 0 ? globalChannelIndex : nil
}

private func mixerGlobalInputChannelIndex(deviceID: AudioDeviceID, channel: Int) -> Int32? {
    mixerGlobalChannelIndex(deviceID: deviceID, type: MIXER_CHANNEL_INPUT, channel: channel)
}

private func mixerGlobalOutputChannelIndex(deviceID: AudioDeviceID, channel: Int) -> Int32? {
    mixerGlobalChannelIndex(deviceID: deviceID, type: MIXER_CHANNEL_OUTPUT, channel: channel)
}

private func mixerEQConfig(from settings: InputChannelEQSettings) -> MixerEQConfig {
    var config = MixerEQConfig()
    config.enabled = settings.enabled ? 1 : 0
    config.highPassEnabled = settings.highPassEnabled ? 1 : 0
    config.highPassFilterType = UInt32(settings.highPassFilterType.rawValue)
    config.highPassSlope = UInt32(settings.highPassSlope.rawValue)
    config.highPassFrequencyHz = Float(settings.highPassFrequencyHz)

    config.lowEnabled = settings.lowEnabled ? 1 : 0
    config.lowFilterType = UInt32(settings.lowFilterType.rawValue)
    config.lowSlope = UInt32(settings.lowSlope.rawValue)
    config.lowGainDB = Float(settings.lowGainDB)
    config.lowCenterFrequencyHz = Float(settings.lowCenterFrequencyHz)
    config.lowQ = Float(settings.lowQ)

    config.lowMidEnabled = settings.lowMidEnabled ? 1 : 0
    config.lowMidFilterType = UInt32(settings.lowMidFilterType.rawValue)
    config.lowMidSlope = UInt32(settings.lowMidSlope.rawValue)
    config.lowMidGainDB = Float(settings.lowMidGainDB)
    config.lowMidCenterFrequencyHz = Float(settings.lowMidCenterFrequencyHz)
    config.lowMidQ = Float(settings.lowMidQ)

    config.midEnabled = settings.midEnabled ? 1 : 0
    config.midFilterType = UInt32(settings.midFilterType.rawValue)
    config.midSlope = UInt32(settings.midSlope.rawValue)
    config.midGainDB = Float(settings.midGainDB)
    config.midCenterFrequencyHz = Float(settings.midCenterFrequencyHz)
    config.midQ = Float(settings.midQ)

    config.presenceEnabled = settings.presenceEnabled ? 1 : 0
    config.presenceFilterType = UInt32(settings.presenceFilterType.rawValue)
    config.presenceSlope = UInt32(settings.presenceSlope.rawValue)
    config.presenceGainDB = Float(settings.presenceGainDB)
    config.presenceCenterFrequencyHz = Float(settings.presenceCenterFrequencyHz)
    config.presenceQ = Float(settings.presenceQ)

    config.highEnabled = settings.highEnabled ? 1 : 0
    config.highFilterType = UInt32(settings.highFilterType.rawValue)
    config.highSlope = UInt32(settings.highSlope.rawValue)
    config.highGainDB = Float(settings.highGainDB)
    config.highCenterFrequencyHz = Float(settings.highCenterFrequencyHz)
    config.highQ = Float(settings.highQ)

    config.lowPassEnabled = settings.lowPassEnabled ? 1 : 0
    config.lowPassFilterType = UInt32(settings.lowPassFilterType.rawValue)
    config.lowPassSlope = UInt32(settings.lowPassSlope.rawValue)
    config.lowPassFrequencyHz = Float(settings.lowPassFrequencyHz)
    return config
}

private func mixerDynamicsConfig(from settings: InputChannelDynamicsSettings) -> MixerDynamicsConfig {
    var config = MixerDynamicsConfig()
    config.enabled = settings.enabled ? 1 : 0
    config.thresholdDB = Float(settings.thresholdDB)
    config.ratio = Float(settings.ratio)
    config.attackMilliseconds = Float(settings.attackMilliseconds)
    config.releaseMilliseconds = Float(settings.releaseMilliseconds)
    config.makeupGainDB = Float(settings.makeupGainDB)
    config.mix = Float(settings.mix)
    config.limiterEnabled = settings.limiterEnabled ? 1 : 0
    config.limiterCeilingDB = Float(settings.limiterCeilingDB)
    return config
}

private func mixerVirtualBusType(for channelType: VirtualChannelType) -> UInt32? {
    switch channelType {
    case .auxSend:
        return MIXER_VIRTUAL_BUS_AUX_SEND
    case .fxSend:
        return MIXER_VIRTUAL_BUS_FX_SEND
    case .auxReturn:
        return MIXER_VIRTUAL_BUS_AUX_RETURN
    case .fxReturn:
        return MIXER_VIRTUAL_BUS_FX_RETURN
    case .dca, .virtualInstrument:
        return nil
    }
}



// Note: This directly bridges to the new Mixer.c C API.

enum ChannelControlProperty {
    case mute(Bool)
    case solo(Bool)
    case link(Bool)
    case pan(Float)
    case fader(Float)
    case auxSend(Float)
    case fxSend(Float)
    case auxSendBus(Int)
    case fxSendBus(Int)
    case postGain(Float)
    // Add more properties as needed
}

struct ChannelStripState: Identifiable {
    let id: String
    var isMuted: Bool = false
    var isSoloed: Bool = false
    var isLinked: Bool = false
    var panValue: Float = 63.0 // range 0.0 (Left) to 1.0 (Right)
    /// The faderValue range is 0.0 (mute) to 1.2 (headroom)
    var faderValue: Float = 1.0 // range 0.0 (mute) to 1.2 (headroom)
    var auxSendValue: Float = 0.0 // range 0.0 (dry) to 1.0 (max send)
    var fxSendValue: Float = 0.0 // range 0.0 (dry) to 1.0 (max send)
    var selectedAuxSendIndex: Int = 0
    var selectedFXSendIndex: Int = 0
    /// This postGainValue is always set from the anchor (even) channel when linked.
    var postGainValue: Float = 1.0 // range 1.0 (min) to 28.0 (max)

    var minDB: Float = -60.0
    var maxDB: Float = 0.0

    var isPolarityFlipped: Bool = false
    var delayMs: Double = 0.0
}

struct VirtualChannelState: Identifiable {
    let id: UUID
    var isMuted: Bool = false
    var isSoloed: Bool = false
    var isLinked: Bool = false
    var panValue: Float = 63.0
    /// The faderValue range is 0.0 (mute) to 1.2 (headroom)
    var faderValue: Float = 1.0 // range 0.0 (mute) to 1.2 (headroom)
    var auxSendValue: Float = 0.0
    var fxSendValue: Float = 0.0
    var selectedAuxSendIndex: Int = 0
    var selectedFXSendIndex: Int = 0
    var postGainValue: Float = 1.0
}

final class ChannelBubbleStore: ObservableObject {
    static let shared = ChannelBubbleStore()
    @Published var states: [String: ChannelBubbleState] = [:]
}

enum EQFilterFamily: Int, CaseIterable, Hashable {
    case butterworth = 0
    case chebyshev = 1
    case bessel = 2
    case linkwitzRiley = 3
}

enum EQFilterSlope: Int, CaseIterable, Hashable {
    case db6 = 0
    case db12 = 1
    case db24 = 2
    case db48 = 3

    var dbPerOctave: Int {
        switch self {
        case .db6: return 6
        case .db12: return 12
        case .db24: return 24
        case .db48: return 48
        }
    }
}

enum EQBandKind: CaseIterable {
    case highPass
    case low
    case lowMid
    case mid
    case presence
    case high
    case lowPass
}

struct InputChannelEQSettings: Hashable {
    var enabled = false

    var highPassEnabled = false
    var highPassFilterType: EQFilterFamily = .butterworth
    var highPassSlope: EQFilterSlope = .db12
    var highPassFrequencyHz = 80.0

    var lowEnabled = true
    var lowFilterType: EQFilterFamily = .butterworth
    var lowSlope: EQFilterSlope = .db12
    var lowGainDB = 0.0
    var lowCenterFrequencyHz = 120.0
    var lowQ = 0.8

    var lowMidEnabled = true
    var lowMidFilterType: EQFilterFamily = .butterworth
    var lowMidSlope: EQFilterSlope = .db12
    var lowMidGainDB = 0.0
    var lowMidCenterFrequencyHz = 420.0
    var lowMidQ = 1.0

    var midEnabled = true
    var midFilterType: EQFilterFamily = .butterworth
    var midSlope: EQFilterSlope = .db12
    var midGainDB = 0.0
    var midCenterFrequencyHz = 1_000.0
    var midQ = 1.0

    var presenceEnabled = true
    var presenceFilterType: EQFilterFamily = .butterworth
    var presenceSlope: EQFilterSlope = .db12
    var presenceGainDB = 0.0
    var presenceCenterFrequencyHz = 4_200.0
    var presenceQ = 1.0

    var highEnabled = true
    var highFilterType: EQFilterFamily = .butterworth
    var highSlope: EQFilterSlope = .db12
    var highGainDB = 0.0
    var highCenterFrequencyHz = 8_000.0
    var highQ = 0.8

    var lowPassEnabled = false
    var lowPassFilterType: EQFilterFamily = .butterworth
    var lowPassSlope: EQFilterSlope = .db12
    var lowPassFrequencyHz = 16_000.0

    mutating func resetBand(_ band: EQBandKind) {
        switch band {
        case .highPass:
            highPassEnabled = false
            highPassFilterType = .butterworth
            highPassSlope = .db12
            highPassFrequencyHz = 80.0
        case .low:
            lowEnabled = true
            lowFilterType = .butterworth
            lowSlope = .db12
            lowGainDB = 0.0
            lowCenterFrequencyHz = 120.0
            lowQ = 0.8
        case .lowMid:
            lowMidEnabled = true
            lowMidFilterType = .butterworth
            lowMidSlope = .db12
            lowMidGainDB = 0.0
            lowMidCenterFrequencyHz = 420.0
            lowMidQ = 1.0
        case .mid:
            midEnabled = true
            midFilterType = .butterworth
            midSlope = .db12
            midGainDB = 0.0
            midCenterFrequencyHz = 1_000.0
            midQ = 1.0
        case .presence:
            presenceEnabled = true
            presenceFilterType = .butterworth
            presenceSlope = .db12
            presenceGainDB = 0.0
            presenceCenterFrequencyHz = 4_200.0
            presenceQ = 1.0
        case .high:
            highEnabled = true
            highFilterType = .butterworth
            highSlope = .db12
            highGainDB = 0.0
            highCenterFrequencyHz = 8_000.0
            highQ = 0.8
        case .lowPass:
            lowPassEnabled = false
            lowPassFilterType = .butterworth
            lowPassSlope = .db12
            lowPassFrequencyHz = 16_000.0
        }
    }

    mutating func resetAllBands() {
        for band in EQBandKind.allCases {
            resetBand(band)
        }
    }
}

struct InputChannelDynamicsSettings: Hashable {
    var enabled = false
    var thresholdDB = -18.0
    var ratio = 3.0
    var attackMilliseconds = 20.0
    var releaseMilliseconds = 250.0
    var makeupGainDB = 0.0
    var mix = 1.0
    var limiterEnabled = true
    var limiterCeilingDB = -1.0
}

struct ChannelBubbleState: Equatable {
    var showDB: Bool = false
    var dbValue: Double = -100.0
    var showPan: Bool = false
    var panValue: Double = 0.0
    var lastUpdated: Date = .distantPast
}

private func setDeviceChannelProperty(deviceID: AudioDeviceID, channel: Int, property: ChannelControlProperty) {
    switch property {
    case .mute(let flag):
        if let globalChannelIndex = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: channel) {
            Mixer_SetChannelMute(globalChannelIndex, flag ? 1 : 0)
        }
    case .solo(let flag):
        if let globalChannelIndex = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: channel) {
            Mixer_SetChannelSolo(globalChannelIndex, flag ? 1 : 0)
        }
    case .link(let flag):
        MixerEngine_SetLink(deviceID: UInt32(deviceID), channel: Int32(channel), link: flag)
    case .pan(let value):
        MixerEngine_SetPan(deviceID: UInt32(deviceID), channel: Int32(channel), pan: value)
    case .fader(let value):
        if let globalChannelIndex = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: channel) {
            Mixer_SetChannelFader(globalChannelIndex, value)
        }
    case .auxSend(let value):
        MixerEngine_SetAuxSend(deviceID: UInt32(deviceID), channel: Int32(channel), auxSend: value)
    case .fxSend(let value):
        MixerEngine_SetFXSend(deviceID: UInt32(deviceID), channel: Int32(channel), fxSend: value)
    case .auxSendBus(let value):
        if let globalChannelIndex = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: channel) {
            Mixer_SetChannelAuxSendBus(globalChannelIndex, UInt32(max(0, value)))
        }
    case .fxSendBus(let value):
        if let globalChannelIndex = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: channel) {
            Mixer_SetChannelFXSendBus(globalChannelIndex, UInt32(max(0, value)))
        }
    case .postGain(let value):
        if let globalChannelIndex = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: channel) {
            Mixer_SetChannelGain(globalChannelIndex, value)
        }
        RingBuffer_SetPostGain(Int32(channel), value)
    }
}

private func extractChannelNumber(from key: String) -> Int {
    // Assumes the key is in the format "DEVICEID-CHANNEL"
    let parts = key.split(separator: "-")
    return parts.last.flatMap { Int($0) } ?? 0
}

@objc public class ChannelStateBridge: NSObject {
    @objc public static func getInputChannelMute(_ deviceID: UInt32, _ channelIndex: Int32) -> Bool {
        return ChannelStateManager.shared.isMuted(deviceID: deviceID, channel: Int(channelIndex))
    }

    @objc public static func isOutputChannelMuted(_ deviceID: UInt32, _ channelIndex: Int32) -> Bool {
        return ChannelStateManager.shared.isOutputMuted(deviceID: deviceID, channel: Int(channelIndex))
    }
}

@_cdecl("IsInputChannelMuted")
public func getInputChannelMute(_ deviceID: UInt32, _ channelIndex: Int32) -> Bool {
    return ChannelStateBridge.getInputChannelMute(deviceID, channelIndex)
}

@_cdecl("IsOutputChannelMuted")
public func IsOutputChannelMuted(_ deviceID: UInt32, _ channelIndex: Int32) -> Bool {
    return ChannelStateBridge.isOutputChannelMuted(deviceID, channelIndex)
}

@_cdecl("MixerEngine_SetMute")
func MixerEngine_SetMute(deviceID: UInt32, channel: Int32, mute: Bool) {
    // Call into C++ or set state via a C bridge
}

@_cdecl("MixerEngine_SetSolo")
func MixerEngine_SetSolo(deviceID: UInt32, channel: Int32, solo: Bool) {
    // Call into C++ or set state via a C bridge
}

@_cdecl("MixerEngine_SetLink")
func MixerEngine_SetLink(deviceID: UInt32, channel: Int32, link: Bool) {
    // Call into C++ or set state via a C bridge
}

@_cdecl("MixerEngine_SetPan")
func MixerEngine_SetPan(deviceID: UInt32, channel: Int32, pan: Float) {
    guard channel >= 0,
          let globalChannelIndex = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: Int(channel)) else {
        return
    }
    Mixer_SetChannelPan(globalChannelIndex, pan / 127.0)
}

@_cdecl("MixerEngine_SetAuxSend")
func MixerEngine_SetAuxSend(deviceID: UInt32, channel: Int32, auxSend: Float) {
    guard channel >= 0,
          let globalChannelIndex = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: Int(channel)) else {
        return
    }
    Mixer_SetChannelAuxSend(globalChannelIndex, max(0.0, min(auxSend / 127.0, 1.0)))
}

@_cdecl("MixerEngine_SetFXSend")
func MixerEngine_SetFXSend(deviceID: UInt32, channel: Int32, fxSend: Float) {
    guard channel >= 0,
          let globalChannelIndex = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: Int(channel)) else {
        return
    }
    Mixer_SetChannelFXSend(globalChannelIndex, max(0.0, min(fxSend / 127.0, 1.0)))
}


struct Route: Hashable {
    let input: Int
    let output: Int
}

final class RoutingBridge {
    static let shared = RoutingBridge()

    private let lock = NSLock()
    private var activeRoutes: Set<Route> = []
    private var explicitOutputs: Set<Int> = []

    func markRoute(from input: Int, to output: Int, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }

        let route = Route(input: input, output: output)
        explicitOutputs.insert(output)
        if enabled {
            activeRoutes.insert(route)
        } else {
            activeRoutes.remove(route)
        }
    }

    func isRouteActive(from input: Int, to output: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeRoutes.contains(Route(input: input, output: output))
    }

    func hasAnyRoutes() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !explicitOutputs.isEmpty
    }

    func hasExplicitRouting(to output: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return explicitOutputs.contains(output)
    }

    func replaceRoutes(activeRoutes: Set<Route>, explicitOutputs: Set<Int>) {
        lock.lock()
        defer { lock.unlock() }
        self.activeRoutes = activeRoutes
        self.explicitOutputs = explicitOutputs
    }
}

@_cdecl("MixerRoute_HasAnyRoutes")
public func MixerRoute_HasAnyRoutes() -> Bool {
    RoutingBridge.shared.hasAnyRoutes()
}

@_cdecl("MixerRoute_HasExplicitRoutesForOutput")
public func MixerRoute_HasExplicitRoutesForOutput(_ outputDeviceID: UInt32, _ outputChannelIndex: Int32) -> Bool {
    let output = (Int(outputDeviceID) << 8) | Int(outputChannelIndex)
    return RoutingBridge.shared.hasExplicitRouting(to: output)
}

@_cdecl("MixerRoute_IsActive")
public func MixerRoute_IsActive(_ inputDeviceID: UInt32, _ inputChannelIndex: Int32, _ outputDeviceID: UInt32, _ outputChannelIndex: Int32) -> Bool {
    let input = (Int(inputDeviceID) << 8) | Int(inputChannelIndex)
    let output = (Int(outputDeviceID) << 8) | Int(outputChannelIndex)
    return RoutingBridge.shared.isRouteActive(from: input, to: output)
}


class ChannelStateManager: ObservableObject {
    static let shared = ChannelStateManager()
    private let lock = NSLock()
    let bubbleStore = ChannelBubbleStore.shared

    enum DCATarget: Hashable {
        case input(deviceID: AudioDeviceID, channel: Int)
        case output(deviceID: AudioDeviceID, channel: Int)
        case virtual(channelID: UUID)
    }

    /// Tracks the state of input channels keyed by "deviceID-channel".
    @Published var channelStates: [String: ChannelStripState] = [:]

    /// Tracks the state of output channels keyed by "deviceID-channel".
    @Published var outputChannelStates: [String: ChannelStripState] = [:]

    @Published var virtualChannelStates: [UUID: VirtualChannelState] = [:]
    @Published var inputEQSettings: [String: InputChannelEQSettings] = [:]
    @Published var inputDynamicsSettings: [String: InputChannelDynamicsSettings] = [:]
    @Published var outputEQSettingsStore: [String: InputChannelEQSettings] = [:]
    @Published var outputDynamicsSettingsStore: [String: InputChannelDynamicsSettings] = [:]
    @Published var virtualEQSettingsStore: [UUID: InputChannelEQSettings] = [:]
    @Published var virtualDynamicsSettingsStore: [UUID: InputChannelDynamicsSettings] = [:]

    @Published var inputGlobalIndexMap: [String: Int] = [:]
    @Published var outputGlobalIndexMap: [String: Int] = [:]
    @Published var dcaAssignments: [UUID: Set<DCATarget>] = [:]

    private func withLock<T>(_ block: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return block()
    }

    var bubbleStates: [String: ChannelBubbleState] {
        get { bubbleStore.states }
        set { bubbleStore.states = newValue }
    }

    /// Converts a fader value (0...1.2) to dB using a non-linear curve.
    /// - Parameters:
    ///   - value: The fader value to convert (0.0 to 1.2).
    ///   - minDB: The minimum dB value corresponding to 0.0 fader (usually negative).
    ///   - maxDB: The maximum dB value corresponding to 1.0 fader.
    /// - Returns: The calculated dB value.
    func faderValueToDB(value: Float, minDB: Float, maxDB: Float) -> Float {
        // Clamp input value
        let clampedValue = max(0.0, min(value, 1.2))

        // Use a common logarithmic curve for fader response
        // Normalize fader range from 0.0 (minDB) to 1.0 (maxDB)
        // For values > 1.0 (headroom), extrapolate linearly above maxDB

        if clampedValue <= 1.0 {
            // The curve maps 0.0 -> minDB, 1.0 -> maxDB, smoothly
            // Using a simple exponential approximation:
            // dB = minDB + (maxDB - minDB) * (value^exponent)
            // Choose exponent < 1 for more gentle slope near 0, e.g. 0.5 (sqrt)
            let exponent: Float = 0.5
            let db = minDB + (maxDB - minDB) * pow(clampedValue, exponent)
            return db
        } else {
            // Headroom above 1.0 fader: linear dB increase
            let headroomValue = clampedValue - 1.0
            let headroomDBRange: Float = 12.0 // Changed from 6.0 to 12.0 dB headroom max
            let db = maxDB + headroomDBRange * headroomValue / 0.2 // scale 0.0-0.2 to 0-12 dB
            return db
        }
    }

    /// Returns the current fader dB value for the given device/channel.
    /// Uses the channel's faderValue, minDB, and maxDB.
    func faderDB(for deviceID: AudioDeviceID, channel: Int) -> Float {
        let key = "\(deviceID)-\(channel)"
        guard let state = channelStates[key] else {
            return 0.0
        }
        return faderValueToDB(value: state.faderValue, minDB: state.minDB, maxDB: 0.0)
    }

    func outputFaderDB(for deviceID: AudioDeviceID, channel: Int) -> Float {
        let key = "\(deviceID)-\(channel)"
        guard let state = outputChannelStates[key] else {
            return 0.0
        }
        return faderValueToDB(value: state.faderValue, minDB: state.minDB, maxDB: state.maxDB)
    }

    /// Toggles mute state for the anchor channel in a linked pair or the individual channel otherwise.
    /// When linked, both channels share the same mute state.
    func toggleMute(deviceID: AudioDeviceID, channel: Int) {
        let anchor = (channel % 2 == 0) ? channel : channel - 1
        let pair = anchor + 1
        let anchorKey = "\(deviceID)-\(anchor)"
        let pairKey = "\(deviceID)-\(pair)"
        var anchorState = channelStates[anchorKey] ?? ChannelStripState(id: anchorKey, maxDB: 0.0)
        let isLinked = anchorState.isLinked
        if isLinked {
            let newMute = !anchorState.isMuted
            anchorState.isMuted = newMute
            channelStates[anchorKey] = anchorState
            setDeviceChannelProperty(deviceID: deviceID, channel: anchor, property: .mute(newMute))

            var pairState = channelStates[pairKey] ?? ChannelStripState(id: pairKey, maxDB: 0.0)
            pairState.isMuted = newMute
            channelStates[pairKey] = pairState
            setDeviceChannelProperty(deviceID: deviceID, channel: pair, property: .mute(newMute))
        } else {
            // Not linked, toggle only this channel
            let key = "\(deviceID)-\(channel)"
            var state = channelStates[key] ?? ChannelStripState(id: key, maxDB: 0.0)
            let newMute = !state.isMuted
            state.isMuted = newMute
            channelStates[key] = state
            setDeviceChannelProperty(deviceID: deviceID, channel: channel, property: .mute(newMute))
        }
    }

    /// Toggles solo state for the anchor channel in a linked pair or the individual channel otherwise.
    /// When linked, both channels share the same solo and mute states.
    /// The C backend manages mute based on solo internally.
    func toggleSolo(deviceID: AudioDeviceID, channel: Int) {
        let anchor = (channel % 2 == 0) ? channel : channel - 1
        let pair = anchor + 1
        let anchorKey = "\(deviceID)-\(anchor)"
        let pairKey = "\(deviceID)-\(pair)"
        var anchorState = channelStates[anchorKey] ?? ChannelStripState(id: anchorKey, maxDB: 0.0)
        let isLinked = anchorState.isLinked
        if isLinked {
            let newSolo = !anchorState.isSoloed
            anchorState.isSoloed = newSolo
            channelStates[anchorKey] = anchorState
            setDeviceChannelProperty(deviceID: deviceID, channel: anchor, property: .solo(newSolo))

            var pairState = channelStates[pairKey] ?? ChannelStripState(id: pairKey, maxDB: 0.0)
            pairState.isSoloed = newSolo
            channelStates[pairKey] = pairState
            setDeviceChannelProperty(deviceID: deviceID, channel: pair, property: .solo(newSolo))

            // Do NOT call mute for other channels due to solo logic; C backend manages mute internally
            for (key, var state) in channelStates where key != anchorKey && key != pairKey {
                if state.isSoloed {
                    state.isSoloed = false
                    channelStates[key] = state
                    setDeviceChannelProperty(deviceID: deviceID, channel: extractChannelNumber(from: key), property: .solo(false))
                }
            }
        } else {
            // Not linked, toggle solo only on this channel
            let key = "\(deviceID)-\(channel)"
            var state = channelStates[key] ?? ChannelStripState(id: key, maxDB: 0.0)
            let newSolo = !state.isSoloed
            state.isSoloed = newSolo
            channelStates[key] = state
            setDeviceChannelProperty(deviceID: deviceID, channel: channel, property: .solo(newSolo))

            // Do NOT call mute for other channels due to solo logic; C backend manages mute internally
            for (otherKey, var otherState) in channelStates where otherKey != key {
                if otherState.isSoloed {
                    otherState.isSoloed = false
                    channelStates[otherKey] = otherState
                    setDeviceChannelProperty(deviceID: deviceID, channel: extractChannelNumber(from: otherKey), property: .solo(false))
                }
            }
        }

        // New line: Update all channel mutes after solo toggle
        updateAllChannelMutesForSolo()
    }

    // MARK: - Polarity

    func isPolarityFlipped(deviceID: AudioDeviceID, channel: Int) -> Bool {
        channelStates["\(deviceID)-\(channel)"]?.isPolarityFlipped ?? false
    }

    func togglePolarity(deviceID: AudioDeviceID, channel: Int) {
        let key = "\(deviceID)-\(channel)"
        var state = channelStates[key] ?? ChannelStripState(id: key, maxDB: 0.0)
        state.isPolarityFlipped.toggle()
        channelStates[key] = state
        if let globalIdx = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: channel) {
            Mixer_SetChannelPolarity(globalIdx, state.isPolarityFlipped ? 1 : 0)
        }
    }

    // MARK: - Delay

    func delayMs(for deviceID: AudioDeviceID, channel: Int) -> Double {
        channelStates["\(deviceID)-\(channel)"]?.delayMs ?? 0.0
    }

    /// Sets the delay for a channel. `ms` is converted to samples at 48 kHz.
    func setDelayMs(_ ms: Double, for deviceID: AudioDeviceID, channel: Int) {
        let key = "\(deviceID)-\(channel)"
        var state = channelStates[key] ?? ChannelStripState(id: key, maxDB: 0.0)
        state.delayMs = max(0.0, ms)
        channelStates[key] = state
        if let globalIdx = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: channel) {
            let delaySamples = UInt32(max(0.0, ms) * 48.0) // 48 samples per ms at 48 kHz
            Mixer_SetChannelDelay(globalIdx, delaySamples)
        }
    }

    /// Always links adjacent channels as even-odd pairs (0-1, 2-3, ...) with even as the anchor.
    /// When linking, all properties except pan are set absolutely to the even channel's value.
    func toggleLink(deviceID: AudioDeviceID, channel: Int) {
        let baseEven = (channel % 2 == 0) ? channel : channel - 1
        let pairOdd = baseEven + 1
        guard baseEven >= 0, pairOdd > baseEven else { return }
        let evenKey = "\(deviceID)-\(baseEven)"
        let oddKey = "\(deviceID)-\(pairOdd)"
        var evenState = channelStates[evenKey] ?? ChannelStripState(id: evenKey, maxDB: 0.0)
        var oddState = channelStates[oddKey] ?? ChannelStripState(id: oddKey, maxDB: 0.0)
        let newLinkState = !evenState.isLinked
        // Update isLinked symmetrically
        evenState.isLinked = newLinkState
        oddState.isLinked = newLinkState
        setDeviceChannelProperty(deviceID: deviceID, channel: baseEven, property: .link(evenState.isLinked))
        setDeviceChannelProperty(deviceID: deviceID, channel: pairOdd, property: .link(oddState.isLinked))
        if newLinkState {
            // Absolute linking for all parameters except pan
            oddState.isMuted = evenState.isMuted
            oddState.isSoloed = evenState.isSoloed
            oddState.faderValue = evenState.faderValue
            oddState.auxSendValue = evenState.auxSendValue
            oddState.fxSendValue = evenState.fxSendValue
            oddState.selectedAuxSendIndex = evenState.selectedAuxSendIndex
            oddState.selectedFXSendIndex = evenState.selectedFXSendIndex

            // The even channel is always the postGainDial anchor, odd's postGainValue is always set by the anchor.
            oddState.postGainValue = evenState.postGainValue // Anchor-to-pair copy for postgaindial logic

            // Future properties: Copy here if added to ChannelStripState

            setDeviceChannelProperty(deviceID: deviceID, channel: pairOdd, property: .mute(oddState.isMuted))
            setDeviceChannelProperty(deviceID: deviceID, channel: pairOdd, property: .solo(oddState.isSoloed))
            setDeviceChannelProperty(deviceID: deviceID, channel: pairOdd, property: .fader(oddState.faderValue))
            setDeviceChannelProperty(deviceID: deviceID, channel: pairOdd, property: .auxSend(oddState.auxSendValue))
            setDeviceChannelProperty(deviceID: deviceID, channel: pairOdd, property: .fxSend(oddState.fxSendValue))
            setDeviceChannelProperty(deviceID: deviceID, channel: pairOdd, property: .auxSendBus(oddState.selectedAuxSendIndex))
            setDeviceChannelProperty(deviceID: deviceID, channel: pairOdd, property: .fxSendBus(oddState.selectedFXSendIndex))
            setDeviceChannelProperty(deviceID: deviceID, channel: pairOdd, property: .postGain(oddState.postGainValue))

            // Pan remains special: even = left, odd = right
            evenState.panValue = 0.0
            oddState.panValue = 127.0
            setDeviceChannelProperty(deviceID: deviceID, channel: baseEven, property: .pan(evenState.panValue))
            setDeviceChannelProperty(deviceID: deviceID, channel: pairOdd, property: .pan(oddState.panValue))
        }
        // Save updated states
        channelStates[evenKey] = evenState
        channelStates[oddKey] = oddState

        // Ensure mute/solo/fader updated for even as well
        setDeviceChannelProperty(deviceID: deviceID, channel: baseEven, property: .mute(evenState.isMuted))
        setDeviceChannelProperty(deviceID: deviceID, channel: baseEven, property: .solo(evenState.isSoloed))
        setDeviceChannelProperty(deviceID: deviceID, channel: baseEven, property: .fader(evenState.faderValue))
        setDeviceChannelProperty(deviceID: deviceID, channel: baseEven, property: .auxSend(evenState.auxSendValue))
        setDeviceChannelProperty(deviceID: deviceID, channel: baseEven, property: .fxSend(evenState.fxSendValue))
        setDeviceChannelProperty(deviceID: deviceID, channel: baseEven, property: .auxSendBus(evenState.selectedAuxSendIndex))
        setDeviceChannelProperty(deviceID: deviceID, channel: baseEven, property: .fxSendBus(evenState.selectedFXSendIndex))
        setDeviceChannelProperty(deviceID: deviceID, channel: baseEven, property: .postGain(evenState.postGainValue))

        // Inserted lines to ensure pan values are communicated to C mixer immediately
        setPan(for: deviceID, channel: baseEven, value: evenState.panValue)
        setPan(for: deviceID, channel: pairOdd, value: oddState.panValue)
    }

    /// Returns true if the given channel is part of a linked even-odd adjacent pair, and both channels have isLinked == true.
    /// The anchor channel (even) acts as the postgaindial anchor when linked.
    func isLinked(deviceID: AudioDeviceID, channel: Int) -> Bool {
        return withLock {
            let baseEven = (channel % 2 == 0) ? channel : channel - 1
            let pairOdd = baseEven + 1
            guard baseEven >= 0, pairOdd > baseEven else { return false }
            let evenKey = "\(deviceID)-\(baseEven)"
            let oddKey = "\(deviceID)-\(pairOdd)"
            guard let evenState = channelStates[evenKey], let oddState = channelStates[oddKey] else {
                return false
            }
            return evenState.isLinked && oddState.isLinked
        }
    }

    /// Returns the anchor channel index for postgaindial in a linked pair.
    /// For a given channel, returns the even-numbered channel index (anchor).
    func postGainDialAnchorChannel(for channel: Int) -> Int {
        return (channel % 2 == 0) ? channel : channel - 1
    }

    func isVirtualLinked(channelID: UUID, in group: [UUID]) -> Bool {
        // Example: Are both this channel and its group neighbor .isLinked == true?
        guard let idx = group.firstIndex(of: channelID) else { return false }
        let pairIdx = idx % 2 == 0 ? idx + 1 : idx - 1
        guard pairIdx >= 0, pairIdx < group.count else { return false }
        let thisLinked = virtualChannelStates[channelID]?.isLinked ?? false
        let pairLinked = virtualChannelStates[group[pairIdx]]?.isLinked ?? false
        return thisLinked && pairLinked
    }

    func toggleVirtualLink(for channelID: UUID, in group: [UUID]) {
        guard let idx = group.firstIndex(of: channelID) else { return }
        let pairIdx = idx % 2 == 0 ? idx + 1 : idx - 1
        guard pairIdx >= 0, pairIdx < group.count else { return }

        var thisState = virtualChannelStates[channelID] ?? VirtualChannelState(id: channelID)
        var pairState = virtualChannelStates[group[pairIdx]] ?? VirtualChannelState(id: group[pairIdx])
        let newLinkState = !(thisState.isLinked && pairState.isLinked)
        thisState.isLinked = newLinkState
        pairState.isLinked = newLinkState
        virtualChannelStates[channelID] = thisState
        virtualChannelStates[group[pairIdx]] = pairState
    }

    func setDCAAssignments(for dcaID: UUID, targets: Set<DCATarget>) {
        guard VirtualChannelManager.shared.channel(for: dcaID)?.type == .dca else { return }
        dcaAssignments[dcaID] = targets
    }

    func dcaTargets(for dcaID: UUID) -> Set<DCATarget> {
        dcaAssignments[dcaID] ?? []
    }

    func addDCATarget(_ target: DCATarget, to dcaID: UUID) {
        guard VirtualChannelManager.shared.channel(for: dcaID)?.type == .dca else { return }
        var targets = dcaAssignments[dcaID] ?? []
        targets.insert(target)
        dcaAssignments[dcaID] = targets
    }

    func removeDCATarget(_ target: DCATarget, from dcaID: UUID) {
        var targets = dcaAssignments[dcaID] ?? []
        targets.remove(target)
        dcaAssignments[dcaID] = targets
    }

    func clearDCATargets(for dcaID: UUID) {
        dcaAssignments[dcaID] = []
    }

    /// Returns true if the given channel exists in the channelStates dictionary for the specified device.
    func channelExists(deviceID: AudioDeviceID, channel: Int) -> Bool {
        let key = "\(deviceID)-\(channel)"
        return channelStates[key] != nil
    }

    /// Returns mute state for the anchor channel in a linked pair or the individual channel otherwise.
    /// The mute state is retrieved directly from the Mixer.c backend via Mixer_GetChannelMute.
    func isMuted(deviceID: AudioDeviceID, channel: Int) -> Bool {
        return withLock {
            if let globalChannelIndex = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: channel) {
                return Mixer_GetChannelMute(globalChannelIndex) != 0
            }
            // Fallback to stored state if backend unavailable
            let key = "\(deviceID)-\(channel)"
            return channelStates[key]?.isMuted ?? false
        }
    }

    /// Returns the solo state for the anchor channel in a linked pair or the individual channel otherwise.
    /// The solo state is retrieved directly from the Mixer.c backend via Mixer_GetChannelSolo.
    func isSoloed(deviceID: AudioDeviceID, channel: Int) -> Bool {
        return withLock {
            if let globalChannelIndex = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: channel) {
                return Mixer_GetChannelSolo(globalChannelIndex) != 0
            }
            // Fallback to stored state if backend unavailable
            let key = "\(deviceID)-\(channel)"
            return channelStates[key]?.isSoloed ?? false
        }
    }

    func pan(for deviceID: AudioDeviceID, channel: Int) -> Float {
        return channelStates["\(deviceID)-\(channel)"]?.panValue ?? 63.0
    }

    func fader(for deviceID: AudioDeviceID, channel: Int) -> Float {
        let anchor = (channel % 2 == 0) ? channel : channel - 1
        let anchorKey = "\(deviceID)-\(anchor)"
        if let anchorState = channelStates[anchorKey], anchorState.isLinked {
            return anchorState.faderValue
        } else {
            return channelStates["\(deviceID)-\(channel)"]?.faderValue ?? 1.0
        }
    }

    func auxSendValue(for deviceID: AudioDeviceID, channel: Int) -> Float {
        return channelStates["\(deviceID)-\(channel)"]?.auxSendValue ?? 0.0
    }

    func setAuxSendPreFade(for deviceID: AudioDeviceID, channel: Int, value: Bool) {
        let globalIdx = Mixer_GetGlobalChannelIndex(deviceID, MIXER_CHANNEL_INPUT, UInt32(channel))
        if globalIdx >= 0 {
            Mixer_SetChannelAuxSendPreFade(globalIdx, value ? 1 : 0)
        }
    }

    func setFXSendPreFade(for deviceID: AudioDeviceID, channel: Int, value: Bool) {
        let globalIdx = Mixer_GetGlobalChannelIndex(deviceID, MIXER_CHANNEL_INPUT, UInt32(channel))
        if globalIdx >= 0 {
            Mixer_SetChannelFXSendPreFade(globalIdx, value ? 1 : 0)
        }
    }

    func auxSendPreFade(for deviceID: AudioDeviceID, channel: Int) -> Bool {
        let globalIdx = Mixer_GetGlobalChannelIndex(deviceID, MIXER_CHANNEL_INPUT, UInt32(channel))
        if globalIdx >= 0 {
            return Mixer_GetChannelAuxSendPreFade(globalIdx) != 0
        }
        return false
    }

    func fxSendPreFade(for deviceID: AudioDeviceID, channel: Int) -> Bool {
        let globalIdx = Mixer_GetGlobalChannelIndex(deviceID, MIXER_CHANNEL_INPUT, UInt32(channel))
        if globalIdx >= 0 {
            return Mixer_GetChannelFXSendPreFade(globalIdx) != 0
        }
        return false
    }

    func fxSendValue(for deviceID: AudioDeviceID, channel: Int) -> Float {
        return channelStates["\(deviceID)-\(channel)"]?.fxSendValue ?? 0.0
    }

    func selectedAuxSendIndex(for deviceID: AudioDeviceID, channel: Int) -> Int {
        channelStates["\(deviceID)-\(channel)"]?.selectedAuxSendIndex ?? 0
    }

    func selectedFXSendIndex(for deviceID: AudioDeviceID, channel: Int) -> Int {
        channelStates["\(deviceID)-\(channel)"]?.selectedFXSendIndex ?? 0
    }

    func auxSendLabel(for deviceID: AudioDeviceID, channel: Int) -> String {
        let channels = VirtualChannelManager.shared.auxSendChannels
        let index = selectedAuxSendIndex(for: deviceID, channel: channel)
        if channels.indices.contains(index) {
            return channels[index].name.replacingOccurrences(of: "Send ", with: "")
        }
        return "Aux \(index + 1)"
    }

    func fxSendLabel(for deviceID: AudioDeviceID, channel: Int) -> String {
        let channels = VirtualChannelManager.shared.fxSendChannels
        let index = selectedFXSendIndex(for: deviceID, channel: channel)
        if channels.indices.contains(index) {
            return channels[index].name.replacingOccurrences(of: "Send ", with: "")
        }
        return "FX \(index + 1)"
    }

    func postGainValue(for deviceID: AudioDeviceID, channel: Int) -> Float {
        return channelStates["\(deviceID)-\(channel)"]?.postGainValue ?? 1.0
    }

    func eqSettings(for deviceID: AudioDeviceID, channel: Int) -> InputChannelEQSettings {
        inputEQSettings["\(deviceID)-\(channel)"] ?? InputChannelEQSettings()
    }

    func dynamicsSettings(for deviceID: AudioDeviceID, channel: Int) -> InputChannelDynamicsSettings {
        inputDynamicsSettings["\(deviceID)-\(channel)"] ?? InputChannelDynamicsSettings()
    }

    func gainReductionDB(for deviceID: AudioDeviceID, channel: Int) -> Float {
        guard let globalChannelIndex = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: channel) else {
            return 0.0
        }
        return Mixer_GetChannelGainReduction(UInt32(globalChannelIndex))
    }

    func setEQSettings(for deviceID: AudioDeviceID, channel: Int, settings: InputChannelEQSettings) {
        let key = "\(deviceID)-\(channel)"
        inputEQSettings[key] = settings
        guard let globalChannelIndex = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: channel) else {
            return
        }
        Mixer_SetChannelEQConfig(globalChannelIndex, mixerEQConfig(from: settings))
    }

    func setDynamicsSettings(for deviceID: AudioDeviceID, channel: Int, settings: InputChannelDynamicsSettings) {
        let key = "\(deviceID)-\(channel)"
        inputDynamicsSettings[key] = settings
        guard let globalChannelIndex = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: channel) else {
            return
        }
        Mixer_SetChannelDynamicsConfig(globalChannelIndex, mixerDynamicsConfig(from: settings))
    }

    func updateEQSettings(for deviceID: AudioDeviceID,
                          channel: Int,
                          mutate: (inout InputChannelEQSettings) -> Void) {
        var settings = eqSettings(for: deviceID, channel: channel)
        mutate(&settings)
        setEQSettings(for: deviceID, channel: channel, settings: settings)
    }

    func updateDynamicsSettings(for deviceID: AudioDeviceID,
                                channel: Int,
                                mutate: (inout InputChannelDynamicsSettings) -> Void) {
        var settings = dynamicsSettings(for: deviceID, channel: channel)
        mutate(&settings)
        setDynamicsSettings(for: deviceID, channel: channel, settings: settings)
    }

    func outputEQSettings(for deviceID: AudioDeviceID, channel: Int) -> InputChannelEQSettings {
        outputEQSettingsStore["\(deviceID)-\(channel)"] ?? InputChannelEQSettings()
    }

    func outputDynamicsSettings(for deviceID: AudioDeviceID, channel: Int) -> InputChannelDynamicsSettings {
        outputDynamicsSettingsStore["\(deviceID)-\(channel)"] ?? InputChannelDynamicsSettings()
    }

    func outputGainReductionDB(for deviceID: AudioDeviceID, channel: Int) -> Float {
        guard let globalChannelIndex = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: channel) else {
            return 0.0
        }
        return Mixer_GetChannelGainReduction(UInt32(globalChannelIndex))
    }

    func setOutputEQSettings(for deviceID: AudioDeviceID, channel: Int, settings: InputChannelEQSettings) {
        let key = "\(deviceID)-\(channel)"
        outputEQSettingsStore[key] = settings
        guard let globalChannelIndex = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: channel) else {
            return
        }
        Mixer_SetChannelEQConfig(globalChannelIndex, mixerEQConfig(from: settings))
    }

    func setOutputDynamicsSettings(for deviceID: AudioDeviceID, channel: Int, settings: InputChannelDynamicsSettings) {
        let key = "\(deviceID)-\(channel)"
        outputDynamicsSettingsStore[key] = settings
        guard let globalChannelIndex = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: channel) else {
            return
        }
        Mixer_SetChannelDynamicsConfig(globalChannelIndex, mixerDynamicsConfig(from: settings))
    }

    func updateOutputEQSettings(for deviceID: AudioDeviceID,
                                channel: Int,
                                mutate: (inout InputChannelEQSettings) -> Void) {
        var settings = outputEQSettings(for: deviceID, channel: channel)
        mutate(&settings)
        setOutputEQSettings(for: deviceID, channel: channel, settings: settings)
    }

    func updateOutputDynamicsSettings(for deviceID: AudioDeviceID,
                                      channel: Int,
                                      mutate: (inout InputChannelDynamicsSettings) -> Void) {
        var settings = outputDynamicsSettings(for: deviceID, channel: channel)
        mutate(&settings)
        setOutputDynamicsSettings(for: deviceID, channel: channel, settings: settings)
    }

    func applyPreviewEQSettings(for deviceID: AudioDeviceID,
                                channelType: UInt32,
                                channel: Int,
                                settings: InputChannelEQSettings) {
        guard let globalChannelIndex = mixerGlobalChannelIndex(deviceID: deviceID, type: channelType, channel: channel) else {
            return
        }
        Mixer_SetChannelEQConfig(globalChannelIndex, mixerEQConfig(from: settings))
    }

    func applyPreviewDynamicsSettings(for deviceID: AudioDeviceID,
                                      channelType: UInt32,
                                      channel: Int,
                                      settings: InputChannelDynamicsSettings) {
        guard let globalChannelIndex = mixerGlobalChannelIndex(deviceID: deviceID, type: channelType, channel: channel) else {
            return
        }
        Mixer_SetChannelDynamicsConfig(globalChannelIndex, mixerDynamicsConfig(from: settings))
    }

    func eqSettings(for channelID: UUID) -> InputChannelEQSettings {
        virtualEQSettingsStore[channelID] ?? InputChannelEQSettings()
    }

    func dynamicsSettings(for channelID: UUID) -> InputChannelDynamicsSettings {
        virtualDynamicsSettingsStore[channelID] ?? InputChannelDynamicsSettings()
    }

    func gainReductionDB(for channelID: UUID, type: VirtualChannelType, channelIndex: Int) -> Float {
        guard let busType = mixerVirtualBusType(for: type), channelIndex >= 0 else {
            return 0.0
        }
        return Mixer_GetVirtualBusGainReduction(busType, UInt32(channelIndex))
    }

    func setEQSettings(for channelID: UUID,
                       type: VirtualChannelType,
                       channelIndex: Int,
                       settings: InputChannelEQSettings) {
        virtualEQSettingsStore[channelID] = settings
        guard let busType = mixerVirtualBusType(for: type), channelIndex >= 0 else {
            return
        }
        Mixer_SetVirtualBusEQConfig(busType, UInt32(channelIndex), mixerEQConfig(from: settings))
    }

    func setDynamicsSettings(for channelID: UUID,
                             type: VirtualChannelType,
                             channelIndex: Int,
                             settings: InputChannelDynamicsSettings) {
        virtualDynamicsSettingsStore[channelID] = settings
        guard let busType = mixerVirtualBusType(for: type), channelIndex >= 0 else {
            return
        }
        Mixer_SetVirtualBusDynamicsConfig(busType, UInt32(channelIndex), mixerDynamicsConfig(from: settings))
    }

    func updateEQSettings(for channelID: UUID,
                          type: VirtualChannelType,
                          channelIndex: Int,
                          mutate: (inout InputChannelEQSettings) -> Void) {
        var settings = eqSettings(for: channelID)
        mutate(&settings)
        setEQSettings(for: channelID, type: type, channelIndex: channelIndex, settings: settings)
    }

    func updateDynamicsSettings(for channelID: UUID,
                                type: VirtualChannelType,
                                channelIndex: Int,
                                mutate: (inout InputChannelDynamicsSettings) -> Void) {
        var settings = dynamicsSettings(for: channelID)
        mutate(&settings)
        setDynamicsSettings(for: channelID, type: type, channelIndex: channelIndex, settings: settings)
    }

    func applyPreviewEQSettings(for channelID: UUID,
                                type: VirtualChannelType,
                                channelIndex: Int,
                                settings: InputChannelEQSettings) {
        guard let busType = mixerVirtualBusType(for: type), channelIndex >= 0 else {
            return
        }
        Mixer_SetVirtualBusEQConfig(busType, UInt32(channelIndex), mixerEQConfig(from: settings))
    }

    func applyPreviewDynamicsSettings(for channelID: UUID,
                                      type: VirtualChannelType,
                                      channelIndex: Int,
                                      settings: InputChannelDynamicsSettings) {
        guard let busType = mixerVirtualBusType(for: type), channelIndex >= 0 else {
            return
        }
        Mixer_SetVirtualBusDynamicsConfig(busType, UInt32(channelIndex), mixerDynamicsConfig(from: settings))
    }

    func setFader(for deviceID: AudioDeviceID, channel: Int, value: Float) {
        // Value should be in 0.0...1.2 range for headroom; values above 1.0 are now allowed and honored by the C mixer
        let anchor = (channel % 2 == 0) ? channel : channel - 1
        let pair = anchor + 1
        let anchorKey = "\(deviceID)-\(anchor)"
        let pairKey = "\(deviceID)-\(pair)"
        if let anchorState = channelStates[anchorKey], anchorState.isLinked {
            // Set both anchor and pair to the same value

            var newAnchorState = anchorState
            newAnchorState.faderValue = value
            channelStates[anchorKey] = newAnchorState

            // Map faderValue to dB using anchor state's minDB and maxDB
            let minDB = anchorState.minDB
            let maxDB = anchorState.maxDB
            let db = faderValueToDB(value: value, minDB: minDB, maxDB: maxDB)
            let linearGain = pow(10.0, db / 20.0)
            setDeviceChannelProperty(deviceID: deviceID, channel: anchor, property: .fader(Float(linearGain)))

            var newPairState = channelStates[pairKey] ?? ChannelStripState(id: pairKey, isMuted: false, isSoloed: false, isLinked: true, panValue: 63.0, faderValue: 1.0, auxSendValue: 0.0, fxSendValue: 0.0, postGainValue: 1.0, maxDB: 0.0)
            newPairState.faderValue = value
            channelStates[pairKey] = newPairState

            // Use pair's minDB and maxDB if available, else fallback to anchor's
            let pairMinDB = newPairState.minDB
            let pairMaxDB = newPairState.maxDB
            let pairDB = faderValueToDB(value: value, minDB: pairMinDB, maxDB: pairMaxDB)
            let pairLinearGain = pow(10.0, pairDB / 20.0)
            setDeviceChannelProperty(deviceID: deviceID, channel: pair, property: .fader(Float(pairLinearGain)))
        } else {
            let key = "\(deviceID)-\(channel)"
            var state = channelStates[key] ?? ChannelStripState(id: key, isMuted: false, isSoloed: false, isLinked: false, panValue: 63.0, faderValue: 1.0, auxSendValue: 0.0, fxSendValue: 0.0, postGainValue: 1.0, maxDB: 0.0)
            state.faderValue = value
            channelStates[key] = state

            let minDB = state.minDB
            let maxDB = state.maxDB
            let db = faderValueToDB(value: value, minDB: minDB, maxDB: maxDB)
            let linearGain = pow(10.0, db / 20.0)
            setDeviceChannelProperty(deviceID: deviceID, channel: channel, property: .fader(Float(linearGain)))
        }

    }

    func getFaderValue(forChannel channel: Int) -> Float {
        return channelStates.values.first(where: { $0.id.hasSuffix("-\(channel)") })?.faderValue ?? 1.0
    }

    // Sets the pan value for a channel and, if linked, mirrors the pan in stereo-opposite for the linked channel
    func setPan(for deviceID: AudioDeviceID, channel: Int, value: Float) {
        let key = "\(deviceID)-\(channel)"
        var state = channelStates[key] ?? ChannelStripState(id: key, isMuted: false, isSoloed: false, isLinked: false, panValue: 63.0, faderValue: 1.0, auxSendValue: 0.0, fxSendValue: 0.0, postGainValue: 1.0, maxDB: 0.0)
        state.panValue = value
        channelStates[key] = state
        let normalizedPan = value / 127.0
        if let globalChannelIndex = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: channel) {
            Mixer_SetChannelPan(globalChannelIndex, normalizedPan)
        }
        setDeviceChannelProperty(deviceID: deviceID, channel: channel, property: .pan(state.panValue))

        if state.isLinked {
            // Stereo-pair mirroring logic: for any channel, find its even base channel,
            // then the linked channel is the other channel in the pair. This ensures correct
            // mirroring between left/right paired channels.
            let baseEven = (channel % 2 == 0) ? channel : channel - 1
            let linkedChannel = (channel == baseEven) ? baseEven + 1 : baseEven
            let linkedKey = "\(deviceID)-\(linkedChannel)"
            var linkedState = channelStates[linkedKey] ?? ChannelStripState(id: linkedKey, isMuted: false, isSoloed: false, isLinked: false, panValue: 63.0, faderValue: 1.0, auxSendValue: 0.0, fxSendValue: 0.0, postGainValue: 1.0, maxDB: 0.0)
            let linkedPanValue = 127.0 - value
            linkedState.panValue = linkedPanValue
            channelStates[linkedKey] = linkedState
            let normalizedLinkedPan = linkedPanValue / 127.0
            if let linkedGlobalChannelIndex = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: linkedChannel) {
                Mixer_SetChannelPan(linkedGlobalChannelIndex, normalizedLinkedPan)
            }
            setDeviceChannelProperty(deviceID: deviceID, channel: linkedChannel, property: .pan(linkedState.panValue))
        }
    }

    func isOutputMuted(deviceID: AudioDeviceID, channel: Int) -> Bool {
        return withLock {
            if let globalChannelIndex = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: channel) {
                return Mixer_GetChannelMute(globalChannelIndex) != 0
            }
            return outputChannelStates["\(deviceID)-\(channel)"]?.isMuted ?? false
        }
    }

    func isOutputSoloed(deviceID: AudioDeviceID, channel: Int) -> Bool {
        return withLock {
            if let globalChannelIndex = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: channel) {
                return Mixer_GetChannelSolo(globalChannelIndex) != 0
            }
            return outputChannelStates["\(deviceID)-\(channel)"]?.isSoloed ?? false
        }
    }

    func isOutputLinked(deviceID: AudioDeviceID, channel: Int) -> Bool {
        return withLock {
            let baseEven = (channel % 2 == 0) ? channel : channel - 1
            let pairOdd = baseEven + 1
            guard baseEven >= 0, pairOdd > baseEven else { return false }
            let evenKey = "\(deviceID)-\(baseEven)"
            let oddKey = "\(deviceID)-\(pairOdd)"
            guard let evenState = outputChannelStates[evenKey], let oddState = outputChannelStates[oddKey] else {
                return false
            }
            return evenState.isLinked && oddState.isLinked
        }
    }

    func isOutputPolarityFlipped(deviceID: AudioDeviceID, channel: Int) -> Bool {
        outputChannelStates["\(deviceID)-\(channel)"]?.isPolarityFlipped ?? false
    }

    func toggleOutputPolarity(deviceID: AudioDeviceID, channel: Int) {
        let key = "\(deviceID)-\(channel)"
        var state = outputChannelStates[key] ?? ChannelStripState(id: key, maxDB: 0.0)
        state.isPolarityFlipped.toggle()
        outputChannelStates[key] = state
        if let globalIdx = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: channel) {
            Mixer_SetChannelPolarity(globalIdx, state.isPolarityFlipped ? 1 : 0)
        }
    }

    func outputDelayMs(for deviceID: AudioDeviceID, channel: Int) -> Double {
        outputChannelStates["\(deviceID)-\(channel)"]?.delayMs ?? 0.0
    }

    func setOutputDelayMs(_ ms: Double, for deviceID: AudioDeviceID, channel: Int) {
        let key = "\(deviceID)-\(channel)"
        var state = outputChannelStates[key] ?? ChannelStripState(id: key, maxDB: 0.0)
        state.delayMs = max(0.0, ms)
        outputChannelStates[key] = state
        if let globalIdx = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: channel) {
            let delaySamples = UInt32(max(0.0, ms) * 48.0)
            Mixer_SetChannelDelay(globalIdx, delaySamples)
        }
    }

    func outputPan(for deviceID: AudioDeviceID, channel: Int) -> Float {
        outputChannelStates["\(deviceID)-\(channel)"]?.panValue ?? 63.0
    }

    func outputFader(for deviceID: AudioDeviceID, channel: Int) -> Float {
        let anchor = (channel % 2 == 0) ? channel : channel - 1
        let anchorKey = "\(deviceID)-\(anchor)"
        if let anchorState = outputChannelStates[anchorKey], anchorState.isLinked {
            return anchorState.faderValue
        }
        return outputChannelStates["\(deviceID)-\(channel)"]?.faderValue ?? 1.0
    }

    func setOutputFader(for deviceID: AudioDeviceID, channel: Int, value: Float) {
        let anchor = (channel % 2 == 0) ? channel : channel - 1
        let pair = anchor + 1
        let anchorKey = "\(deviceID)-\(anchor)"
        let pairKey = "\(deviceID)-\(pair)"

        if let anchorState = outputChannelStates[anchorKey], anchorState.isLinked {
            var newAnchorState = anchorState
            newAnchorState.faderValue = value
            outputChannelStates[anchorKey] = newAnchorState

            let db = faderValueToDB(value: value, minDB: newAnchorState.minDB, maxDB: newAnchorState.maxDB)
            let linearGain = pow(10.0, db / 20.0)
            if let globalChannelIndex = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: anchor) {
                Mixer_SetChannelFader(globalChannelIndex, linearGain)
            }

            var pairState = outputChannelStates[pairKey] ?? ChannelStripState(id: pairKey, isLinked: true, maxDB: 0.0)
            pairState.faderValue = value
            outputChannelStates[pairKey] = pairState

            let pairDB = faderValueToDB(value: value, minDB: pairState.minDB, maxDB: pairState.maxDB)
            let pairLinearGain = pow(10.0, pairDB / 20.0)
            if let globalChannelIndex = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: pair) {
                Mixer_SetChannelFader(globalChannelIndex, pairLinearGain)
            }
            return
        }

        let key = "\(deviceID)-\(channel)"
        var state = outputChannelStates[key] ?? ChannelStripState(id: key, maxDB: 0.0)
        state.faderValue = value
        outputChannelStates[key] = state

        let db = faderValueToDB(value: value, minDB: state.minDB, maxDB: state.maxDB)
        let linearGain = pow(10.0, db / 20.0)
        if let globalChannelIndex = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: channel) {
            Mixer_SetChannelFader(globalChannelIndex, linearGain)
        }
    }

    func setOutputPan(for deviceID: AudioDeviceID, channel: Int, value: Float) {
        let key = "\(deviceID)-\(channel)"
        var state = outputChannelStates[key] ?? ChannelStripState(id: key, maxDB: 0.0)
        state.panValue = value
        outputChannelStates[key] = state

        if let globalChannelIndex = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: channel) {
            Mixer_SetChannelPan(globalChannelIndex, value / 127.0)
        }

        if state.isLinked {
            let baseEven = (channel % 2 == 0) ? channel : channel - 1
            let linkedChannel = (channel == baseEven) ? baseEven + 1 : baseEven
            let linkedKey = "\(deviceID)-\(linkedChannel)"
            var linkedState = outputChannelStates[linkedKey] ?? ChannelStripState(id: linkedKey, maxDB: 0.0)
            let linkedPanValue = 127.0 - value
            linkedState.panValue = linkedPanValue
            outputChannelStates[linkedKey] = linkedState
            if let linkedGlobalChannelIndex = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: linkedChannel) {
                Mixer_SetChannelPan(linkedGlobalChannelIndex, linkedPanValue / 127.0)
            }
        }
    }

    func toggleOutputMute(deviceID: AudioDeviceID, channel: Int) {
        let anchor = (channel % 2 == 0) ? channel : channel - 1
        let pair = anchor + 1
        let anchorKey = "\(deviceID)-\(anchor)"
        let pairKey = "\(deviceID)-\(pair)"
        var anchorState = outputChannelStates[anchorKey] ?? ChannelStripState(id: anchorKey, maxDB: 0.0)
        let isLinked = anchorState.isLinked

        if isLinked {
            let newMute = !anchorState.isMuted
            anchorState.isMuted = newMute
            outputChannelStates[anchorKey] = anchorState
            if let globalChannelIndex = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: anchor) {
                Mixer_SetChannelMute(globalChannelIndex, newMute ? 1 : 0)
            }

            var pairState = outputChannelStates[pairKey] ?? ChannelStripState(id: pairKey, isLinked: true, maxDB: 0.0)
            pairState.isMuted = newMute
            outputChannelStates[pairKey] = pairState
            if let globalChannelIndex = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: pair) {
                Mixer_SetChannelMute(globalChannelIndex, newMute ? 1 : 0)
            }
            return
        }

        let key = "\(deviceID)-\(channel)"
        var state = outputChannelStates[key] ?? ChannelStripState(id: key, maxDB: 0.0)
        let newMute = !state.isMuted
        state.isMuted = newMute
        outputChannelStates[key] = state
        if let globalChannelIndex = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: channel) {
            Mixer_SetChannelMute(globalChannelIndex, newMute ? 1 : 0)
        }
    }

    func toggleOutputSolo(deviceID: AudioDeviceID, channel: Int) {
        let anchor = (channel % 2 == 0) ? channel : channel - 1
        let pair = anchor + 1
        let anchorKey = "\(deviceID)-\(anchor)"
        let pairKey = "\(deviceID)-\(pair)"
        var anchorState = outputChannelStates[anchorKey] ?? ChannelStripState(id: anchorKey, maxDB: 0.0)
        let isLinked = anchorState.isLinked
        let soloChannel = isLinked ? anchor : channel
        let soloKey = "\(deviceID)-\(soloChannel)"

        var soloState = isLinked ? anchorState : (outputChannelStates[soloKey] ?? ChannelStripState(id: soloKey, maxDB: 0.0))
        let newSolo = !soloState.isSoloed
        soloState.isSoloed = newSolo
        outputChannelStates[soloKey] = soloState
        if let globalChannelIndex = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: soloChannel) {
            Mixer_SetChannelSolo(globalChannelIndex, newSolo ? 1 : 0)
        }

        for (key, var state) in outputChannelStates where key != anchorKey && key != pairKey && key != soloKey {
            let parts = key.split(separator: "-")
            guard parts.count == 2,
                  let otherDeviceID = UInt32(parts[0]),
                  let otherChannel = Int(parts[1]),
                  otherDeviceID == deviceID else {
                continue
            }
            if state.isSoloed {
                state.isSoloed = false
                outputChannelStates[key] = state
                if let globalChannelIndex = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: otherChannel) {
                    Mixer_SetChannelSolo(globalChannelIndex, 0)
                }
            }
        }

        guard isLinked else {
            return
        }

        anchorState.isSoloed = newSolo
        outputChannelStates[anchorKey] = anchorState

        var pairState = outputChannelStates[pairKey] ?? ChannelStripState(id: pairKey, isLinked: true, maxDB: 0.0)
        pairState.isSoloed = newSolo
        outputChannelStates[pairKey] = pairState
        if let globalChannelIndex = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: pair) {
            Mixer_SetChannelSolo(globalChannelIndex, newSolo ? 1 : 0)
        }
    }

    func toggleOutputLink(deviceID: AudioDeviceID, channel: Int) {
        let baseEven = (channel % 2 == 0) ? channel : channel - 1
        let pairOdd = baseEven + 1
        guard baseEven >= 0, pairOdd > baseEven else { return }

        let evenKey = "\(deviceID)-\(baseEven)"
        let oddKey = "\(deviceID)-\(pairOdd)"
        var evenState = outputChannelStates[evenKey] ?? ChannelStripState(id: evenKey, maxDB: 0.0)
        var oddState = outputChannelStates[oddKey] ?? ChannelStripState(id: oddKey, maxDB: 0.0)
        let newLinkState = !evenState.isLinked

        evenState.isLinked = newLinkState
        oddState.isLinked = newLinkState

        if newLinkState {
            oddState.isMuted = evenState.isMuted
            oddState.isSoloed = evenState.isSoloed
            oddState.faderValue = evenState.faderValue
            oddState.panValue = 127.0
            evenState.panValue = 0.0
        }

        outputChannelStates[evenKey] = evenState
        outputChannelStates[oddKey] = oddState

        if let evenGlobal = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: baseEven) {
            Mixer_SetChannelMute(evenGlobal, evenState.isMuted ? 1 : 0)
            Mixer_SetChannelSolo(evenGlobal, evenState.isSoloed ? 1 : 0)
        }
        if let oddGlobal = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: pairOdd) {
            Mixer_SetChannelMute(oddGlobal, oddState.isMuted ? 1 : 0)
            Mixer_SetChannelSolo(oddGlobal, oddState.isSoloed ? 1 : 0)
        }

        setOutputFader(for: deviceID, channel: baseEven, value: evenState.faderValue)
        if newLinkState {
            setOutputPan(for: deviceID, channel: baseEven, value: evenState.panValue)
            setOutputPan(for: deviceID, channel: pairOdd, value: oddState.panValue)
        }
    }

    // MARK: - Virtual Channel State Management

    func isMuted(for channelID: UUID) -> Bool {
        let soloed = virtualChannelStates.values.contains { $0.isSoloed }
        if soloed {
            return !(virtualChannelStates[channelID]?.isSoloed ?? false)
        }
        return virtualChannelStates[channelID]?.isMuted ?? false
    }

    func toggleMute(for channelID: UUID) {
        var state = virtualChannelStates[channelID] ?? VirtualChannelState(id: channelID)
        state.isMuted.toggle()
        virtualChannelStates[channelID] = state
    }

    func toggleSolo(for channelID: UUID) {
        let soloed = virtualChannelStates[channelID]?.isSoloed ?? false
        for (id, var state) in virtualChannelStates {
            if id == channelID {
                state.isSoloed = !soloed
                state.isMuted = false
            } else {
                state.isSoloed = false
                state.isMuted = true
            }
            virtualChannelStates[id] = state
        }
    }

    func isVirtualSoloed(channelID: UUID, in group: [UUID]) -> Bool {
        guard group.contains(channelID) else { return false }
        return virtualChannelStates[channelID]?.isSoloed ?? false
    }

    func isVirtualMuted(channelID: UUID, in group: [UUID]) -> Bool {
        guard group.contains(channelID) else { return false }
        return virtualChannelStates[channelID]?.isMuted ?? false
    }

    func toggleVirtualSolo(for channelID: UUID, in group: [UUID]) {
        guard group.contains(channelID) else { return }

        let soloed = virtualChannelStates[channelID]?.isSoloed ?? false
        for id in group {
            var state = virtualChannelStates[id] ?? VirtualChannelState(id: id)
            if id == channelID {
                state.isSoloed = !soloed
                state.isMuted = false
            } else {
                state.isSoloed = false
                state.isMuted = !soloed
            }
            virtualChannelStates[id] = state
        }
    }

    func pan(for channelID: UUID) -> Float {
        return virtualChannelStates[channelID]?.panValue ?? 63.0
    }

    func setPan(for channelID: UUID, value: Float) {
        var state = virtualChannelStates[channelID] ?? VirtualChannelState(id: channelID)
        state.panValue = value
        virtualChannelStates[channelID] = state
    }

    func fader(for channelID: UUID) -> Float {
        return virtualChannelStates[channelID]?.faderValue ?? 0.8
    }

    func setFader(for channelID: UUID, value: Float) {
        var state = virtualChannelStates[channelID] ?? VirtualChannelState(id: channelID)
        state.faderValue = value
        virtualChannelStates[channelID] = state

        if VirtualChannelManager.shared.channel(for: channelID)?.type == .dca {
            applyDCAFaderOverrides(for: channelID, value: value)
        }
    }

    private func applyDCAFaderOverrides(for dcaID: UUID, value: Float) {
        guard VirtualChannelManager.shared.channel(for: dcaID)?.type == .dca else { return }

        let targets = dcaAssignments[dcaID] ?? []
        for target in targets {
            switch target {
            case .input(let deviceID, let channel):
                setFader(for: deviceID, channel: channel, value: value)
            case .output(let deviceID, let channel):
                setOutputFader(for: deviceID, channel: channel, value: value)
            case .virtual(let channelID):
                guard channelID != dcaID else { continue }
                if VirtualChannelManager.shared.channel(for: channelID)?.type == .dca {
                    continue
                }
                setFader(for: channelID, value: value)
            }
        }
    }

    func auxSendValue(for channelID: UUID) -> Float {
        virtualChannelStates[channelID]?.auxSendValue ?? 0.0
    }

    func fxSendValue(for channelID: UUID) -> Float {
        virtualChannelStates[channelID]?.fxSendValue ?? 0.0
    }

    func setAuxSend(for channelID: UUID, value: Float) {
        var state = virtualChannelStates[channelID] ?? VirtualChannelState(id: channelID)
        state.auxSendValue = value
        virtualChannelStates[channelID] = state
    }

    func setFXSend(for channelID: UUID, value: Float) {
        var state = virtualChannelStates[channelID] ?? VirtualChannelState(id: channelID)
        state.fxSendValue = value
        virtualChannelStates[channelID] = state
    }

    func selectedAuxSendIndex(for channelID: UUID) -> Int {
        virtualChannelStates[channelID]?.selectedAuxSendIndex ?? 0
    }

    func selectedFXSendIndex(for channelID: UUID) -> Int {
        virtualChannelStates[channelID]?.selectedFXSendIndex ?? 0
    }

    func auxSendLabel(for channelID: UUID) -> String {
        let channels = VirtualChannelManager.shared.auxSendChannels
        let index = selectedAuxSendIndex(for: channelID)
        if channels.indices.contains(index) {
            return channels[index].name.replacingOccurrences(of: "Send ", with: "")
        }
        return "Aux \(index + 1)"
    }

    func fxSendLabel(for channelID: UUID) -> String {
        let channels = VirtualChannelManager.shared.fxSendChannels
        let index = selectedFXSendIndex(for: channelID)
        if channels.indices.contains(index) {
            return channels[index].name
        }
        return "FX \(index + 1)"
    }

    func setSelectedAuxSendIndex(for channelID: UUID, value: Int) {
        let clampedIndex = max(0, min(value, max(VirtualChannelManager.shared.auxSendChannels.count - 1, 0)))
        var state = virtualChannelStates[channelID] ?? VirtualChannelState(id: channelID)
        state.selectedAuxSendIndex = clampedIndex
        virtualChannelStates[channelID] = state
    }

    func setSelectedFXSendIndex(for channelID: UUID, value: Int) {
        let clampedIndex = max(0, min(value, max(VirtualChannelManager.shared.fxSendChannels.count - 1, 0)))
        var state = virtualChannelStates[channelID] ?? VirtualChannelState(id: channelID)
        state.selectedFXSendIndex = clampedIndex
        virtualChannelStates[channelID] = state
    }

    func setAuxSendPreFade(for channelID: UUID, value: Bool) {
        let channelIndex = VirtualChannelManager.shared.channel(for: channelID)?.index ?? 0
        Mixer_SetChannelAuxSendPreFade(Int32(channelIndex), value ? 1 : 0)
    }

    func setFXSendPreFade(for channelID: UUID, value: Bool) {
        let channelIndex = VirtualChannelManager.shared.channel(for: channelID)?.index ?? 0
        Mixer_SetChannelFXSendPreFade(Int32(channelIndex), value ? 1 : 0)
    }

    func auxSendPreFade(for channelID: UUID) -> Bool {
        let channelIndex = VirtualChannelManager.shared.channel(for: channelID)?.index ?? 0
        return Mixer_GetChannelAuxSendPreFade(Int32(channelIndex)) != 0
    }

    func fxSendPreFade(for channelID: UUID) -> Bool {
        let channelIndex = VirtualChannelManager.shared.channel(for: channelID)?.index ?? 0
        return Mixer_GetChannelFXSendPreFade(Int32(channelIndex)) != 0
    }

    // MARK: - New methods for auxSend, fxSend, and postGain

    func setAuxSend(for deviceID: AudioDeviceID, channel: Int, value: Float) {
        let key = "\(deviceID)-\(channel)"
        var state = channelStates[key] ?? ChannelStripState(id: key, isMuted: false, isSoloed: false, isLinked: false,
                                                           panValue: 63.0, faderValue: 1.0, auxSendValue: 0.0, fxSendValue: 0.0, postGainValue: 1.0, maxDB: 0.0)
        state.auxSendValue = value
        channelStates[key] = state
        setDeviceChannelProperty(deviceID: deviceID, channel: channel, property: .auxSend(state.auxSendValue))

        // Mirror auxSend to linked channel
        if state.isLinked {
            let linkedChannel = (channel % 2 == 0) ? channel + 1 : channel - 1
            let linkedKey = "\(deviceID)-\(linkedChannel)"
            var linkedState = channelStates[linkedKey] ?? ChannelStripState(id: linkedKey, isMuted: false, isSoloed: false, isLinked: false,
                                                                          panValue: 63.0, faderValue: 1.0, auxSendValue: 0.0, fxSendValue: 0.0, postGainValue: 1.0, maxDB: 0.0)
            linkedState.auxSendValue = value
            channelStates[linkedKey] = linkedState
            setDeviceChannelProperty(deviceID: deviceID, channel: linkedChannel, property: .auxSend(linkedState.auxSendValue))
        }
    }

    func setFXSend(for deviceID: AudioDeviceID, channel: Int, value: Float) {
        let key = "\(deviceID)-\(channel)"
        var state = channelStates[key] ?? ChannelStripState(id: key, isMuted: false, isSoloed: false, isLinked: false,
                                                           panValue: 63.0, faderValue: 1.0, auxSendValue: 0.0, fxSendValue: 0.0, postGainValue: 1.0, maxDB: 0.0)
        state.fxSendValue = value
        channelStates[key] = state
        setDeviceChannelProperty(deviceID: deviceID, channel: channel, property: .fxSend(state.fxSendValue))

        // Mirror fxSend to linked channel
        if state.isLinked {
            let linkedChannel = (channel % 2 == 0) ? channel + 1 : channel - 1
            let linkedKey = "\(deviceID)-\(linkedChannel)"
            var linkedState = channelStates[linkedKey] ?? ChannelStripState(id: linkedKey, isMuted: false, isSoloed: false, isLinked: false,
                                                                          panValue: 63.0, faderValue: 1.0, auxSendValue: 0.0, fxSendValue: 0.0, postGainValue: 1.0, maxDB: 0.0)
            linkedState.fxSendValue = value
            channelStates[linkedKey] = linkedState
            setDeviceChannelProperty(deviceID: deviceID, channel: linkedChannel, property: .fxSend(linkedState.fxSendValue))
        }
    }

    func setSelectedAuxSendIndex(for deviceID: AudioDeviceID, channel: Int, value: Int) {
        let clampedIndex = max(0, min(value, max(VirtualChannelManager.shared.auxSendChannels.count - 1, 0)))
        let key = "\(deviceID)-\(channel)"
        var state = channelStates[key] ?? ChannelStripState(id: key, maxDB: 0.0)
        state.selectedAuxSendIndex = clampedIndex
        channelStates[key] = state
        setDeviceChannelProperty(deviceID: deviceID, channel: channel, property: .auxSendBus(clampedIndex))

        if state.isLinked {
            let linkedChannel = (channel % 2 == 0) ? channel + 1 : channel - 1
            let linkedKey = "\(deviceID)-\(linkedChannel)"
            var linkedState = channelStates[linkedKey] ?? ChannelStripState(id: linkedKey, isLinked: true, maxDB: 0.0)
            linkedState.selectedAuxSendIndex = clampedIndex
            channelStates[linkedKey] = linkedState
            setDeviceChannelProperty(deviceID: deviceID, channel: linkedChannel, property: .auxSendBus(clampedIndex))
        }
    }

    func setSelectedFXSendIndex(for deviceID: AudioDeviceID, channel: Int, value: Int) {
        let clampedIndex = max(0, min(value, max(VirtualChannelManager.shared.fxSendChannels.count - 1, 0)))
        let key = "\(deviceID)-\(channel)"
        var state = channelStates[key] ?? ChannelStripState(id: key, maxDB: 0.0)
        state.selectedFXSendIndex = clampedIndex
        channelStates[key] = state
        setDeviceChannelProperty(deviceID: deviceID, channel: channel, property: .fxSendBus(clampedIndex))

        if state.isLinked {
            let linkedChannel = (channel % 2 == 0) ? channel + 1 : channel - 1
            let linkedKey = "\(deviceID)-\(linkedChannel)"
            var linkedState = channelStates[linkedKey] ?? ChannelStripState(id: linkedKey, isLinked: true, maxDB: 0.0)
            linkedState.selectedFXSendIndex = clampedIndex
            channelStates[linkedKey] = linkedState
            setDeviceChannelProperty(deviceID: deviceID, channel: linkedChannel, property: .fxSendBus(clampedIndex))
        }
    }

    /// Sets post-gain for a channel. If the channel is linked, updates both channels in the pair in real time.
    func setPostGain(for deviceID: AudioDeviceID, channel: Int, value: Float) {
        let anchor = (channel % 2 == 0) ? channel : channel - 1
        let pair = anchor + 1
        let anchorKey = "\(deviceID)-\(anchor)"
        let pairKey = "\(deviceID)-\(pair)"
        if let anchorState = channelStates[anchorKey], anchorState.isLinked {
            // Set both anchor and pair to the same postGain
            let maxDB: Float = 28.0
            let t = value / 28.0
            let dBValue = t * maxDB // 0...+28 dB
            let linearGain = pow(10.0, dBValue / 20.0)
            var newAnchorState = anchorState
            newAnchorState.postGainValue = dBValue
            channelStates[anchorKey] = newAnchorState
            setDeviceChannelProperty(deviceID: deviceID, channel: anchor, property: .postGain(Float(linearGain)))

            var newPairState = channelStates[pairKey] ?? ChannelStripState(id: pairKey, isMuted: false, isSoloed: false, isLinked: true, panValue: 63.0, faderValue: 1.0, auxSendValue: 0.0, fxSendValue: 0.0, postGainValue: 1.0, maxDB: 0.0)
            newPairState.postGainValue = dBValue
            channelStates[pairKey] = newPairState
            setDeviceChannelProperty(deviceID: deviceID, channel: pair, property: .postGain(Float(linearGain)))
        } else {
            let key = "\(deviceID)-\(channel)"
            let maxDB: Float = 28.0
            let t = value / 28.0
            let dBValue = t * maxDB
            let linearGain = pow(10.0, dBValue / 20.0)
            var state = channelStates[key] ?? ChannelStripState(id: key, isMuted: false, isSoloed: false, isLinked: false, panValue: 63.0, faderValue: 1.0, auxSendValue: 0.0, fxSendValue: 0.0, postGainValue: 1.0, maxDB: 0.0)
            state.postGainValue = dBValue
            channelStates[key] = state
            setDeviceChannelProperty(deviceID: deviceID, channel: channel, property: .postGain(Float(linearGain)))
        }
    }

    /// Returns a UI-ready string for the post-gain dB value (e.g. "+14.2 dB")
    func postGainDisplayString(for deviceID: AudioDeviceID, channel: Int) -> String {
        let dB = channelStates["\(deviceID)-\(channel)"]?.postGainValue ?? 1.0
        return String(format: "+%.1f dB", dB)
    }

    /// Initializes linked state for even-odd channel pairs if not already set.
    /// Should be called at device/channel enumeration or metering setup time for each device.
    func initializeLinkedPairsIfNeeded(for deviceID: AudioDeviceID, channelCount: Int) {
        for channel in 0..<channelCount {
            let key = "\(deviceID)-\(channel)"
            var state = channelStates[key] ?? ChannelStripState(id: key, maxDB: 0.0)
            // Link in even-odd pairs by default
            if channel % 2 == 0 && channel + 1 < channelCount {
                state.isLinked = true
                state.panValue = 0.0
                channelStates[key] = state
                let pairKey = "\(deviceID)-\(channel+1)"
                var pairState = channelStates[pairKey] ?? ChannelStripState(id: pairKey, maxDB: 0.0)
                pairState.isLinked = true
                pairState.panValue = 127.0
                channelStates[pairKey] = pairState
            } else if channelStates[key] == nil {
                // For non-linked channels, explicitly set pan to center 0.5 as default
                state.panValue = 63.0 // Default pan is center for non-linked channels
                channelStates[key] = state
            }
        }
    }

    /// Initializes linked state for virtual channels as 1-2, 3-4, ... (1-based pairs).
    /// Should be called at virtual channel enumeration/setup time.
    ///
    /// NOTE: This new signature enforces type-homogeneous linking groups.
    func initializeVirtualLinkedPairsIfNeeded(channelIDs: [UUID], channelType: VirtualChannelType) {
        // Runtime check: ensure all channelIDs correspond to VirtualChannels of the specified channelType
        let nonMatching = channelIDs.filter {
            VirtualChannelManager.shared.channel(for: $0)?.type != channelType
        }
        if !nonMatching.isEmpty {
            print("Warning: Channel IDs contain types other than \(channelType). Skipping linking initialization.")
            return
        }

        // All channels match the specified type, proceed with linking logic
        for (index, channelID) in channelIDs.enumerated() {
            var state = virtualChannelStates[channelID] ?? VirtualChannelState(id: channelID)
            // Link as 1-based: 1-2, 3-4, etc.
            if (index + 1) % 2 == 1, index + 1 < channelIDs.count {
                state.isLinked = true
                state.panValue = 0.0
                virtualChannelStates[channelID] = state
                let pairID = channelIDs[index + 1]
                var pairState = virtualChannelStates[pairID] ?? VirtualChannelState(id: pairID)
                pairState.isLinked = true
                pairState.panValue = 127.0
                virtualChannelStates[pairID] = pairState
            } else if virtualChannelStates[channelID] == nil {
                // Non-linked channels default to center pan
                state.panValue = 63.0
                virtualChannelStates[channelID] = state
            }
        }
    }

    /// Nudges all pan values by ±0.001 for linked channels and centers all mono/unlinked channels.
    func nudgeAllPanValues() {
        // Update all physical channels
        for (key, state) in channelStates {
            let deviceChannelParts = key.split(separator: "-")
            guard deviceChannelParts.count == 2, let deviceID = UInt32(deviceChannelParts[0]), let channel = Int(deviceChannelParts[1]) else { continue }
            if state.isLinked {
                let oldPan = state.panValue
                let nudge: Float = (oldPan < 127.0) ? 0.001 : -0.001
                setPan(for: deviceID, channel: channel, value: oldPan + nudge)
            } else {
                setPan(for: deviceID, channel: channel, value: 63.0)
            }
        }
        // Update all virtual channels
        for (uuid, state) in virtualChannelStates {
            if state.isLinked {
                let oldPan = state.panValue
                let nudge: Float = (oldPan < 127.0) ? 0.001 : -0.001
                setPan(for: uuid, value: oldPan + nudge)
            } else {
                setPan(for: uuid, value: 63.0)
            }
        }
    }

    /// Shows or updates a dB or pan bubble for a channel and its link, with optional timer auto-hide.
    /// - Parameters:
    ///   - deviceID: The audio device ID.
    ///   - channel: The channel index.
    ///   - dbValue: The dB value to show (used if isDB is true).
    ///   - panValue: The pan value to show (used if isDB is false).
    ///   - isDB: Set true for dB, false for pan.
    ///   - show: Show or hide the bubble.
    ///   - duration: If > 0, auto-hides after this number of seconds.
    func showBubble(for deviceID: AudioDeviceID, channel: Int, dbValue: Double? = nil, panValue: Double? = nil, isDB: Bool, show: Bool, duration: TimeInterval = 2.0) {
        let key = "\(deviceID)-\(channel)"
        var state = bubbleStates[key] ?? ChannelBubbleState()
        let now = Date()
        if isDB {
            state.showDB = show
            if let dbValue = dbValue { state.dbValue = dbValue }
        } else {
            state.showPan = show
            if let panValue = panValue { state.panValue = panValue }
        }
        state.lastUpdated = now
        bubbleStates[key] = state

        // Handle linked channel partner as well, if needed
        if isLinked(deviceID: deviceID, channel: channel) {
            let partner = (channel % 2 == 0) ? channel + 1 : channel - 1
            let partnerKey = "\(deviceID)-\(partner)"
            var partnerState = bubbleStates[partnerKey] ?? ChannelBubbleState()
            if isDB {
                partnerState.showDB = show
                if let dbValue = dbValue { partnerState.dbValue = dbValue }
            } else {
                partnerState.showPan = show
                if let panValue = panValue { partnerState.panValue = 127.0 - panValue }
            }
            partnerState.lastUpdated = now
            bubbleStates[partnerKey] = partnerState
        }

        // Auto-hide after duration
        if show && duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                guard let self = self else { return }
                var staleState = self.bubbleStates[key] ?? ChannelBubbleState()
                if isDB { staleState.showDB = false } else { staleState.showPan = false }
                self.bubbleStates[key] = staleState
                // Hide for partner
                if self.isLinked(deviceID: deviceID, channel: channel) {
                    let partner = (channel % 2 == 0) ? channel + 1 : channel - 1
                    let partnerKey = "\(deviceID)-\(partner)"
                    var partnerState = self.bubbleStates[partnerKey] ?? ChannelBubbleState()
                    if isDB { partnerState.showDB = false } else { partnerState.showPan = false }
                    self.bubbleStates[partnerKey] = partnerState
                }
            }
        }
    }

    // MARK: - New private helper method added as per instructions

    private func updateAllChannelMutesForSolo() {
        let anySoloed = channelStates.values.contains { $0.isSoloed }
        for (key, state) in channelStates {
            let deviceChannelParts = key.split(separator: "-")
            guard deviceChannelParts.count == 2,
                  let deviceID = UInt32(deviceChannelParts[0]),
                  let channel = Int(deviceChannelParts[1]) else { continue }
            let shouldMute: Bool
            if anySoloed {
                shouldMute = !state.isSoloed
            } else {
                shouldMute = state.isMuted
            }
            setDeviceChannelProperty(deviceID: AudioDeviceID(deviceID), channel: channel, property: .mute(shouldMute))
        }
    }

    /// Returns the persistent global mixer channel index for a given device/channel, or -1 if not found.
    func globalChannelIndex(for deviceID: AudioDeviceID, channel: Int) -> Int {
        inputGlobalIndexMap["\(deviceID)-\(channel)"] ?? -1
    }

    /// Returns a formatted string for the globalChannelIndex for UI overlay. Returns "--" if invalid.
    func globalChannelIndexString(for deviceID: AudioDeviceID, channel: Int) -> String {
        let idx = globalChannelIndex(for: deviceID, channel: channel)
        return idx >= 0 ? "In #\(idx)" : "In --"
    }

    /// Returns the persistent global output mixer channel index for a given device/channel, or -1 if not found.
    func globalOutputChannelIndex(for deviceID: AudioDeviceID, channel: Int) -> Int {
        outputGlobalIndexMap["\(deviceID)-\(channel)"] ?? -1
    }

    /// Returns a formatted string for the globalOutputChannelIndex for UI overlay. Returns "--" if invalid.
    func globalOutputChannelIndexString(for deviceID: AudioDeviceID, channel: Int) -> String {
        let idx = globalOutputChannelIndex(for: deviceID, channel: channel)
        return idx >= 0 ? "Out #\(idx)" : "Out --"
    }

    /// Returns input-global index (0-based) for the specified device/channel, counting only input channels.
    /// Iterates through channelStates sorted by key and counts input channels until the specified device/channel is found.
    func inputGlobalIndex(for deviceID: AudioDeviceID, channel: Int) -> Int? {
        var count = 0
        for (key, state) in channelStates.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: "-")
            guard parts.count == 2, let devID = UInt32(parts[0]), let ch = Int(parts[1]) else { continue }
            // Only count input channels
            // Here we assume all keys are inputs; if output channels are added, filter accordingly
            if devID == deviceID && ch == channel {
                return count
            }
            count += 1
        }
        return nil
    }

    /// Returns output-global index (0-based) for the specified device/channel, counting only output channels.
    /// Iterates through outputChannelStates sorted by key and counts output channels until the specified device/channel is found.
    func outputGlobalIndex(for deviceID: AudioDeviceID, channel: Int) -> Int? {
        var count = 0
        for (key, state) in outputChannelStates.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: "-")
            guard parts.count == 2, let devID = UInt32(parts[0]), let ch = Int(parts[1]) else { continue }
            if devID == deviceID && ch == channel {
                return count
            }
            count += 1
        }
        return nil
    }

    // MARK: - New method to initialize output channel states

    /// Initializes the outputChannelStates dictionary for a given device and channel count.
    /// Ensures output channels have a default ChannelStripState for UI and overlay consistency.
    ///
    /// Usage:
    /// Call this method where you initialize or activate output devices,
    /// typically alongside `initializeLinkedPairsIfNeeded` for input channels.
    func initializeOutputChannelStatesIfNeeded(for deviceID: AudioDeviceID, channelCount: Int) {
        for channel in 0..<channelCount {
            let key = "\(deviceID)-\(channel)"
            var state = outputChannelStates[key] ?? ChannelStripState(id: key, maxDB: 0.0)
            if outputEQSettingsStore[key] == nil {
                outputEQSettingsStore[key] = InputChannelEQSettings()
            }
            if outputDynamicsSettingsStore[key] == nil {
                outputDynamicsSettingsStore[key] = InputChannelDynamicsSettings()
            }

            if channel % 2 == 0 && channel + 1 < channelCount {
                state.isLinked = true
                state.panValue = 0.0
            } else if channel % 2 == 1 {
                state.isLinked = true
                state.panValue = 127.0
            } else {
                state.panValue = 63.0
            }

            outputChannelStates[key] = state

            if let globalChannelIndex = mixerGlobalOutputChannelIndex(deviceID: deviceID, channel: channel) {
                if let eqSettings = outputEQSettingsStore[key] {
                    Mixer_SetChannelEQConfig(globalChannelIndex, mixerEQConfig(from: eqSettings))
                }
                if let dynamicsSettings = outputDynamicsSettingsStore[key] {
                    Mixer_SetChannelDynamicsConfig(globalChannelIndex, mixerDynamicsConfig(from: dynamicsSettings))
                }
            }
        }
    }

    func initializeInputChannelStatesIfNeeded(for deviceID: AudioDeviceID, channelCount: Int) {
        for channel in 0..<channelCount {
            let key = "\(deviceID)-\(channel)"
            if channelStates[key] == nil {
                channelStates[key] = ChannelStripState(id: key, maxDB: 0.0)
            }
            if inputEQSettings[key] == nil {
                inputEQSettings[key] = InputChannelEQSettings()
            }
            if inputDynamicsSettings[key] == nil {
                inputDynamicsSettings[key] = InputChannelDynamicsSettings()
            }

            if let globalChannelIndex = mixerGlobalInputChannelIndex(deviceID: deviceID, channel: channel) {
                if let eqSettings = inputEQSettings[key] {
                    Mixer_SetChannelEQConfig(globalChannelIndex, mixerEQConfig(from: eqSettings))
                }
                if let dynamicsSettings = inputDynamicsSettings[key] {
                    Mixer_SetChannelDynamicsConfig(globalChannelIndex, mixerDynamicsConfig(from: dynamicsSettings))
                }
            }
        }
        // Ensure global input and output index maps are rebuilt to keep overlays correct.
        // This fixes the issue with input channels showing as Global -- in UI.
        // Only call if AudioDeviceManager and OutputDeviceManager are available and provide device lists.
        let inputDevices = AudioDeviceManager.shared.inputDevices
        let outputDevices = OutputDeviceManager.shared.outputDevices
        let inputTuples = inputDevices.map { ($0.deviceID, Int($0.inputChannels)) }
        let outputTuples = outputDevices.map { ($0.deviceID, Int($0.outputChannels)) }
        rebuildGlobalChannelIndexes(inputDevices: inputTuples, outputDevices: outputTuples)
    }
    /*
     Reminder:
     - Call `initializeOutputChannelStatesIfNeeded(for:channelCount:)` in output device registration,
       activation, or metering setup code, similar to input channel initialization.
     - This ensures the UI and overlays always have initialized state data for output channels.
     - Do not alter input channel logic or stored states.
    */

    /// Returns an array of input ChannelStripState optionals for the specified device and count.
    func inputChannelStates(for deviceID: AudioDeviceID, count: Int) -> [ChannelStripState?] {
        (0..<count).map { channelStates["\(deviceID)-\($0)"] }
    }

    /// Returns an array of output ChannelStripState optionals for the specified device and count.
    func outputChannelStates(for deviceID: AudioDeviceID, count: Int) -> [ChannelStripState?] {
        (0..<count).map { outputChannelStates["\(deviceID)-\($0)"] }
    }

    /// Rebuilds the global input and output channel index mappings. Call this whenever the device/channel topology changes.
    /// - Parameters:
    ///   - inputDevices: Array of (deviceID, channelCount) for all input devices.
    ///   - outputDevices: Array of (deviceID, channelCount) for all output devices.
    func rebuildGlobalChannelIndexes(inputDevices: [(AudioDeviceID, Int)], outputDevices: [(AudioDeviceID, Int)]) {
        var inputIdx = 0
        var newInputMap: [String: Int] = [:]
        for (deviceID, channelCount) in inputDevices.sorted(by: { $0.0 < $1.0 }) {
            for channel in 0..<channelCount {
                let key = "\(deviceID)-\(channel)"
                newInputMap[key] = inputIdx
                inputIdx += 1
            }
        }
        inputGlobalIndexMap = newInputMap

        var outputIdx = 0
        var newOutputMap: [String: Int] = [:]
        for (deviceID, channelCount) in outputDevices.sorted(by: { $0.0 < $1.0 }) {
            for channel in 0..<channelCount {
                let key = "\(deviceID)-\(channel)"
                newOutputMap[key] = outputIdx
                outputIdx += 1
            }
        }
        outputGlobalIndexMap = newOutputMap
    }

    /// Returns the global input channel index for a device/channel, or nil if not found.
    func globalInputIndex(for deviceID: AudioDeviceID, channel: Int) -> Int? {
        inputGlobalIndexMap["\(deviceID)-\(channel)"]
    }
    /// Returns the global output channel index for a device/channel, or nil if not found.
    func globalOutputIndex(for deviceID: AudioDeviceID, channel: Int) -> Int? {
        outputGlobalIndexMap["\(deviceID)-\(channel)"]
    }
}
