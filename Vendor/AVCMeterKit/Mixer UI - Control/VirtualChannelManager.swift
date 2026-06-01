//
//  VirtualChannelManager.swift
//  AVCMeter
//
//  Created by Chris Izatt on 07/07/2025.
//

import Foundation
import Combine
import AVFoundation
import AudioToolbox
import CoreAudio

/// Enumeration of virtual channel types (Input and Output)
enum VirtualChannelType: String, Codable {
    case fxReturn
    case auxReturn
    case virtualInstrument
    case fxSend
    case auxSend
    case dca
}

/// Base virtual channel struct
struct VirtualChannel: Identifiable, Codable {
    let id = UUID()
    let name: String
    let type: VirtualChannelType
    var index: Int
    var isMuted: Bool = false
    var pan: Float = 63.0  // 0 = hard left, 127 = hard right
    var gain: Float = 1.0  // linear gain multiplier
}

struct VirtualInstrumentDescriptor: Identifiable, Hashable {
    let componentType: UInt32
    let componentSubType: UInt32
    let componentManufacturer: UInt32
    let name: String
    let manufacturerName: String

    var id: String {
        "\(componentType)-\(componentSubType)-\(componentManufacturer)"
    }

    var displayName: String {
        name
    }

    var audioComponentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: componentType,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }
}

struct VirtualInstrumentSelection: Codable {
    let instrumentID: String
    let displayName: String
    let manufacturerName: String
}

/// Manager for creating and storing all virtual input/output channels
final class VirtualChannelManager: ObservableObject {
    static let shared = VirtualChannelManager()

    private let viSelectionDefaultsKey = "viInstrumentSelectionByChannel"

    struct VirtualMeteringContext: Identifiable {
        // Stable identity based on type+name so SwiftUI can diff without tearing down views
        var id: String { "\(type.rawValue):\(name)" }
        let name: String
        let type: VirtualChannelType
        var channels: [VirtualChannel]
    }

    @Published var fxReturnChannels: [VirtualChannel] = []
    @Published var auxReturnChannels: [VirtualChannel] = []
    @Published var virtualInstrumentChannels: [VirtualChannel] = []

    @Published var fxSendChannels: [VirtualChannel] = []
    @Published var auxSendChannels: [VirtualChannel] = []
    @Published var dcaChannels: [VirtualChannel] = []

    @Published var inputGroups: [VirtualMeteringContext] = []
    @Published var outputGroups: [VirtualMeteringContext] = []
    @Published var availableVirtualInstruments: [VirtualInstrumentDescriptor] = []
    @Published private(set) var virtualInstrumentSelectionByChannel: [String: VirtualInstrumentSelection] = [:]

    init() {
        loadVirtualInstrumentSelections()
        createVirtualInputs()
        createVirtualOutputs()
        createGroupedContexts()
        refreshAvailableVirtualInstruments()
    }

    // MARK: - Initialization

    private func createVirtualInputs() {
        fxReturnChannels = (0..<8).map {
            VirtualChannel(name: "FX Return \($0 + 1)", type: .fxReturn, index: $0)
        }

        auxReturnChannels = (0..<16).map {
            VirtualChannel(name: "Aux Return \($0 + 1)", type: .auxReturn, index: $0)
        }

        virtualInstrumentChannels = (0..<16).map {
            VirtualChannel(name: "VI \($0 + 1)", type: .virtualInstrument, index: $0)
        }
    }

    private func createVirtualOutputs() {
        fxSendChannels = (0..<4).map {
            VirtualChannel(name: "FX Send \($0 + 1)", type: .fxSend, index: $0)
        }

        auxSendChannels = (0..<8).map {
            VirtualChannel(name: "Aux Send \($0 + 1)", type: .auxSend, index: $0)
        }

        dcaChannels = (0..<8).map {
            VirtualChannel(name: "DCA \($0 + 1)", type: .dca, index: $0)
        }
    }

    // MARK: - Dynamic Generator

    func generateChannels(type: VirtualChannelType, count: Int) {
        let channels = (0..<count).map {
            VirtualChannel(name: "\(displayName(for: type)) \($0 + 1)", type: type, index: $0)
        }
        assignChannels(type: type, channels: channels)
        createGroupedContexts()
    }

    private func displayName(for type: VirtualChannelType) -> String {
        switch type {
        case .fxReturn: return "FX Return"
        case .auxReturn: return "Aux Return"
        case .virtualInstrument: return "VI"
        case .fxSend: return "FX Send"
        case .auxSend: return "Aux Send"
        case .dca: return "DCA"
        }
    }

    private func assignChannels(type: VirtualChannelType, channels: [VirtualChannel]) {
        switch type {
        case .fxReturn:
            fxReturnChannels = channels
        case .auxReturn:
            auxReturnChannels = channels
        case .virtualInstrument:
            virtualInstrumentChannels = channels
        case .fxSend:
            fxSendChannels = channels
        case .auxSend:
            auxSendChannels = channels
        case .dca:
            dcaChannels = channels
        }
        createGroupedContexts()
    }

    // MARK: - Utility

