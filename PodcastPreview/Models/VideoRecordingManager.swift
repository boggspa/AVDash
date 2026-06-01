
import Foundation
import AVFoundation
import Combine
import PodcastPreviewCore

@MainActor
final class VideoRecordingManager: ObservableObject {
    static let shared = VideoRecordingManager()
    
    @Published var recordingStates: [String: RecordingState] = [:]
    @Published var selectedAudioDevices: [String: AudioDeviceID] = [:]
    
    private var assetWriters: [String: AVAssetWriter] = [:]
    private var videoInputs: [String: AVAssetWriterInput] = [:]
    private var pixelBufferAdaptors: [String: AVAssetWriterInputPixelBufferAdaptor] = [:]
    private var sessions: [String: AVCaptureSession] = [:]
    private var timers: [String: Timer] = [:]
    
    struct RecordingState: Equatable {
        var isRecording: Bool = false
        var duration: TimeInterval = 0
    }
    
    func toggleRecording(for cameraID: String, displayName: String, codec: AVVideoCodecType = .proRes422, resolution: String = "1920x1080", processedFrameSource: CameraMetalPreviewModel? = nil) {
        if recordingStates[cameraID]?.isRecording == true {
            stopRecording(for: cameraID, processedFrameSource: processedFrameSource)
        } else {
            startRecording(for: cameraID, displayName: displayName, codec: codec, resolution: resolution, processedFrameSource: processedFrameSource)
        }
    }
    
    func startRecording(for cameraID: String, displayName: String, codec: AVVideoCodecType, resolution: String, processedFrameSource: CameraMetalPreviewModel? = nil) {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateString = formatter.string(from: Date())
        let fileName = "Recording_\(displayName)_\(dateString).mov"
        let outputURL = documentsPath.appendingPathComponent(fileName)
        
        // Remove existing file if any
        try? FileManager.default.removeItem(at: outputURL)
        
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            
            let resParts = resolution.split(separator: "x")
            let width = Int(resParts[0]) ?? 1920
            let height = Int(resParts[1]) ?? 1080
            
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
            
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ]
            )
            
            if writer.canAdd(videoInput) {
                writer.add(videoInput)
            }
            
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            
            assetWriters[cameraID] = writer
            videoInputs[cameraID] = videoInput
            pixelBufferAdaptors[cameraID] = adaptor
            
            if let source = processedFrameSource {
                source.onProcessedFrame = { [weak self] buffer, timestamp in
                    Task { @MainActor in
                        self?.appendVideoBuffer(buffer, timestamp: timestamp, for: cameraID)
                    }
                }
            }
            
            recordingStates[cameraID] = RecordingState(isRecording: true, duration: 0)
            startTimer(for: cameraID)
            
        } catch {
            print("Error: Failed to start AVAssetWriter: \(error)")
        }
    }
    
    func stopRecording(for cameraID: String, processedFrameSource: CameraMetalPreviewModel? = nil) {
        processedFrameSource?.onProcessedFrame = nil
        
        if let writer = assetWriters[cameraID], let input = videoInputs[cameraID] {
            input.markAsFinished()
            writer.finishWriting {
                DispatchQueue.main.async {
                    print("AVAssetWriter finished recording for \(cameraID)")
                }
            }
        }
        
        assetWriters.removeValue(forKey: cameraID)
        videoInputs.removeValue(forKey: cameraID)
        pixelBufferAdaptors.removeValue(forKey: cameraID)
        
        recordingStates[cameraID]?.isRecording = false
        stopTimer(for: cameraID)
    }
    
    private func appendVideoBuffer(_ buffer: CVPixelBuffer, timestamp: CMTime, for cameraID: String) {
        guard let adaptor = pixelBufferAdaptors[cameraID],
              let input = videoInputs[cameraID],
              input.isReadyForMoreMediaData else {
            return
        }
        
        adaptor.append(buffer, withPresentationTime: timestamp)
    }
    
    func setAudioDevice(for cameraID: String, audioDeviceID: AudioDeviceID?) {
        selectedAudioDevices[cameraID] = audioDeviceID
        
        let session = getOrCreateSession(for: cameraID)
        session.beginConfiguration()
        
        // Remove existing audio inputs
        for input in session.inputs {
            if (input as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true {
                session.removeInput(input)
            }
        }
        
        // Add new one
        if let id = audioDeviceID, let avDevice = findAVAudioDevice(for: id) {
            do {
                let input = try AVCaptureDeviceInput(device: avDevice)
                if session.canAddInput(input) {
                    session.addInput(input)
                }
            } catch {
                print("Error: Failed to add audio input to recording session: \(error)")
            }
        }
        
        session.commitConfiguration()
    }
    
    private func getOrCreateSession(for cameraID: String, resolution: String = "1920x1080") -> AVCaptureSession {
        if let session = sessions[cameraID] {
            return session
        }
        
        let session = AVCaptureSession()
        session.beginConfiguration()
        
        // Set resolution preset
        if resolution == "3840x2160" && session.canSetSessionPreset(.hd4K3840x2160) {
            session.sessionPreset = .hd4K3840x2160
        } else if resolution == "1920x1080" && session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if resolution == "1280x720" && session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        
        // Find video device
        if let videoDevice = AVCaptureDevice(uniqueID: cameraID) {
            do {
                let input = try AVCaptureDeviceInput(device: videoDevice)
                if session.canAddInput(input) {
                    session.addInput(input)
                }
            } catch {
                print("Error: Failed to create video input for recording session: \(error)")
            }
        }
        
        session.commitConfiguration()
        sessions[cameraID] = session
        return session
    }
    
    private func startTimer(for cameraID: String) {
        timers[cameraID]?.invalidate()
        timers[cameraID] = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recordingStates[cameraID]?.duration += 1
            }
        }
    }
    
    private func stopTimer(for cameraID: String) {
        timers[cameraID]?.invalidate()
        timers.removeValue(forKey: cameraID)
    }
    
    private func findAVAudioDevice(for coreAudioID: AudioDeviceID) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices
        
        var nameBuffer: [CChar] = Array(repeating: 0, count: 256)
        if AudioDevices_GetDeviceName(coreAudioID, &nameBuffer, 256) == noErr {
            let name = String(cString: nameBuffer)
            return devices.first(where: { $0.localizedName == name })
        }
        
        return nil
    }
}
