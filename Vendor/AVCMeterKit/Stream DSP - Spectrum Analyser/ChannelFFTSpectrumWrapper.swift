//
//  ChannelFFTSpectrumWrapper.swift
//  AVCMeter
//
//  Created by Chris Izatt on 22/06/2025.
//

import Foundation
import Combine

class ChannelFFTSpectrumWrapper: ObservableObject {
    private let channelIndex: Int
    let fftSize: Int
    private let totalChannels: Int
    let device: AudioDevice

    @Published var normalizedMagnitudes: [NSNumber] = []
    @Published var peakData: [Float] = []

    private var updateTimer: Timer?

    init(channelIndex: Int, fftSize: Int = 512, device: AudioDevice, totalChannels: Int) {
        self.channelIndex = channelIndex
        self.fftSize = fftSize
        self.device = device
        self.totalChannels = totalChannels
    }

    func processSamples(_ samples: UnsafeMutablePointer<Float>, length: Int) {
        // Extract only this channel’s samples
        var channelSamples = [Float]()
        for i in stride(from: channelIndex, to: length, by: totalChannels) {
            channelSamples.append(samples[i])
        }
        // Forward this channel’s raw PCM samples directly to the C bridge
        channelSamples.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                ChannelSpectrumBridge_ProcessSamples(device.deviceID, Int32(channelIndex), UnsafeMutablePointer(mutating: base), Int32(buffer.count))
            }
        }
    }

    /// Begins periodic fetching of peak magnitudes at given frames-per-second.
    func start(fps: Double = 60.0) {
        // Invalidate any existing timer
        updateTimer?.invalidate()
        // Schedule on main run loop common modes
        let newTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / fps, repeats: true) { [weak self] _ in
            self?.getPeakMagnitudes()
        }
        RunLoop.main.add(newTimer, forMode: .common)
        updateTimer = newTimer
    }

    /// Stops the periodic updating.
    func stop() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    /// Updates `normalizedMagnitudes` from the FFT bridge and publishes it
    func getPeakMagnitudes() {
        var length: Int32 = 0
        guard let magnitudesPointer = ChannelSpectrumBridge_getPeakMagnitudes(device.deviceID, Int32(channelIndex), &length), length > 0 else {
            return
        }

        let binCount = min(Int(length), fftSize)
        let buffer = UnsafeBufferPointer<Float>(start: magnitudesPointer, count: binCount)

        let normalized = Array(buffer.map { min(max($0, 0.0), 1.0) }) // clamp to [0,1] to ensure visible graph range

        if normalized.allSatisfy({ $0 == 0.0 }) {
            return
        }

        // Clamp magnitudes to [0,1] to ensure they render in the SwiftUI graph
        DispatchQueue.main.async { [weak self] in
            self?.peakData = normalized
            self?.normalizedMagnitudes = normalized.map { NSNumber(value: $0) }
        }
    }

    func rawMagnitudes() -> [Float] {
        var length: Int32 = 0
        guard let pointer = ChannelSpectrumBridge_getPeakMagnitudes(device.deviceID, Int32(channelIndex), &length),
              length > 0 else {
            return []
        }
        let binCount = min(Int(length), fftSize)
        let buffer = UnsafeBufferPointer(start: pointer, count: binCount)
        return Array(buffer)
    }
    func peakMagnitudes() -> [Float] {
        return peakData
    }

    deinit {
        stop()
    }
}
