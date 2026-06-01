//
//  AVCaptureMeteringSession.swift
//  AVCMeter
//
//  This class uses AVCaptureSession to create a fallback audio metering session
//  using AVFoundation. It processes live audio buffers to compute and return
//  RMS and Peak values in dBFS from a given input device UID.
//
//  Created by Chris Izatt on 11/06/2025.
//

import AVFoundation

// MARK: - AVCaptureMeteringSession
// Provides a lightweight audio metering fallback using AVFoundation,
// useful when CoreAudio-based HAL input streams are unavailable.
class AVCaptureMeteringSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "AVCaptureMeteringQueue")
    private var levelUpdate: ((Float, Float) -> Void)?

    /// Initializes the session with a given device UID and callback for level updates.
    /// - Parameters:
    ///   - deviceUID: Unique ID of the input audio device.
    ///   - levelUpdate: Closure receiving RMS and Peak levels (in dB).
    init(deviceUID: String, levelUpdate: @escaping (Float, Float) -> Void) {
        self.levelUpdate = levelUpdate
        super.init()

        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.builtInMicrophone, .externalUnknown, .microphone]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        )

        guard let device = discovery.devices.first(where: {
            $0.uniqueID == deviceUID
        }) else {
            print("AVCaptureDevice with UID \(deviceUID) not found.")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }

            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
        } catch {
            print("Error setting up AVCapture input: \(error)")
        }
    }

    /// Starts the AVCapture audio session.
    /// - Returns: Bool indicating if the session is running.
    func start() -> Bool {
        session.startRunning()
        return session.isRunning
    }

    /// Stops the AVCapture audio session.
    func stop() {
        session.stopRunning()
    }

    /// Delegate method processing audio sample buffers.
    /// Computes RMS and peak values and sends them to the callback.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let pointer = dataPointer else { return }

        // Bind the raw audio data to Int16 samples and calculate RMS and Peak
        let samples = UnsafeMutableRawPointer(pointer).bindMemory(to: Int16.self, capacity: length / 2)
        let sampleCount = length / 2

        var sumSquares: Float = 0
        var peak: Float = 0

        for i in 0..<sampleCount {
            let sample = samples[i]
            let absSample = abs(Float(sample))
            peak = max(peak, absSample)
            let floatSample = Float(sample)
            sumSquares += floatSample * floatSample
        }

        let meanSquare = sumSquares / Float(sampleCount)
        let rms = sqrt(meanSquare)
        let rmsDb = 20 * log10(rms / Float(Int16.max))
        let peakDb = 20 * log10(peak / Float(Int16.max))

        DispatchQueue.main.async {
            // Send computed dB values to the provided callback on the main thread
            self.levelUpdate?(rmsDb.isFinite ? rmsDb : -100, peakDb.isFinite ? peakDb : -100)
        }
    }
}
