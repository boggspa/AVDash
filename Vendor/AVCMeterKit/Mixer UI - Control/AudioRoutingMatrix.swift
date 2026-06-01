//
//  AudioRoutingMatrix.swift
//  AVCMeter
//
//  Created by Chris Izatt on 08/07/2025.
//

import Foundation
import CoreAudio
import SwiftUI



typealias InputSampleFetcher = @convention(c) (Int32, UnsafeMutablePointer<Float>, Int32) -> Void
typealias OutputSampleWriter = @convention(c) (Int32, UnsafePointer<Float>?, Int32) -> Void



// MARK: Audio Routing Matrix
/// A class to manage audio routing logic using a C-backed routing matrix.
/// Provides dynamic control of channel routing and gain values.
class AudioRoutingMatrixManager: ObservableObject {

    static let shared = AudioRoutingMatrixManager(syncedInputs: [:], syncedOutputs: [:])

    @Published var inputChannels: [Int] = []
    @Published var outputChannels: [Int] = []
    @Published var routingTable: [RoutingKey: Bool] = [:] // [input -> output]: enabled
    @Published var inputLabels: [Int: String] = [:]
    @Published var outputLabels: [Int: String] = [:]
    @Published var routingGains: [RoutingKey: Float] = [:]
    @Published var syncedInputs: [AudioDeviceID: [Int]] = [:]
    @Published var syncedOutputs: [AudioDeviceID: [Int]] = [:]
    @Published var lastUpdated: Date = Date()

    func updateRoutingMatrixMappings() {
        let allInputs: [(Int, String)] = syncedInputs.flatMap { deviceID, channels -> [(Int, String)] in
            guard let context = AudioDeviceManager.shared.contextForDeviceID(deviceID) else { return [] }
            let mask = MultiDeviceStreamManager.shared.channelMaskCache[deviceID] ?? Array(repeating: true, count: Int(context.device.inputChannels))
            return channels.enumerated().compactMap { (index, channel) -> (Int, String)? in
                guard mask.indices.contains(index), mask[index] else { return nil }
                let globalChannelID = Int(deviceID) << 8 | channel
                return (globalChannelID, "\(context.device.name) Ch \(channel + 1)")
            }
        }

        var inputList = allInputs

        let allOutputs: [(Int, String)] = syncedOutputs.flatMap { deviceID, channels -> [(Int, String)] in
            guard let context = MultiOutputStreamManager.shared.activeOutputPollers[deviceID]?.context else { return [] }
            let mask = OutputDeviceManager.shared.selectedChannelMasks[deviceID] ?? Array(repeating: true, count: Int(context.device.outputChannels))
            return channels.filter { mask.indices.contains($0) ? mask[$0] : false }.map { channel in
                let globalChannelID = Int(deviceID) << 8 | channel
                return (globalChannelID, "\(context.device.name) Ch \(channel + 1)")
            }
        }

        self.inputChannels = allInputs.map(\.0)
        self.outputChannels = allOutputs.map(\.0)

        for (input, label) in inputList {
            inputLabels[input] = label
        }
        for (output, label) in allOutputs {
            outputLabels[output] = label
        }

        let validKeys = Set(outputChannels.flatMap { output in
            inputChannels.map { input in RoutingKey(input: input, output: output) }
        })

        routingTable = routingTable.filter { validKeys.contains($0.key) }
        routingGains = routingGains.filter { validKeys.contains($0.key) }

        for output in outputChannels {
            for input in inputChannels {
                let key = RoutingKey(input: input, output: output)
                if routingTable[key] == nil {
                    routingTable[key] = true
                    routingGains[key] = 1.0
                }
            }
        }

        syncBridgeFromRoutingTable()
        self.lastUpdated = Date()
    }

    func updateInputs(_ newInputs: [AudioDeviceID: [Int]]) {
        syncedInputs = newInputs
        updateRoutingMatrixMappings()
    }

    func updateOutputs(_ newOutputs: [AudioDeviceID: [Int]]) {
        syncedOutputs = newOutputs
        updateRoutingMatrixMappings()
    }

