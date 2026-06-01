import SwiftUI
import PodcastPreviewCore

enum HealthToolbarMetricTone {
    case neutral
    case accent
    case good
    case warning
    case danger
    case blue
    case red
    case green

    var foregroundColor: Color {
        switch self {
        case .neutral:
            return .white.opacity(0.88)
        case .accent:
            return .accentColor
        case .good:
            return .green
        case .warning:
            return .orange
        case .danger:
            return .red
        case .blue:
            return .blue
        case .red:
            return .red
        case .green:
            return .green
        }
    }

    var backgroundColor: Color {
        switch self {
        case .neutral:
            return Color.white.opacity(0.06)
        case .accent:
            return Color.accentColor.opacity(0.14)
        case .good:
            return Color.green.opacity(0.14)
        case .warning:
            return Color.orange.opacity(0.14)
        case .danger:
            return Color.red.opacity(0.14)
        case .blue:
            return Color.blue.opacity(0.14)
        case .red:
            return Color.red.opacity(0.14)
        case .green:
            return Color.green.opacity(0.14)
        }
    }
}

struct HealthToolbarMetric: Identifiable {
    let id: String
    let label: String
    let value: String
    let systemImage: String?
    let tone: HealthToolbarMetricTone

    init(
        id: String,
        label: String,
        value: String,
        systemImage: String? = nil,
        tone: HealthToolbarMetricTone = .neutral
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.systemImage = systemImage
        self.tone = tone
    }
}

@MainActor
struct SharedHealthToolbar: View {
    let localSectionTitle: String
    let localMetrics: [HealthToolbarMetric]

    @Environment(\.appUIScale) private var appUIScale

    private let hardwareMonitoringModel: HardwareMonitoringModel
    @ObservedObject private var cpuSampler: CPUStatsSampler
    @ObservedObject private var gpuSampler: GPUStatsSampler
    @ObservedObject private var ramSampler: RAMStatsSampler
    @State private var toolbarDemandToken: HardwareStatsDemandToken?

    init(localSectionTitle: String, localMetrics: [HealthToolbarMetric]) {
        let model = HardwareMonitoringModel.shared
        self.localSectionTitle = localSectionTitle
        self.localMetrics = localMetrics
        self.hardwareMonitoringModel = model
        _cpuSampler = ObservedObject(wrappedValue: model.cpuSampler)
        _gpuSampler = ObservedObject(wrappedValue: model.gpuSampler)
        _ramSampler = ObservedObject(wrappedValue: model.ramSampler)
    }

    private var horizontalPadding: CGFloat { 12 * appUIScale }
    private var verticalPadding: CGFloat { 10 * appUIScale }
    private var itemSpacing: CGFloat { 8 * appUIScale }
    private var sectionSpacing: CGFloat { 12 * appUIScale }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: sectionSpacing) {
                sectionLabel("System")

                ForEach(systemMetrics) { metric in
                    HealthToolbarChip(metric: metric)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1, height: 18 * appUIScale)
                    .padding(.horizontal, 2 * appUIScale)

                sectionLabel(localSectionTitle)

                ForEach(localMetrics) { metric in
                    HealthToolbarChip(metric: metric)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
        }
        .background(
            ZStack {
                if #available(macOS 12.0, *) {
                    WindowGlassBackground()
                } else {
                    Color.black.opacity(0.4)
                }
                Color.black.opacity(0.18)
            }
        )
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1),
            alignment: .top
        )
        .onAppear {
            if toolbarDemandToken == nil {
                toolbarDemandToken = hardwareMonitoringModel.beginHardwareStatsDemand(.toolbar)
            }
        }
        .onDisappear {
            toolbarDemandToken?.invalidate()
            toolbarDemandToken = nil
        }
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11 * appUIScale, weight: .semibold))
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }

    private var systemMetrics: [HealthToolbarMetric] {
        [
            HealthToolbarMetric(
                id: "system-cpu",
                label: "CPU",
                value: percentageString(cpuSampler.totalUsage),
                systemImage: "cpu",
                tone: .blue
            ),
            HealthToolbarMetric(
                id: "system-gpu",
                label: "GPU",
                value: percentageString(aggregateGPUUsage),
                systemImage: "memorychip",
                tone: .red
            ),
            HealthToolbarMetric(
                id: "system-ram",
                label: "RAM",
                value: ramSampler.latestMemorySnapshot?.ramLabel ?? (ramSampler.ramLabel ?? "—"),
                systemImage: "externaldrive.fill.badge.person.crop",
                tone: .green
            )
        ]
    }

    private var aggregateGPUUsage: Double? {
        let usages = gpuSampler.gpus.compactMap(\.usage)
        guard !usages.isEmpty else { return nil }
        return min(Double(usages.reduce(0) { $0 + $1 }), 1.0)
    }

    private var ramTone: HealthToolbarMetricTone {
        if ramSampler.pressureValue >= 0.95 {
            return .danger
        }
        if ramSampler.pressureValue >= 0.8 {
            return .warning
        }
        return .neutral
    }

    private func percentageString<T: BinaryFloatingPoint>(_ value: T?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", Double(value) * 100)
    }

    private func tone(for ratio: Double) -> HealthToolbarMetricTone {
        if ratio >= 0.95 {
            return .danger
        }
        if ratio >= 0.8 {
            return .warning
        }
        if ratio > 0 {
            return .good
        }
        return .neutral
    }
}

