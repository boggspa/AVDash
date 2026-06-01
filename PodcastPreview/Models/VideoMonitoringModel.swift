//
//  VideoMonitoringModel.swift
//  PodcastPreview
//
//  Created by Chris Izatt on 18/12/2025.
//

import Foundation
import AVFoundation
import Combine
import PodcastPreviewCore
import CoreGraphics
import Darwin

// MARK: - VideoMonitoringModel

/// Container/logic for Video mode:
/// - Enumerates cameras (sandbox-safe)
/// - Manages AVCaptureSession start/stop
/// - Holds placeholders for scope pipelines (RGB Parade / Vectorscope)
final class VideoMonitoringModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    // MARK: Types

    struct CameraDevice: Identifiable, Equatable {
        let id: String            // same as uniqueID
        let uniqueID: String
        let displayName: String

        static func == (lhs: CameraDevice, rhs: CameraDevice) -> Bool {
            lhs.uniqueID == rhs.uniqueID
        }
    }

    enum Status: Equatable {
        case idle
        case noCameras
        case ready
        case starting
        case running
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .noCameras: return "No cameras detected"
            case .ready: return "Ready"
            case .starting: return "Starting…"
            case .running: return "Running"
            case .failed(let msg): return "Error: \(msg)"
            }
        }
    }

    enum FormatPreference: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case nv12 = "NV12 (YUV)"
        case bgra = "BGRA (Uncompressed RGB)"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .auto: return "Auto (Try All Formats)"
            case .nv12: return "NV12 (YUV 4:2:0)"
            case .bgra: return "BGRA (Uncompressed RGB)"
            }
        }
    }

    enum PreviewMode: String, CaseIterable, Identifiable {
        case metal = "Metal"
        case native = "Native"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .metal: return "Metal (Full Features)"
            case .native: return "Native (Preview Only)"
            }
        }

        var description: String {
            switch self {
            case .metal: return "GPU rendering with scopes and analysis"
            case .native: return "Preview layer only - most compatible"
            }
        }
    }

    // MARK: Published state

    @Published var devices: [CameraDevice] = []
    @Published var selectedUniqueID: String? = nil
    @Published var status: Status = .idle
    @Published var formatPreference: FormatPreference = .auto
    @Published var previewMode: PreviewMode = .metal

    // Live frame stats (debug/UX)
    @Published var videoResolutionText: String = "—"
    @Published var videoFPSText: String = "—"
    @Published private(set) var droppedFrameCount: Int = 0

    // CPU fallback scopes for legacy GPUs (low-res, throttled)
    @Published var cpuVectorscopeImage: CGImage? = nil
    @Published var cpuParadeImage: CGImage? = nil
    @Published private(set) var hasReceivedFrame: Bool = false

    /// Preview frame hook (e.g. Metal preview). Called on the video output queue (NOT main).
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    /// Optional scopes hook (vectorscope/parade). Called on the video output queue (NOT main).
    /// On legacy GPUs we disable this to avoid driver hangs.
    var onScopeFrame: ((CVPixelBuffer) -> Void)?

    /// Expose the session for a preview-layer view (we'll build an NSViewRepresentable next).
    /// Note: UI should not mutate this session directly.
    let session = AVCaptureSession()

    /// Whether the video data output is currently attached and active.
    /// In Native preview mode, this is false (preview layer only).
    /// In Metal mode, this is true (full processing pipeline).
    @Published var isDataOutputActive: Bool = false

    // MARK: - Recording State
    @Published var isRecording: Bool = false
    @Published var recordingDuration: TimeInterval = 0
    private var recordingTimer: Timer?
    private let movieFileOutput = AVCaptureMovieFileOutput()
    private var movieFileOutputDelegate: RecordingDelegate?

    override init() {
        super.init()
        previewMode = Self.defaultPreviewMode(prefersNative: !supportsMetalScopes || !Self.isAppleSilicon())
    }

    // MARK: Public API - Recording

    func startRecording(codec: AVVideoCodecType = .proRes422) {
        sessionQueue.async {
            guard !self.isRecording else { return }

            // Ensure output is added
            if !self.session.outputs.contains(self.movieFileOutput) {
                self.session.beginConfiguration()
                if self.session.canAddOutput(self.movieFileOutput) {
                    self.session.addOutput(self.movieFileOutput)
                }
                self.session.commitConfiguration()
            }

            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let dateString = formatter.string(from: Date())
            let fileName = "Recording_\(self.selectedDisplayName ?? "Camera")_\(dateString).mov"
            let outputURL = documentsPath.appendingPathComponent(fileName)

            self.movieFileOutputDelegate = RecordingDelegate(onFinished: { [weak self] url in
                Task { @MainActor [weak self] in
                    AppDebugConsole.log("Recording finished: \(url.path)", category: "Video")
                    self?.stopRecordingTimer()
                }
            })

            if let connection = self.movieFileOutput.connection(with: .video) {
                // On macOS we set the codec in outputSettings directly.
                // We'll trust ProRes/H264 are available for now as they are standard on macOS.
                self.movieFileOutput.setOutputSettings([AVVideoCodecKey: codec], for: connection)
            }

            self.movieFileOutput.startRecording(to: outputURL, recordingDelegate: self.movieFileOutputDelegate!)

            DispatchQueue.main.async {
                self.isRecording = true
                self.recordingDuration = 0
                self.startRecordingTimer()
            }
        }
    }

    func stopRecording() {
        sessionQueue.async {
            guard self.isRecording else { return }
            self.movieFileOutput.stopRecording()
            DispatchQueue.main.async {
                self.isRecording = false
                self.stopRecordingTimer()
            }
        }
    }

    func setAudioInput(deviceID: AudioDeviceID?) {
        sessionQueue.async {
            self.session.beginConfiguration()

            // Remove existing audio input
            if let current = self.currentAudioInput {
                self.session.removeInput(current)
                self.currentAudioInput = nil
            }

            // Add new audio input
            if let id = deviceID, let avDevice = self.findAVAudioDevice(for: id) {
                do {
                    let input = try AVCaptureDeviceInput(device: avDevice)
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.currentAudioInput = input
                    }
                } catch {
                    Task { @MainActor in
                        AppDebugConsole.log("Error: Failed to add audio input: \(error)", category: "Video")
                    }
                }
            }

            self.session.commitConfiguration()
        }
    }

    private func findAVAudioDevice(for coreAudioID: AudioDeviceID) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone, .externalUnknown],
            mediaType: .audio,
            position: .unspecified
        ).devices

        // Match by name or try to find a way to map coreAudioID to AVCaptureDevice.uniqueID
        // On macOS, AVCaptureDevice.uniqueID often looks like a string of the CoreAudio device UID.
        // Let's try to match by name as a fallback.

        // I'll need to query the name from the CoreAudio ID.
        var nameBuffer: [CChar] = Array(repeating: 0, count: 256)
        if AudioDevices_GetDeviceName(coreAudioID, &nameBuffer, 256) == noErr {
            let name = String(cString: nameBuffer)
            return devices.first(where: { $0.localizedName == name })
        }

        return nil
    }

    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.recordingDuration += 1
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: Private

    private let sessionQueue = DispatchQueue(label: "VideoMonitoringModel.sessionQueue", qos: .userInitiated)
    private var currentInput: AVCaptureDeviceInput? = nil
    private var currentAudioInput: AVCaptureDeviceInput? = nil

    // Use serial queue with QoS explicitly set for Big Sur compatibility
    private let outputQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "VideoMonitoringModel.videoOutputQueue", qos: .userInitiated)
        // Ensure queue is not suspended on creation
        queue.async { }
        return queue
    }()
    private let videoOutput = AVCaptureVideoDataOutput()

    // Start/stop guarding (older Macs can block inside startRunning)
    private var isStartingSession: Bool = false
    private var startTimeoutWorkItem: DispatchWorkItem? = nil
    private var noFrameFallbackWorkItem: DispatchWorkItem? = nil

    // Metal capability (legacy Intel GPUs cannot safely run compute scopes)
    private let supportsMetalScopes: Bool = {
        guard let dev = MTLCreateSystemDefaultDevice() else { return false }
        if #available(macOS 10.15, *) {
            return dev.supportsFamily(.mac2)
        } else {
            return false
        }
    }()

    // CPU fallback scopes (legacy GPUs)
    private var lastCPUScopeTick: CFTimeInterval = 0
    private let cpuScopeInterval: CFTimeInterval = 0.15   // ~6–7 fps
    private let cpuVectorSize: Int = 256
    private let cpuParadeLaneWidth: Int = 128
    private let cpuParadeHeight: Int = 256

    // CPU vectorscope ring overlay (generated once per size)
    private var cpuVectorscopeRingRGBA: [UInt8]? = nil
    private var cpuVectorscopeRingSize: Int = 0

    // FPS estimation
    private var lastFPSTick: CFTimeInterval = CACurrentMediaTime()
    private var framesSinceLastFPSTick: Int = 0

    var selectedDisplayName: String? {
        guard let id = selectedUniqueID else { return nil }
        return devices.first(where: { $0.uniqueID == id })?.displayName
    }

    var scopesAvailable: Bool { supportsMetalScopes }

    // MARK: Public API

    /// Starts the capture session with a guard against re-entrancy and a hard timeout.
    /// On some older Intel Macs, `startRunning()` can block for a long time if the camera fails to start.
    /// Must be called on `sessionQueue`.
    private func startSessionSafely(timeoutSeconds: TimeInterval = 20.0) {
        if session.isRunning {
            AppDebugConsole.log("Info: Session already running", category: "Video")
            DispatchQueue.main.async { self.status = .running }
            return
        }
        if isStartingSession {
            AppDebugConsole.log("Warning: Already starting session, ignoring", category: "Video")
            return
        }

        AppDebugConsole.log("Starting capture session...", category: "Video")
        isStartingSession = true

        // Cancel any previous timeout.
        startTimeoutWorkItem?.cancel()
        startTimeoutWorkItem = nil

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // If we're still starting and session isn't running, abort.
            if self.isStartingSession && !self.session.isRunning {
                AppDebugConsole.log("Error: Session start timeout (\(timeoutSeconds)s)", category: "Video")
                self.session.stopRunning()

                DispatchQueue.main.async {
                    self.status = .failed("Camera failed to start (timeout)")
                    self.videoResolutionText = "—"
                    self.videoFPSText = "—"
                    self.droppedFrameCount = 0
                }

                self.isStartingSession = false
            }
        }

        startTimeoutWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: work)

        // Start (can block on some systems)
        AppDebugConsole.log("Calling session.startRunning()...", category: "Video")
        self.session.startRunning()
        AppDebugConsole.log("session.startRunning() returned, isRunning = \(self.session.isRunning)", category: "Video")

        // Intel Big Sur fallback: if .high preset failed, retry with .medium
        // which is more likely to be negotiable with older FaceTime HD cameras.
        if !self.session.isRunning && self.session.sessionPreset == .high {
            AppDebugConsole.log("Warning: .high preset failed, retrying with .medium", category: "Video")
            self.session.beginConfiguration()
            self.session.sessionPreset = .medium
            self.session.commitConfiguration()
            self.session.startRunning()
            AppDebugConsole.log("Retry returned, isRunning = \(self.session.isRunning)", category: "Video")
        }

        // If we got here, startRunning returned.
        DispatchQueue.main.async {
            self.status = self.session.isRunning ? .running : .failed("Camera failed to start")
            if self.session.isRunning {
                AppDebugConsole.log("Success: Session successfully started", category: "Video")
            } else {
                AppDebugConsole.log("Error: Session failed to start", category: "Video")
            }
        }

        if self.session.isRunning {
            self.scheduleNoFrameFallbackIfNeeded()
        }

        self.isStartingSession = false
        self.startTimeoutWorkItem?.cancel()
        self.startTimeoutWorkItem = nil
    }

    private func cancelStartTimeout() {
        startTimeoutWorkItem?.cancel()
        startTimeoutWorkItem = nil
        isStartingSession = false
    }

    func refreshDevices() {
        // Enumerating devices does not trigger camera permission prompts.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )

        let cams = discovery.devices.map { dev in
            CameraDevice(id: dev.uniqueID, uniqueID: dev.uniqueID, displayName: dev.localizedName)
        }

        DispatchQueue.main.async {
            self.devices = cams

            if cams.isEmpty {
                self.status = .noCameras
                self.selectedUniqueID = nil
                return
            }

            // Keep selection only if still present. Otherwise default to None.
            if let sel = self.selectedUniqueID, cams.contains(where: { $0.uniqueID == sel }) {
                self.status = .ready
            } else {
                self.selectedUniqueID = nil
                self.status = .ready
            }
        }
    }

    /// Call when the user changes the selected camera.
    func selectCamera(uniqueID: String?) {
        selectedUniqueID = uniqueID

        // Avoid reconfiguring while a start attempt is in progress (can deadlock on older Macs).
        if isStartingSession {
            return
        }

        // None selected -> stop and detach inputs (no permission prompts)
        guard selectedUniqueID != nil else {
            stop()
            sessionQueue.async {
                self.detachAllInputs()
            }
            return
        }

        // A camera is selected: configure (or reconfigure) and start.
        if session.isRunning {
            reconfigureSessionForSelectedCamera()
        } else {
            start()
        }
    }

    /// Call when the user changes the format preference.
    /// Restarts the session to apply the new format.
    func formatPreferenceChanged() {
        // Only restart if Metal mode is active (format doesn't matter for Native preview)
        guard previewMode == .metal else { return }
        guard session.isRunning else { return }
        // Reconfigure with new format preference
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.start()
        }
    }

    /// Call when the user changes the preview mode.
    /// Reconfigures the session to add/remove data output as needed.
    func previewModeChanged() {
        cancelNoFrameFallback()
        guard session.isRunning else { return }

        // Reconfigure session on the session queue
        sessionQueue.async {
            self.session.beginConfiguration()

            if self.previewMode == .metal {
                // Switching TO Metal: add data output if not present
                if !self.session.outputs.contains(where: { $0 === self.videoOutput }) {
                    Task { @MainActor in
                        AppDebugConsole.log("Switching to Metal mode: adding data output", category: "Video")
                    }
                    self.configureVideoOutput()
                }
            } else {
                // Switching TO Native: remove data output if present
                if self.session.outputs.contains(where: { $0 === self.videoOutput }) {
                    Task { @MainActor in
                        AppDebugConsole.log("Switching to Native mode: removing data output", category: "Video")
                    }
                    self.session.removeOutput(self.videoOutput)
                    DispatchQueue.main.async { self.isDataOutputActive = false }
                }
            }

            self.session.commitConfiguration()

            if self.previewMode == .metal {
                self.scheduleNoFrameFallbackIfNeeded()
            }
        }
    }

    /// Helper to configure video output based on current format preference.
    /// Must be called within beginConfiguration/commitConfiguration block.
    private func configureVideoOutput() {
        let preferredFormats: [OSType]
        switch formatPreference {
        case .nv12:
            preferredFormats = [
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        case .bgra:
            preferredFormats = [kCVPixelFormatType_32BGRA]
        case .auto:
            preferredFormats = [
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_32BGRA
            ]
        }

        var outputAdded = false
        for format in preferredFormats {
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(format),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)

                let formatName: String
                switch format {
                case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                    formatName = "NV12 Full-Range"
                case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
                    formatName = "NV12 Video-Range"
                case kCVPixelFormatType_32BGRA:
                    formatName = "BGRA"
                default:
                    formatName = "Format \(format)"
                }

                AppDebugConsole.log("Success: Added video output (\(formatName))", category: "Video")

                if let conn = videoOutput.connection(with: .video) {
                    if conn.isVideoMirroringSupported {
                        conn.automaticallyAdjustsVideoMirroring = false
                        conn.isVideoMirrored = false
                    }
                }

                outputAdded = true
                DispatchQueue.main.async { self.isDataOutputActive = true }
                break
            }
        }

        if !outputAdded {
            AppDebugConsole.log("Error: Cannot add video output (all formats failed)", category: "Video")
            DispatchQueue.main.async {
                self.isDataOutputActive = false
            }
        }
    }

    func start() {
        guard !session.isRunning else {
            DispatchQueue.main.async { self.status = .running }
            scheduleNoFrameFallbackIfNeeded()
            return
        }

        // If no cameras, do nothing.
        guard let _ = selectedUniqueID ?? devices.first?.uniqueID else {
            DispatchQueue.main.async { self.status = .noCameras }
            return
        }

        DispatchQueue.main.async { self.status = .starting }
        DispatchQueue.main.async { self.hasReceivedFrame = false }
        cancelNoFrameFallback()

        sessionQueue.async {
            self.configureOrReconfigureSessionForSelectedCamera()
            self.startSessionSafely(timeoutSeconds: 20.0)
        }
    }

    func stop() {
        guard session.isRunning else {
            cancelNoFrameFallback()
            DispatchQueue.main.async {
                self.status = self.devices.isEmpty ? .noCameras : .ready
                self.videoResolutionText = "—"
                self.videoFPSText = "—"
                self.droppedFrameCount = 0
                self.hasReceivedFrame = false
            }
            return
        }

        sessionQueue.async {
            self.cancelStartTimeout()
            self.cancelNoFrameFallback()
            self.session.stopRunning()
            DispatchQueue.main.async {
                self.status = self.devices.isEmpty ? .noCameras : .ready
                self.videoResolutionText = "—"
                self.videoFPSText = "—"
                self.droppedFrameCount = 0
                self.hasReceivedFrame = false
            }
        }
    }

    // MARK: Session configuration

    private func detachAllInputs() {
        self.session.beginConfiguration()
        defer { self.session.commitConfiguration() }

        if let input = self.currentInput {
            self.session.removeInput(input)
            self.currentInput = nil
        }
    }

    private func configureOrReconfigureSessionForSelectedCamera() {
        // Always ensure the session input matches the current selection.
        let desiredID = selectedUniqueID ?? devices.first?.uniqueID
        guard let desiredID else {
            AppDebugConsole.log("Error: No camera ID available", category: "Video")
            DispatchQueue.main.async { self.status = .noCameras }
            return
        }

        // If we already have this device selected, do nothing.
        if let current = currentInput?.device.uniqueID, current == desiredID {
            AppDebugConsole.log("Info: Camera already configured: \(desiredID)", category: "Video")
            return
        }

        AppDebugConsole.log("Configuring session for camera: \(desiredID)", category: "Video")
        AppDebugConsole.log("   Preview mode: \(previewMode.displayName)", category: "Video")

        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            AppDebugConsole.log("Success: Session configuration committed", category: "Video")
        }

        session.sessionPreset = .high
        AppDebugConsole.log("   Session preset: .high", category: "Video")

        // Remove existing input
        if let input = currentInput {
            AppDebugConsole.log("   Removing existing input: \(input.device.localizedName)", category: "Video")
            session.removeInput(input)
            currentInput = nil
        }

        // Use DiscoverySession for compatibility with Intel/Big Sur (don't use deprecated .devices(for:))
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )

        AppDebugConsole.log("   Discovery found \(discovery.devices.count) device(s)", category: "Video")
        for dev in discovery.devices {
            AppDebugConsole.log("     - \(dev.localizedName) (\(dev.uniqueID))", category: "Video")
        }

        guard let device = discovery.devices.first(where: { $0.uniqueID == desiredID }) else {
            AppDebugConsole.log("Error: Camera device not found with ID: \(desiredID)", category: "Video")
            DispatchQueue.main.async { self.status = .failed("Selected camera not found") }
            return
        }

        AppDebugConsole.log("Success: Found device: \(device.localizedName)", category: "Video")
        AppDebugConsole.log("   Device connected: \(device.isConnected)", category: "Video")
        AppDebugConsole.log("   Device suspended: \(device.isSuspended)", category: "Video")

        // Check camera authorization
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        AppDebugConsole.log("   Camera authorization: \(authStatus.rawValue) (\(authStatusString(authStatus)))", category: "Video")

        if authStatus != .authorized {
            AppDebugConsole.log("Warning: Camera not authorized! Status: \(authStatusString(authStatus))", category: "Video")
            DispatchQueue.main.async {
                self.status = .failed("Camera permission not granted")
            }
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            AppDebugConsole.log("Success: Created AVCaptureDeviceInput", category: "Video")

            if session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
                AppDebugConsole.log("Success: Added input for \(device.localizedName)", category: "Video")
                AppDebugConsole.log("   Session inputs count: \(session.inputs.count)", category: "Video")
            } else {
                AppDebugConsole.log("Error: Session cannot add input (canAddInput returned false)", category: "Video")
                DispatchQueue.main.async { self.status = .failed("Cannot add camera input") }
                return
            }
        } catch {
            AppDebugConsole.log("Error: Failed to create input: \(error.localizedDescription)", category: "Video")
            DispatchQueue.main.async { self.status = .failed(error.localizedDescription) }
            return
        }

        // Only attach video data output if using Metal rendering mode
        // Native mode = preview layer only (most compatible for older systems)
        if previewMode == .metal {
            // Ensure a video output is attached (for scopes analysis).
            if !session.outputs.contains(where: { $0 === videoOutput }) {
                AppDebugConsole.log("Adding video output for Metal mode...", category: "Video")
                configureVideoOutput()
            } else {
                AppDebugConsole.log("Info: Video output already attached, re-setting delegate", category: "Video")
                // Delegate may have been cleared by the system; ensure it's set.
                videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
                DispatchQueue.main.async { self.isDataOutputActive = true }
            }
        } else {
            // Native preview mode: remove data output if attached
            if session.outputs.contains(where: { $0 === videoOutput }) {
                AppDebugConsole.log("Removing video output for Native preview mode", category: "Video")
                session.removeOutput(videoOutput)
                DispatchQueue.main.async { self.isDataOutputActive = false }
            } else {
                AppDebugConsole.log("Info: Native preview mode - no data output needed", category: "Video")
                DispatchQueue.main.async { self.isDataOutputActive = false }
            }
        }

        AppDebugConsole.log("   Session outputs count: \(session.outputs.count)", category: "Video")

        // Reset FPS estimation when (re)configuring.
        lastFPSTick = CACurrentMediaTime()
        framesSinceLastFPSTick = 0
        DispatchQueue.main.async {
            self.hasReceivedFrame = false
            self.droppedFrameCount = 0
        }
        cancelNoFrameFallback()

        // Big Sur Intel Mac workaround: Force delegate re-attachment after configuration
        // Some configurations silently detach the delegate on older systems
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.sessionQueue.async {
                // Verify delegate is still attached and re-set if needed
                if self.videoOutput.sampleBufferDelegate == nil {
                    Task { @MainActor in
                        AppDebugConsole.log("Warning: Delegate was detached, re-attaching...", category: "Video")
                        self.videoOutput.setSampleBufferDelegate(self, queue: self.outputQueue)
                    }
                }
            }
        }
    }

    /// Helper to convert authorization status to human-readable string
    private func authStatusString(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not Determined"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorized: return "Authorized"
        @unknown default: return "Unknown"
        }
    }

    private func reconfigureSessionForSelectedCamera() {
        sessionQueue.async {
            if self.isStartingSession { return }
            self.configureOrReconfigureSessionForSelectedCamera()
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output === videoOutput else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            AppDebugConsole.log("Warning: Frame arrived but no pixel buffer", category: "Video")
            return
        }

        if !hasReceivedFrame {
            DispatchQueue.main.async {
                self.hasReceivedFrame = true
            }
            cancelNoFrameFallback()
        }

        // Log first frame for debugging (reset counter on each start)
        if framesSinceLastFPSTick == 0 {
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let formatStr: String
            switch format {
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                formatStr = "NV12 Full-Range"
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
                formatStr = "NV12 Video-Range"
            default:
                formatStr = "Format \(format)"
            }
            AppDebugConsole.log("Success: First frame received! \(w)x\(h) \(formatStr)", category: "Video")
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Always feed preview.
        onFrame?(pixelBuffer, timestamp)

        // Scopes:
        // - Modern GPUs: feed Metal compute scopes.
        // - Legacy GPUs: run a low-res CPU fallback at a throttled rate.
        if supportsMetalScopes {
            onScopeFrame?(pixelBuffer)
        } else {
            let nowScope = CACurrentMediaTime()
            if nowScope - lastCPUScopeTick >= cpuScopeInterval {
                lastCPUScopeTick = nowScope

                if let vec = buildCPUVectorscopeImage(from: pixelBuffer, size: cpuVectorSize) {
                    DispatchQueue.main.async { self.cpuVectorscopeImage = vec }
                }
                if let parade = buildCPUParadeImage(from: pixelBuffer, laneWidth: cpuParadeLaneWidth, height: cpuParadeHeight) {
                    DispatchQueue.main.async { self.cpuParadeImage = parade }
                }
            }
        }

        // Lightweight stats for UI (resolution + estimated fps).
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        framesSinceLastFPSTick += 1
        let now = CACurrentMediaTime()
        let dt = now - lastFPSTick

        // Update at ~2Hz to keep UI cheap.
        if dt >= 0.5 {
            let fps = Double(framesSinceLastFPSTick) / dt
            framesSinceLastFPSTick = 0
            lastFPSTick = now

            DispatchQueue.main.async {
                self.videoResolutionText = "\(w)×\(h)"
                self.videoFPSText = String(format: "%.0f fps", fps)
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output === videoOutput else { return }
        DispatchQueue.main.async {
            self.droppedFrameCount += 1
        }
    }

    // MARK: - CPU fallback scopes (legacy GPUs)

    /// Very small, fast vectorscope using NV12 chroma plane (CbCr). Plots points into a 256x256 bitmap.
    private func buildCPUVectorscopeImage(from pixelBuffer: CVPixelBuffer, size: Int) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return nil }

        let chromaW = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let chromaH = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let chromaBpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        guard let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }

        // RGBA output
        let outW = size
        let outH = size
        var rgba = [UInt8](repeating: 0, count: outW * outH * 4)
        // Opaque black background
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba[i + 3] = 255
        }

        // Sample sparsely for speed.
        let step = 4
        let src = chromaBase.assumingMemoryBound(to: UInt8.self)

        // Chroma threshold removes near-gray noise (biggest fidelity win)
        let chromaThreshold = 12   // tweak 8–20 depending on taste

        for y in stride(from: 0, to: chromaH, by: step) {
            let row = y * chromaBpr
            for x in stride(from: 0, to: chromaW, by: step) {
                let idx = row + x * 2
                let cb = Int(src[idx + 0])
                let cr = Int(src[idx + 1])

                // Distance from neutral chroma (128,128)
                let du = cb - 128
                let dv = cr - 128

                // Cheap saturation metric (no sqrt)
                let sat = abs(du) + abs(dv)
                if sat < chromaThreshold { continue }

                // Map to scope space
                let px = min(max(cb, 0), 255)
                let py = min(max(255 - cr, 0), 255) // invert so up is higher Cr

                let o = (py * outW + px) * 4

                // Saturation-weighted density accumulation
                // Stronger chroma builds brighter clusters
                let boost = min(48, sat / 2)

                let r = min(255, Int(rgba[o + 0]) + boost)
                let g = min(255, Int(rgba[o + 1]) + boost)
                let b = min(255, Int(rgba[o + 2]) + boost)

                rgba[o + 0] = UInt8(r)
                rgba[o + 1] = UInt8(g)
                rgba[o + 2] = UInt8(b)
                rgba[o + 3] = 255
            }
        }

        // Overlay a static RGB/CMY reference ring for readability (CPU-cheap)
        overlayCPUVectorscopeRing(into: &rgba, size: outW)

        return makeCGImageRGBA(bytes: rgba, width: outW, height: outH)
    }

    private func scheduleNoFrameFallbackIfNeeded(timeoutSeconds: TimeInterval = 3.0) {
        cancelNoFrameFallback()
        guard previewMode == .metal else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.session.isRunning, self.previewMode == .metal, !self.hasReceivedFrame else { return }

            AppDebugConsole.log("Warning: No frames received in Metal mode after \(timeoutSeconds)s, switching to Native preview", category: "Video")
            DispatchQueue.main.async {
                self.previewMode = .native
                self.previewModeChanged()
            }
        }

        noFrameFallbackWorkItem = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: work)
    }

    private func cancelNoFrameFallback() {
        noFrameFallbackWorkItem?.cancel()
        noFrameFallbackWorkItem = nil
    }

    private static func defaultPreviewMode(prefersNative: Bool) -> PreviewMode {
        prefersNative ? .native : .metal
    }

    private static func isAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }

    /// Alpha-blend a cached hue ring over the vectorscope bitmap.
    private func overlayCPUVectorscopeRing(into rgba: inout [UInt8], size: Int) {
        if cpuVectorscopeRingRGBA == nil || cpuVectorscopeRingSize != size {
            cpuVectorscopeRingRGBA = makeCPUVectorscopeRingRGBA(size: size)
            cpuVectorscopeRingSize = size
        }
        guard let ring = cpuVectorscopeRingRGBA, ring.count == rgba.count else { return }

        // Alpha blend ring over plot: dst = src*a + dst*(1-a)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            let a = Int(ring[i + 3])
            if a == 0 { continue }
            let invA = 255 - a

            let sr = Int(ring[i + 0])
            let sg = Int(ring[i + 1])
            let sb = Int(ring[i + 2])

            let dr = Int(rgba[i + 0])
            let dg = Int(rgba[i + 1])
            let db = Int(rgba[i + 2])

            rgba[i + 0] = UInt8((sr * a + dr * invA) / 255)
            rgba[i + 1] = UInt8((sg * a + dg * invA) / 255)
            rgba[i + 2] = UInt8((sb * a + db * invA) / 255)
            rgba[i + 3] = 255
        }
    }

    /// Create a static hue wheel ring with simple RGB/CMY orientation ticks (RGBA8).
    private func makeCPUVectorscopeRingRGBA(size: Int) -> [UInt8] {
        let w = size
        let h = size
        var rgba = [UInt8](repeating: 0, count: w * h * 4)

        let cx = Double(w - 1) / 2.0
        let cy = Double(h - 1) / 2.0
        let radius = min(cx, cy)

        // Similar proportions to the Metal ring
        let innerR = 0.78
        let outerR = 0.92

        // 6 ticks for quick orientation (R, Y, G, C, B, M around the circle)
        let tickAngles: [Double] = [0, 60, 120, 180, 240, 300].map { $0 * .pi / 180.0 }

        @inline(__always) func hsvToRgb(h: Double, s: Double, v: Double) -> (UInt8, UInt8, UInt8) {
            let hh = (h.truncatingRemainder(dividingBy: 1.0)) * 6.0
            let i = Int(hh)
            let f = hh - Double(i)
            let p = v * (1.0 - s)
            let q = v * (1.0 - s * f)
            let t = v * (1.0 - s * (1.0 - f))

            let (r, g, b): (Double, Double, Double)
            switch i {
            case 0: (r, g, b) = (v, t, p)
            case 1: (r, g, b) = (q, v, p)
            case 2: (r, g, b) = (p, v, t)
            case 3: (r, g, b) = (p, q, v)
            case 4: (r, g, b) = (t, p, v)
            default: (r, g, b) = (v, p, q)
            }

            return (
                UInt8(min(255, max(0, Int(r * 255.0)))),
                UInt8(min(255, max(0, Int(g * 255.0)))),
                UInt8(min(255, max(0, Int(b * 255.0)))) )
        }

        // Precompute tick positions
        let tickR = radius * 0.86
        let tickHalf = 2 // ~5x5
        var tickPoints: [(Int, Int, Double)] = []
        tickPoints.reserveCapacity(tickAngles.count)
        for a in tickAngles {
            let x = Int((cx + cos(a) * tickR).rounded())
            let y = Int((cy + sin(a) * tickR).rounded())
            tickPoints.append((x, y, a))
        }

        // Draw ring
        for y in 0..<h {
            let dy = Double(y) - cy
            for x in 0..<w {
                let dx = Double(x) - cx
                let r = sqrt(dx * dx + dy * dy) / radius
                if r < innerR || r > outerR { continue }

                let ang = atan2(dy, dx) // -pi..pi
                let hue = (ang / (2.0 * .pi)) + 0.5 // 0..1

                let (rr, gg, bb) = hsvToRgb(h: hue, s: 1.0, v: 1.0)
                let o = (y * w + x) * 4
                rgba[o + 0] = rr
                rgba[o + 1] = gg
                rgba[o + 2] = bb
                rgba[o + 3] = 180
            }
        }

        // Draw small ticks
        for (tx, ty, a) in tickPoints {
            let hue = (a / (2.0 * .pi)) + 0.5
            let (tr, tg, tb) = hsvToRgb(h: hue, s: 0.9, v: 1.0)

            for yy in (ty - tickHalf)...(ty + tickHalf) {
                if yy < 0 || yy >= h { continue }
                for xx in (tx - tickHalf)...(tx + tickHalf) {
                    if xx < 0 || xx >= w { continue }
                    let o = (yy * w + xx) * 4
                    rgba[o + 0] = tr
                    rgba[o + 1] = tg
                    rgba[o + 2] = tb
                    rgba[o + 3] = 230
                }
            }
        }

        return rgba
    }

    /// Low-res RGB parade using Y + CbCr -> RGB conversion. Produces 3 lanes side-by-side.
    private func buildCPUParadeImage(from pixelBuffer: CVPixelBuffer, laneWidth: Int, height: Int) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return nil }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)

        let yBpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvBpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }

        let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
        let uvPtr = uvBase.assumingMemoryBound(to: UInt8.self)

        let outW = laneWidth * 3
        let outH = height
        var rgba = [UInt8](repeating: 0, count: outW * outH * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba[i + 3] = 255 }

        // Sample sparsely
        let stepX = max(1, w / 160)
        let stepY = max(1, h / 120)

        @inline(__always) func clamp255(_ v: Int) -> UInt8 {
            return UInt8(min(255, max(0, v)))
        }

        // Full-range YCbCr (approx) to RGB
        @inline(__always) func ycbcrToRGB(y: Int, cb: Int, cr: Int) -> (Int, Int, Int) {
            let Y = y
            let Cb = cb - 128
            let Cr = cr - 128
            // ITU-R BT.601-ish full-range approximation
            let r = Y + Int(1.402 * Double(Cr))
            let g = Y - Int(0.344136 * Double(Cb)) - Int(0.714136 * Double(Cr))
            let b = Y + Int(1.772 * Double(Cb))
            return (r, g, b)
        }

        for sy in stride(from: 0, to: h, by: stepY) {
            let yRow = sy * yBpr
            let uvRow = (sy / 2) * uvBpr
            for sx in stride(from: 0, to: w, by: stepX) {
                let yVal = Int(yPtr[yRow + sx])
                let uvIndex = uvRow + (sx / 2) * 2
                let cb = Int(uvPtr[uvIndex + 0])
                let cr = Int(uvPtr[uvIndex + 1])

                let (r, g, b) = ycbcrToRGB(y: yVal, cb: cb, cr: cr)

                // Map x across lane width
                let xLane = Int(Double(sx) / Double(w) * Double(laneWidth - 1))

                // Plot each channel into its lane
                let rr = clamp255(r)
                let gg = clamp255(g)
                let bb = clamp255(b)

                func plot(lane: Int, value: UInt8, color: (UInt8, UInt8, UInt8)) {
                    let x = lane * laneWidth + xLane
                    let y = Int(Double(255 - Int(value)) / 255.0 * Double(outH - 1))
                    let o = (y * outW + x) * 4
                    // brighten additively
                    rgba[o + 0] = min(255, rgba[o + 0] &+ (color.0 / 3))
                    rgba[o + 1] = min(255, rgba[o + 1] &+ (color.1 / 3))
                    rgba[o + 2] = min(255, rgba[o + 2] &+ (color.2 / 3))
                    rgba[o + 3] = 255
                }

                plot(lane: 0, value: rr, color: (255, 0, 0))
                plot(lane: 1, value: gg, color: (0, 255, 0))
                plot(lane: 2, value: bb, color: (0, 0, 255))
            }
        }

        return makeCGImageRGBA(bytes: rgba, width: outW, height: outH)
    }

    private func makeCGImageRGBA(bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        let cfData = CFDataCreate(nil, bytes, bytes.count)
        guard let data = cfData,
              let provider = CGDataProvider(data: data) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

// MARK: - Recording Delegate

private nonisolated final class RecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate {
    var onFinished: ((URL) -> Void)?

    init(onFinished: @escaping (URL) -> Void) {
        self.onFinished = onFinished
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        if let error = error {
            Task { @MainActor in
                AppDebugConsole.log("Error: Recording error: \(error.localizedDescription)", category: "Video")
            }
        }
        onFinished?(outputFileURL)
    }
}
