
import SwiftUI
import PodcastPreviewShared
import AVFoundation
import PodcastPreviewCore

struct VideoSidebarView: View {
    @ObservedObject var videoModel: VideoMonitoringModel
    @ObservedObject var metalPreview: CameraMetalPreviewModel
    @ObservedObject var audioManager: MultiDeviceAudioManager
    @ObservedObject var recordingManager = VideoRecordingManager.shared

    @Environment(\.appUIScale) private var appUIScale
    @Environment(\.colorScheme) private var colorScheme

    private var sidebarWidth: CGFloat { 300 * appUIScale }
    private var scaledPadding: CGFloat { 16 * appUIScale }
    private var scaledSpacing: CGFloat { 12 * appUIScale }
    private var scaledHeadlineFontSize: CGFloat { 14 * appUIScale }
    private var scaledCaptionFontSize: CGFloat { 12 * appUIScale }

    // Recording Settings State
    @State private var selectedCodec: String = "ProRes 422"
    @State private var masterResolution: String = "1920x1080"

    private var codecType: AVVideoCodecType {
        switch selectedCodec {
        case "ProRes 422": return .proRes422
        case "H.264": return .h264
        case "HEVC": return .hevc
        default: return .proRes422
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header / Settings
            VStack(alignment: .leading, spacing: scaledSpacing) {
                Text("Record Settings")
                    .font(.system(size: scaledHeadlineFontSize, weight: .bold))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Codec")
                            .font(.system(size: scaledCaptionFontSize))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: $selectedCodec) {
                            Text("ProRes 422").tag("ProRes 422")
                            Text("H.264").tag("H.264")
                            Text("HEVC").tag("HEVC")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 120)
                    }

                    HStack {
                        Text("Resolution")
                            .font(.system(size: scaledCaptionFontSize))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: $masterResolution) {
                            Text("1080p").tag("1920x1080")
                            Text("4K").tag("3840x2160")
                            Text("720p").tag("1280x720")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }
                .padding(10)
                .graphiteSurface(.control, cornerRadius: 8)
            }
            .padding(scaledPadding)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: scaledSpacing) {
                    // Camera Section
                    SidebarSectionHeader(title: "Camera Devices", icon: "video.fill")

                    ForEach(videoModel.devices) { device in
                        CameraDeviceCard(
                            device: device,
                            isMain: videoModel.selectedUniqueID == device.uniqueID,
                            recordingState: recordingManager.recordingStates[device.uniqueID] ?? VideoRecordingManager.RecordingState(),
                            onToggleRecording: {
                                // Only pass metalPreview if it's the active camera being recorded
                                let processedSource = (videoModel.selectedUniqueID == device.uniqueID) ? metalPreview : nil
                                recordingManager.toggleRecording(for: device.uniqueID, displayName: device.displayName, codec: codecType, resolution: masterResolution, processedFrameSource: processedSource)
                            }
                        )
                    }

                    Spacer(minLength: 20)

                    // Audio Section
                    SidebarSectionHeader(title: "Audio Input Devices", icon: "mic.fill")

                    ForEach(audioManager.availableDevices) { device in
                        AudioInputDeviceCard(
                            device: device,
                            isArmed: isAudioArmed(device.deviceID),
                            metering: audioManager.deviceMeteringStates[device.id],
                            onToggleArm: {
                                toggleAudioArm(device)
                            }
                        )
                    }

                    Spacer(minLength: 20)

                    // Virtual Camera Section
                    SidebarSectionHeader(title: "Virtual Camera", icon: "camera.shutter.button.fill")

                    VirtualCameraSidebarCard()
                }
                .padding(scaledPadding)
            }
        }
        .frame(width: sidebarWidth)
        .graphiteSidebarChrome(separatorEdge: .trailing)
    }

    private func isAudioArmed(_ deviceID: AudioDeviceID) -> Bool {
        // For simplicity, we'll check if this audio device is selected for any camera recording
        recordingManager.selectedAudioDevices.values.contains(deviceID)
    }

    private func toggleAudioArm(_ device: AudioDeviceModel) {
        if isAudioArmed(device.deviceID) {
            for (camID, id) in recordingManager.selectedAudioDevices where id == device.deviceID {
                recordingManager.setAudioDevice(for: camID, audioDeviceID: nil)
            }
            audioManager.stopPeakMonitoring(for: device)
        } else {
            // Assign to main camera if available
            if let mainID = videoModel.selectedUniqueID {
                recordingManager.setAudioDevice(for: mainID, audioDeviceID: device.deviceID)
            }
            audioManager.togglePeakMonitoring(for: device)
        }
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    let icon: String
    @Environment(\.appUIScale) private var appUIScale

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
            Text(title)
                .font(.system(size: 13 * appUIScale, weight: .semibold))
                .textCase(.uppercase)
                .foregroundColor(.secondary)
        }
        .padding(.top, 8)
    }
}

private struct CameraDeviceCard: View {
    let device: VideoMonitoringModel.CameraDevice
    let isMain: Bool
    let recordingState: VideoRecordingManager.RecordingState
    let onToggleRecording: () -> Void