private struct HealthToolbarChip: View {
    let metric: HealthToolbarMetric

    @Environment(\.appUIScale) private var appUIScale

    var body: some View {
        HStack(spacing: 6 * appUIScale) {
            if let systemImage = metric.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10 * appUIScale, weight: .semibold))
                    .foregroundColor(metric.tone.foregroundColor)
            }

            Text(metric.label)
                .font(.system(size: 11 * appUIScale, weight: .medium))
                .foregroundColor(.secondary)

            Text(metric.value)
                .font(.system(size: 11 * appUIScale, weight: .semibold))
                .foregroundColor(metric.tone.foregroundColor)
        }
        .padding(.horizontal, 10 * appUIScale)
        .padding(.vertical, 6 * appUIScale)
        .background(Capsule(style: .continuous).fill(metric.tone.backgroundColor))
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

@MainActor
struct VideoHealthToolbar: View {
    @ObservedObject var videoModel: VideoMonitoringModel

    var body: some View {
        SharedHealthToolbar(localSectionTitle: "Video", localMetrics: localMetrics)
    }

    private var localMetrics: [HealthToolbarMetric] {
        [
            HealthToolbarMetric(
                id: "video-status",
                label: "Status",
                value: videoModel.status.label,
                systemImage: "dot.radiowaves.left.and.right",
                tone: statusTone
            ),
            HealthToolbarMetric(
                id: "video-renderer",
                label: "Renderer",
                value: videoModel.previewMode.rawValue,
                systemImage: "sparkles.tv",
                tone: .accent
            ),
            HealthToolbarMetric(
                id: "video-resolution",
                label: "Resolution",
                value: videoModel.videoResolutionText,
                systemImage: "rectangle.expand.vertical",
                tone: .neutral
            ),
            HealthToolbarMetric(
                id: "video-fps",
                label: "FPS",
                value: videoModel.videoFPSText,
                systemImage: "speedometer",
                tone: videoModel.hasReceivedFrame ? .good : .neutral
            ),
            HealthToolbarMetric(
                id: "video-dropped",
                label: "Dropped",
                value: String(videoModel.droppedFrameCount),
                systemImage: "exclamationmark.arrow.trianglehead.counterclockwise",
                tone: videoModel.droppedFrameCount > 0 ? .warning : .neutral
            )
        ]
    }

    private var statusTone: HealthToolbarMetricTone {
        switch videoModel.status {
        case .running:
            return videoModel.hasReceivedFrame ? .good : .warning
        case .starting:
            return .warning
        case .failed:
            return .danger
        case .noCameras:
            return .danger
        case .idle, .ready:
            return .neutral
        }
    }
}

@MainActor
struct VirtualCameraComposerHealthToolbar: View {
    @ObservedObject var composer: VirtualCameraComposerModel
    @ObservedObject var publisher: VirtualCameraPublisher
    @ObservedObject var driverService: VirtualCameraDriverService

    var body: some View {
        SharedHealthToolbar(localSectionTitle: "Composer", localMetrics: localMetrics)
    }