    /// Rebuilds routing maps from current active devices — call this instead of ContentView().updateRoutingMatrixMappings()
    func refreshFromActiveDevices() {
        let manager = AudioDeviceManager.shared
        let inputContexts = manager.activeDevices.values.map { $0 }
        let inputMap: [AudioDeviceID: [Int]] = Dictionary(
            uniqueKeysWithValues: inputContexts.map { context in
                let mask = manager.selectedChannelMasks[context.device.deviceID]
                    ?? Array(repeating: true, count: Int(context.device.inputChannels))
                let indices = mask.enumerated().compactMap { $0.element ? $0.offset : nil }
                return (context.device.deviceID, indices)
            }
        )
        let outputMap = MultiOutputStreamManager.shared.getActiveOutputChannels()
        updateInputs(inputMap)
        updateOutputs(outputMap)
        updateRoutingMatrixMappings()
    }


    /// Represents a routing connection between a global input and global output.
    /// Both input and output must be in global channel ID format (deviceID << 8 | channel).
    struct RoutingKey: Hashable {
        let input: Int
        let output: Int
    }

    init(syncedInputs: [AudioDeviceID: [Int]], syncedOutputs: [AudioDeviceID: [Int]]) {
        self.syncedInputs = syncedInputs
        self.syncedOutputs = syncedOutputs
        updateRoutingMatrixMappings()
    }

    /// Toggle a route using global channel IDs (deviceID << 8 | channel).
    func toggleRoute(input: Int, output: Int) {
        let key = RoutingKey(input: input, output: output)
        let newState = !(routingTable[key] ?? false)
        setRoute(input: input, output: output, enabled: newState)
    }

    func setRoute(input: Int, output: Int, enabled: Bool) {
        let key = RoutingKey(input: input, output: output)
        routingTable[key] = enabled

        if enabled {
            routingGains[key] = 1.0
        } else {
            routingGains.removeValue(forKey: key)
        }

        RoutingBridge.shared.markRoute(from: input, to: output, enabled: enabled)
        lastUpdated = Date()
    }

    func setAllRoutes(forInput input: Int, enabled: Bool) {
        for output in outputChannels {
            setRoute(input: input, output: output, enabled: enabled)
        }
        syncBridgeFromRoutingTable()
        lastUpdated = Date()
    }

    func setAllRoutes(forOutput output: Int, enabled: Bool) {
        for input in inputChannels {
            setRoute(input: input, output: output, enabled: enabled)
        }
        syncBridgeFromRoutingTable()
        lastUpdated = Date()
    }

    func resetAllRoutesToDefault() {
        for output in outputChannels {
            for input in inputChannels {
                let key = RoutingKey(input: input, output: output)
                routingTable[key] = true
                routingGains[key] = 1.0
            }
        }
        syncBridgeFromRoutingTable()
        lastUpdated = Date()
    }

    func isRouteEnabled(input: Int, output: Int) -> Bool {
        return routingTable[RoutingKey(input: input, output: output)] ?? false
    }

    func setRoutingGainValue(input: Int, output: Int, gain: Float) {
        let key = RoutingKey(input: input, output: output)
        routingGains[key] = gain
    }

    private func syncBridgeFromRoutingTable() {
        let activeRoutes = Set(
            routingTable.compactMap { entry in
                entry.value ? Route(input: entry.key.input, output: entry.key.output) : nil
            }
        )
        RoutingBridge.shared.replaceRoutes(
            activeRoutes: activeRoutes,
            explicitOutputs: Set(outputChannels)
        )
    }

/*
    /// Process and mix all routed input/output channel pairs for a block of audio frames.
    /// Call this from a timer or audio-driven thread to perform full Swift-side routing.
    @MainActor
    func processRoutingFrameBlock(frameCount: Int) {
        let inputPollers = MultiDeviceStreamManager.shared.activePollers
        let outputPollers = MultiOutputStreamManager.shared.activeOutputPollers
        let channelMaskCache = MultiDeviceStreamManager.shared.channelMaskCache

        for (outputDeviceID, outputEntry) in outputPollers {
            let context = outputEntry.context
            let outputChannelMask = OutputDeviceManager.shared.selectedChannelMasks[outputDeviceID] ?? []

            for outputChannel in 0..<context.device.outputChannels {
                guard outputChannelMask.indices.contains(Int(outputChannel)),
                      outputChannelMask[Int(outputChannel)] else { continue }

                let outputGlobalChannel = Int(outputDeviceID) << 8 | Int(outputChannel)
                var outputBuffer = [Float](repeating: 0.0, count: frameCount)

                for (inputDeviceID, inputPoller) in inputPollers {
                    let inputChannelMask = channelMaskCache[inputDeviceID] ?? []

                    for inputChannel in 0..<inputPoller.channelMask.count {
                        guard inputChannelMask.indices.contains(Int(inputChannel)),
                              inputChannelMask[Int(inputChannel)] else { continue }

                        let inputGlobalChannel = Int(inputDeviceID) << 8 | Int(inputChannel)
                        let routingKey = RoutingKey(input: inputGlobalChannel, output: outputGlobalChannel)
                        guard routingTable[routingKey] == true else { continue }
                        let gain = routingGains[routingKey] ?? 1.0

                        if let buffer = inputRingBuffers[inputGlobalChannel] {
                            let tempBuffer = buffer.read(frames: frameCount)
                            let readCount = tempBuffer.count
                            if readCount > 0 {
                                for i in 0..<min(frameCount, readCount) {
                                    outputBuffer[i] += tempBuffer[i] * gain
                                }
                            }
                        }
                    }
                }

                // Write the final mixed outputBuffer to the HAL-compatible ring buffer for playback
                outputBuffer.withUnsafeBufferPointer { ptr in
                    let outCh = outputGlobalChannel & 0xFF // just channel number
                    WriteToOutputBuffer(Int(Int32(outCh)), ptr.baseAddress, Int(Int32(frameCount)))
                }
            }
        }
    }*/


// MARK: - Routing Gain C Bridge

}