    @Environment(\.appUIScale) private var appUIScale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.system(size: 13 * appUIScale, weight: .semibold))
                        .lineLimit(1)
                    if isMain {
                        Text("MAIN OUTPUT")
                            .font(.system(size: 9 * appUIScale, weight: .bold))
                            .foregroundColor(.accentColor)
                    }
                }
                Spacer()

                if recordingState.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .opacity(Int(recordingState.duration) % 2 == 0 ? 1 : 0.3)
                }
            }

            HStack {
                Text("1920x1080 • 30 FPS")
                    .font(.system(size: 10 * appUIScale))
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatTime(recordingState.duration))
                    .font(.system(size: 10 * appUIScale, design: .monospaced))
                    .foregroundColor(recordingState.isRecording ? .red : .secondary)
            }

            HStack(spacing: 8) {
                Button(action: onToggleRecording) {
                    HStack {
                        Image(systemName: recordingState.isRecording ? "stop.fill" : "record.circle")
                        Text(recordingState.isRecording ? "Stop" : "Record")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(recordingState.isRecording ? Color.red.opacity(0.2) : Color.white.opacity(0.1))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(recordingState.isRecording ? Color.red.opacity(0.5) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .foregroundColor(recordingState.isRecording ? .red : .primary)
            }
        }
        .padding(12)
        .background(
            ThemeRoundedRectangle(cornerRadius: 12).themed(
                fill: isMain ? GraphiteSlateTheme.controlActiveFill : GraphiteSlateTheme.cardFill,
                stroke: isMain ? GraphiteSlateTheme.accentBlue.opacity(0.34) : GraphiteSlateTheme.cardStroke
            )
        )
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

private struct AudioInputDeviceCard: View {
    let device: AudioDeviceModel
    let isArmed: Bool
    var metering: DeviceMeteringState?
    let onToggleArm: () -> Void

    @Environment(\.appUIScale) private var appUIScale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.system(size: 12 * appUIScale, weight: .medium))
                        .lineLimit(1)
                    Text("\(device.transportType.rawValue) • \(Int(device.sampleRate/1000))kHz")
                        .font(.system(size: 10 * appUIScale))
                        .foregroundColor(.secondary)
                }
                Spacer()

                Button(action: onToggleArm) {
                    Image(systemName: isArmed ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(isArmed ? .green : .secondary)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
            }

            if isArmed, let state = metering {
                AudioInputDeviceMeteringView(state: state)
            }
        }
        .padding(10)
        .background(
            ThemeRoundedRectangle(cornerRadius: 10).themed(
                fill: isArmed ? Color.green.opacity(0.10) : GraphiteSlateTheme.cardFill,
                stroke: isArmed ? Color.green.opacity(0.30) : GraphiteSlateTheme.cardStroke
            )
        )
    }
}

private struct AudioInputDeviceMeteringView: View {
    @ObservedObject var state: DeviceMeteringState
    @Environment(\.appUIScale) private var appUIScale

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<Int(state.channelCount), id: \.self) { index in
                let level = state.channelMetering.indices.contains(index) ? state.channelMetering[index].peak : 0
                AudioMeterCapsule(level: level)
            }
        }
    }
}

private struct AudioMeterCapsule: View {
    let level: Float // Linear 0.0 - 1.0
    @Environment(\.appUIScale) private var appUIScale

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(GraphiteSlateTheme.controlFill)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.green, .yellow, .red],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, level))))
            }
        }
        .frame(height: 4 * appUIScale)
    }
}

private struct VirtualCameraSidebarCard: View {
    @ObservedObject var composer = VirtualCameraComposerModel.shared
    @ObservedObject var driverService = VirtualCameraDriverService.shared
    @Environment(\.appUIScale) private var appUIScale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Device Name")
                    .font(.system(size: 10 * appUIScale, weight: .bold))
                    .foregroundColor(.secondary)
                TextField("Name", text: $composer.deviceName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12 * appUIScale))
                    .padding(6)
                    .graphiteSurface(.control, cornerRadius: 5)
            }

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Resolution")
                        .font(.system(size: 10 * appUIScale, weight: .bold))
                        .foregroundColor(.secondary)
                    Picker("", selection: $composer.resolution) {
                        Text("1080p").tag("1920x1080")
                        Text("720p").tag("1280x720")
                        Text("4K").tag("3840x2160")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 80)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    Text("FPS")
                        .font(.system(size: 10 * appUIScale, weight: .bold))
                        .foregroundColor(.secondary)
                    Picker("", selection: $composer.frameRate) {
                        ForEach(composer.availableFrameRates, id: \.self) { frameRate in
                            Text(composer.frameRateLabel(frameRate)).tag(frameRate)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 84)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(driverService.driverBundleName)
                    .font(.system(size: 11 * appUIScale, weight: .semibold))
                Text(driverService.statusMessage)
                    .font(.system(size: 10 * appUIScale))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: openComposer) {
                HStack {
                    Image(systemName: "wand.and.stars")
                    Text("Open Composer")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.2))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Button(action: { composer.installDriver() }) {
                    Text(driverService.actionInProgress ? "Working…" : (driverService.isInstalled ? "Repair Driver" : "Install Driver"))
                        .font(.system(size: 11 * appUIScale))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(driverService.actionInProgress || !driverService.isBundledPayloadAvailable)

                Button(action: { composer.uninstallDriver() }) {
                    Text("Uninstall")
                        .font(.system(size: 11 * appUIScale))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(driverService.actionInProgress || !driverService.isInstalled)
            }
            .padding(.top, 4)
        }
        .padding(12)
        .background(
            ThemeRoundedRectangle(cornerRadius: 12).themed(fill: GraphiteSlateTheme.cardFill, stroke: GraphiteSlateTheme.cardStroke)
        )
        .onAppear {
            driverService.refreshStatus()
            composer.refreshDevices()
        }
    }

    private func openComposer() {
        let entry = FloatingCustomMonitorCardEntry(
            key: "virtual-camera-composer",
            title: "Virtual Camera Composer",
            windowTitle: "Virtual Camera Composer",
            defaultContentSize: CGSize(width: 1000, height: 700),
            minimumContentSize: CGSize(width: 600, height: 400),
            prefersFullWidthInCustomStack: false,
            startsPinned: false,
            content: AnyView(VirtualCameraComposerView())
        )
        FloatingMonitorWindowController.shared.openCustomCard(entry)
    }
}
