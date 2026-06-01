//
//  AudioBridgeManager.swift
//  AVCMeter
//
//  Created by Chris Izatt on 13/06/2025.
//

import Foundation
import CoreAudio

final class AudioBridgeManager: ObservableObject {
    static let shared = AudioBridgeManager()
    enum Mode {
        case transmit
        case receive
        case idle
    }

    @Published var mode: Mode = .idle
    @Published var selectedDeviceID: AudioDeviceID?
    @Published var selectedChannels: [Int] = []

    private var txPublisher: TXStreamPublisher?
    private var rxReceiver: RXStreamReceiver?

    func config(for deviceID: AudioDeviceID) -> AudioBridgeConfig {
        switch mode {
        case .transmit:
            return AudioBridgeConfig(sampleRate: 48000, numChannels: 2, frameSize: 2048, port: 8000, mode: .transmit)
        case .receive:
            return AudioBridgeConfig(sampleRate: 48000, numChannels: 2, frameSize: 2048, port: 8000, mode: .receive)
        case .idle:
            return AudioBridgeConfig(sampleRate: 48000, numChannels: 2, frameSize: 2048, port: 8000, mode: .transmit)
        }
    }

}