    private var localMetrics: [HealthToolbarMetric] {
        var metrics = [
            HealthToolbarMetric(
                id: "composer-output",
                label: "Output",
                value: outputStateLabel,
                systemImage: "dot.radiowaves.left.and.right",
                tone: outputStateTone
            ),
            HealthToolbarMetric(
                id: "composer-driver",
                label: "Driver",
                value: driverStateLabel,
                systemImage: "camera.macro",
                tone: driverStateTone
            )
        ]

        if let runtime = publisher.runtimeStatus {
            metrics.append(HealthToolbarMetric(
                id: "composer-dal",
                label: "DAL",
                value: runtime.healthState,
                systemImage: "externaldrive.badge.checkmark",
                tone: dalRuntimeTone(runtime)
            ))

            if runtime.startCount > 0 && !runtime.isStale {
                metrics.append(HealthToolbarMetric(
                    id: "composer-consumed-fps",
                    label: "Consumed",
                    value: String(format: "%.0f fps", runtime.frameRate),
                    systemImage: "speedometer",
                    tone: .good
                ))
            }
        } else {
            metrics.append(HealthToolbarMetric(
                id: "composer-dal",
                label: "DAL",
                value: "No Client",
                systemImage: "externaldrive.badge.xmark",
                tone: .neutral
            ))
        }

        metrics.append(contentsOf: [
            HealthToolbarMetric(
                id: "composer-resolution",
                label: "Resolution",
                value: publisher.lastPublishedResolutionText == "—" ? composer.resolution : publisher.lastPublishedResolutionText,
                systemImage: "rectangle.expand.vertical",
                tone: .neutral
            ),
            HealthToolbarMetric(
                id: "composer-fps",
                label: "Publish",
                value: publisher.lastPublishedFrameRateText == "—" ? String(format: "%.0f fps", composer.frameRate) : publisher.lastPublishedFrameRateText,
                systemImage: "speedometer",
                tone: publisher.isRunning ? .good : .neutral
            ),
            HealthToolbarMetric(
                id: "composer-layers",
                label: "Layers",
                value: String(max(publisher.lastPublishedLayerCount, composer.layers.count)),
                systemImage: "square.on.square",
                tone: .accent
            )
        ])

        return metrics
    }

    private var outputStateLabel: String {
        if publisher.isRunning, publisher.lastPublishedFrameSequence != nil {
            return "Publishing"
        }
        if composer.isOutputActive {
            return "Starting"
        }
        return "Idle"
    }

    private var outputStateTone: HealthToolbarMetricTone {
        if publisher.publishFailureCount > 0 {
            return .warning
        }
        if publisher.isRunning, publisher.lastPublishedFrameSequence != nil {
            return .good
        }
        if composer.isOutputActive {
            return .warning
        }
        return .neutral
    }

    private var driverStateLabel: String {
        if driverService.actionInProgress {
            return "Working…"
        }
        if driverService.isInstalled {
            return "Installed"
        }
        if driverService.isBundledPayloadAvailable {
            return "Bundled"
        }
        return "Missing"
    }

    private var driverStateTone: HealthToolbarMetricTone {
        if driverService.actionInProgress {
            return .accent
        }
        if driverService.isInstalled {
            return .good
        }
        if driverService.isBundledPayloadAvailable {
            return .warning
        }
        return .danger
    }

    private func dalRuntimeTone(_ runtime: VirtualCameraDALRuntimeStatus) -> HealthToolbarMetricTone {
        if runtime.isStale { return .neutral }
        if runtime.isFallbackActive { return .warning }
        if runtime.isUsingPublishedSurface { return .good }
        if runtime.isStreamRunning { return .warning }
        return .neutral
    }
}

@MainActor
struct VirtualCameraRuntimeHealthToolbar: View {
    let sectionTitle: String

    @ObservedObject var publisher = VirtualCameraPublisher.shared
    @ObservedObject var composer = VirtualCameraComposerModel.shared
    @ObservedObject var driverService = VirtualCameraDriverService.shared

    var body: some View {
        VirtualCameraComposerHealthToolbar(
            composer: composer,
            publisher: publisher,
            driverService: driverService
        )
    }
}