/// A SwiftUI view that shows a grid of input/output routing toggles.
struct AudioRoutingMatrixView: View {
    @ObservedObject var manager = AudioRoutingMatrixManager.shared

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 14) {
                controlsRow
                headerRow
                ForEach(matrixRows) { row in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.outputLabel)
                                .font(.system(size: 14, weight: .semibold))
                            HStack(spacing: 8) {
                                Button("All") {
                                    manager.setAllRoutes(forOutput: row.output, enabled: true)
                                }
                                Button("None") {
                                    manager.setAllRoutes(forOutput: row.output, enabled: false)
                                }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        }
                        .frame(width: 150, alignment: .leading)
                        ForEach(row.inputColumns, id: \.input) { column in
                            columnView(for: column)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            manager.updateRoutingMatrixMappings()
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {
            Button("Default All Routes") {
                manager.resetAllRoutesToDefault()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
            )

            Text("\(manager.inputChannels.count) inputs -> \(manager.outputChannels.count) outputs")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            Text("Output/Input")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 150, alignment: .leading)
            ForEach(manager.inputChannels, id: \.self) { input in
                Text(manager.inputLabels[input] ?? "In \(input)")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 92)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private struct MatrixCell {
        let input: Int
        let output: Int
        let isEnabled: Bool
        let faderValue: Float
    }

    private struct MatrixRow: Identifiable {
        let id: String
        let output: Int
        let outputLabel: String
        let inputColumns: [MatrixCell]
    }

    private var matrixRows: [MatrixRow] {
        _ = manager.lastUpdated  // trigger recompute when updated
        return manager.outputChannels.enumerated().map { index, output in
            let label = manager.outputLabels[output] ?? "Out \(output)"
            let inputs = manager.inputChannels.map { input in
                MatrixCell(
                    input: input,
                    output: output,
                    isEnabled: manager.isRouteEnabled(input: input, output: output),
                    faderValue: ChannelStateManager.shared.getFaderValue(forChannel: input)
                )
            }
            return MatrixRow(
                id: "out-\(output)-\(index)",
                output: output,
                outputLabel: label,
                inputColumns: inputs
            )
        }
    }

    @ViewBuilder
    private func columnView(for cell: MatrixCell) -> some View {
        VStack(spacing: 8) {
            Button {
                manager.toggleRoute(input: cell.input, output: cell.output)
            } label: {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(cell.isEnabled ? Color.green.opacity(0.78) : Color.white.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(cell.isEnabled ? Color.green.opacity(0.95) : Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .frame(width: 26, height: 26)
                    .overlay(
                        Image(systemName: cell.isEnabled ? "checkmark" : "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(cell.isEnabled ? 0.95 : 0.45))
                    )
            }
            .buttonStyle(.plain)

            Text(String(format: "%.0f%%", min(max(cell.faderValue, 0), 1.2) * 100))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .frame(width: 92)
    }
}

extension AudioDeviceManager {
    func contextForDeviceID(_ deviceID: AudioDeviceID) -> DeviceMeteringContext? {
        return activeDevices[deviceID]
    }
}