    func refreshAvailableVirtualInstruments() {
        let manager = AVAudioUnitComponentManager.shared()
        var description = AudioComponentDescription()
        description.componentType = kAudioUnitType_MusicDevice
        description.componentSubType = 0
        description.componentManufacturer = 0
        description.componentFlags = 0
        description.componentFlagsMask = 0

        let components = manager.components(matching: description)
        availableVirtualInstruments = components.map { component in
            let desc = component.audioComponentDescription
            return VirtualInstrumentDescriptor(
                componentType: desc.componentType,
                componentSubType: desc.componentSubType,
                componentManufacturer: desc.componentManufacturer,
                name: component.name,
                manufacturerName: component.manufacturerName
            )
        }
        .sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    func selectedVirtualInstrumentID(for deviceID: AudioDeviceID, channelIndex: Int) -> String? {
        let key = virtualInstrumentSelectionKey(deviceID: deviceID, channelIndex: channelIndex)
        return virtualInstrumentSelectionByChannel[key]?.instrumentID
    }

    func selectedVirtualInstrumentDisplayName(for deviceID: AudioDeviceID, channelIndex: Int) -> String? {
        let key = virtualInstrumentSelectionKey(deviceID: deviceID, channelIndex: channelIndex)
        return virtualInstrumentSelectionByChannel[key]?.displayName
    }

    func selectedVirtualInstrument(for deviceID: AudioDeviceID, channelIndex: Int) -> VirtualInstrumentDescriptor? {
        guard let selectedID = selectedVirtualInstrumentID(for: deviceID, channelIndex: channelIndex) else {
            return nil
        }
        return availableVirtualInstruments.first(where: { $0.id == selectedID })
    }

    func selectVirtualInstrument(_ instrument: VirtualInstrumentDescriptor, for deviceID: AudioDeviceID, channelIndex: Int) {
        let key = virtualInstrumentSelectionKey(deviceID: deviceID, channelIndex: channelIndex)
        virtualInstrumentSelectionByChannel[key] = VirtualInstrumentSelection(
            instrumentID: instrument.id,
            displayName: instrument.displayName,
            manufacturerName: instrument.manufacturerName
        )
        persistVirtualInstrumentSelections()
        VirtualInstrumentHostManager.shared.updateInstrumentSelection(
            for: deviceID,
            channelIndex: channelIndex,
            instrument: instrument
        )
    }

    func clearVirtualInstrumentSelection(for deviceID: AudioDeviceID, channelIndex: Int) {
        let key = virtualInstrumentSelectionKey(deviceID: deviceID, channelIndex: channelIndex)
        virtualInstrumentSelectionByChannel.removeValue(forKey: key)
        persistVirtualInstrumentSelections()
        VirtualInstrumentHostManager.shared.updateInstrumentSelection(
            for: deviceID,
            channelIndex: channelIndex,
            instrument: nil
        )
    }

    func channel(for id: UUID) -> VirtualChannel? {
        allChannels.first(where: { $0.id == id })
    }

    var allChannels: [VirtualChannel] {
        fxReturnChannels +
        auxReturnChannels +
        virtualInstrumentChannels +
        fxSendChannels +
        auxSendChannels +
        dcaChannels
    }
    var inputContexts: [VirtualMeteringContext] {
        [
            VirtualMeteringContext(name: "FX Returns", type: .fxReturn, channels: fxReturnChannels),
            VirtualMeteringContext(name: "Aux Returns", type: .auxReturn, channels: auxReturnChannels),
            VirtualMeteringContext(name: "VIs", type: .virtualInstrument, channels: virtualInstrumentChannels)
        ]
    }

    var outputContexts: [VirtualMeteringContext] {
        [
            VirtualMeteringContext(name: "FX Sends", type: .fxSend, channels: fxSendChannels),
            VirtualMeteringContext(name: "Aux Sends", type: .auxSend, channels: auxSendChannels),
            VirtualMeteringContext(name: "DCA", type: .dca, channels: dcaChannels)
        ]
    }

    var fxReturnContexts: [VirtualMeteringContext] {
        return [
            VirtualMeteringContext(name: "FX Returns", type: .fxReturn, channels: fxReturnChannels)
        ]
    }
    private func createGroupedContexts() {
        inputGroups = [
            VirtualMeteringContext(name: "FX Returns", type: .fxReturn, channels: fxReturnChannels),
            VirtualMeteringContext(name: "Aux Returns", type: .auxReturn, channels: auxReturnChannels),
            VirtualMeteringContext(name: "VIs", type: .virtualInstrument, channels: virtualInstrumentChannels)
        ]

        outputGroups = [
            VirtualMeteringContext(name: "FX Sends", type: .fxSend, channels: fxSendChannels),
            VirtualMeteringContext(name: "Aux Sends", type: .auxSend, channels: auxSendChannels),
            VirtualMeteringContext(name: "DCA", type: .dca, channels: dcaChannels)
        ]
    }

    func updateChannel(_ updated: VirtualChannel) {
        switch updated.type {
        case .fxReturn:
            fxReturnChannels[updated.index] = updated
        case .auxReturn:
            auxReturnChannels[updated.index] = updated
        case .virtualInstrument:
            virtualInstrumentChannels[updated.index] = updated
        case .fxSend:
            fxSendChannels[updated.index] = updated
        case .auxSend:
            auxSendChannels[updated.index] = updated
        case .dca:
            dcaChannels[updated.index] = updated
        }
        createGroupedContexts()
    }

    private func virtualInstrumentSelectionKey(deviceID: AudioDeviceID, channelIndex: Int) -> String {
        "\(deviceID)-\(channelIndex)"
    }

    private func loadVirtualInstrumentSelections() {
        guard let data = UserDefaults.standard.data(forKey: viSelectionDefaultsKey) else {
            return
        }

        if let decoded = try? JSONDecoder().decode([String: VirtualInstrumentSelection].self, from: data) {
            virtualInstrumentSelectionByChannel = decoded
        }
    }

    private func persistVirtualInstrumentSelections() {
        guard let data = try? JSONEncoder().encode(virtualInstrumentSelectionByChannel) else {
            return
        }
        UserDefaults.standard.set(data, forKey: viSelectionDefaultsKey)
    }
}

extension VirtualChannelType {
    var isLinkable: Bool {
        switch self {
        case .fxSend:
            return false
        default:
            return true
        }
    }
}
