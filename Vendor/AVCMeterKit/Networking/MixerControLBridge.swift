//
//  MixerControlBridge.swift
//  AVCMeter
//
//  Created by Chris Izatt on 18/06/2025.
//

import Foundation
import Combine

@MainActor
final class MixerControlBridge: ObservableObject {
    static let shared = MixerControlBridge()

    // Published mixer state
    @Published var inputChannels: [Channel] = []
    @Published var outputChannels: [Channel] = []

    // Control: Mixer on/off, routing mode, sample rate, etc.
    @Published var isTransmitting: Bool = false
    @Published var sampleRate: Double = 48000

    private init() {
        loadInitialConfiguration()
    }

    func loadInitialConfiguration() {
        // Default mixer state used until the daemon publishes its runtime configuration.
        inputChannels = [
            Channel(name: "Mic 1", index: 0, isSelected: true),
            Channel(name: "Mic 2", index: 1, isSelected: false)
        ]
        outputChannels = [
            Channel(name: "Headphones", index: 0, isSelected: true),
            Channel(name: "Network Stream", index: 1, isSelected: false)
        ]
    }

    func toggleTransmit(_ enabled: Bool) {
        isTransmitting = enabled
        if enabled {
            startMixing()
        } else {
            stopMixing()
        }
    }

    func startMixing() {
        // Reserved hook for the C mixer engine bridge.
        print("[Mixer] Starting with sample rate \(sampleRate)")
    }

    func stopMixing() {
        // Reserved hook for stopping mixer routing threads.
        print("[Mixer] Stopping mixer")
    }

    func updateChannelSelection(input: Bool, index: Int, isSelected: Bool) {
        if input {
            guard index >= 0 && index < inputChannels.count else { return }
            inputChannels[index].isSelected = isSelected
        } else {
            guard index >= 0 && index < outputChannels.count else { return }
            outputChannels[index].isSelected = isSelected
        }
    }
}
